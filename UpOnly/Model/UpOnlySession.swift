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
    enum RestoreOutcome { case restored, needsConfirmation, cancelled, failed }
    private(set) var state: State = .locked
    private(set) var document: VaultDocument?
    /// Counts document replacements, so work derived from the document can be reused until it changes.
    @ObservationIgnored private(set) var documentRevision = 0
    /// The 24-hour charts' hourly valuations, by page, document revision and hour: each is two dozen valuations.
    @ObservationIgnored var hourlyCache: [String: [(moment: Date, components: [ValuationComponent])]] = [:]
    /// Intraday prices for the 24-hour, 7-day and 30-day charts, by "range|asset", fetched while one of those
    /// ranges is showing. Kept in memory only; the vault keeps its own hourly and daily prices.
    private(set) var intraday: [String: ChartEstimates.Series] = [:]
    @ObservationIgnored private var intradayFetchedAt: [String: Date] = [:]
    private(set) var monthModel: PopoverModel?
    /// True while unlocking, creating, restoring or saving a change the user made; forms disable while it's set.
    private(set) var isBusy = false
    /// One vault write at a time. Writers wait their turn instead of failing; a waiting user edit goes before background work.
    @ObservationIgnored private var writerActive = false
    @ObservationIgnored private var userWriters: [UUID] = []
    @ObservationIgnored private var configuringBackground = false
    @ObservationIgnored private var exportingBackup = false
    /// A backup chosen to replace the vault, kept while the user confirms. Lock clears it.
    @ObservationIgnored private var pendingRestore: (package: BackupPackage, recovery: RecoveryCode)?
    @ObservationIgnored private var reconfigureBackground = false
    private(set) var sessionToken = UUID()
    var message: String?
    private(set) var fxIssues: [String: String] = [:]
    /// Last manual or scheduled update's problem per price source ("crypto", "metals", "fx"), cleared on success.
    private(set) var sourceIssues: [String: String] = [:]
    /// What the dashboard shows, chosen with the switcher: everything, one bank group ("personal" or a company's
    /// id), one portfolio, or cash flow. Kept here so a trip to Manage or Add returns to the same page.
    enum DashboardSelection: Equatable { case all, bankGroup(String), portfolio(UUID), cashFlow }
    var dashboardSelection: DashboardSelection = .all
    /// The switcher sheet over the dashboard. Esc closes it before the menu, and closing the menu closes it.
    var showingSwitcher = false
    /// The All assets page's height. Every other dashboard page opens at the same size and scrolls within it.
    var dashboardHeight: CGFloat?
    /// Income & spending's account choice, put back after a bank or company page borrowed it.
    var cashFlowScope: PerformanceScope?
    /// 1 for net worth pages, 0 for cash flow; the older way of saying which half of the dashboard is showing.
    var destination: Int {
        get { dashboardSelection == .cashFlow ? 0 : 1 }
        set { if newValue == 0 { dashboardSelection = .cashFlow } else if dashboardSelection == .cashFlow { dashboardSelection = .all } }
    }
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
    var privacyMode: Bool { privacyOverride ?? (document?.settings.privacyMode == true) }
    /// Privacy mode's stand-in factor: amounts show scaled by it, so they look real but say nothing. Nil when figures
    /// show as they are. Worked out once per document.
    var standInFactor: Decimal? {
        guard privacyMode, let document else { return nil }
        if let cached = standInCache, cached.revision == documentRevision { return cached.factor }
        let factor = UpOnlyStandIn.factor(total: AssetOwnership.personalValue(at: Date(), scope: .allTracked, document: document).total, vaultID: document.vaultID)
        standInCache = (documentRevision, factor)
        return factor
    }
    @ObservationIgnored private var standInCache: (revision: Int, factor: Decimal)?
    /// Hiding values takes effect at once, even while another save finishes; the saved setting follows.
    private var privacyOverride: Bool?
    @ObservationIgnored private var privacyAttempt = UUID()
    var importDraft: ImportBatchDraft?
    var importMode: ImportMode = .statements
    var importTableMode = false
    private(set) var importReturnSection = "Add your info"
    // An import started from the home + button returns to the overview when it ends.
    var importReturnsHome = false
    // The single-entry form shows its own Back; the Manage header steps aside.
    var entryEditorInMenu = false
    var importMessage: String?
    /// "Add account" opens the guided form on its new-account step; the form clears this once it has read it.
    var importStartsNewAccount = false
    private(set) var importLoading = false
    private(set) var importRevision = UUID()
    @ObservationIgnored private var importTask: Task<ImportBatchDraft, Error>?
    @ObservationIgnored private var preparedMutation: Task<VaultDocument, Error>?
    private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundTask: Task<Void, Never>?
    @ObservationIgnored private var requestWatcher: Task<Void, Never>?
    @ObservationIgnored private var historyRebuildTask: Task<Void, Never>?
    /// True while past days are being recomputed in the background.
    private(set) var historyRebuilding = false
    @ObservationIgnored private var backgroundCacheRequest: Task<(packets: [BackgroundPacket], issues: [String]), Never>?
    private(set) var backgroundIssues: [String] = []
    private var priceRequest: Task<PriceUpdate, Error>?
    /// True while `priceRequest` is a scheduled catch-up, which a manual refresh may pre-empt.
    private var priceRequestIsAutomatic = false
    @ObservationIgnored private var networkMonitor: NWPathMonitor?
    @ObservationIgnored private var networkAvailable = true
    private var catalogRequest: Task<[CatalogCoin], Error>?
    private var sourceRevision = UUID()
    private(set) var catalog: [CatalogCoin] = []
    private(set) var refreshing = false
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
    @ObservationIgnored private var lastActivity = Date()
    @ObservationIgnored private var financeSurfaces = 0
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
    /// The menu stays open (and idle lock waits) only while the dialog itself is on screen, not during the work after it.
    private func presentFilePanel(_ panel: NSSavePanel) async -> NSApplication.ModalResponse {
        let token = sessionToken
        activeFilePanel = panel
        pickerDepth += 1
        defer { pickerFinished(); if activeFilePanel === panel { activeFilePanel = nil } }
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
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var inactivityTimer: Timer?
    @ObservationIgnored private var eventMonitor: Any?
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
                    guard reconnected else { return }
                    self.startBackgroundRefresh()
                    // History periods that failed while offline are retried now, not after their six-hour back-off.
                    if self.state == .unlocked { Task { await self.refreshPrices(reconnected: true, automatic: true) } }
                }
            }
            monitor.start(queue: DispatchQueue(label: "org.uponly.network"))
            networkMonitor = monitor
            startBackgroundRefresh()
            startRequestWatcher()
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
            if await vault.openedPrevious { message = Self.previousCopyNotice }
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
            if await vault.openedPrevious { message = Self.previousCopyNotice }
        } catch VaultError.cancelled { }
        catch { if sessionToken == token { message = "That recovery code could not open this vault." } }
    }

    func returnToUnlock() {
        guard !isBusy, state != .unlocked else { return }
        state = vault.io.fileExists(at: layout.current) ? .locked : .newVault
        message = nil
        // No evaluation is running now; show the fingerprint/password button instead of a spinner.
        if state == .locked { authenticationFailed = true }
    }
    /// Stops a Touch ID prompt that is waiting for a finger, e.g. when the user switches to the recovery code.
    func cancelPendingUnlock() {
        authenticationContext?.invalidate(); authenticationContext = nil
    }

    func lockAndAuthenticate() {
        lock()
        // Re-arm the embedded fingerprint only. Without Touch ID, asking to lock shouldn't pop a password dialog.
        if liveAuthenticator == nil || LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) { beginUnlock() }
        else { authenticationFailed = true }
    }

    func lock() { endSession(lockingVault: true) }

    /// Clears the session's work and view state. A restore whose vault already opened the backup passes false,
    /// keeping that new vault session and the authentication it was saved with.
    private func endSession(lockingVault: Bool) {
        activeFilePanel?.cancel(nil)
        pendingRestore = nil
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
        cancelImport(); importDraft = nil; importMessage = nil; importStartsNewAccount = false; catalog = []; sourceMessage = nil; refreshing = false
        addingInMenu = false
        managementInMenu = false
        importReturnsHome = false
        entryEditorInMenu = false
        entryMonthForManagement = ""
        requestedRateCurrency = nil
        fxIssues = [:]
        if lockingVault { vault.lock() }
        sessionToken = UUID()
        document = nil; documentRevision += 1; hourlyCache = [:]; intraday = [:]; intradayFetchedAt = [:]
        monthModel = nil
        dashboardSelection = .all
        showingSwitcher = false; dashboardHeight = nil; cashFlowScope = nil
        message = nil
        isBusy = false; writerActive = false; userWriters = []; configuringBackground = false; reconfigureBackground = false
        sourceIssues = [:]
        state = vault.io.fileExists(at: layout.current) ? .locked : .newVault
    }

    private func publish(_ document: VaultDocument, freshUnlock: Bool = false) {
        self.document = document; documentRevision += 1
        if freshUnlock || monthModel == nil {
            let model = PopoverModel()
            model.owner = self
            monthModel = model
        }
        if freshUnlock || !document.showsDestination(destination) { destination = document.defaultDestination }
        if freshUnlock || !document.showsSection(managementSection) { managementSection = document.defaultManagementSection }
        monthModel?.replace(with: document)
        // A page whose portfolio was archived, or whose company no longer has an account, goes back to All assets.
        if !Self.selectionExists(dashboardSelection, in: document) {
            if case .bankGroup = dashboardSelection { monthModel?.selectScope(cashFlowScope ?? .all); cashFlowScope = nil }
            dashboardSelection = .all
        }
        state = .unlocked
        if freshUnlock { recordActivity(); scheduleRefresh() }
        else if !isFixture { Task { await Task.yield(); await self.configureBackground() } }
    }

    /// Waits until no other write is running, then claims the writer. Background work also waits for queued user edits.
    /// User edits go in the order they were made, so two quick toggles save in that order.
    /// Fetches intraday prices for every coin (and gold) held, for a 24-hour, 7-day or 30-day chart. Each is reused for
    /// a few minutes over 24 hours and longer over the other ranges; a failure leaves the chart on saved prices.
    func loadIntraday(_ range: WorthRange) async {
        guard state == .unlocked, let document, range.intradayStep != nil else { return }
        let token = sessionToken, now = Date()
        let reuse: TimeInterval = range == .day ? 5 * 60 : range == .week ? 30 * 60 : 2 * 3600
        let assets = Set(document.holdings.filter { $0.isActive(at: now) && document.portfolio(id: $0.portfolioID)?.isActive(at: now) == true }.map(\.assetID))
            .filter { PreciousMetal.asset($0) == nil ? document.settings.automaticPrices || isFixture : (document.settings.automaticMetals || isFixture) && PreciousMetal.asset($0) == .gold }
        for asset in assets.sorted(by: { $0.rawValue < $1.rawValue }) {
            let key = range.title + "|" + asset.rawValue
            if let fetched = intradayFetchedAt[key], now.timeIntervalSince(fetched) < reuse { continue }
            let reference = document.quotes.filter { $0.assetID == asset }.max { $0.providerTime < $1.providerTime }?.priceUSD.value
            let symbol = PublicPrices.knownSymbols[asset.rawValue] ?? catalog.first { $0.id == asset.rawValue }?.symbol.lowercased()
            let series: ChartEstimates.Series
            #if UPONLY_FIXTURE
            if isFixture {
                let saved = document.quotes.filter { $0.assetID == asset }.map { (time: $0.providerTime, value: $0.priceUSD.value) }.sorted { $0.time < $1.time }
                series = Self.syntheticIntraday(asset, saved: saved, range: range, now: now)
            }
            else { series = (try? await PublicPrices.intraday(asset, symbol: symbol, reference: reference, range: range, now: now, coinGeckoKey: document.settings.coinGeckoKey)) ?? [] }
            #else
            series = (try? await PublicPrices.intraday(asset, symbol: symbol, reference: reference, range: range, now: now, coinGeckoKey: document.settings.coinGeckoKey)) ?? []
            #endif
            guard token == sessionToken, state == .unlocked else { return }
            intradayFetchedAt[key] = now
            if !series.isEmpty { intraday[key] = series }
        }
    }
    #if UPONLY_FIXTURE
    /// Saved prices drawn between, with a little noise at each step, so the finer charts can be looked at without
    /// the network and still agree with the saved days.
    static func syntheticIntraday(_ asset: CanonicalAssetID, saved: ChartEstimates.Series, range: WorthRange, now: Date) -> ChartEstimates.Series {
        guard let seconds = range.seconds, let step = range.intradayStep, let last = saved.last else { return [] }
        var seed = asset.rawValue.unicodeScalars.reduce(UInt64(7)) { $0 &* 31 &+ UInt64($1.value) }
        var points: ChartEstimates.Series = []
        var time = now.addingTimeInterval(-seconds - step)
        while time < now {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let noise = 1 + (Double(seed >> 33) / Double(1 << 31) - 0.5) * 0.008
            if let price = ChartEstimates.estimate(saved, at: time)?.value { points.append((time, price * Decimal(noise))) }
            time = time.addingTimeInterval(step)
        }
        return points + [(now, last.value)]
    }
    #endif
    static func selectionExists(_ selection: DashboardSelection, in document: VaultDocument, at date: Date = Date()) -> Bool {
        switch selection {
        case .all, .cashFlow: return true
        case .portfolio(let id): return document.portfolio(id: id)?.isActive(at: date) == true
        case .bankGroup(let id):
            return document.accounts.contains { document.isBankTracked($0.id, at: date) && (AssetOwnership.businessID(for: $0, in: document) ?? "personal") == id }
        }
    }
    private func acquireWriter(token: UUID, background: Bool) async throws {
        let ticket = UUID()
        if !background { userWriters.append(ticket) }
        defer { if !background, token == sessionToken { userWriters.removeAll { $0 == ticket } } }
        let deadline = Date().addingTimeInterval(background ? 600 : 60)
        while writerActive || (background ? !userWriters.isEmpty : userWriters.first != ticket) {
            guard token == sessionToken, state == .unlocked else { throw VaultError.locked }
            guard Date() < deadline else { throw VaultError.barrierHeld }
            try await Task.sleep(for: .milliseconds(25))
        }
        guard token == sessionToken, state == .unlocked else { throw VaultError.locked }
        writerActive = true
    }
    func mutate(_ edit: (inout VaultDocument) throws -> Void) async throws {
        guard state == .unlocked else { throw VaultError.locked }
        let token = sessionToken
        try await acquireWriter(token: token, background: false)
        isBusy = true
        defer { if token == sessionToken { isBusy = false; writerActive = false } }
        let current = try await vault.currentSession()
        guard token == sessionToken else { throw VaultError.locked }
        var next = current.document
        try edit(&next)
        try await persist(next, replacing: current, token: token)
    }

    private func persist(_ proposed: VaultDocument, replacing current: VaultSession, token: UUID) async throws {
        guard token == sessionToken, state == .unlocked else { throw VaultError.locked }
        var next = proposed
        // A confirmed month reopens only when its figures change: a row added, removed, re-amounted or re-typed.
        // Learning a row's day, a relabel from a sync, or a new empty account is not a reason to ask again.
        func ledger(_ entries: [Entry], _ month: String) -> [String] {
            entries.filter { $0.month == month }.map { $0.id.uuidString + "|" + $0.kind.rawValue + "|" + $0.bucket.rawValue + "|" + $0.currency + "|" + NSDecimalNumber(decimal: $0.amount).stringValue }.sorted()
        }
        next.reviewedMonths.removeAll { month in ledger(current.document.entries, month) != ledger(next.entries, month) }
        let now = Date()
        // A backdated quantity changes past days; recompute them away from the main actor.
        var backdated = next.quantities.filter { $0.ordinal >= current.document.nextOrdinal }.map(\.effectiveAt).min()
        // New or removed balance observations dated before today also change past days.
        let previousBalances = Set(current.document.bankBalances.map(\.id)), nextBalances = Set(next.bankBalances.map(\.id))
        let changedBalanceDays = current.document.bankBalances.filter { !nextBalances.contains($0.id) }.map(\.observedAt)
            + next.bankBalances.filter { !previousBalances.contains($0.id) }.map(\.observedAt)
        if let earliest = changedBalanceDays.min(), earliest < UTCDay.start(of: now) { backdated = min(backdated ?? earliest, earliest) }
        // Backdated tracking makes an account count on earlier days, so those days change too.
        if let tracked = next.bankTracking.filter({ $0.ordinal >= current.document.nextOrdinal }).map(\.effectiveAt).min(), tracked < UTCDay.start(of: now) { backdated = min(backdated ?? tracked, tracked) }
        // Archiving or restoring a portfolio changes every day since it was archived.
        let archiveDays = next.portfolios.compactMap { portfolio -> Date? in
            let before = current.document.portfolio(id: portfolio.id)?.archivedAt
            return before == portfolio.archivedAt ? nil : [before, portfolio.archivedAt].compactMap { $0 }.min()
        }
        if let archived = archiveDays.min(), archived < UTCDay.start(of: now) { backdated = min(backdated ?? archived, archived) }
        // Past days are rebuilt afterwards in short background chunks, newest first, so saving never waits on years of history.
        let rebuilt = backdated.map { $0 < UTCDay.start(of: now) } ?? false
        if rebuilt, let backdated {
            let from = min(next.pendingHistoryRebuild?.from ?? backdated, UTCDay.start(of: backdated))
            next.pendingHistoryRebuild = PendingHistoryRebuild(from: from, cursor: now)
        }
        for scope in next.valuationScopes {
            NetWorthCalculator.recordSample(NetWorthCalculator.value(at: now, scope: scope, document: next, now: now), in: &next)
        }
        next.generation = current.document.generation + 1
        try await vault.commit(next, expectedGeneration: current.document.generation, sessionID: current.sessionID)
        guard token == sessionToken else { throw VaultError.locked }
        publish(next)
        if rebuilt { scheduleHistoryRebuild() }
    }
    /// Recomputes stored daily values in 45-day chunks, newest first, each saved on its own so the interface stays
    /// responsive and the chart fills in progressively. Progress lives in the vault, so a relaunch resumes.
    /// Fetches history prices first, so rebuilt days can be valued on the first pass, and again once finished.
    func scheduleHistoryRebuild() {
        guard historyRebuildTask == nil, document?.pendingHistoryRebuild != nil else { return }
        historyRebuilding = true
        historyRebuildTask = Task { [weak self] in
            await self?.refreshPrices()
            var failed = false
            while let self, self.state == .unlocked, self.document?.pendingHistoryRebuild != nil {
                do {
                    // The chunk is worked out from the document being saved, so a backdated save that landed while this
                    // waited for its turn widens the range instead of being overwritten.
                    try await self.mutatePrepared { document in
                        guard let pending = document.pendingHistoryRebuild else { throw CancellationError() }
                        // Days before the rebuild horizon are never stored (HoldingMutations.rebuildHistory), so stop there.
                        let from = max(UTCDay.start(of: pending.from), UTCDay.start(of: Date()).addingTimeInterval(-2200 * 86400))
                        var next = document
                        guard pending.cursor > from else { next.pendingHistoryRebuild = nil; return next }
                        let chunkStart = max(from, UTCDay.start(of: pending.cursor).addingTimeInterval(-45 * 86400))
                        next = HoldingMutations.rebuildHistory(from: chunkStart, to: pending.cursor, document: document, now: Date())
                        next.pendingHistoryRebuild = chunkStart <= from ? nil : PendingHistoryRebuild(from: pending.from, cursor: chunkStart)
                        return next
                    }
                } catch {
                    failed = !(error is CancellationError)
                    break
                }
                // Give a waiting edit its turn between chunks.
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard let self else { return }
            if self.state == .unlocked { await self.refreshPrices() }
            self.historyRebuildTask = nil; self.historyRebuilding = false
            // A backdated save during the last chunk queued more work; pick it up now rather than in 15 minutes.
            // After a failed save (full disk, size limit) the 15-minute loop retries instead of spinning here.
            if !failed, self.state == .unlocked, self.document?.pendingHistoryRebuild != nil { self.scheduleHistoryRebuild() }
        }
    }
    /// Re-runs balance reconstruction for every account so tracking and derived series match the current rules.
    func repairBalanceHistory() async {
        guard state == .unlocked, let doc = document else { return }
        let ids = Set(doc.accounts.filter { account in doc.bankBalances.contains { $0.accountID == account.id } }.map(\.id))
        guard !ids.isEmpty else { return }
        // Most runs change nothing; skip the full-vault write then.
        var probe = doc
        guard BalanceReconstruction.apply(accountIDs: ids, to: &probe) != nil else { return }
        try? await mutatePrepared { document in
            var next = document
            _ = BalanceReconstruction.apply(accountIDs: ids, to: &next)
            return next
        }
    }

    /// Prepares the next document off the main actor. Background writers (history, prices, cached updates) don't
    /// set `isBusy`, so forms stay usable while they run; user edits simply wait for them to finish.
    private func mutatePrepared(background: Bool = true, _ prepare: @escaping @Sendable (VaultDocument) throws -> VaultDocument) async throws {
        guard state == .unlocked else { throw VaultError.locked }
        let token = sessionToken
        try await acquireWriter(token: token, background: background)
        if !background { isBusy = true }
        defer { if token == sessionToken { if !background { isBusy = false }; writerActive = false; preparedMutation = nil } }
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

    static func name(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw VaultError.invalidAmount }
        return name
    }

    static let previousCopyNotice = "Your vault file was damaged, so Up Only opened the copy from your previous save. Your most recent change may be missing."
    static let inactivityInterval: TimeInterval = 5 * 60
    func recordActivity(at date: Date = Date()) { lastActivity = date }
    func handleActivity(at date: Date = Date()) {
        // App Nap can delay timer delivery while the menu is closed. An expired
        // session must lock before a new click can restart its idle period.
        checkInactivity(at: date)
        recordActivity(at: date)
    }
    func checkInactivity(at date: Date = Date()) {
        // Activity inside the out-of-process file dialog isn't seen here, so an open dialog gets longer before locking.
        guard state == .unlocked, date.timeIntervalSince(lastActivity) >= (filePickerIsOpen ? 3 : 1) * Self.inactivityInterval else { return }
        lock()
    }
    func togglePrivacyMode() async throws {
        recordActivity()
        let hidden = !privacyMode, attempt = UUID()
        privacyOverride = hidden; privacyAttempt = attempt
        // Only the latest toggle hands back to the saved setting, so a quick double toggle doesn't flicker.
        defer { if privacyAttempt == attempt { privacyOverride = nil } }
        try await mutate { $0.settings.privacyMode = hidden }
    }

    func menuOpened() {
        surfaceOpened()
        // One attempt per opening. Reopening retries after cancellation;
        // changes to the lock view must not immediately prompt again.
        if state == .locked { beginUnlock() }
        else if state == .unlocked {
            // A note from an earlier visit ("Couldn't save…") no longer describes what's on screen.
            message = nil
            Task { await self.applyBackgroundCache() }
        }
    }
    func surfaceOpened() { financeSurfaces += 1; handleActivity() }
    func surfaceClosed() {
        dropZoneVisible = false
        showingSwitcher = false
        financeSurfaces = max(0, financeSurfaces - 1)
        // Dismissing a popover keeps the vault available for the remaining idle period.
        if financeSurfaces == 0, authenticationContext != nil { lock() }
    }
    private func pickerFinished() {
        pickerDepth = max(0, pickerDepth - 1)
        recordActivity()
    }

    @discardableResult
    func startImport(_ mode: ImportMode, prefill: Bool = false, accountID: UUID? = nil, portfolioID: UUID? = nil, holdingID: UUID? = nil, newAccount: Bool = false) -> Bool {
        guard state == .unlocked, let document else { return false }
        guard importDraft == nil else {
            // Show the unfinished draft rather than silently ignoring the tap.
            managementSection = "Add your info"; addingInMenu = false; managementInMenu = true
            importMessage = "Your unfinished draft is still here. Save it or discard it before starting another."
            return false
        }
        importReturnSection = managementSection
        cancelImport(); importMessage = nil; importMode = mode; importTableMode = false; managementSection = "Add your info"
        importStartsNewAccount = newAccount && mode == .bankBalances
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
        finishHomeImport(saved: nil)
    }
    /// `saved` is the mode of a batch that was saved, or nil when the import was discarded.
    private func finishHomeImport(saved: ImportMode?) {
        guard importReturnsHome else { return }
        importReturnsHome = false; managementInMenu = false; addingInMenu = false; importMessage = nil
        if let saved { flash(saved == .statements ? "Statement imported." : saved == .bankBalances ? "Balances saved." : saved == .metals ? "Gold & silver saved." : "Holdings saved.") }
    }
    func cancelImport() {
        importTask?.cancel(); importTask = nil; importLoading = false; importRevision = UUID()
    }
    func chooseImportFiles() async {
        guard state == .unlocked, !importLoading, !filePickerIsOpen else { focusFilePicker(); return }
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
        let task = Task.detached(priority: .userInitiated) { () throws -> ImportBatchDraft in
            var next = draft
            guard urls.count + next.sources.filter({ !$0.grid.isEmpty }).count <= ImportBatchDraft.maxFiles else { throw ImportFailure("Choose at most 50 files.") }
            // Only an account chosen before picking files applies to every file; otherwise each file is matched on its own.
            let defaultAccount = next.sources.first { $0.grid.isEmpty && $0.account.existingID != nil }?.account ?? ImportAccount()
            if next.rows.isEmpty { next.sources.removeAll { $0.grid.isEmpty } }
            for url in urls {
                try Task.checkCancellation()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= VaultLimits.maxBatchBytes else { throw StatementError.tooLarge }
                let bytes = try Data(contentsOf: url)
                for var source in try ImportParser.sources(bytes: bytes, filename: url.lastPathComponent, mode: next.mode) {
                    source.account = ImportParser.account(for: source, preferred: defaultAccount, saved: accounts)
                    // Income, spending and company transfers are classified when the batch is checked, with the final number format.
                    next.rows += try ImportParser.rows(source: source, mode: next.mode)
                    next.sources.append(source); try next.checkLimits()
                }
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
            var source = try ImportParser.source(bytes: Data(text.utf8), filename: "Pasted cells", mode: next.mode)
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
        let token = sessionToken, mode = importDraft?.mode ?? importMode
        let panel = NSSavePanel(); panel.allowedContentTypes = [.commaSeparatedText]; panel.nameFieldStringValue = mode.rawValue + ".csv"
        guard await presentFilePanel(panel) == .OK, let url = panel.url, token == sessionToken else { return }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do { try mode.template.write(to: url, atomically: true, encoding: .utf8) }
        catch { importMessage = "The template could not be saved." }
    }
    func commitImportBatch(_ draft: ImportBatchDraft) async throws {
        let coins = catalog
        try await mutatePrepared(background: false) { document in
            let review = ImportBatchProcessor.evaluate(draft, document: document, catalog: coins)
            guard !review.hasErrors, review.added > 0, let next = review.document else {
                throw ImportFailure(review.globalError ?? "Review this batch again. Fix or exclude every flagged row before saving.")
            }
            return next
        }
        importDraft = nil; importMessage = "Your information has been saved."; managementSection = importReturnSection
        finishHomeImport(saved: draft.mode)
        Task { await refreshPrices() }
    }

    func exportBackup() async {
        guard state == .unlocked, !filePickerIsOpen, !exportingBackup else { focusFilePicker(); return }
        let token = sessionToken
        let panel = NSSavePanel()
        // A dated name keeps earlier backups and never collides with yesterday's.
        panel.nameFieldStringValue = "Up Only Backup " + ImportDateFormat.today(Date()) + ".uponlybackup"
        panel.canCreateDirectories = true
        guard await presentFilePanel(panel) == .OK, let url = panel.url, token == sessionToken else { return }
        exportingBackup = true; defer { exportingBackup = false }
        do {
            let package = try await BackupCoordinator.makePackage(store: vault, producers: [])
            guard token == sessionToken else { throw VaultError.locked }
            // Hashing and writing up to a few hundred megabytes stays off the main thread.
            try await Task.detached(priority: .userInitiated) {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                try BackupCoordinator.publish(package, to: url, io: DiskFileIO())
            }.value
            guard token == sessionToken else { return }
            flash("Encrypted backup saved. Keep your recovery code separately.")
        } catch { if token == sessionToken { message = "Backup could not be saved. Choose a new filename and try again." } }
    }
    /// Replaces the recovery code after Touch ID or the Mac password. The old code stops opening this vault;
    /// backups exported earlier keep the code they were exported with.
    func replaceRecoveryCode(_ code: RecoveryCode) async -> Bool {
        guard state == .unlocked else { return false }
        let token = sessionToken
        message = nil
        do {
            try await acquireWriter(token: token, background: false)
            isBusy = true
            defer { if token == sessionToken { isBusy = false; writerActive = false } }
            let current = try await vault.currentSession()
            guard token == sessionToken else { throw VaultError.locked }
            try await vault.rotateRecovery(code, sessionID: current.sessionID)
            guard token == sessionToken else { return false }
            flash("Recovery code replaced. Export a new backup so it uses the new code.")
            return true
        } catch VaultError.cancelled { return false }
        catch {
            if token == sessionToken { message = "Your recovery code couldn’t be replaced. Your current code still works." }
            return false
        }
    }
    /// A success note that clears itself, so it doesn't linger on later pages.
    func flash(_ text: String) {
        message = text
        let token = sessionToken
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, self.sessionToken == token, self.message == text else { return }
            self.message = nil
        }
    }

    private func installLockObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.startBackgroundRefresh() }
        })
        // Lock before the observer returns, so the vault is closed before the Mac sleeps.
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lock() }
            })
        }
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.lock() } })
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
                // A multi-currency Wise export becomes one source per currency.
                let sources = try ImportParser.sources(bytes: Data(contentsOf: URL(fileURLWithPath: path)), filename: "statement.csv", mode: .statements)
                var batch = ImportBatchDraft(mode: .statements, sources: sources, rows: try sources.flatMap { try ImportParser.rows(source: $0, mode: .statements) })
                let review = ImportBatchProcessor.evaluate(batch, document: doc)
                guard !review.hasErrors, let saved = review.document else { throw ImportFailure("Statement validation failed.") }
                batch.sources = sources.map { source in
                    var source = source
                    source.account.existingID = saved.accounts.first { $0.name == source.account.name && $0.currency == source.account.currency }?.id ?? saved.accounts[0].id
                    return source
                }
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
                // A company whose share is only recorded from this month, as when its sheet starts late.
                if ProcessInfo.processInfo.environment["UPONLY_PREVIEW_OWNERSHIP_GAP"] == "1" {
                    fixture.businessAccounting?[0].ownership = [.init(fromMonth: MonthKey.current().description, numerator: 1, denominator: 2)]
                }
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
        guard state == .unlocked, !isFixture, !accountingRefreshing else { return }
        let token = sessionToken
        accountingRefreshing = true; accountingError = nil
        defer { if token == sessionToken { accountingRefreshing = false; accountingRequest = nil } }
        do {
            let request = Task.detached(priority: .utility) { try await AccountingAPI.fetchResult(AccountingConnection.load()) }; accountingRequest = request
            let result = try await request.value
            guard token == sessionToken, !Task.isCancelled, !request.isCancelled else { return }
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
        guard state == .unlocked, !isFixture, !wiseRefreshing, document?.settings.automaticWise == true else { return }
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
                #if UPONLY_PERSONAL
                // Wise rows saved before days were kept need one sync to rebuild their balance history.
                if self.document?.entries.contains(where: { $0.source == .wise && $0.day == nil }) == true { await self.refreshWise() }
                #endif
                await self.repairBalanceHistory()
                self.scheduleHistoryRebuild()
                await self.refreshPrices(automatic: true)
                do { try await Task.sleep(for: .seconds(15 * 60)) } catch { return }
            }
        }
    }
    func refreshPrices(reconnected: Bool = false, automatic: Bool = false, round: Int = 0) async {
        let log = Logger(subsystem: "org.uponly", category: "prices")
        // A manual refresh takes over from a scheduled catch-up instead of silently doing nothing.
        if !automatic, priceRequestIsAutomatic, let running = priceRequest { running.cancel(); priceRequest = nil; priceRequestIsAutomatic = false; log.notice("manual refresh pre-empted scheduled catch-up") }
        guard state == .unlocked, !refreshing, priceRequest == nil, !isFixture, let doc = document else {
            log.notice("refresh skipped automatic=\(automatic) unlocked=\(self.state == .unlocked) refreshing=\(self.refreshing) pending=\(self.priceRequest != nil)")
            return
        }
        let activeHoldings = doc.holdings.filter { $0.isActive(at: Date()) && doc.portfolio(id: $0.portfolioID)?.isActive(at: Date()) == true }
        log.notice("refresh start automatic=\(automatic) prices=\(doc.settings.automaticPrices) metals=\(doc.settings.automaticMetals) fx=\(doc.settings.automaticFX) keyLength=\(doc.settings.coinGeckoKey.count) holdings=\(doc.holdings.count, privacy: .private) active=\(activeHoldings.count, privacy: .private) portfolios=\(doc.portfolios.count, privacy: .private)")
        let token = sessionToken, revision = sourceRevision
        if automatic {
            guard priceRequest == nil else { return }
            // A reconnect retries right away; otherwise catch-up runs once per history slot.
            let claimed = reconnected ? true : (try? await BackgroundRefreshSchedule.shared.claim(vaultID: doc.vaultID, root: Config.supportDirectory, source: "history")) == true
            guard claimed, token == sessionToken, state == .unlocked, priceRequest == nil else { return }
        } else {
            refreshing = true
            sourceMessage = "Updating prices and checking for missed history…"
        }
        fxIssues = [:]
        var mine: Task<PriceUpdate, Error>?
        // Only the refresh that owns the current request clears it; a pre-empted catch-up must not clobber its replacement.
        defer { if token == sessionToken, revision == sourceRevision, priceRequest == mine { refreshing = false; priceRequest = nil; priceRequestIsAutomatic = false } }
        do {
            let request = Task.detached(priority: automatic ? .utility : .userInitiated) { try await PublicPrices.update(document: doc, reconnected: reconnected, includeCurrent: !automatic && round == 0) }
            priceRequest = request; priceRequestIsAutomatic = automatic; mine = request
            let update = try await request.value
            log.notice("refresh result quotes=\(update.quotes.count) rates=\(update.rates.count) messages=\(update.messages.joined(separator: " | "), privacy: .private) issues=\(update.sourceIssues.values.joined(separator: " | "), privacy: .private)")
            guard token == sessionToken, revision == sourceRevision, !Task.isCancelled else { log.notice("refresh result discarded: session changed or cancelled"); return }
            if !update.quotes.isEmpty || !update.rates.isEmpty || !update.coverage.isEmpty {
                try await commitPriceUpdate(update)
            }
            guard token == sessionToken, revision == sourceRevision else { return }
            if !automatic { sourceMessage = update.messages.isEmpty ? "Updated " + Date().formatted(date: .omitted, time: .shortened) : update.messages.joined(separator: "\n") }
            fxIssues = update.fxIssues
            if !automatic {
                // Follow-up rounds only fetch history, so they add to the first round's report rather than replace it.
                if round == 0 {
                    sourceIssues = update.sourceIssues
                    // A successful manual update supersedes an earlier background failure for that source.
                    for (source, issue) in [("Crypto", "crypto"), ("Metals", "metals"), ("Exchange rates", "fx")] where update.sourceIssues[issue] == nil {
                        backgroundIssues.removeAll { $0 == source || $0.lowercased().hasPrefix(issue + " ") }
                    }
                } else { sourceIssues.merge(update.sourceIssues) { $1 } }
                // Keep going while history is still queued, instead of leaving gaps until the next hourly slot.
                if round < 6, update.messages.contains(where: { $0.hasPrefix("More price history is queued") }) {
                    Task { [weak self] in await self?.refreshPrices(round: round + 1) }
                }
            }
        } catch {
            log.error("refresh failed: \(String(describing: error), privacy: .private)")
            // A catch-up pre-empted by a manual refresh isn't a failure.
            if error is CancellationError || mine?.isCancelled == true { return }
            if token == sessionToken, revision == sourceRevision, !Task.isCancelled {
                let issue = (error as? PriceError)?.localizedDescription ?? "Prices could not be saved. Your saved observations are unchanged; catch-up will retry."
                if !automatic { sourceMessage = issue; sourceIssues = ["crypto": issue, "metals": issue, "fx": issue] }
                if doc.settings.automaticFX {
                    fxIssues = Dictionary(uniqueKeysWithValues: Set(doc.accounts.map(\.currency) + doc.entries.map(\.currency)).subtracting(["USD"]).map { ($0, issue) })
                }
            }
        }
    }
    /// A structural summary of the vault for debugging chart gaps, written only when the user asks for it.
    /// It names accounts and holdings but has no amounts; the file is readable by this user only.
    func writeDiagnostics() -> String {
        guard let doc = document else { return "Unlock first." }
        let day = BalanceReconstruction.dayFormatter()
        var lines: [String] = ["generated \(Date())"]
        lines.append("accounts:")
        for account in doc.accounts {
            let balances = doc.bankBalances.filter { $0.accountID == account.id }
            let derived = balances.filter { $0.source == BalanceReconstruction.source }
            let entries = doc.entries.filter { $0.accountID == account.id || (account.externalProfileID != nil && $0.source == .wise && $0.currency == account.currency && $0.sourceRef?.hasPrefix("wise:" + account.externalProfileID! + ":") == true) }
            let tracking = doc.bankTracking.filter { $0.accountID == account.id }.sorted { $0.ordinal < $1.ordinal }.map { ($0.tracked ? "on " : "off ") + day.string(from: $0.effectiveAt) }
            lines.append("  \(account.name) [\(account.currency)] profile=\(account.externalProfileID ?? "-") balances=\(balances.count) (derived \(derived.count), \(derived.map { day.string(from: $0.observedAt) }.min() ?? "-")..\(derived.map { day.string(from: $0.observedAt) }.max() ?? "-")) real=\(balances.filter { $0.source != BalanceReconstruction.source }.map { $0.source + "@" + day.string(from: $0.observedAt) }.sorted().suffix(3).joined(separator: ",")) entries=\(entries.count) withDay=\(entries.filter { $0.day != nil }.count) withOutflow=\(entries.filter { $0.outflow != nil }.count) tracking=\(tracking.joined(separator: ";")) trackedNow=\(doc.isBankTracked(account.id, at: Date()))")
        }
        lines.append("fx:")
        for currency in Set(doc.fx.map(\.sourceCurrency)).sorted() {
            let days = Set(doc.fx.filter { $0.sourceCurrency == currency }.map { day.string(from: UTCDay.start(of: $0.providerTime)) })
            lines.append("  \(currency) days=\(days.count) first=\(days.min() ?? "-") last=\(days.max() ?? "-")")
        }
        lines.append("coverage: " + (doc.priceHistoryCoverage ?? []).map { $0.key + " " + day.string(from: $0.start) + ".." + day.string(from: $0.end) + ($0.complete ? " ok" : " partial") }.joined(separator: " | "))
        lines.append("daily valuations (allTracked, last 300 days):")
        let samples = doc.dailyValuations.filter { $0.scope == .allTracked && $0.utcDay > Date().addingTimeInterval(-300 * 86400) }.sorted { $0.utcDay < $1.utcDay }
        var previous = ""
        for sample in samples {
            let missing = sample.components.filter { $0.missing != nil }.map { $0.label + ":" + ($0.missing ?? "") }.sorted().joined(separator: ",")
            let line = "complete=\(sample.isComplete) components=\(sample.components.count) missing=[\(missing)]"
            if line != previous { lines.append("  \(day.string(from: sample.utcDay)) " + line); previous = line }
        }
        let days = Dictionary(grouping: samples) { UTCDay.start(of: $0.utcDay) }
        let completeDays = days.values.filter { $0.contains(where: \.isComplete) }.count
        lines.append("  … \(samples.count) samples over \(days.count) days; \(completeDays) days have a complete value, \(days.count - completeDays) do not; a line is printed only when the state changes")
        // Why a chart would have to estimate or leave out a day: a company's share not recorded for the month, or
        // a part with no value even after estimating.
        lines.append("companies:")
        for book in doc.businessAccounting ?? [] {
            lines.append("  \(book.name) first=\(book.firstMonth) ownership=" + book.ownership.sorted { $0.fromMonth < $1.fromMonth }.map { $0.fromMonth + " " + $0.label }.joined(separator: ", "))
        }
        let estimates = ChartEstimates(document: doc)
        let exact = samples.filter { AssetOwnership.personalTotal($0.components, at: $0.utcDay, document: doc) != nil }.count
        let valued = samples.filter { estimates.personalTotal($0.components, day: $0.utcDay) != nil }.count
        lines.append("  chart: \(exact) samples valued as saved, \(valued - exact) estimated, \(samples.count - valued) left out")
        lines.append("pending rebuild: " + (doc.pendingHistoryRebuild.map { day.string(from: $0.from) + " .. " + day.string(from: $0.cursor) } ?? "none"))
        let url = Config.supportDirectory.appendingPathComponent("diagnostics.txt")
        do {
            try Data(lines.joined(separator: "\n").utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return "Written to " + url.path
        }
        catch { return "Could not write: " + error.localizedDescription }
    }
    func commitPriceUpdate(_ update: PriceUpdate) async throws {
        try await mutatePrepared { current in try PriceHistory.applying(update, to: current, now: Date()) }
    }
    func repairExchangeRates(month: MonthKey, currencies: [String]) async {
        guard state == .unlocked else { return }
        // Explicit repair takes priority over a broad background history refresh.
        priceRequest?.cancel(); priceRequest = nil; priceRequestIsAutomatic = false
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
    /// Replaces the catalog with ranked search hits for `query`. Cheap enough to run as the user types.
    func searchCatalog(_ query: String) async {
        guard state == .unlocked, !isFixture, let settings = document?.settings else { return }
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 2, !Task.isCancelled else { return }
        let token = sessionToken, revision = sourceRevision
        catalogRequest?.cancel()
        let request = Task { try await PublicPrices.searchCoins(clean, key: settings.automaticPrices ? settings.coinGeckoKey : "") }
        catalogRequest = request
        guard let coins = try? await request.value, token == sessionToken, revision == sourceRevision, !Task.isCancelled else { return }
        var merged = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
        for coin in coins { merged[coin.id] = coin }
        catalog = Array(merged.values)
    }
    private func resetSourceWork() {
        refreshTask?.cancel(); refreshTask = nil
        priceRequest?.cancel(); priceRequest = nil; priceRequestIsAutomatic = false
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
    /// Restores a backup from the welcome screen, into an empty vault folder.
    @discardableResult
    func restoreBackup(code: String) async -> Bool {
        guard state == .newVault else { return false }
        return await chooseBackup(code: code, confirmed: true) == .restored
    }
    /// Restores a backup in place of the unlocked vault. A vault with records returns `.needsConfirmation` and keeps the
    /// chosen backup, so the confirmed call doesn't ask for the folder again.
    func restoreReplacingVault(code: String, confirmed: Bool) async -> RestoreOutcome {
        guard state == .unlocked else { return .cancelled }
        if confirmed, let pending = pendingRestore, pending.recovery.matches(code) {
            return await restoreBackup(pending.package, recovery: pending.recovery, confirmed: true)
        }
        return await chooseBackup(code: code, confirmed: confirmed)
    }
    func cancelPendingRestore() { pendingRestore = nil }

    private func chooseBackup(code: String, confirmed: Bool) async -> RestoreOutcome {
        pendingRestore = nil
        guard !isBusy, !filePickerIsOpen else { focusFilePicker(); return .cancelled }
        // Check the code's shape before asking for a folder, so a typo doesn't cost a trip through the file dialog.
        guard let recovery = try? RecoveryCode(canonical: code) else {
            message = "That recovery code isn’t complete. Check every group and try again."
            return .failed
        }
        let token = sessionToken, replacing = state == .unlocked
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "Choose the Up Only Backup folder"; panel.prompt = "Restore"
        guard await presentFilePanel(panel) == .OK, let url = panel.url, token == sessionToken else { return .cancelled }
        isBusy = true; message = nil
        // Reading and hashing up to a few hundred megabytes stays off the main thread.
        let package = try? await Task.detached(priority: .userInitiated) { () throws -> BackupPackage in
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            return try BackupCoordinator.read(from: url, io: DiskFileIO())
        }.value
        guard token == sessionToken else { return .cancelled }
        isBusy = false
        guard let package else { message = Self.restoreFailure(replacing: replacing); return .failed }
        return await restoreBackup(package, recovery: recovery, confirmed: confirmed)
    }
    private static func restoreFailure(replacing: Bool) -> String {
        replacing ? "Restore failed. Your current vault is unchanged." : "Restore failed. Check the backup and recovery code. An existing vault is never replaced."
    }

    /// The restore both entry points share. A code that doesn't open the backup stops here, and replacing a vault with
    /// records asks first. Then the user authenticates and the backup is restored and opened. An unlocked vault's folder
    /// is moved aside, never deleted; if anything fails after that, it is put back and the vault locks.
    func restoreBackup(_ package: BackupPackage, recovery: RecoveryCode, confirmed: Bool) async -> RestoreOutcome {
        pendingRestore = nil
        let replacing = state == .unlocked
        guard replacing || state == .newVault, !isBusy else { return .cancelled }
        guard BackupCoordinator.opens(package, with: recovery) else {
            message = "That recovery code doesn’t open this backup. Use the code that was current when it was exported."
            return .failed
        }
        if replacing, !confirmed, document?.hasRecords == true {
            pendingRestore = (package: package, recovery: recovery)
            return .needsConfirmation
        }
        var token = sessionToken
        isBusy = true; message = nil
        defer { if token == sessionToken { isBusy = false } }
        do {
            let opened: VaultSession
            if replacing {
                // The vault's own authenticator (the session's live one in the app), so the restore's Keychain write uses
                // this authentication and Touch ID stays wired.
                try await vault.authenticator.evaluate()
                guard token == sessionToken else { return .cancelled }
                try await acquireWriter(token: token, background: false)
                let aside = layout.replacedRoot(at: Date(), io: vault.io)
                do {
                    opened = try await vault.replace(with: package, recovery: recovery, aside: aside)
                } catch {
                    guard token == sessionToken else { return .failed }
                    // A backup refused before anything moved leaves the vault open; otherwise the original is back, locked,
                    // with unlock ready as after Lock now.
                    if await vault.isUnlocked { writerActive = false } else { lockAndAuthenticate() }
                    message = vault.io.fileExists(at: aside)
                        ? "Restore failed. Your vault is in the folder “\(aside.lastPathComponent)” beside where it was."
                        : Self.restoreFailure(replacing: true)
                    return .failed
                }
                guard token == sessionToken else { return .failed }
                // The vault already has the backup's session; clear what the replaced one left behind.
                endSession(lockingVault: false)
                token = sessionToken
                publish(opened.document, freshUnlock: true)
                flash("Backup restored. Your previous vault is in the folder “\(aside.lastPathComponent)” beside it.")
                return .restored
            }
            #if UPONLY_FIXTURE
            let keys: VaultKeyStoring = MemoryKeyStore()
            let auth: VaultAuthenticating = FixtureAuthenticator()
            #else
            let keys: VaultKeyStoring = KeychainVaultKeyStore()
            // Keep the session's authenticator so embedded Touch ID and "Use Mac password" stay wired after restoring.
            let live = liveAuthenticator ?? LiveAuthenticator()
            liveAuthenticator = live
            let auth: VaultAuthenticating = live
            #endif
            try await auth.evaluate()
            guard token == sessionToken else { throw VaultError.locked }
            try await vault.releaseEmptyDestination()
            _ = try BackupCoordinator.restore(package: package, recovery: recovery, keys: keys, layout: layout, io: DiskFileIO(), authenticator: auth)
            vault = VaultStore(layout: layout, io: DiskFileIO(), keys: keys, authenticator: auth)
            opened = try await vault.unlock()
            guard token == sessionToken else { return .failed }
            publish(opened.document, freshUnlock: true)
            return .restored
        } catch VaultError.cancelled { return .cancelled }
        catch {
            if token == sessionToken { message = Self.restoreFailure(replacing: replacing) }
            return .failed
        }
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
    /// A `refresh.request` file in the support folder asks an unlocked app to repair balance history and refresh
    /// prices and rates now. It lets a script trigger the same work as the Sources refresh button.
    private func startRequestWatcher() {
        requestWatcher?.cancel()
        requestWatcher = Task { [weak self] in
            let refresh = Config.supportDirectory.appendingPathComponent("refresh.request")
            // `rebuild.request` recomputes every stored day from the earliest asset or balance, in the background.
            let rebuild = Config.supportDirectory.appendingPathComponent("rebuild.request")
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, self.state == .unlocked, !self.isBusy else { continue }
                if FileManager.default.fileExists(atPath: rebuild.path) {
                    try? FileManager.default.removeItem(at: rebuild)
                    await self.rebuildAllHistory()
                }
                guard FileManager.default.fileExists(atPath: refresh.path), !self.refreshing else { continue }
                try? FileManager.default.removeItem(at: refresh)
                await self.repairBalanceHistory()
                #if UPONLY_PERSONAL
                if self.document?.settings.automaticWise == true { await self.refreshWise() }
                #endif
                await self.refreshPrices()
            }
        }
    }
    /// Marks every stored day for recomputation, from the earliest holding or balance, and starts the background rebuild.
    func rebuildAllHistory() async {
        guard state == .unlocked, let doc = document else { return }
        let earliest = (doc.holdings.map(\.createdAt) + doc.bankBalances.map(\.observedAt)).min() ?? Date()
        try? await mutate { document in
            document.pendingHistoryRebuild = PendingHistoryRebuild(from: UTCDay.start(of: earliest), cursor: Date())
        }
        scheduleHistoryRebuild()
    }
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
                        self.backgroundIssues = issues
                        if self.state == .unlocked { await self.applyBackgroundCache() }
                    }
                } catch { self?.backgroundIssues = ["Background source configuration"] }
                do { try await Task.sleep(for: .seconds(BackgroundRefresh.interval)) } catch { return }
            }
        }
    }
    func configureBackground() async {
        guard !isFixture, state == .unlocked, let current = document, current.settings.setupComplete else { return }
        // One configuration at a time: overlapping runs would each mint a signing key. A request that arrives
        // meanwhile runs once more afterwards with the latest document.
        guard !configuringBackground else { reconfigureBackground = true; return }
        configuringBackground = true
        let token = sessionToken
        defer {
            if token == sessionToken {
                configuringBackground = false
                if reconfigureBackground { reconfigureBackground = false; Task { await self.configureBackground() } }
            }
        }
        do {
            let saved = try await Task.detached(priority: .utility) { try BackgroundConfiguration.load() }.value
            guard token == sessionToken, state == .unlocked else { return }
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
        guard !isFixture, state == .unlocked, let current = document else { return }
        let token = sessionToken
        guard backgroundCacheRequest == nil else { return }
        let root = Config.supportDirectory
        let request = Task.detached(priority: .utility) { BackgroundRefresh.cachedPackets(document: current, root: root) }
        backgroundCacheRequest = request
        defer { if token == sessionToken { backgroundCacheRequest = nil } }
        let result = await withTaskCancellationHandler(operation: { await request.value }, onCancel: { request.cancel() })
        guard token == sessionToken, state == .unlocked, !Task.isCancelled, !request.isCancelled else { return }
        backgroundIssues = Array(Set(backgroundIssues + result.issues))
        // Each cached update is saved on its own, so one unreadable packet can't hold back the others.
        var failed = false
        for update in result.packets {
            guard token == sessionToken, state == .unlocked else { return }
            do { try await mutatePrepared { try BackgroundRefresh.applying(update, to: $0) } } catch { failed = true }
        }
        if failed, token == sessionToken { backgroundIssues = Array(Set(backgroundIssues + ["Cached updates"])) }
    }
}
