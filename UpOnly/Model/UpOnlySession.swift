import AppKit
import Foundation
import os
import Observation
import UniformTypeIdentifiers
import SwiftUI
import Darwin
import Network
import LocalAuthentication

@MainActor @Observable
final class UpOnlySession {
    enum State { case newVault, locked, unlocked, recovery }
    private(set) var state: State = .locked
    private(set) var document: VaultDocument?
    private(set) var monthModel: PopoverModel?
    private(set) var isBusy = false
    private(set) var sessionToken = UUID()
    var message: String?
    private(set) var fxIssues: [String: String] = [:]
    /// Last manual or scheduled update's problem per price source ("crypto", "metals", "fx"), cleared on success.
    private(set) var sourceIssues: [String: String] = [:]
    var destination = 0
    var addingInMenu = false
    var managementInMenu = false
    var managementSection = "Accounts"
    var entryMonthForManagement = ""
    var requestedRateCurrency: String?
    private var vault: VaultStore
    @ObservationIgnored private var liveAuthenticator: LiveAuthenticator?
    private(set) var authenticationContext: LAContext?
    private(set) var passwordUnlockRequested = false
    private(set) var authenticationFailed = false
    @ObservationIgnored private(set) var unlockTiming: UnlockTiming?
    var privacyMode: Bool { document?.settings.privacyMode == true }
    var importDraft: ImportBatchDraft?
    var importMode: ImportMode = .statements
    var importTableMode = false
    private(set) var importReturnSection = "Add your info"
    // An import started from the home + button returns to the overview when it ends.
    var importReturnsHome = false
    // The single-entry form shows its own Back; the Manage header steps aside.
    var entryEditorInMenu = false
    var importMessage: String?
    private(set) var importLoading = false
    private(set) var importRevision = UUID()
    @ObservationIgnored private var importTask: Task<ImportBatchDraft, Error>?
    @ObservationIgnored private var preparedMutation: Task<VaultDocument, Error>?
    private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundCacheRequest: Task<(packets: [BackgroundPacket], issues: [String]), Never>?
    private(set) var backgroundCheckedAt: Date?
    private(set) var backgroundIssues: [String] = []
    private var priceRequest: Task<PriceUpdate, Error>?
    /// True while `priceRequest` is a scheduled catch-up, which a manual refresh may pre-empt.
    private var priceRequestIsAutomatic = false
    @ObservationIgnored private var networkMonitor: NWPathMonitor?
    private var networkAvailable = true
    private var catalogRequest: Task<[CatalogCoin], Error>?
    private var sourceRevision = UUID()
    private(set) var catalog: [CatalogCoin] = []
    private(set) var refreshing = false
    var attentionIncludesPerformance = false
    var sourceMessage: String?
    private(set) var setupProgressMessage: String?
    @ObservationIgnored private var pendingSetupProgress: SetupProgress?
    @ObservationIgnored private var setupProgressTask: Task<Void, Never>?
    let layout: VaultLayout
    let isFixture: Bool
    #if UPONLY_PERSONAL
    private(set) var accountingRefreshing = false
    private(set) var accountingError: String?
    @ObservationIgnored private var accountingRequest: Task<AccountingFetch, Error>?
    private(set) var wiseProfiles: [WiseConfiguredProfile] = []
    private(set) var wiseRefreshing = false
    var wiseMessage: String?
    private(set) var wiseError: String?
    @ObservationIgnored private var wiseRequest: Task<WiseSnapshot, Error>?
    #endif
    private var lastActivity = Date()
    private var financeSurfaces = 0
    private var pickerDepth = 0
    @ObservationIgnored private var activeFilePanel: NSSavePanel?
    var filePickerIsOpen: Bool { pickerDepth > 0 }
    /// True while the statement drop zone is on screen, so a drag from Finder does not dismiss the menu.
    var dropZoneVisible = false
    var menuStaysOpen: Bool { filePickerIsOpen || (state == .unlocked && dropZoneVisible) }
    func focusFilePicker() {
        NSApp.activate(ignoringOtherApps: true)
        activeFilePanel?.makeKeyAndOrderFront(nil)
        activeFilePanel?.orderFrontRegardless()
    }
    private func presentFilePanel(_ panel: NSSavePanel) async -> NSApplication.ModalResponse {
        let token = sessionToken
        activeFilePanel = panel
        defer { if activeFilePanel === panel { activeFilePanel = nil } }
        // This is an explicit user request to open a dialog. Cooperative
        // activation alone can leave an accessory app’s panel behind another app.
        NSApp.activate(ignoringOtherApps: true)
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        // Yield so popover lifetime observation sees pickerDepth before another
        // window takes focus. Present the system panel above the menu surface.
        await Task.yield()
        guard token == sessionToken else { return .cancel }
        return await withCheckedContinuation { continuation in
            panel.begin { response in continuation.resume(returning: response) }
            panel.makeKeyAndOrderFront(nil)
            panel.orderFrontRegardless()
        }
    }
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
        let authenticator = LiveAuthenticator()
        liveAuthenticator = authenticator
        vault = VaultStore(layout: layout, io: DiskFileIO(), keys: KeychainVaultKeyStore(), authenticator: authenticator)
        #endif
        state = vault.io.fileExists(at: layout.current) ? .locked : .newVault
        if !isFixture {
            installLockObservers()
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                let available = path.status == .satisfied
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let reconnected = available && !self.networkAvailable
                    self.networkAvailable = available
                    if reconnected { self.startBackgroundRefresh() }
                }
            }
            monitor.start(queue: DispatchQueue(label: "org.uponly.network"))
            networkMonitor = monitor
            startBackgroundRefresh()
        }
        #if UPONLY_FIXTURE
        if ProcessInfo.processInfo.environment["UPONLY_PREVIEW_IDLE_LOCK"] == "1" { installLockObservers() }
        #endif
        #if UPONLY_PERSONAL
        if !isFixture {
            wiseProfiles = (try? WiseConnection.load())?.profiles ?? []
            if ProcessInfo.processInfo.environment["UPONLY_PERSONAL_VERIFY"] == "1" {
                Task {
                    do {
                        let snapshot = try await WiseAPI.fetch(WiseConnection.load())
                        let pair = VaultCrypto.makeInboxKeyPair()
                        let empty = VaultDocument.empty(inboxPrivateKeyX963: pair.privateX963, inboxPublicKeyX963: pair.publicX963)
                        let imported = try WiseAPI.apply(snapshot, to: empty)
                        print("UPONLY_WISE_VERIFIED profiles=\(snapshot.profiles.count) accounts=\(imported.accounts.count) transactions=\(imported.entries.count) images=\(snapshot.profiles.filter { $0.profile.image != nil }.count)")
                    } catch { print("UPONLY_WISE_VERIFY_FAILED " + error.localizedDescription) }
                    fflush(stdout)
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        #endif
        #if UPONLY_FIXTURE
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            Task { await prepareFixture() }
        }
        #endif
    }

    #if UPONLY_FIXTURE
    init(testing vault: VaultStore, layout: VaultLayout) {
        self.vault = vault; self.layout = layout; self.isFixture = true; self.state = .newVault
    }
    #endif

    func beginUnlock(usePassword: Bool = false) {
        guard state == .locked, !passwordUnlockRequested else { return }
        if usePassword {
            // Fence the old evaluation before replacing it. Its delayed reply must
            // never clear or publish the new password attempt.
            lock()
            passwordUnlockRequested = true
            liveAuthenticator?.preparePassword()
            NSApp.activate()
        } else {
            guard !isBusy, authenticationContext == nil else { return }
        }
        authenticationFailed = false
        let context = LAContext()
        if !usePassword, let liveAuthenticator,
           context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) {
            liveAuthenticator.prepareEmbedded(context)
            authenticationContext = context
            // The embedded view starts evaluation only after attaching this context.
        } else {
            let token = sessionToken
            Task {
                guard token == sessionToken, state == .locked else { return }
                await unlock()
            }
        }
    }

    func unlockEmbedded(_ context: LAContext) async {
        guard authenticationContext === context else { return }
        await unlock()
    }

    func unlock() async {
        guard !isBusy else { return }
        let token = sessionToken
        isBusy = true; message = nil; authenticationFailed = false
        defer { if sessionToken == token { isBusy = false; authenticationContext = nil; passwordUnlockRequested = false } }
        do {
            let timing = ProcessInfo.processInfo.environment["UPONLY_MEASURE_UNLOCK"] == "1"
                ? UnlockTiming(method: passwordUnlockRequested ? "password" : authenticationContext != nil ? "touch_id" : "system") : nil
            let opened = try await vault.unlock(timing: timing)
            guard sessionToken == token else { return }
            unlockTiming = timing
            publish(opened.document, freshUnlock: true)
            timing?.mark("dashboard_published")
        } catch VaultError.needsRecovery { if sessionToken == token { state = .recovery } }
        catch VaultError.cancelled { if sessionToken == token { authenticationFailed = true } }
        catch VaultError.keychainUnavailable(_) { if sessionToken == token { authenticationFailed = true; message = "macOS couldn’t access this app’s secure storage. Please reopen the updated app and try again." } }
        catch { if sessionToken == token { authenticationFailed = true; message = "Your vault could not be opened. Please try unlocking again." } }
    }

    func recordUnlockedMenuDisplay() {
        guard state == .unlocked, let timing = unlockTiming else { return }
        unlockTiming = nil
        timing.finish(at: Config.supportDirectory.appendingPathComponent("unlock-timing.json"))
    }

    func create(recovery: RecoveryCode) async {
        guard !isBusy else { return }
        let token = sessionToken
        isBusy = true; message = nil
        defer { if sessionToken == token { isBusy = false } }
        do {
            let opened = try await vault.create(recovery: recovery, confirmation: recovery.canonical)
            guard sessionToken == token else { return }
            publish(opened.document, freshUnlock: true)
        } catch VaultError.cancelled { }
        catch {
            if sessionToken == token {
                state = vault.io.fileExists(at: layout.current) ? .locked : .newVault
                message = state == .newVault
                    ? "Your vault could not be created. Setup hasn’t finished; please try again."
                    : "Setup could not finish. Your saved vault is still here; try unlocking to continue."
            }
        }
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

    func returnToUnlock() {
        guard !isBusy, state != .unlocked else { return }
        state = vault.io.fileExists(at: layout.current) ? .locked : .newVault
        message = nil
    }

    func lockAndAuthenticate() {
        lock()
        beginUnlock()
    }

    func lock() {
        activeFilePanel?.cancel(nil)
        unlockTiming = nil
        authenticationContext?.invalidate(); authenticationContext = nil
        passwordUnlockRequested = false
        authenticationFailed = false
        setupProgressTask?.cancel(); setupProgressTask = nil; pendingSetupProgress = nil; setupProgressMessage = nil
        preparedMutation?.cancel(); preparedMutation = nil
        #if UPONLY_PERSONAL
        accountingRequest?.cancel(); accountingRequest = nil; accountingRefreshing = false; accountingError = nil
        wiseRequest?.cancel(); wiseRequest = nil; wiseRefreshing = false; wiseMessage = nil; wiseError = nil
        #endif
        refreshTask?.cancel(); refreshTask = nil
        backgroundCacheRequest?.cancel(); backgroundCacheRequest = nil
        priceRequest?.cancel(); priceRequest = nil
        catalogRequest?.cancel(); catalogRequest = nil
        sourceRevision = UUID()
        cancelImport(); importDraft = nil; importMessage = nil; catalog = []; sourceMessage = nil; refreshing = false
        addingInMenu = false
        managementInMenu = false
        importReturnsHome = false
        entryEditorInMenu = false
        entryMonthForManagement = ""
        requestedRateCurrency = nil
        fxIssues = [:]
        vault.lock()
        sessionToken = UUID()
        document = nil
        monthModel = nil
        destination = 0
        message = nil
        isBusy = false
        state = vault.io.fileExists(at: layout.current) ? .locked : .newVault
    }

    private func publish(_ document: VaultDocument, freshUnlock: Bool = false) {
        self.document = document
        if freshUnlock || monthModel == nil {
            let model = PopoverModel()
            model.owner = self
            monthModel = model
        }
        if freshUnlock || !document.showsDestination(destination) { destination = document.defaultDestination }
        if freshUnlock || !document.showsSection(managementSection) { managementSection = document.defaultManagementSection }
        monthModel?.replace(with: document)
        state = .unlocked
        if freshUnlock { recordActivity(); scheduleRefresh() }
        else if !isFixture { Task { await Task.yield(); await self.configureBackground() } }
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
        try await persist(next, replacing: current, token: token)
    }

    private func persist(_ proposed: VaultDocument, replacing current: VaultSession, token: UUID) async throws {
        guard token == sessionToken, state == .unlocked else { throw VaultError.locked }
        var next = proposed
        let addedAccount = next.accounts.contains { account in !current.document.accounts.contains { $0.id == account.id } }
        next.reviewedMonths.removeAll { month in
            addedAccount || current.document.entries.filter { $0.month == month } != next.entries.filter { $0.month == month }
        }
        let now = Date()
        // A backdated quantity changes past days; recompute them away from the main actor.
        let backdated = next.quantities.filter { $0.ordinal >= current.document.nextOrdinal }.map(\.effectiveAt).min()
        if let backdated, backdated < UTCDay.start(of: now) {
            let proposed = next
            next = await Task.detached(priority: .userInitiated) { HoldingMutations.rebuildHistory(from: backdated, document: proposed, now: now) }.value
            guard token == sessionToken, state == .unlocked else { throw VaultError.locked }
        }
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

    private func mutatePrepared(_ prepare: @escaping @Sendable (VaultDocument) throws -> VaultDocument) async throws {
        guard state == .unlocked, !isBusy else { throw VaultError.locked }
        let token = sessionToken; isBusy = true
        defer { if token == sessionToken { isBusy = false; preparedMutation = nil } }
        let current = try await vault.currentSession()
        guard token == sessionToken else { throw VaultError.locked }
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let next = try prepare(current.document)
            try Task.checkCancellation()
            return next
        }
        preparedMutation = task
        let next = try await task.value
        guard token == sessionToken, !task.isCancelled else { throw VaultError.locked }
        try await persist(next, replacing: current, token: token)
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
            doc.entries.append(contentsOf: draft.entries.filter { !references.contains($0.sourceRef ?? "") }); doc.track(.cashFlow)
            doc.importedStatements.append(ImportedStatement(digest: draft.digest, originalBytes: draft.bytes, importedAt: Date()))
            let months = Set(draft.entries.map(\.month))
            doc.reviewedMonths.removeAll { months.contains($0) }
        }
    }

    func addPortfolio(name: String, ownerBusinessID: String? = nil) async throws {
        let clean = try Self.name(name)
        try await mutate { document in
            guard !document.portfolios.contains(where: { !$0.isArchived && $0.name.caseInsensitiveCompare(clean) == .orderedSame })
            else { throw VaultError.invalidAmount }
            if let ownerBusinessID, !(document.businessAccounting ?? []).contains(where: { $0.id == ownerBusinessID }) { throw VaultError.invalidAmount }
            document.portfolios.append(Portfolio(name: clean, ownerBusinessID: ownerBusinessID)); document.track(.crypto)
        }
    }

    func addAccount(name: String, currency: String, balance: String, date: Date) async throws {
        let clean = try Self.name(name)
        let code = try MoneyInput.normalizeCurrency(currency)
        let amount = try MoneyInput.parseExact(balance)
        guard date <= Date().addingTimeInterval(300) else { throw VaultError.observationInFuture }
        try await mutate { document in
            let account = Account(name: clean, currency: code)
            document.accounts.append(account); document.track(.banks)
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

    static let inactivityInterval: TimeInterval = 5 * 60
    func recordActivity(at date: Date = Date()) { lastActivity = date }
    func handleActivity(at date: Date = Date()) {
        // App Nap can delay timer delivery while the menu is closed. An expired
        // session must lock before a new click can restart its idle period.
        checkInactivity(at: date)
        recordActivity(at: date)
    }
    func checkInactivity(at date: Date = Date()) {
        guard state == .unlocked, date.timeIntervalSince(lastActivity) >= Self.inactivityInterval else { return }
        lock()
    }
    func togglePrivacyMode() async throws {
        recordActivity()
        try await mutate { $0.settings.privacyMode.toggle() }
    }

    func menuOpened() {
        surfaceOpened()
        // One attempt per opening. Reopening retries after cancellation;
        // changes to the lock view must not immediately prompt again.
        if state == .locked { beginUnlock() }
        else if state == .unlocked { Task { await self.applyBackgroundCache() } }
    }
    func surfaceOpened() { financeSurfaces += 1; handleActivity() }
    func surfaceClosed() {
        dropZoneVisible = false
        financeSurfaces = max(0, financeSurfaces - 1)
        // Dismissing a popover keeps the vault available for the remaining idle period.
        if financeSurfaces == 0, authenticationContext != nil { lock() }
    }
    private func pickerFinished() {
        pickerDepth = max(0, pickerDepth - 1)
        recordActivity()
    }

    @discardableResult
    func startImport(_ mode: ImportMode, prefill: Bool = false, accountID: UUID? = nil, portfolioID: UUID? = nil, holdingID: UUID? = nil) -> Bool {
        guard state == .unlocked, let document else { return false }
        guard importDraft == nil else {
            managementSection = "Add your info"
            importMessage = "Your unfinished draft is still here. Save it or go back before starting another."
            return false
        }
        importReturnSection = managementSection
        cancelImport(); importMessage = nil; importMode = mode; importTableMode = false; managementSection = "Add your info"
        var batch = ImportBatchDraft(mode: mode)
        var source = ImportSourceDraft(filename: prefill ? "Current balances" : "Manual entry", bytes: Data(), grid: [])
        source.hasHeader = false
        if let id = accountID, let account = document.accounts.first(where: { $0.id == id }) {
            source.account = ImportAccount(existingID: id, name: account.name, currency: account.currency)
        }
        batch.sources = [source]
        if prefill, mode == .bankBalances {
            batch.rows = document.accounts.filter { accountID == nil || $0.id == accountID }.enumerated().map { index, account in
                let balance = document.bankBalances.filter { $0.accountID == account.id }.max { $0.observedAt < $1.observedAt }
                return ImportDraftRow(sourceID: source.id, line: index + 1, content: .bankBalance(BankBalanceInput(account: ImportAccount(existingID: account.id, name: account.name, currency: account.currency), balance: balance.map { UpOnlyFormat.quantity($0.amount.value) } ?? "")))
            }
        } else if prefill, mode.isHolding {
            batch.rows = document.holdings.filter { $0.isActive(at: Date()) && document.portfolio(id: $0.portfolioID)?.isActive(at: Date()) == true && document.portfolio(id: $0.portfolioID)?.kind == mode.kind && (holdingID == nil || $0.id == holdingID) && (portfolioID == nil || $0.portfolioID == portfolioID) }.enumerated().map { index, holding in
                ImportDraftRow(sourceID: source.id, line: index + 1, content: .holding(HoldingInput(portfolioID: holding.portfolioID, portfolioName: document.portfolio(id: holding.portfolioID)?.name ?? "", coin: holding.assetID.rawValue, resolvedCoinID: holding.assetID.rawValue, assetName: holding.assetName, quantity: document.effectiveQuantity(holdingID: holding.id, at: Date()).map(UpOnlyFormat.quantity) ?? "0")))
            }
        } else if mode.isHolding, let portfolioID, let portfolio = document.portfolio(id: portfolioID), !portfolio.isArchived, portfolio.kind == mode.kind {
            batch.rows = [ImportDraftRow(sourceID: source.id, line: 1, content: .holding(HoldingInput(portfolioID: portfolioID, portfolioName: portfolio.name)))]
        }
        importDraft = batch
        return true
    }
    func discardImport() {
        cancelImport(); importDraft = nil; importMessage = nil; managementSection = importReturnSection
        finishHomeImport(saved: false)
    }
    private func finishHomeImport(saved: Bool) {
        guard importReturnsHome else { return }
        importReturnsHome = false; managementInMenu = false; addingInMenu = false
        if saved { message = "Statement imported." }
    }
    func cancelImport() {
        importTask?.cancel(); importTask = nil; importLoading = false; importRevision = UUID()
    }
    func chooseStatements(accountID: UUID? = nil) async {
        if importDraft?.mode != .statements { startImport(.statements, accountID: accountID) }
        guard importDraft?.mode == .statements else { return }
        await chooseImportFiles()
    }
    func chooseImportFiles() async {
        guard state == .unlocked, !importLoading, !filePickerIsOpen else { focusFilePicker(); return }
        pickerDepth += 1; defer { pickerFinished() }
        let token = sessionToken
        let panel = NSOpenPanel(); panel.allowedContentTypes = importDraft?.mode == .statements ? [.commaSeparatedText] : [.commaSeparatedText, .tabSeparatedText, .plainText]
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        guard await presentFilePanel(panel) == .OK, token == sessionToken else { return }
        await readImportFiles(panel.urls)
    }
    func readImportFiles(_ urls: [URL]) async {
        let urls = urls.map { ($0 as NSURL).filePathURL ?? $0 }
        guard state == .unlocked, !importLoading else { return }
        if importDraft == nil { startImport(importMode) }
        guard let draft = importDraft else { return }
        if draft.mode == .statements, urls.contains(where: { $0.pathExtension.lowercased() != "csv" }) {
            importMessage = "Choose CSV files for statements."
            return
        }
        let token = sessionToken, revision = UUID(); importRevision = revision
        importLoading = true; importMessage = "Reading files…"
        let accounts = document?.accounts ?? []
        let importDocument = document
        let task = Task.detached(priority: .userInitiated) { () throws -> ImportBatchDraft in
            var next = draft
            guard urls.count + next.sources.filter({ !$0.grid.isEmpty }).count <= ImportBatchDraft.maxFiles else { throw ImportFailure("Choose at most 50 files.") }
            let defaultAccount = next.sources.first?.account ?? ImportAccount()
            if next.rows.isEmpty { next.sources.removeAll { $0.grid.isEmpty } }
            for url in urls {
                try Task.checkCancellation()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= VaultLimits.maxBatchBytes else { throw StatementError.tooLarge }
                let bytes = try Data(contentsOf: url)
                var source = try ImportParser.source(bytes: bytes, filename: url.lastPathComponent, mode: next.mode, pasted: url.pathExtension.lowercased() == "tsv")
                source.account = ImportParser.account(for: source, preferred: defaultAccount, saved: accounts)
                var rows = try ImportParser.rows(source: source, mode: next.mode)
                if next.mode == .statements, let importDocument {
                    for index in rows.indices where rows[index].statement.originalType.isEmpty {
                        let input = rows[index].statement
                        if let date = try? source.dateFormat.date(input.date) { rows[index].statement.kind = OwnerPayments.classify(input.kind, label: input.label, month: String(ImportDateFormat.today(date).prefix(7)), document: importDocument) }
                    }
                }
                next.rows += rows
                next.sources.append(source); try next.checkLimits()
            }
            return next
        }
        importTask = task
        do {
            let next = try await task.value
            guard sessionToken == token, importRevision == revision, state == .unlocked else { return }
            importDraft = next; importMessage = nil
        } catch { if sessionToken == token, importRevision == revision { importMessage = error is CancellationError ? "Reading cancelled. Your draft is unchanged." : error.localizedDescription } }
        if sessionToken == token, importRevision == revision { importTask = nil; importLoading = false }
    }
    func pasteImport(_ text: String) async {
        guard state == .unlocked, !importLoading, let draft = importDraft else { return }
        let token = sessionToken, revision = UUID(); importRevision = revision
        importLoading = true; importMessage = "Reading pasted cells…"
        let task = Task.detached(priority: .userInitiated) { () throws -> ImportBatchDraft in
            var next = draft
            var source = try ImportParser.source(bytes: Data(text.utf8), filename: "Pasted cells", mode: next.mode, pasted: true)
            source.account = next.sources.first?.account ?? ImportAccount()
            if next.rows.isEmpty { next.sources.removeAll { $0.grid.isEmpty } }
            next.rows += try ImportParser.rows(source: source, mode: next.mode); next.sources.append(source)
            try next.checkLimits(); return next
        }
        importTask = task
        do {
            let next = try await task.value
            guard sessionToken == token, importRevision == revision, state == .unlocked else { return }
            importDraft = next; importMessage = nil
        } catch { if sessionToken == token, importRevision == revision { importMessage = error.localizedDescription } }
        if sessionToken == token, importRevision == revision { importTask = nil; importLoading = false }
    }
    func saveImportTemplate() async {
        guard state == .unlocked, !filePickerIsOpen else { focusFilePicker(); return }
        pickerDepth += 1; defer { pickerFinished() }
        let token = sessionToken, mode = importDraft?.mode ?? importMode
        let panel = NSSavePanel(); panel.allowedContentTypes = [.commaSeparatedText]; panel.nameFieldStringValue = mode.rawValue + ".csv"
        guard await presentFilePanel(panel) == .OK, let url = panel.url, token == sessionToken else { return }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do { try mode.template.write(to: url, atomically: true, encoding: .utf8) }
        catch { importMessage = "The template could not be saved." }
    }
    func commitImportBatch(_ draft: ImportBatchDraft) async throws {
        let coins = catalog
        try await mutatePrepared { document in
            let review = ImportBatchProcessor.evaluate(draft, document: document, catalog: coins)
            guard !review.hasErrors, review.added > 0, let next = review.document else {
                throw ImportFailure(review.globalError ?? "Review this batch again. Fix or exclude every flagged row before saving.")
            }
            return next
        }
        importDraft = nil; importMessage = "Your information has been saved."; managementSection = importReturnSection
        finishHomeImport(saved: true)
        Task { await refreshPrices() }
    }

    func exportBackup() async {
        guard state == .unlocked, !filePickerIsOpen else { focusFilePicker(); return }
        pickerDepth += 1
        defer { pickerFinished() }
        let token = sessionToken
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Up Only Backup.uponlybackup"
        panel.canCreateDirectories = true
        guard await presentFilePanel(panel) == .OK, let url = panel.url, token == sessionToken else { return }
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
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.startBackgroundRefresh() }
        })
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.lock() }
            })
        }
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.lock() } })
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
            self?.handleActivity()
            return event
        }
        inactivityTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkInactivity()
            }
        }
        if let inactivityTimer { RunLoop.main.add(inactivityTimer, forMode: .common) }
    }

    #if UPONLY_FIXTURE
    private func prepareFixture() async {
        if let path = ProcessInfo.processInfo.environment["UPONLY_VERIFY_STATEMENT"] {
            do {
                let pair = VaultCrypto.makeInboxKeyPair()
                var doc = VaultDocument.empty(inboxPrivateKeyX963: pair.privateX963, inboxPublicKeyX963: pair.publicX963)
                let names = (ProcessInfo.processInfo.environment["UPONLY_VERIFY_STATEMENT_COUNTERPARTIES"] ?? "").split(separator: ";").map(String.init)
                doc.businessAccounting = [BusinessBook(id: "fixture", name: "Fixture", ownership: [.init(fromMonth: "1900-01", numerator: 1, denominator: 2)], firstMonth: "1900-01", sourceURL: "", basis: "Fixture", fetchedAt: Date(), transferCounterparties: names)]
                var source = try ImportParser.source(bytes: Data(contentsOf: URL(fileURLWithPath: path)), filename: "statement.csv", mode: .statements)
                var batch = ImportBatchDraft(mode: .statements, sources: [source], rows: try ImportParser.rows(source: source, mode: .statements))
                let review = ImportBatchProcessor.evaluate(batch, document: doc)
                guard !review.hasErrors, let saved = review.document else { throw ImportFailure("Statement validation failed.") }
                source.account.existingID = saved.accounts[0].id; batch.sources = [source]
                let repeated = ImportBatchProcessor.evaluate(batch, document: saved)
                guard !repeated.hasErrors, repeated.duplicates == saved.entries.count else { throw ImportFailure("Repeat import failed.") }
                let result: [String: Any] = ["rows": batch.rows.count, "saved": saved.entries.count, "excluded": batch.rows.filter { !$0.included }.count, "duplicates": repeated.duplicates, "transfers": saved.entries.filter { $0.kind == .transfer }.count, "months": Dictionary(grouping: saved.entries, by: \.month).mapValues(\.count)]
                let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
                print("UPONLY_STATEMENT_VERIFIED " + String(decoding: data, as: UTF8.self))
            } catch { print("UPONLY_STATEMENT_FAILED " + error.localizedDescription) }
            fflush(stdout); NSApplication.shared.terminate(nil); return
        }

        #if UPONLY_PERSONAL
        if ProcessInfo.processInfo.environment["UPONLY_VERIFY_BACKGROUND"] == "1" {
            do {
                let inbox = VaultCrypto.makeInboxKeyPair(), signing = VaultCrypto.makeSigningKeyPair()
                var isolated = VaultDocument.empty(inboxPrivateKeyX963: inbox.privateX963, inboxPublicKeyX963: inbox.publicX963)
                isolated.backgroundSignerPublicKey = signing.publicX963
                let config = BackgroundConfiguration(vaultID: isolated.vaultID, inboxPublicKey: inbox.publicX963, signingPrivateKey: signing.privateX963, signingPublicKey: signing.publicX963, crypto: ["bitcoin"], currencies: ["EUR", "GBP"], metals: [.gold], pricesEnabled: true, fxEnabled: true, metalsEnabled: true, coinGeckoKey: "", wiseEnabled: true, accountingEnabled: true)
                let issues = await BackgroundRefresh.fetch(configuration: config, root: Config.supportDirectory)
                var verified: [String] = []
                for source in BackgroundRefresh.sources {
                    let path = BackgroundRefresh.path(source, root: Config.supportDirectory)
                    guard FileManager.default.fileExists(atPath: path.path) else { continue }
                    let envelope = try VaultJSON.decode(BackgroundEnvelope.self, from: Data(contentsOf: path))
                    let packet = try envelope.open(document: isolated)
                    guard packet.source == source else { throw VaultError.corrupt }
                    verified.append(source)
                }
                print("UPONLY_BACKGROUND_VERIFIED=" + verified.joined(separator: ","))
                print("UPONLY_BACKGROUND_ISSUES=" + issues.joined(separator: ","))
            } catch { print("UPONLY_BACKGROUND_FAILED") }
            fflush(stdout); NSApplication.shared.terminate(nil); return
        }
        if ProcessInfo.processInfo.environment["UPONLY_VERIFY_ACCOUNTING"] == "1" {
            do {
                let books = try await AccountingAPI.fetch(AccountingConnection.load())
                try FileManager.default.createDirectory(at: Config.supportDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let output = Config.supportDirectory.appendingPathComponent("accounting-audit.json")
                try JSONEncoder().encode(books).write(to: output, options: [.atomic])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
                print("UPONLY_ACCOUNTING_VERIFIED books=\(books.count) months=\(books.reduce(0) { $0 + $1.months.count })")
                print("UPONLY_ACCOUNTING_AUDIT=\(output.path)")
            } catch { print("UPONLY_ACCOUNTING_FAILED " + ((error as? ImportFailure)?.text ?? "Native accounting check failed.")) }
            fflush(stdout); NSApplication.shared.terminate(nil); return
        }
        #endif
        if ProcessInfo.processInfo.environment["UPONLY_VERIFY_PUBLIC_FX"] == "1" {
            do {
                let update = try await PublicPrices.fx(currencies: ["USD", "GBP", "EUR", "AED", "ZZZ"])
                guard Set(update.rates.map(\.sourceCurrency)) == ["GBP", "EUR", "AED"], Set(update.fxIssues.keys) == ["ZZZ"] else { throw PriceError.invalidResponse }
                let data = try await PublicPrices.request(host: "api.frankfurter.dev", path: "/v2/rates", query: [URLQueryItem(name: "base", value: "GBP"), URLQueryItem(name: "quotes", value: "USD"), URLQueryItem(name: "from", value: "2026-09-01"), URLQueryItem(name: "to", value: "2026-09-04")])
                let history = try PublicPrices.decodeFX(data, currency: "GBP", fetchedAt: Date(), start: ImportDateFormat.iso.date("2026-09-01"), end: ImportDateFormat.iso.date("2026-09-05"))
                guard history.count == 4 else { throw PriceError.invalidResponse }
                let pair = VaultCrypto.makeInboxKeyPair()
                var synthetic = VaultDocument.empty(inboxPrivateKeyX963: pair.privateX963, inboxPublicKeyX963: pair.publicX963)
                synthetic.settings.automaticFX = true
                let month = MonthKey("2026-08")!
                synthetic.entries = [Entry(month: month, kind: .expense, amount: 10, currency: "EUR", label: "Synthetic")]
                let repaired = try await PublicPrices.performanceFX(document: synthetic, now: Date(), month: month, currencies: ["EUR"], retry: true)
                synthetic = try PriceHistory.applying(repaired, to: synthetic, now: Date())
                guard repaired.fxIssues.isEmpty, MonthlyLedger.rate(currency: "EUR", month: month, document: synthetic, now: Date()) != nil else { throw PriceError.invalidResponse }
                print("UPONLY_LIVE_FX_PASS current=3 isolatedFailures=1 historicalDays=4 augustRepair=passed"); fflush(stdout)
                NSApplication.shared.terminate(nil)
            } catch { print("UPONLY_LIVE_FX_FAIL"); fflush(stdout); NSApplication.shared.terminate(nil) }
            return
        }
        let code = RecoveryCode.random()
        do {
            let preview = ProcessInfo.processInfo.environment["UPONLY_PREVIEW_DESTINATION"] ?? ""
            let longText = ProcessInfo.processInfo.environment["UPONLY_PREVIEW_LONG_TEXT"] == "1"
            if let dark = ProcessInfo.processInfo.environment["UPONLY_PREVIEW_DARK"] {
                NSApplication.shared.appearance = NSAppearance(named: dark == "1" ? .darkAqua : .aqua)
            }
            #if UPONLY_PERSONAL
            wiseProfiles = [WiseConfiguredProfile(id: 1, name: "Personal", bucket: .personal), WiseConfiguredProfile(id: 2, name: longText ? "Business operations" : "Business", bucket: .otherBusiness), WiseConfiguredProfile(id: 3, name: "Studio", bucket: .otherBusiness)]
            #endif
            if preview != "welcome" && preview != "recovery" {
            _ = try await vault.create(recovery: code, confirmation: code.canonical)
            let opened = try await vault.currentSession()
            var fixture = opened.document
            let tracked = ProcessInfo.processInfo.environment["UPONLY_PREVIEW_TRACKED"].map { $0.split(separator: ",").compactMap { TrackedKind(rawValue: String($0)) } } ?? TrackedKind.allCases
            if !["setup", "sources", "empty", "syncing", "sync-error", "resume-setup"].contains(preview) { fixture = try UpOnlyFixture.document(from: fixture, tracked: tracked) }
            if preview == "resume-setup" { fixture.settings.setupProgress = SetupProgress(step: 1, tracked: [.banks, .crypto], fx: true) }
            if ["empty", "syncing", "sync-error"].contains(preview) {
                fixture.settings.setupComplete = true; fixture.settings.tracked = tracked
                #if UPONLY_PERSONAL
                fixture.settings.automaticWise = preview != "empty"
                wiseRefreshing = preview == "syncing"
                if preview == "sync-error" { wiseError = "Wise could not be reached. Check your connection and try again."; wiseMessage = wiseError }
                #endif
            }
            if ProcessInfo.processInfo.environment["UPONLY_PREVIEW_NEEDS_ATTENTION"] == "1" { fixture.reviewedMonths = [] }
            #if UPONLY_PERSONAL
            // Synthetic dashboard status states; compiled out of the installed app.
            if let status = ProcessInfo.processInfo.environment["UPONLY_PREVIEW_BANK_STATUS"] {
                fixture.settings.automaticWise = true
                wiseRefreshing = status == "updating"
                wiseError = status == "error" ? "Wise could not refresh. Your saved records are unchanged." : nil
            }
            if let status = ProcessInfo.processInfo.environment["UPONLY_PREVIEW_ACCOUNTING_STATUS"] {
                accountingRefreshing = status == "updating"
                accountingError = status == "error" ? "Accounting could not refresh. Your saved results are unchanged." : nil
            }
            #endif
            if ["missing-rates", "worth-missing-rates", "failed-rates"].contains(preview) {
                for index in fixture.entries.indices { fixture.entries[index].currency = "CHF" }
                for index in fixture.accounts.indices { fixture.accounts[index].currency = "CHF" }
                for index in fixture.bankBalances.indices { fixture.bankBalances[index].currency = "CHF" }
                fixture.fx = []; fixture.dailyValuations = []
            }
            if longText {
                for index in fixture.accounts.indices { fixture.accounts[index].name = "Everyday spending and shared household expenses across several currencies" }
                for index in fixture.portfolios.indices { fixture.portfolios[index].name = "Long term savings and investments for future plans" }
                for index in fixture.entries.indices { fixture.entries[index].label = "A longer transaction description with enough detail to identify the payment clearly" }
                if !fixture.bankBalances.isEmpty { fixture.bankBalances[fixture.bankBalances.count - 1].amount = PreciseDecimal(Decimal(string: "1234567890123456789012345678")!) }
            }
            if preview == "failed-rates" { fixture.settings.automaticFX = true; fxIssues = ["CHF": "Couldn’t get the CHF → USD rate. Try again or add a dated rate."] }
            if preview == "missing-balances" { fixture.bankBalances = []; fixture.dailyValuations = [] }
            if preview.hasPrefix("performance") || preview == "networth-companies" {
                var months: [BusinessMonth] = []
                var cursor = MonthKey.current().previous
                for index in 0..<48 {
                    let profit = preview == "performance-loss" ? Decimal((index % 7 - 3) * 950) : Decimal((index % 7 - 2) * 450 + 1700)
                    months.append(BusinessMonth(month: cursor.description, profitUSD: profit, revenueUSD: profit + 4000, expensesUSD: 4000, sourceRange: "Synthetic accounting"))
                    cursor = cursor.previous
                }
                let first = months.map(\.month).min()!
                fixture.businessAccounting = [
                    BusinessBook(id: "studio", name: "Studio", ownership: [.init(fromMonth: first, numerator: 1, denominator: 1)], firstMonth: first, sourceURL: "https://docs.google.com/spreadsheets/d/synthetic/edit", basis: "Net proceeds less operating expenses, before owner draws.", months: months.map { var copy = $0; copy.profitUSD = (try? OwnershipPeriod(fromMonth: first, numerator: 1, denominator: 3).portion(copy.profitUSD)) ?? 0; copy.revenueUSD = copy.profitUSD + 4000; return copy }, fetchedAt: Date(), warning: preview == "performance-missing" ? "The accounting sheet reports a failed check." : nil),
                    BusinessBook(id: "agency", name: "Agency", ownership: [.init(fromMonth: first, numerator: 1, denominator: 3), .init(fromMonth: MonthKey.current().previous.description, numerator: 1, denominator: 2)], firstMonth: first, sourceURL: "https://docs.google.com/spreadsheets/d/synthetic/edit", basis: "Actual revenue less operating expenses, before all owner payouts.", months: months, fetchedAt: Date())]
            }
            if preview == "networth-companies" {
                let start = Date().addingTimeInterval(-90 * 86400)
                for (name, owner, currency, balance) in [("Agency", "agency", "USD", Decimal(30000)), ("Studio", "studio", "GBP", Decimal(1000)), ("Studio", "studio", "USD", Decimal(4000))] {
                    let account = Account(name: name + " · " + currency, currency: currency, ownerBusinessID: owner, externalProfileID: owner)
                    fixture.accounts.append(account); fixture.setBankTracked(account.id, tracked: true, at: start)
                    for day in 0...90 {
                        let date = start.addingTimeInterval(Double(day) * 86400)
                        fixture.bankBalances.append(BankBalanceObservation(id: UUID(), accountID: account.id, amount: PreciseDecimal(balance), currency: currency, observedAt: date, source: "Synthetic", sourceIdentity: account.id.uuidString))
                        fixture.fx.append(FXObservation(sourceCurrency: "GBP", targetCurrency: "USD", rate: PreciseDecimal(Decimal(string: "1.25")!), providerTime: date, fetchedAt: date, provider: "Synthetic"))
                    }
                }
                if let index = fixture.portfolios.firstIndex(where: { $0.kind == .crypto }) { fixture.portfolios[index].ownerBusinessID = "agency" }
                fixture.dailyValuations = []
                for day in 0...90 {
                    let date = start.addingTimeInterval(Double(day) * 86400)
                    fixture = NetWorthCalculator.recordingSample(NetWorthCalculator.value(at: date, scope: .allTracked, document: fixture, now: date), in: fixture)
                }
            }
            if preview == "single-month" {
                fixture.entries = fixture.entries.filter { $0.month == MonthKey.current().description }
            }
            if preview == "missing-prices" { fixture.quotes = []; fixture.dailyValuations = [] }
            fixture.settings.privacyMode = ProcessInfo.processInfo.environment["UPONLY_PREVIEW_PRIVACY"] == "1"
            fixture.generation = opened.document.generation + 1
            try await vault.commit(fixture, expectedGeneration: opened.document.generation, sessionID: opened.sessionID)
            publish(fixture, freshUnlock: true)
            if preview.hasPrefix("performance") {
                let selected = ProcessInfo.processInfo.environment["UPONLY_PERFORMANCE_SCOPE"] ?? "all"
                monthModel?.selectScope(selected == "all" ? .all : selected == "personal" ? .personal : .business(selected))
                monthModel?.select(preview == "performance-missing" ? .current() : .current().previous)
                if let raw = ProcessInfo.processInfo.environment["UPONLY_PERFORMANCE_PERIOD"], let period = PerformancePeriod(rawValue: raw) { monthModel?.selectPeriod(period) }
            }
            if ["networth", "networth-companies", "worth-missing-rates", "missing-balances", "missing-prices"].contains(preview), fixture.showsNetWorth { destination = 1 }
            if preview == "import" { startImport(tracked.contains(.banks) ? .bankBalances : tracked.contains(.crypto) ? .holdings : .metals, prefill: true) }
            if preview == "add-info" { managementSection = "Add your info" }
            if preview == "manual-bank" { managementSection = "Accounts"; startImport(.bankBalances) }
            if preview == "manual-crypto" { managementSection = "Portfolios"; startImport(.holdings) }
            if preview == "manual-metals" { managementSection = "Precious metals"; startImport(.metals) }
            if preview == "statements" { startImport(.statements) }
            if preview == "guided-choices" { addingInMenu = true }
            else if preview.hasPrefix("guided-") {
                let mode: ImportMode = preview == "guided-bank" ? .bankBalances : preview == "guided-metals" ? .metals : .holdings
                startImport(mode, prefill: true)
                if var batch = importDraft { batch.rows = Array(batch.rows.prefix(1)); importDraft = batch }
                if mode == .bankBalances { importDraft?.rows[0].bank.balance = "1250.50" }
                else { importDraft?.rows[0].holding.quantity = mode == .metals ? "50" : "0.25" }
                addingInMenu = true
            }
            if preview == "metals" { managementSection = "Precious metals" }
            if preview == "import", longText { importDraft?.sources[0].filename = "All statements and closing balances for the household spending account — September 2026.csv" }
            if preview == "locked" || preview == "recover" || preview == "resume-setup" {
                lock()
                if preview == "recover" { state = .recovery }
            }
            }
            if ProcessInfo.processInfo.environment["UPONLY_PREVIEW_AUTH_CANCEL"] == "1", let authenticator = vault.authenticator as? FixtureAuthenticator {
                authenticator.shouldCancel = true
            }
            let isManagement = ["accounts", "portfolios", "entries", "import", "tracking", "preferences", "security", "metals", "add-info", "manual-bank", "manual-crypto", "manual-metals", "statements"].contains(preview)
            if preview == "tracking" { managementSection = "Manage" }
            if preview == "preferences" { managementSection = "Sources" }
            if preview == "security" { managementSection = "Security" }
            if ["accounts", "portfolios", "entries"].contains(preview) { managementSection = preview == "accounts" ? "Accounts" : preview == "portfolios" ? "Portfolios" : "Entries" }
            managementInMenu = isManagement
            if let file = ProcessInfo.processInfo.environment["UPONLY_PREVIEW_IMPORT_FILE"] {
                if let raw = ProcessInfo.processInfo.environment["UPONLY_PREVIEW_IMPORT_MODE"], let mode = ImportMode(rawValue: raw) {
                    discardImport(); startImport(mode)
                } else if importDraft == nil { startImport(.statements) }
                await readImportFiles(file.split(separator: ";").map { URL(fileURLWithPath: String($0)) })
                if ProcessInfo.processInfo.environment["UPONLY_PREVIEW_IMPORT_DUPLICATE"] == "1", let batch = importDraft {
                    try await commitImportBatch(batch)
                    startImport(.statements)
                    await readImportFiles([URL(fileURLWithPath: file)])
                }
                managementInMenu = true; managementSection = "Add your info"
            }
            if ProcessInfo.processInfo.environment["UPONLY_PREVIEW_MENU_BAR"] == "1" {
                print("UPONLY_SYNTHETIC_MENU_READY"); fflush(stdout)
                return
            }
            let offscreen = ProcessInfo.processInfo.environment["UPONLY_PREVIEW_OFFSCREEN"] == "1"
            let window = UpOnlyFixtureWindow(contentRect: NSRect(x: offscreen ? -5000 : 120, y: offscreen ? -5000 : 120, width: 344, height: 560), styleMask: [.borderless], backing: .buffered, defer: false)
            window.title = "Up Only Preview"
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: ProcessInfo.processInfo.environment["UPONLY_PREVIEW_DARK"] == "1" ? .darkAqua : .aqua)
            if preview == "calendar" { window.contentView = NSHostingView(rootView: UpOnlyDateCalendar(date: .constant(Date()), done: {})) }
            else { window.contentView = NSHostingView(rootView: UpOnlyPanel().environment(self)) }
            previewWindow = window
            if offscreen { window.installAuditCommands(at: Config.supportDirectory) }
            if offscreen || ProcessInfo.processInfo.environment["UPONLY_PREVIEW_HIDDEN"] != "1" { window.orderBack(nil) }
            if ProcessInfo.processInfo.environment["UPONLY_PREVIEW_CAPTURE"] == "1" {
                try? await Task.sleep(for: .milliseconds(900))
                if let content = window.contentView {
                    content.layoutSubtreeIfNeeded()
                    window.setContentSize(content.fittingSize); content.layoutSubtreeIfNeeded()
                    print("UPONLY_SYNTHETIC_FITTING=\(content.fittingSize.width)x\(content.fittingSize.height)")
                    if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                        content.cacheDisplay(in: content.bounds, to: bitmap)
                        if let png = bitmap.representation(using: .png, properties: [:]) {
                            let url = Config.supportDirectory.appendingPathComponent("preview.png")
                            try FileManager.default.createDirectory(at: Config.supportDirectory, withIntermediateDirectories: true)
                            try png.write(to: url)
                            print("UPONLY_SYNTHETIC_RENDER=" + url.path)
                            print("UPONLY_SYNTHETIC_WINDOW=\(window.windowNumber)"); fflush(stdout)
                        }
                    }
                }
            }
        } catch { message = "The isolated preview could not start." }
    }

    #endif
}

#if UPONLY_PERSONAL
extension UpOnlySession {
    func refreshAccounting() async {
        guard state == .unlocked, !isFixture, !accountingRefreshing, !isBusy else { return }
        let token = sessionToken
        accountingRefreshing = true; accountingError = nil
        defer { if token == sessionToken { accountingRefreshing = false; accountingRequest = nil } }
        do {
            let request = Task.detached(priority: .utility) { try await AccountingAPI.fetchResult(AccountingConnection.load()) }; accountingRequest = request
            let result = try await request.value
            guard token == sessionToken, !Task.isCancelled, !request.isCancelled else { return }
            while isBusy, token == sessionToken, !request.isCancelled { try await Task.sleep(for: .milliseconds(100)) }
            guard token == sessionToken, !request.isCancelled else { return }
            try await mutate { $0.businessAccounting = AccountingHistory.merging(result.books, into: $0.businessAccounting ?? []); OwnerPayments.reconcile(in: &$0); $0.track(.cashFlow) }
            if !result.failedSources.isEmpty { accountingError = result.failedSources.joined(separator: ", ") + " couldn’t refresh. Saved results retained." }
        } catch {
            if token == sessionToken, !Task.isCancelled, !(error is CancellationError) {
                accountingError = (error as? ImportFailure)?.text ?? "Accounting could not refresh. Showing saved results."
            }
        }
    }
    func refreshWise() async {
        guard state == .unlocked, !isFixture, !wiseRefreshing, !isBusy, document?.settings.automaticWise == true else { return }
        let token = sessionToken
        wiseRefreshing = true; wiseMessage = nil; wiseError = nil
        defer { if token == sessionToken { wiseRefreshing = false; wiseRequest = nil } }
        do {
            let connection = try await Task.detached(priority: .utility) { try WiseConnection.load() }.value
            guard token == sessionToken, state == .unlocked, !Task.isCancelled else { return }
            wiseProfiles = connection.profiles
            let request = Task { try await WiseAPI.fetch(connection) }; wiseRequest = request
            let snapshot = try await request.value
            guard token == sessionToken, !Task.isCancelled, !request.isCancelled, document?.settings.automaticWise == true else { return }
            try await mutatePrepared { doc in try WiseAPI.apply(snapshot, to: doc) }
            guard token == sessionToken else { return }
            if let document {
                try? await BackgroundRefreshSchedule.shared.finish(vaultID: document.vaultID, root: Config.supportDirectory, failed: false)
            }
            backgroundIssues.removeAll { $0 == "Bank balances" }
            wiseMessage = "Wise updated " + Date().formatted(date: .omitted, time: .shortened)
        } catch {
            if token == sessionToken, !Task.isCancelled, !(error is CancellationError) {
                wiseError = (error as? ImportFailure)?.text ?? "Wise could not refresh. Your saved records are unchanged."
                wiseMessage = wiseError
            }
        }
    }
    func setWiseEnabled(_ enabled: Bool) async {
        wiseRequest?.cancel()
        await perform { $0.settings.automaticWise = enabled }
        if enabled { await refreshWise() }
    }
}
#endif

extension UpOnlySession {
    func checkpointSetup(_ progress: SetupProgress) {
        guard state == .unlocked, document?.settings.setupComplete == false else { return }
        let next = progress.normalized
        guard next != document?.settings.setupProgress || pendingSetupProgress != nil || setupProgressMessage != nil else { return }
        pendingSetupProgress = next
        guard setupProgressTask == nil else { return }
        let token = sessionToken
        setupProgressTask = Task { [weak self] in
            guard let self else { return }
            defer { if token == self.sessionToken { self.setupProgressTask = nil } }
            while let progress = self.pendingSetupProgress, token == self.sessionToken, !Task.isCancelled {
                if self.isBusy {
                    do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                    continue
                }
                self.pendingSetupProgress = nil
                do {
                    try self.validateSourceKey(progress.coinGeckoKey, prices: false)
                    try self.validateSourceKey(progress.metalHistoryKey, prices: false)
                    try await self.mutate { document in
                        guard !document.settings.setupComplete else { return }
                        document.settings.setupProgress = progress
                    }
                    if token == self.sessionToken { self.setupProgressMessage = nil }
                } catch {
                    if token == self.sessionToken {
                        self.setupProgressMessage = "Your latest setup choices could not be saved. Please try again before closing."
                    }
                    return
                }
            }
        }
    }
    func flushSetupProgress() async throws {
        while let task = setupProgressTask { await task.value }
        if let setupProgressMessage { throw ImportFailure(setupProgressMessage) }
    }
    func scheduleRefresh() {
        guard !isFixture else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.state == .unlocked else { return }
                await self.configureBackground()
                await self.applyBackgroundCache()
                await self.refreshPrices(automatic: true)
                do { try await Task.sleep(for: .seconds(15 * 60)) } catch { return }
            }
        }
    }
    func refreshPrices(reconnected: Bool = false, automatic: Bool = false) async {
        let log = Logger(subsystem: "org.uponly", category: "prices")
        // A manual refresh takes over from a scheduled catch-up instead of silently doing nothing.
        if !automatic, priceRequestIsAutomatic, let running = priceRequest { running.cancel(); priceRequest = nil; priceRequestIsAutomatic = false; log.notice("manual refresh pre-empted scheduled catch-up") }
        guard state == .unlocked, !refreshing, priceRequest == nil, !isFixture, let doc = document else {
            log.notice("refresh skipped automatic=\(automatic) unlocked=\(self.state == .unlocked) refreshing=\(self.refreshing) pending=\(self.priceRequest != nil)")
            return
        }
        let activeHoldings = doc.holdings.filter { $0.isActive(at: Date()) && doc.portfolio(id: $0.portfolioID)?.isActive(at: Date()) == true }
        log.notice("refresh start automatic=\(automatic) prices=\(doc.settings.automaticPrices) metals=\(doc.settings.automaticMetals) fx=\(doc.settings.automaticFX) keyLength=\(doc.settings.coinGeckoKey.count) holdings=\(doc.holdings.count) active=\(activeHoldings.count) portfolios=\(doc.portfolios.count)")
        let token = sessionToken, revision = sourceRevision
        if automatic {
            guard priceRequest == nil,
                  (try? await BackgroundRefreshSchedule.shared.claim(vaultID: doc.vaultID, root: Config.supportDirectory, source: "history")) == true,
                  token == sessionToken, state == .unlocked, priceRequest == nil else { return }
        } else {
            refreshing = true
            sourceMessage = "Updating prices and checking for missed history…"
        }
        fxIssues = [:]
        var mine: Task<PriceUpdate, Error>?
        // Only the refresh that owns the current request clears it; a pre-empted catch-up must not clobber its replacement.
        defer { if token == sessionToken, revision == sourceRevision, priceRequest == mine { refreshing = false; priceRequest = nil; priceRequestIsAutomatic = false } }
        do {
            let request = Task.detached(priority: automatic ? .utility : .userInitiated) { try await PublicPrices.update(document: doc, reconnected: reconnected, includeCurrent: !automatic) }
            priceRequest = request; priceRequestIsAutomatic = automatic; mine = request
            let update = try await request.value
            log.notice("refresh result quotes=\(update.quotes.count) rates=\(update.rates.count) messages=\(update.messages.joined(separator: " | "), privacy: .public) issues=\(update.sourceIssues.values.joined(separator: " | "), privacy: .public)")
            guard token == sessionToken, revision == sourceRevision, !Task.isCancelled else { log.notice("refresh result discarded: session changed or cancelled"); return }
            if !update.quotes.isEmpty || !update.rates.isEmpty || !update.coverage.isEmpty {
                try await commitPriceUpdate(update)
            }
            guard token == sessionToken, revision == sourceRevision else { return }
            if !automatic { sourceMessage = update.messages.isEmpty ? "Updated " + Date().formatted(date: .omitted, time: .shortened) : update.messages.joined(separator: "\n") }
            fxIssues = update.fxIssues
            if !automatic {
                sourceIssues = update.sourceIssues
                // A successful manual update supersedes an earlier background failure for that source.
                for (source, issue) in [("Crypto", "crypto"), ("Metals", "metals"), ("Exchange rates", "fx")] where update.sourceIssues[issue] == nil {
                    backgroundIssues.removeAll { $0 == source || $0.lowercased().hasPrefix(issue + " ") }
                }
            }
        } catch {
            log.error("refresh failed: \(String(describing: error), privacy: .public)")
            if token == sessionToken, revision == sourceRevision, !Task.isCancelled {
                let issue = (error as? PriceError)?.localizedDescription ?? "Prices could not be saved. Your saved observations are unchanged; catch-up will retry."
                if !automatic { sourceMessage = issue; sourceIssues = ["crypto": issue, "metals": issue, "fx": issue] }
                if doc.settings.automaticFX {
                    fxIssues = Dictionary(uniqueKeysWithValues: Set(doc.accounts.map(\.currency) + doc.entries.map(\.currency)).subtracting(["USD"]).map { ($0, issue) })
                }
            }
        }
    }
    func commitPriceUpdate(_ update: PriceUpdate) async throws {
        try await mutatePrepared { current in try PriceHistory.applying(update, to: current, now: Date()) }
    }
    func repairExchangeRates(month: MonthKey, currencies: [String]) async {
        guard state == .unlocked, !isBusy else { return }
        // Explicit repair takes priority over a broad background history refresh.
        priceRequest?.cancel(); priceRequest = nil
        let token = sessionToken
        sourceRevision = UUID(); let revision = sourceRevision
        refreshing = true; fxIssues = [:]
        defer { if token == sessionToken, revision == sourceRevision { refreshing = false; priceRequest = nil } }
        do {
            if document?.settings.automaticFX != true { try await mutate { $0.settings.automaticFX = true } }
            guard let doc = document else { return }
            let fixture = isFixture
            let request = Task.detached(priority: .userInitiated) { () async throws -> PriceUpdate in
                #if UPONLY_FIXTURE
                if fixture {
                    var update = PriceUpdate()
                    for item in PublicPrices.monthlyFXRequests(document: doc, now: Date(), month: month, currencies: currencies, retry: true) {
                        if ProcessInfo.processInfo.environment["UPONLY_PREVIEW_FX_FAILURE"] == "1" { update.fxIssues[item.identifier] = "Couldn’t get the dated rate. Try again or add it manually." }
                        else { update.rates.append(FXObservation(sourceCurrency: item.identifier, targetCurrency: "USD", rate: PreciseDecimal(Decimal(string: "1.25")!), providerTime: item.end.addingTimeInterval(-86400), fetchedAt: Date(), provider: "Synthetic")) }
                    }
                    return update
                }
                #endif
                return try await PublicPrices.performanceFX(document: doc, now: Date(), month: month, currencies: currencies, retry: true)
            }
            priceRequest = request
            let update = try await request.value
            guard token == sessionToken, revision == sourceRevision else { return }
            if !update.rates.isEmpty { try await commitPriceUpdate(update) }
            fxIssues = update.fxIssues
            sourceMessage = update.fxIssues.isEmpty ? "Exchange rates updated for " + month.title + "." : "Some exchange rates are still missing."
        } catch {
            guard token == sessionToken, revision == sourceRevision else { return }
            fxIssues = Dictionary(uniqueKeysWithValues: currencies.map { ($0, "The rate couldn’t be saved. Try again or enter a dated rate.") })
        }
    }
    func enableExchangeRates() async {
        guard state == .unlocked else { return }
        resetSourceWork()
        do {
            try await mutate { $0.settings.automaticFX = true }
            scheduleRefresh()
        } catch { message = "Exchange rates could not be enabled. Please try again." }
    }
    func loadCatalog() async {
        // The public coin list needs no key; a Demo key is used when present.
        guard state == .unlocked, !isFixture, let settings = document?.settings else { return }
        let token = sessionToken, revision = sourceRevision
        do {
            catalogRequest?.cancel()
            let request = Task { try await PublicPrices.catalog(key: settings.automaticPrices ? settings.coinGeckoKey : "") }
            catalogRequest = request
            let coins = try await request.value
            if token == sessionToken, revision == sourceRevision, !Task.isCancelled { catalog = coins }
        } catch { if token == sessionToken, revision == sourceRevision { sourceMessage = (error as? PriceError)?.localizedDescription ?? "The coin list could not be loaded. You can enter its CoinGecko ID manually." } }
    }
    private func resetSourceWork() {
        refreshTask?.cancel(); refreshTask = nil
        priceRequest?.cancel(); priceRequest = nil
        catalogRequest?.cancel(); catalogRequest = nil
        sourceRevision = UUID(); catalog = []; refreshing = false; sourceMessage = nil
    }
    private func validateSourceKey(_ key: String, prices: Bool) throws {
        guard key.utf8.count <= 512, !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !prices || !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ImportFailure("Paste a valid API key from your provider, without line breaks.") }
    }
    func saveSources(prices: Bool, fx: Bool, key: String, metals: Bool? = nil, metalKey: String? = nil, wise: Bool? = nil) async throws {
        try validateSourceKey(key, prices: prices)
        try validateSourceKey(metalKey ?? "", prices: false)
        resetSourceWork()
        do {
            try await mutate { doc in
                #if UPONLY_PERSONAL
                if let wise { doc.settings.automaticWise = wise }
                #endif
                doc.settings.automaticPrices = prices
                doc.settings.automaticFX = fx
                doc.settings.coinGeckoKey = key
                if let metals { doc.settings.automaticMetals = metals }
                if let metalKey { doc.settings.metalHistoryKey = metalKey }
                doc.priceHistoryCoverage?.removeAll { !$0.complete }
            }
        } catch { if state == .unlocked { scheduleRefresh() }; throw error }
        // Fetch current prices and rates first so the source shows data, then start the scheduled loop.
        guard state == .unlocked else { return }
        Task { [weak self] in
            guard let self else { return }
            if prices || fx || metals == true { await self.refreshPrices() }
            if self.state == .unlocked { self.scheduleRefresh() }
        }
    }
    func completeSetup(tracked: [TrackedKind], prices: Bool, fx: Bool, key: String, metals: Bool = false, metalKey: String = "") async throws {
        try await flushSetupProgress()
        guard !tracked.isEmpty else { throw VaultError.invalidAmount }
        try validateSourceKey(key, prices: prices)
        try validateSourceKey(metalKey, prices: false)
        resetSourceWork()
        defer { if state == .unlocked { scheduleRefresh() } }
        try await mutate { doc in
            doc.settings.tracked = TrackedKind.normalized(tracked)
            doc.settings.automaticPrices = prices && tracked.contains(.crypto)
            doc.settings.automaticFX = fx && (tracked.contains(.banks) || tracked.contains(.cashFlow))
            doc.settings.coinGeckoKey = prices && tracked.contains(.crypto) ? key : ""
            doc.settings.automaticMetals = metals && tracked.contains(.metals)
            doc.settings.metalHistoryKey = metalKey
            doc.settings.setupComplete = true
            doc.settings.setupProgress = nil
            #if UPONLY_PERSONAL
            doc.settings.automaticWise = !wiseProfiles.isEmpty
            #endif
        }
    }
    func restoreBackup(code: String) async {
        guard state == .newVault, !isBusy, !filePickerIsOpen else { focusFilePicker(); return }
        pickerDepth += 1; defer { pickerFinished() }
        let token = sessionToken
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard await presentFilePanel(panel) == .OK, let url = panel.url, token == sessionToken else { return }
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

#if UPONLY_FIXTURE
private final class UpOnlyFixtureWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    private var auditTimer: Timer?
    private var lastAuditID = ""
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        ProcessInfo.processInfo.environment["UPONLY_PREVIEW_OFFSCREEN"] == "1" ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
    func installAuditCommands(at directory: URL) {
        guard ProcessInfo.processInfo.environment["UPONLY_PREVIEW_OFFSCREEN"] == "1" else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        print("UPONLY_AUDIT_DIRECTORY=" + directory.path); fflush(stdout)
        auditTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.readAuditCommand(at: directory) }
        }
    }
    private func controls(in view: NSView) -> [NSView] {
        if view is NSTextField || view is NSTextView { return [view] }
        return view.subviews.flatMap { controls(in: $0) }
    }
    private func readAuditCommand(at directory: URL) {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("ui-command.json")), data.count <= 8192,
              let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = command["id"] as? String, id != lastAuditID, let contentView else { return }
        lastAuditID = id
        let fields = controls(in: contentView)
        var response: [String: Any] = ["id": id, "success": false]
        if command["action"] as? String == "capture" {
            contentView.layoutSubtreeIfNeeded()
            setContentSize(contentView.fittingSize)
            contentView.layoutSubtreeIfNeeded()
            if let bitmap = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) {
                contentView.cacheDisplay(in: contentView.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    do { try png.write(to: directory.appendingPathComponent("audit.png")); response["success"] = true } catch {}
                }
            }
        } else if command["action"] as? String == "controls" {
            response["success"] = true
            response["controls"] = fields.enumerated().map { index, view in ["index": index, "type": String(describing: type(of: view)), "placeholder": (view as? NSTextField)?.placeholderString ?? ""] as [String: Any] }
        } else if command["action"] as? String == "type", let index = command["index"] as? Int, fields.indices.contains(index), let text = command["text"] as? String {
            if let field = fields[index] as? NSTextField {
                field.stringValue = text
                field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
                response["success"] = true
            } else if let field = fields[index] as? NSTextView {
                field.string = text
                field.didChangeText()
                response["success"] = true
            }
        }
        if let encoded = try? JSONSerialization.data(withJSONObject: response) { try? encoded.write(to: directory.appendingPathComponent("ui-response.json"), options: .atomic) }
    }
}
#endif


extension UpOnlySession {
    func startBackgroundRefresh() {
        guard !isFixture else { return }
        backgroundTask?.cancel()
        backgroundTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    guard let self else { return }
                    let load = Task.detached(priority: .utility) { try BackgroundConfiguration.load() }
                    if let configuration = try await load.value {
                        guard !Task.isCancelled else { return }
                        let root = Config.supportDirectory
                        let request = Task.detached(priority: .utility) { await BackgroundRefresh.fetch(configuration: configuration, root: root) }
                        let issues = await withTaskCancellationHandler(operation: { await request.value }, onCancel: { request.cancel() })
                        guard !Task.isCancelled else { return }
                        self.backgroundCheckedAt = Date(); self.backgroundIssues = issues
                        if self.state == .unlocked { await self.applyBackgroundCache() }
                    }
                } catch { self?.backgroundIssues = ["Background source configuration"] }
                do { try await Task.sleep(for: .seconds(BackgroundRefresh.interval)) } catch { return }
            }
        }
    }
    func configureBackground() async {
        guard !isFixture, state == .unlocked, !isBusy, let current = document, current.settings.setupComplete else { return }
        let token = sessionToken
        do {
            let saved = try await Task.detached(priority: .utility) { try BackgroundConfiguration.load() }.value
            guard token == sessionToken, state == .unlocked, !isBusy else { return }
            let pair: (privateX963: Data, publicX963: Data)
            if let saved, saved.vaultID == current.vaultID, saved.signingPublicKey == current.backgroundSignerPublicKey {
                pair = (saved.signingPrivateKey, saved.signingPublicKey)
            } else {
                pair = VaultCrypto.makeSigningKeyPair()
                try await mutate { $0.backgroundSignerPublicKey = pair.publicX963 }
            }
            guard state == .unlocked, let doc = document, doc.vaultID == current.vaultID else { return }
            let active = doc.holdings.filter { $0.isActive(at: Date()) && doc.portfolio(id: $0.portfolioID)?.isActive(at: Date()) == true }
            var config = BackgroundConfiguration(vaultID: doc.vaultID, inboxPublicKey: doc.inboxPublicKeyX963, signingPrivateKey: pair.privateX963, signingPublicKey: pair.publicX963,
                crypto: Set(active.filter { PreciousMetal.asset($0.assetID) == nil }.map { $0.assetID.rawValue }).sorted(),
                currencies: Set(doc.accounts.map(\.currency) + doc.entries.filter { $0.bucket == .personal }.map(\.currency)).subtracting(["USD"]).sorted(),
                metals: Set(active.compactMap { PreciousMetal.asset($0.assetID) }).sorted { $0.rawValue < $1.rawValue },
                pricesEnabled: doc.settings.automaticPrices, fxEnabled: doc.settings.automaticFX, metalsEnabled: doc.settings.automaticMetals, coinGeckoKey: doc.settings.coinGeckoKey)
            #if UPONLY_PERSONAL
            config.wiseEnabled = doc.settings.automaticWise
            config.accountingEnabled = await Task.detached(priority: .utility) { (try? AccountingConnection.load()) != nil }.value
            #endif
            guard token == sessionToken, state == .unlocked else { return }
            if config != saved {
                let next = config
                // Sources whose settings changed are fetched again now rather than after their usual interval.
                var changed: [String] = []
                if saved?.pricesEnabled != next.pricesEnabled || saved?.coinGeckoKey != next.coinGeckoKey || saved?.crypto != next.crypto { changed.append("crypto") }
                if saved?.fxEnabled != next.fxEnabled || saved?.currencies != next.currencies { changed.append("fx") }
                if saved?.metalsEnabled != next.metalsEnabled || saved?.metals != next.metals { changed.append("metals") }
                let root = Config.supportDirectory, vaultID = doc.vaultID
                await BackgroundRefreshSchedule.shared.reset(vaultID: vaultID, root: root, sources: changed)
                try await Task.detached(priority: .utility) { try next.save() }.value
                if token == sessionToken, state == .unlocked { startBackgroundRefresh() }
            }
        } catch { backgroundIssues = ["Background source setup"] }
    }
    func applyBackgroundCache() async {
        guard !isFixture, state == .unlocked, !isBusy, let current = document else { return }
        let token = sessionToken
        guard backgroundCacheRequest == nil else { return }
        let root = Config.supportDirectory
        let request = Task.detached(priority: .utility) { BackgroundRefresh.cachedPackets(document: current, root: root) }
        backgroundCacheRequest = request
        defer { if token == sessionToken { backgroundCacheRequest = nil } }
        let result = await withTaskCancellationHandler(operation: { await request.value }, onCancel: { request.cancel() })
        guard token == sessionToken, state == .unlocked, !Task.isCancelled, !request.isCancelled else { return }
        backgroundIssues = Array(Set(backgroundIssues + result.issues))
        // A user edit can finish while the cache is read. Do not interrupt it or
        // overwrite its draft; the next refresh can apply this unchanged cache.
        guard !isBusy, !result.packets.isEmpty else { return }
        do {
            let updates = result.packets
            try await mutatePrepared { document in try updates.reduce(document) { try BackgroundRefresh.applying($1, to: $0) } }
        } catch { if token == sessionToken { backgroundIssues = Array(Set(backgroundIssues + ["Cached updates"])) } }
    }
}
