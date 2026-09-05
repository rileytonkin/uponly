import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import SwiftUI

@MainActor @Observable
final class UpOnlySession {
    enum State { case newVault, locked, unlocked, recovery }
    private(set) var state: State = .locked
    private(set) var document: VaultDocument?
    private(set) var monthModel: PopoverModel?
    private(set) var isBusy = false
    private(set) var sessionToken = UUID()
    var message: String?
    var destination = 0
    var managementSection = "Accounts"
    private var vault: VaultStore
    var pendingStatement: StatementDraft?
    var choosingStatementAccount = false
    private var refreshTask: Task<Void, Never>?
    private var priceRequest: Task<([QuoteObservation], [FXObservation]), Error>?
    private var catalogRequest: Task<[CatalogCoin], Error>?
    private var sourceRevision = UUID()
    private(set) var catalog: [CatalogCoin] = []
    private(set) var refreshing = false
    var sourceMessage: String?
    let layout: VaultLayout
    let isFixture: Bool
    private var lastActivity = Date()
    private var financeSurfaces = 0
    private var pickerDepth = 0
    private var observers: [NSObjectProtocol] = []
    private var inactivityTimer: Timer?
    private var eventMonitor: Any?
    #if UPONLY_FIXTURE
    @ObservationIgnored private var previewWindow: NSWindow?
    #endif

    init() {
        #if UPONLY_FIXTURE
        isFixture = true
        #else
        isFixture = false
        #endif
        layout = VaultLayout(root: Config.supportDirectory.appendingPathComponent("Vault", isDirectory: true))
        #if UPONLY_FIXTURE
        vault = VaultStore(layout: layout, io: DiskFileIO(), keys: MemoryKeyStore(), authenticator: FixtureAuthenticator())
        #else
        vault = VaultStore(layout: layout, io: DiskFileIO(), keys: KeychainVaultKeyStore(), authenticator: LiveAuthenticator())
        #endif
        state = FileManager.default.fileExists(atPath: layout.current.path) ? .locked : .newVault
        if !isFixture { installLockObservers() }
        #if UPONLY_FIXTURE
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            Task { await prepareFixture() }
        }
        #endif
    }

    func unlock() async {
        guard !isBusy else { return }
        let token = sessionToken
        isBusy = true; message = nil
        defer { if sessionToken == token { isBusy = false } }
        do {
            let opened = try await vault.unlock()
            guard sessionToken == token else { return }
            publish(opened.document, freshUnlock: true)
        } catch VaultError.needsRecovery { if sessionToken == token { state = .recovery } }
        catch VaultError.cancelled { }
        catch { if sessionToken == token { message = "Your vault could not be opened. Use your recovery code, or restore a backup into a fresh installation." } }
    }

    func create(recovery: RecoveryCode, confirmation: String) async {
        guard !isBusy else { return }
        let token = sessionToken
        isBusy = true; message = nil
        defer { if sessionToken == token { isBusy = false } }
        do {
            let opened = try await vault.create(recovery: recovery, confirmation: confirmation)
            guard sessionToken == token else { return }
            publish(opened.document, freshUnlock: true)
        } catch VaultError.confirmationMismatch { if sessionToken == token { message = "The recovery code does not match. Check the saved copy and try again." } }
        catch VaultError.cancelled { }
        catch { if sessionToken == token { if FileManager.default.fileExists(atPath: layout.current.path) { state = .recovery }; message = "Setup could not finish. Keep your recovery code; no existing vault was replaced." } }
    }

    func recover(code: String) async {
        guard !isBusy else { return }
        let token = sessionToken
        isBusy = true; message = nil
        defer { if sessionToken == token { isBusy = false } }
        do {
            let opened = try await vault.recover(RecoveryCode(canonical: code))
            guard sessionToken == token else { return }
            publish(opened.document, freshUnlock: true)
        } catch VaultError.cancelled { }
        catch { if sessionToken == token { message = "That recovery code could not open this vault." } }
    }

    func lock() {
        refreshTask?.cancel(); refreshTask = nil
        priceRequest?.cancel(); priceRequest = nil
        catalogRequest?.cancel(); catalogRequest = nil
        sourceRevision = UUID()
        choosingStatementAccount = false
        pendingStatement = nil; catalog = []; sourceMessage = nil; refreshing = false
        vault.lock()
        sessionToken = UUID()
        document = nil
        monthModel = nil
        destination = 0
        message = nil
        isBusy = false
        state = FileManager.default.fileExists(atPath: layout.current.path) ? .locked : .newVault
    }

    private func publish(_ document: VaultDocument, freshUnlock: Bool = false) {
        self.document = document
        if freshUnlock || monthModel == nil {
            destination = 0
            let model = PopoverModel()
            model.owner = self
            monthModel = model
        }
        monthModel?.replace(with: document)
        state = .unlocked
        lastActivity = Date()
        if freshUnlock { scheduleRefresh(); reconsiderClosedSurfaces() }
    }

    func mutate(_ edit: (inout VaultDocument) throws -> Void) async throws {
        guard state == .unlocked, !isBusy else { throw VaultError.locked }
        let token = sessionToken
        isBusy = true
        defer { if token == sessionToken { isBusy = false } }
        let current = try await vault.currentSession()
        guard token == sessionToken else { throw VaultError.locked }
        var next = current.document
        try edit(&next)
        next.reviewedMonths.removeAll { month in
            current.document.entries.filter { $0.month == month } != next.entries.filter { $0.month == month }
        }
        let now = Date()
        let scopes: [ValuationScope] = [.allTracked, .banks] + next.portfolios.map { .portfolio($0.id) }
        for scope in scopes {
            next = NetWorthCalculator.recordingSample(
                NetWorthCalculator.value(at: now, scope: scope, document: next, now: now), in: next
            )
        }
        next.generation = current.document.generation + 1
        try await vault.commit(next, expectedGeneration: current.document.generation, sessionID: current.sessionID)
        guard token == sessionToken else { throw VaultError.locked }
        publish(next)
    }

    func perform(_ edit: (inout VaultDocument) throws -> Void) async {
        let token = sessionToken
        do { try await mutate(edit); message = nil }
        catch { if token == sessionToken { message = error as? VaultError == .oversizedVault ? "This vault has reached its 128 MB limit. The last saved version is unchanged and can still be backed up." : "Your change could not be saved. Please try again." } }
    }

    func importStatement(_ draft: StatementDraft) async throws {
        try await mutate { doc in
            guard doc.accounts.contains(where: { $0.id == draft.accountID }) else { throw VaultError.invalidAmount }
            guard !doc.importedStatements.contains(where: { $0.digest == draft.digest }) else { throw StatementError.duplicate }
            let references = Set(doc.entries.compactMap(\.sourceRef))
            doc.entries.append(contentsOf: draft.entries.filter { !references.contains($0.sourceRef ?? "") })
            doc.importedStatements.append(ImportedStatement(digest: draft.digest, originalBytes: draft.bytes, importedAt: Date()))
            let months = Set(draft.entries.map(\.month))
            doc.reviewedMonths.removeAll { months.contains($0) }
        }
    }

    func addPortfolio(name: String) async throws {
        let clean = try Self.name(name)
        try await mutate { document in
            guard !document.portfolios.contains(where: { !$0.isArchived && $0.name.caseInsensitiveCompare(clean) == .orderedSame })
            else { throw VaultError.invalidAmount }
            document.portfolios.append(Portfolio(name: clean))
        }
    }

    func addAccount(name: String, currency: String, balance: String, date: Date) async throws {
        let clean = try Self.name(name)
        let code = try MoneyInput.normalizeCurrency(currency)
        let amount = try MoneyInput.parseExact(balance)
        guard date <= Date().addingTimeInterval(300) else { throw VaultError.observationInFuture }
        try await mutate { document in
            let account = Account(name: clean, currency: code)
            document.accounts.append(account)
            document.setBankTracked(account.id, tracked: true, at: date)
            document.bankBalances.append(BankBalanceObservation(
                id: UUID(), accountID: account.id, amount: PreciseDecimal(amount), currency: code,
                observedAt: date, source: "manual", sourceIdentity: account.id.uuidString
            ))
        }
    }

    func updateBalance(account: Account, text: String, date: Date) async throws {
        let amount = try MoneyInput.parseExact(text)
        guard date <= Date().addingTimeInterval(300) else { throw VaultError.observationInFuture }
        try await mutate { document in
            guard document.accounts.contains(where: { $0.id == account.id }) else { throw VaultError.invalidAmount }
            document.bankBalances.append(BankBalanceObservation(
                id: UUID(), accountID: account.id, amount: PreciseDecimal(amount), currency: account.currency,
                observedAt: date, source: "manual", sourceIdentity: account.id.uuidString
            ))
        }
    }

    static func name(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw VaultError.invalidAmount }
        return name
    }

    func surfaceOpened() { financeSurfaces += 1; lastActivity = Date() }
    func surfaceClosed() {
        financeSurfaces = max(0, financeSurfaces - 1)
        reconsiderClosedSurfaces()
    }
    private func reconsiderClosedSurfaces() {
        guard !isFixture else { return }
        let token = sessionToken
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            if token == sessionToken && financeSurfaces == 0 && pickerDepth == 0 { lock() }
        }
    }
    private func pickerFinished() {
        pickerDepth = max(0, pickerDepth - 1)
        reconsiderClosedSurfaces()
    }

    func chooseStatements(accountID: UUID? = nil) async {
        guard state == .unlocked else { return }
        guard let accountID else { choosingStatementAccount = true; return }
        guard document?.accounts.contains(where: { $0.id == accountID }) == true else {
            message = "Choose an account before importing its statement."; return
        }
        pickerDepth += 1; defer { pickerFinished() }
        let token = sessionToken
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.commaSeparatedText]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard await panel.begin() == .OK, let url = panel.url, token == sessionToken else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= VaultLimits.maxBatchBytes else { throw StatementError.tooLarge }
            let bytes = try Data(contentsOf: url)
            let draft = try StatementParser.read(bytes, filename: url.lastPathComponent, accountID: accountID)
            guard !document!.importedStatements.contains(where: { $0.digest == draft.digest }) else { throw StatementError.duplicate }
            pendingStatement = draft
        } catch { message = (error as? StatementError)?.localizedDescription ?? "That statement could not be read." }
    }

    func exportBackup() async {
        guard state == .unlocked else { return }
        pickerDepth += 1
        defer { pickerFinished() }
        let token = sessionToken
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Up Only Backup.uponlybackup"
        panel.canCreateDirectories = true
        guard await panel.begin() == .OK, let url = panel.url, token == sessionToken else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let package = try await BackupCoordinator.makePackage(store: vault, producers: [])
            guard token == sessionToken else { throw VaultError.locked }
            try BackupCoordinator.publish(package, to: url, io: DiskFileIO())
            message = "Encrypted backup saved. Keep your recovery code separately."
        } catch { if token == sessionToken { message = "Backup could not be saved. Choose a new filename and try again." } }
    }

    private func installLockObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.lock() }
            })
        }
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.lock() } })
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
            self?.lastActivity = Date()
            return event
        }
        inactivityTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .unlocked else { return }
                if Date().timeIntervalSince(self.lastActivity) >= 300 { self.lock() }
            }
        }
    }

    #if UPONLY_FIXTURE
    private func prepareFixture() async {
        let code = RecoveryCode.random()
        do {
            _ = try await vault.create(recovery: code, confirmation: code.canonical)
            let opened = try await vault.currentSession()
            var fixture = opened.document
            if ProcessInfo.processInfo.environment["UPONLY_PREVIEW_DESTINATION"] != "setup" { fixture = try UpOnlyFixture.document(from: fixture) }
            fixture.generation = opened.document.generation + 1
            try await vault.commit(fixture, expectedGeneration: opened.document.generation, sessionID: opened.sessionID)
            publish(fixture, freshUnlock: true)
            if ProcessInfo.processInfo.environment["UPONLY_PREVIEW_DESTINATION"] == "networth" { destination = 1 }
            let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 344, height: 480), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Up Only Preview"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: UpOnlyPanel().environment(self))
            previewWindow = window
            window.orderBack(nil)
            if ProcessInfo.processInfo.environment["UPONLY_PREVIEW_CAPTURE"] == "1" {
                try? await Task.sleep(for: .milliseconds(300))
                if let content = window.contentView {
                    content.layoutSubtreeIfNeeded()
                    if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                        content.cacheDisplay(in: content.bounds, to: bitmap)
                        if let png = bitmap.representation(using: .png, properties: [:]) {
                            let url = Config.supportDirectory.appendingPathComponent("preview.png")
                            try png.write(to: url)
                            print("UPONLY_SYNTHETIC_RENDER=" + url.path)
                        }
                    }
                }
            }
        } catch { message = "The isolated preview could not start." }
    }
    #endif
}

extension UpOnlySession {
    func scheduleRefresh() {
        guard !isFixture else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.state == .unlocked else { return }
                await self.refreshPrices()
                do { try await Task.sleep(for: .seconds(15 * 60)) } catch { return }
            }
        }
    }
    func refreshPrices() async {
        guard state == .unlocked, !refreshing, !isFixture, let doc = document else { return }
        let token = sessionToken, revision = sourceRevision
        let ids = doc.holdings.filter { $0.isActive(at: Date()) && doc.portfolio(id: $0.portfolioID)?.isActive(at: Date()) == true }.map { $0.assetID.rawValue }
        let currencies = Set(doc.accounts.map(\.currency) + doc.entries.map(\.currency))
        let settings = doc.settings
        refreshing = true
        defer { if token == sessionToken { refreshing = false } }
        do {
            let request = Task {
                let quotes = settings.automaticPrices ? try await PublicPrices.quotes(ids: ids, key: settings.coinGeckoKey) : []
                let rates = settings.automaticFX ? try await PublicPrices.fx(currencies: currencies) : []
                return (quotes, rates)
            }
            priceRequest = request
            let (quotes, rates) = try await request.value
            guard token == sessionToken, revision == sourceRevision, !Task.isCancelled else { return }
            priceRequest = nil
            if quotes.isEmpty && rates.isEmpty { return }
            try await mutate { doc in
                for quote in quotes where !doc.quotes.contains(where: { $0.assetID == quote.assetID && $0.providerTime == quote.providerTime }) { doc.quotes.append(quote) }
                for rate in rates where !doc.fx.contains(where: { $0.sourceCurrency == rate.sourceCurrency && $0.providerTime == rate.providerTime }) { doc.fx.append(rate) }
            }
            sourceMessage = "Updated " + Date().formatted(date: .omitted, time: .shortened)
        } catch {
            if token == sessionToken, revision == sourceRevision, !Task.isCancelled { sourceMessage = (error as? PriceError)?.localizedDescription ?? "Prices could not refresh. Saved observations are unchanged." }
        }
    }
    func loadCatalog() async {
        guard state == .unlocked, !isFixture, let settings = document?.settings, settings.automaticPrices else { return }
        let token = sessionToken
        do {
            catalogRequest?.cancel()
            let request = Task { try await PublicPrices.catalog(key: settings.coinGeckoKey) }
            catalogRequest = request
            let coins = try await request.value
            if token == sessionToken { catalog = coins }
        } catch { if token == sessionToken { sourceMessage = (error as? PriceError)?.localizedDescription ?? "The coin list could not be loaded. You can enter its CoinGecko ID manually." } }
    }
    func saveSources(prices: Bool, fx: Bool, key: String) async throws {
        guard key.utf8.count <= 512, !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw VaultError.invalidAmount }
        refreshTask?.cancel(); refreshTask = nil
        priceRequest?.cancel(); priceRequest = nil
        catalogRequest?.cancel(); catalogRequest = nil
        sourceRevision = UUID()
        try await mutate { doc in doc.settings.automaticPrices = prices; doc.settings.automaticFX = fx; doc.settings.coinGeckoKey = key }
        scheduleRefresh()
    }
    func restoreBackup(code: String) async {
        guard state == .newVault, !isBusy else { return }
        pickerDepth += 1; defer { pickerFinished() }
        let token = sessionToken
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard await panel.begin() == .OK, let url = panel.url, token == sessionToken else { return }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        isBusy = true; defer { if token == sessionToken { isBusy = false } }
        do {
            let package = try BackupCoordinator.read(from: url, io: DiskFileIO())
            let recovery = try RecoveryCode(canonical: code)
            #if UPONLY_FIXTURE
            let keys: VaultKeyStoring = MemoryKeyStore()
            let auth: VaultAuthenticating = FixtureAuthenticator()
            #else
            let keys: VaultKeyStoring = KeychainVaultKeyStore()
            let auth: VaultAuthenticating = LiveAuthenticator()
            #endif
            try await auth.evaluate()
            guard token == sessionToken else { throw VaultError.locked }
            try await vault.releaseEmptyDestination()
            _ = try BackupCoordinator.restore(package: package, recovery: recovery, keys: keys, layout: layout, io: DiskFileIO(), authenticator: auth)
            vault = VaultStore(layout: layout, io: DiskFileIO(), keys: keys, authenticator: auth)
            let opened = try await vault.unlock()
            guard token == sessionToken else { return }
            publish(opened.document, freshUnlock: true)
        } catch { if token == sessionToken { message = "Restore failed. Check the backup and recovery code. An existing vault is never replaced." } }
    }
}
