import SwiftUI
import LocalAuthentication
import LocalAuthenticationEmbeddedUI

struct UpOnlyPanel: View {
    var menuLifecycleManaged = false
    var closeMenu: (() -> Void)?
    @Environment(UpOnlySession.self) private var session
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Group {
            if session.state == .unlocked, session.document?.settings.setupComplete == true, session.managementInMenu, !session.addingInMenu {
                UpOnlyManagement().id(session.sessionToken).frame(width: 344)
            } else if session.state != .unlocked {
                panelContent.fixedSize(horizontal: false, vertical: true)
            } else {
                UpOnlyMenuScroll(maxHeight: 600) { panelContent }
                    .frame(width: 344).fixedSize(horizontal: false, vertical: true)
            }
        }
        .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.regular)
        .background { Color(nsColor: .windowBackgroundColor).ignoresSafeArea() }
        .background(UpOnlyPanelKeyboard(close: { if let closeMenu { closeMenu() } else { dismiss() } }).frame(width: 0, height: 0))
        .background {
            if session.state == .unlocked, session.unlockTiming != nil {
                UpOnlyUnlockDisplayProbe { session.recordUnlockedMenuDisplay() }.frame(width: 1, height: 1)
            }
        }
        .onAppear { if !menuLifecycleManaged { session.menuOpened() } }
        .onDisappear { if !menuLifecycleManaged { session.surfaceClosed() } }
    }
    private var panelContent: some View {
        Group {
            if session.state == .unlocked, let model = session.monthModel {
                Group {
                if session.document?.settings.setupComplete != true { UpOnlySetup().id(session.sessionToken) }
                else if session.addingInMenu { UpOnlyEntryFlow(compact: true).id(session.sessionToken) }
                else { UpOnlyUnlockedPanel(model: model).id(session.sessionToken) }
                }.frame(width: 344)
            } else { UpOnlyLockView().id(session.sessionToken) }
        }
    }
}

// An opt-in probe reports after AppKit displays the unlocked menu. It samples
// no pixels or accessibility values and draws no visible content.
private struct UpOnlyUnlockDisplayProbe: NSViewRepresentable {
    var displayed: () -> Void
    func makeNSView(context: Context) -> Probe { let view = Probe(); view.displayed = displayed; return view }
    func updateNSView(_ view: Probe, context: Context) { view.displayed = displayed; view.schedule() }
    final class Probe: NSView {
        var displayed: (() -> Void)?
        private var pending = false
        private var attempts = 0
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); schedule() }
        func schedule() {
            guard !pending, displayed != nil, window != nil, attempts < 60 else { return }
            pending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16)) { [weak self] in
                guard let self else { return }
                self.pending = false; self.attempts += 1
                guard let window = self.window, window.isVisible, window.frame.width >= 300 else { self.schedule(); return }
                window.displayIfNeeded()
                let callback = self.displayed; self.displayed = nil
                callback?()
            }
        }
    }
}

// A locked row can have window focus without a focused SwiftUI control. Handle
// Escape for this panel even then, leaving calendars, sheets and other windows alone.
private struct UpOnlyPanelKeyboard: NSViewRepresentable {
    var close: () -> Void
    func makeNSView(context: Context) -> KeyboardView { let view = KeyboardView(); view.close = close; return view }
    func updateNSView(_ nsView: KeyboardView, context: Context) { nsView.close = close }
    static func dismantleNSView(_ nsView: KeyboardView, coordinator: ()) { nsView.stopMonitoring() }
    final class KeyboardView: NSView {
        private var monitor: Any?
        var close: (() -> Void)?
        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53, let window = self?.window, window.isVisible,
                      window.attachedSheet == nil,
                      window.childWindows?.contains(where: { $0.isVisible }) != true,
                      event.window === window || (event.window == nil && window.isKeyWindow)
                else { return event }
                self?.close?()
                return nil
            }
        }
    }
}

struct UpOnlyLockView: View {
    @Environment(UpOnlySession.self) private var session
    @State private var recovery: RecoveryCode?
    @State private var savedCode = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var recoveryText = ""
    @State private var showRecovery = false
    @State private var showRestore = false
    private var compactUnlock: Bool { session.state == .locked && !showRecovery && !showRestore }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let recovery, session.state == .newVault {
                UpOnlySetupHeader(step: 1, symbol: "key.fill", title: "Save your recovery code", subtitle: "We generated this code for you. Save it in case you lose access to this Mac.")
                UpOnlyRecoveryCodeCard(code: recovery)
                Toggle("I’ve saved my recovery code somewhere safe", isOn: $savedCode).toggleStyle(.checkbox).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                Text("Keep it separately from your encrypted backups.").fixedSize(horizontal: false, vertical: true).font(.system(size: 11)).foregroundStyle(.secondary)
                HStack {
                    Button("Back") { self.recovery = nil; savedCode = false }.buttonStyle(.bordered).disabled(session.isBusy)
                    Spacer(minLength: 4)
                    Button("Create encrypted vault") { Task { await session.create(recovery: recovery) } }
                        .buttonStyle(.glassProminent).controlSize(.large).keyboardShortcut(.defaultAction).disabled(session.isBusy || !savedCode)
                }
                Text("Touch ID or your Mac password will protect the vault key.").fixedSize(horizontal: false, vertical: true).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if showRestore {
                UpOnlyWordmark(width: 64)
                Text("Restore your backup").font(.system(size: 18, weight: .semibold))
                Text("Use the recovery code saved when this backup’s vault was created.").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                SecureField("Recovery code for your backup", text: $recoveryText).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Recovery code for backup")
                    .onAppear {
                        #if UPONLY_FIXTURE
                        if let code = ProcessInfo.processInfo.environment["UPONLY_PREVIEW_RESTORE_CODE"] { recoveryText = code }
                        #endif
                    }
                Button("Choose encrypted backup…") { Task { await session.restoreBackup(code: recoveryText); recoveryText = "" } }
                    .disabled(session.isBusy || recoveryText.isEmpty)
                Button("Back") { showRestore = false; recoveryText = "" }
            } else if showRecovery || session.state == .recovery {
                UpOnlyWordmark(width: 64)
                Text("Use your saved recovery code").font(.system(size: 18, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Text("Up Only generated this code during setup. On this Mac, you can also try unlocking with Touch ID or your Mac password.").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                SecureField("Recovery code", text: $recoveryText).textFieldStyle(.roundedBorder)
                Button("Recover vault") { Task { await session.recover(code: recoveryText); recoveryText = "" } }
                    .buttonStyle(.glassProminent).disabled(session.isBusy || recoveryText.isEmpty)
                Button("Back to unlock") { showRecovery = false; recoveryText = ""; session.returnToUnlock() }.buttonStyle(.bordered).disabled(session.isBusy)
            } else if session.state == .newVault {
                UpOnlyWordmark()
                VStack(alignment: .leading, spacing: 8) {
                    Text("All your wealth, in one place.").font(.system(size: 15, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    Text("Your accounts, assets and cash flow.").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("Encrypted. Stored on your Mac.").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                #if UPONLY_PERSONAL
                if !session.wiseProfiles.isEmpty {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(session.wiseProfiles) { profile in
                            VStack(spacing: 6) {
                                UpOnlyProfileImage(data: profile.image, name: profile.name, size: 44)
                                Text(profile.name).fixedSize(horizontal: false, vertical: true).font(.system(size: 11)).multilineTextAlignment(.center)
                            }.frame(maxWidth: .infinity)
                        }
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(UpOnlyTint.netWorth.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                }
                #endif
                VStack(spacing: 10) {
                    Button { recovery = RecoveryCode.random(); savedCode = false } label: {
                        Text("Get started").fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity)
                    }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                    Button { showRestore = true } label: {
                        Text("Restore an encrypted backup…").fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity)
                    }.buttonStyle(.bordered)
                }.controlSize(.large).disabled(session.isBusy)
            } else {
                HStack(spacing: 0) {
                    UpOnlyWordmark(width: 42)
                        .contextMenu {
                            Button("Use Mac password") { session.beginUnlock(usePassword: true) }
                            Button("Use recovery code") { showRecovery = true }
                        }
                        .accessibilityAction(named: Text("Use recovery code")) { showRecovery = true }
                        .accessibilityAction(named: Text("Use Mac password")) { session.beginUnlock(usePassword: true) }
                        .help("Control-click to use your recovery code")
                    Spacer(minLength: 16)
                    if let context = session.authenticationContext {
                        UpOnlyAuthenticationIcon(context: context, password: { session.beginUnlock(usePassword: true) }) {
                            Task { await session.unlockEmbedded(context) }
                        }.id(ObjectIdentifier(context)).frame(width: 32, height: 32)
                    } else if session.authenticationFailed {
                        Image(systemName: "touchid").font(.system(size: 28)).foregroundStyle(.secondary)
                            .frame(width: 32, height: 32).accessibilityHidden(true)
                            .overlay { UpOnlyPasswordClick { session.beginUnlock(usePassword: true) } }
                    } else {
                        ProgressView().controlSize(.small).frame(width: 32, height: 32)
                    }
                }.frame(height: 36)
            }
            if let message = session.message { Text(message).fixedSize(horizontal: false, vertical: true).font(.system(size: 12)).foregroundStyle(.secondary) }
            if session.isBusy && !compactUnlock { ProgressView().controlSize(.small) }
        }.padding(.horizontal, 20).padding(.vertical, compactUnlock ? 10 : 20).frame(width: compactUnlock ? 144 : 344, alignment: .leading)
        .accessibilityIdentifier("UpOnlyLocked")
        .animation(reduceMotion ? nil : .snappy, value: recovery)
        .onAppear {
            #if UPONLY_FIXTURE
            if session.state == .newVault, ProcessInfo.processInfo.environment["UPONLY_PREVIEW_DESTINATION"] == "recovery" { recovery = RecoveryCode.random() }
            #endif
        }
    }
}

private struct UpOnlyUnlockedPanel: View {
    @Environment(UpOnlySession.self) private var session
    var model: PopoverModel
    @State private var scope: ValuationScope = .allTracked
    @State private var detail: String?
    @State private var companySelection: CompanySelection?
    @State private var worthRange: WorthRange = .year
    @State private var companyChart: CompanyChart = .balance
    @State private var showEmptyBalances = false
    enum CompanyChart { case balance, profit }
    /// Net worth is always today's value; the range only sets how much history the chart shows.
    /// Cash flow keeps the month, year or all-time selector.
    private var isWorthPage: Bool { !(session.destination == 0 && shows(.cashFlow)) }
    private var selectedInterval: DateInterval {
        guard isWorthPage else { return model.selectedInterval() }
        let now = Date()
        if worthRange == .month {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = UTCDay.timeZone
            let current = MonthKey.current()
            let start = calendar.date(from: DateComponents(year: current.year, month: current.month, day: 1)) ?? now
            return DateInterval(start: min(start, now), end: now)
        }
        return DateInterval(start: now.addingTimeInterval(-worthRange.seconds), end: now)
    }

    private func shows(_ kind: TrackedKind) -> Bool { session.document?.shows(kind) == true }
    private var showsNetWorth: Bool { session.document?.showsNetWorth == true }
    private func manage(_ section: String) {
        if section == "Entries" { session.entryMonthForManagement = model.period == .monthly ? model.month.description : "" }
        if section == "Needs attention" { session.attentionIncludesPerformance = true }
        session.managementSection = section
        session.managementInMenu = true
    }
    private var result: ValuationResult? {
        session.document.map { AssetOwnership.personalValue(at: selectedInterval.end, scope: scope, document: $0) }
    }
    private var hasData: Bool {
        guard let document = session.document else { return false }
        return !document.accounts.isEmpty || !document.entries.isEmpty || !document.holdings.isEmpty || !(document.businessAccounting ?? []).isEmpty
    }
    var body: some View {
        let attention = attentionItems
        return VStack(spacing: 0) {
            navigationHeader.padding(.top, 14).padding(.bottom, 16)
            if !attention.isEmpty, companySelection == nil, detail == nil, selectedPortfolio == nil { attentionBanner(attention).padding(.bottom, 16) }
            if let companySelection { companyContent(companySelection) }
            else if !hasData, shows(.cashFlow) || showsNetWorth { firstDataContent }
            else if session.destination == 0 && shows(.cashFlow) { monthContent }
            else if showsNetWorth { worthContent }
            else { firstDataContent }
            if let message = session.message {
                Text(message).fixedSize(horizontal: false, vertical: true).font(.system(size: 11)).foregroundStyle(.secondary).padding(.bottom, 10)
            }
        }.padding(.horizontal, 20).padding(.bottom, 16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("UpOnlyUnlocked")
        .onChange(of: session.document?.settings.tracked) { _, _ in scope = .allTracked; detail = nil }
        .onChange(of: session.document?.portfolios) { _, _ in
            if case .portfolio(let id) = scope, session.document?.portfolio(id: id)?.isArchived != false { scope = .allTracked }
        }
    }
    @ViewBuilder private var navigationHeader: some View {
        if let selection = companySelection {
            UpOnlyPageHeader(title: model.books.first { $0.id == selection.group.businessID }?.name ?? selection.group.name,
                             backLabel: "Back to net worth", profileImage: selection.group.image) {
                model.selectScope(selection.previousScope); companySelection = nil
            }
        } else if let portfolio = selectedPortfolio {
            UpOnlyPageHeader(title: portfolio.name, backLabel: "Back to net worth") { scope = .allTracked }
        } else if let detail {
            UpOnlyPageHeader(title: detail == "personal" ? "Personal" : selectedBusiness?.book.name ?? "Company",
                             backLabel: "Back to cash flow") { self.detail = nil }
        } else {
            HStack(spacing: 8) {
                if shows(.cashFlow) && showsNetWorth {
                    Picker("Dashboard section", selection: Binding(get: { session.destination }, set: { session.destination = $0; detail = nil })) {
                        Text("Net worth").tag(1)
                        Text("Cash flow").tag(0)
                    }.pickerStyle(.segmented).controlSize(.regular).font(.system(size: 12)).labelsHidden().fixedSize()
                } else if shows(.cashFlow) { destination("Cash flow", value: 0) }
                else if showsNetWorth { destination("Net worth", value: 1) }
                Spacer(minLength: 0)
                addButton
                dashboardActions
            }.frame(minHeight: 32)
        }
    }
    private var syncNeedsAttention: Bool {
        if !session.backgroundIssues.isEmpty { return true }
        #if UPONLY_PERSONAL
        return session.accountingError != nil || session.backgroundIssues.contains { $0 == "Accounting" || $0.hasSuffix(" accounting") }
            || (session.document?.settings.automaticWise == true && (session.wiseError != nil || session.backgroundIssues.contains("Bank balances")))
        #else
        return false
        #endif
    }
    private var attentionItems: [String] {
        guard hasData, let document = session.document else { return syncNeedsAttention ? ["A source couldn’t refresh"] : [] }
        let report = model.attention(in: document, includePerformance: true)
        var items: [String] = []
        if !report.balances.isEmpty { items.append(report.balances.count == 1 ? "Balance needed for " + report.balances[0].name : "\(report.balances.count) balances needed") }
        if !report.quantities.isEmpty { items.append(report.quantities.count == 1 ? "Quantity needed for " + report.quantities[0].assetName : "\(report.quantities.count) quantities needed") }
        if report.pricesNeeded { items.append("Prices or exchange rates missing") }
        // The current month is always open; it only needs a look once it ends.
        let months = report.spendingMonths.filter { $0 != .current() }
        if !months.isEmpty { items.append(months.count == 1 ? "Check " + months[0].title : "\(months.count) months to check") }
        if !report.accountingNames.isEmpty { items.append("Accounting incomplete") }
        if syncNeedsAttention { items.append("A source couldn’t refresh") }
        return items
    }
    private func attentionBanner(_ items: [String]) -> some View {
        Button { manage("Needs attention") } label: {
            HStack(spacing: 10) {
                Circle().fill(.orange).frame(width: 7, height: 7).accessibilityHidden(true)
                Text(items.count == 1 ? items[0] : "\(items.count) things need attention").font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            }.padding(.horizontal, 14).padding(.vertical, 9).contentShape(Capsule())
        }.buttonStyle(.plain).glassEffect(.regular, in: .capsule).accessibilityIdentifier("DataAttention")
            .accessibilityLabel("Needs attention").accessibilityValue(items.joined(separator: ", "))
    }
    private var addButton: some View {
        Button { session.addingInMenu = true } label: {
            Image(systemName: "plus").font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
                .frame(width: 32, height: 32).contentShape(Circle())
        }
        .buttonStyle(.plain).glassEffect(.regular, in: .circle)
        .accessibilityLabel("Add").accessibilityIdentifier("AddInfo").help("Add a balance, holding, transaction or statement")
    }
    private var dashboardActions: some View {
        Menu {
            Button { manage("Manage") } label: { Label("Manage", systemImage: "slider.horizontal.3") }
                .accessibilityIdentifier("ManageUpOnly")
            UpOnlyPrivacyButton(inMenu: true)
            Divider()
            Button { session.lockAndAuthenticate() } label: { Label("Lock", systemImage: "lock") }
                .keyboardShortcut("l", modifiers: .command).accessibilityLabel("Lock Up Only")
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .frame(width: 32, height: 32).glassEffect(.regular, in: .circle)
        .accessibilityLabel("More").accessibilityIdentifier("DashboardActions")
        .help("Manage, privacy and lock")
    }
    private func destination(_ title: String, value: Int) -> some View {
        Button { session.destination = value; detail = nil } label: {
            Text(title).fixedSize(horizontal: false, vertical: true).font(.system(size: 12, weight: session.destination == value ? .semibold : .regular))
                .foregroundStyle(session.destination == value ? .primary : .secondary)
        }.buttonStyle(.bordered).controlSize(.small).tint(session.destination == value ? Color.accentColor : Color.secondary).accessibilityAddTraits(session.destination == value ? .isSelected : [])
    }
    private var firstDataContent: some View { addFirstData }
    private var addFirstData: some View {
        VStack(alignment: .leading, spacing: 16) {
            headline(eyebrow(showsNetWorth ? "Net worth" : "Cash flow"))
            VStack(alignment: .leading, spacing: 7) {
                Text("Start with one balance").font(.system(size: 19, weight: .semibold)).tracking(-0.3)
                Text("A bank account, some crypto, gold or silver, or an income and spending statement. Add more any time with the plus button.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Button { session.addingInMenu = true } label: { Text("Add").frame(maxWidth: .infinity) }
                .buttonStyle(.glassProminent).controlSize(.large)
        }.padding(.bottom, 4)
    }
    private var personalRateGaps: [(MonthKey, [String])] {
        guard session.destination == 0, let document = session.document else { return [] }
        if case .business = model.scope { return [] }
        return model.attentionMonths.reversed().compactMap { month in
            if case .exchangeRates(let currencies)? = MonthlyLedger.personal(month, document: document).unavailable { return (month, currencies) }
            return nil
        }
    }
    private var repairMonth: MonthKey { personalRateGaps.first?.0 ?? AssetOwnership.month(at: selectedInterval.end) }
    private var missingCurrencies: [String] {
        if let gap = personalRateGaps.first { return gap.1 }
        return Set((result?.components ?? []).filter { $0.missing == "fx" }.map(\.currency)).sorted()
    }
    private var exchangeRateAction: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Exchange rate missing").font(.system(size: 13, weight: .semibold))
            Text("To show this in USD, Up needs " + missingCurrencies.joined(separator: ", ") + " rates for " + repairMonth.title + ".")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let issue = missingCurrencies.compactMap({ session.fxIssues[$0] }).first {
                Text(issue).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Menu("Exchange rates") {
                Button(session.document?.settings.automaticFX == true ? "Get " + repairMonth.shortName + " rates" : "Enable exchange rates") {
                    Task { await session.repairExchangeRates(month: repairMonth, currencies: missingCurrencies) }
                }.disabled(session.isBusy || session.refreshing).accessibilityIdentifier("RepairExchangeRates")
                Button("Add rate manually") {
                    session.entryMonthForManagement = repairMonth.description
                    session.requestedRateCurrency = missingCurrencies.first
                    session.managementSection = "Entries"; session.managementInMenu = true
                }.disabled(session.isBusy)
            }.modifier(UpOnlyPillMenu()).accessibilityLabel("Resolve exchange rates")
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
    private var nativeMonthContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            exchangeRateAction
            DisclosureGroup("Amounts in " + model.month.title) {
                if let document = session.document, let rows = try? MonthlyLedger.nativeTotals(model.month, document: document) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(rows) { row in
                            VStack(spacing: 4) {
                                UpOnlyValueRow(label: row.currency + " income", value: UpOnlyFormat.currencyMoney(row.totals.moneyIn, currency: row.currency))
                                UpOnlyValueRow(label: row.currency + " spending", value: UpOnlyFormat.currencyMoney(row.totals.moneyOut, currency: row.currency))
                            }
                        }
                    }.padding(.top, 8)
                }
            }.font(.system(size: 12))
            Button("View transactions") { manage("Entries") }.buttonStyle(.bordered).controlSize(.small)
        }
    }
    // Every page opens the same way: what the number is on the left, when on the right,
    // then the number itself. Nothing else competes with the figure.
    private func headline<Eyebrow: View>(_ eyebrow: Eyebrow) -> some View {
        HStack(alignment: .center, spacing: 8) {
            eyebrow
            Spacer(minLength: 8)
            if isWorthPage { rangeSelector } else { periodSelector }
        }.frame(minHeight: 26)
    }
    private var rangeSelector: some View {
        Menu {
            ForEach(WorthRange.allCases, id: \.self) { range in
                Toggle(range.title, isOn: Binding(get: { worthRange == range }, set: { _ in worthRange = range }))
            }
        } label: { Text(worthRange.title).font(.system(size: 12, weight: .medium)).lineLimit(1) }
            .modifier(UpOnlyPillMenu()).fixedSize()
            .accessibilityLabel("Chart range").accessibilityValue(worthRange.title)
    }
    private func eyebrow(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
    }
    private var compactPeriodTitle: String {
        switch model.period {
        case .monthly: String(model.month.shortName.prefix(3)) + " " + String(model.month.year)
        case .annual: String(model.month.year)
        case .allTime: "All time"
        }
    }
    private var periodPhrase: String {
        if isWorthPage { return worthRange == .month ? "this month" : "over the " + worthRange.phrase }
        return switch model.period {
        case .monthly: model.month == .current() ? "this month" : "in " + String(model.month.shortName.prefix(3)) + " " + String(model.month.year)
        case .annual: model.month.year == MonthKey.current().year ? "this year" : "in " + String(model.month.year)
        case .allTime: "all time"
        }
    }
    private var periodSelector: some View {
        GlassEffectContainer {
            HStack(spacing: 0) {
                if model.period != .allTime {
                    Button { model.stepPeriod(by: -1) } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(UpOnlyToolbarButtonStyle(size: 26)).disabled(!model.canStepPeriodBack)
                        .accessibilityLabel(model.period == .monthly ? "Previous month" : "Previous year")
                    Divider().frame(height: 10)
                }
                Menu {
                    ForEach(PerformancePeriod.allCases, id: \.self) { period in
                        Toggle(period == .monthly ? "By month" : period == .annual ? "By year" : "All time", isOn: Binding(get: { model.period == period }, set: { _ in model.selectPeriod(period) }))
                    }
                    Divider()
                    if model.period == .monthly {
                        Menu("Go to month") {
                            ForEach(model.selectableMonths, id: \.self) { month in Button(month.title) { model.select(month) } }
                        }
                    } else if model.period == .annual {
                        Menu("Go to year") {
                            ForEach(Array(Set(model.selectableMonths.map(\.year))).sorted(by: >), id: \.self) { year in
                                Button(String(year)) { model.select(MonthKey(year: year, month: 1)) }
                            }
                        }
                    }
                    Button("This month") { model.selectPeriod(.monthly); model.select(.current()) }
                } label: { Text(compactPeriodTitle).font(.system(size: 12, weight: .medium)).lineLimit(1) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 8).frame(minHeight: 26)
                    .accessibilityLabel("Time period").accessibilityValue(model.periodTitle)
                if model.period != .allTime {
                    Divider().frame(height: 10)
                    Button { model.stepPeriod(by: 1) } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(UpOnlyToolbarButtonStyle(size: 26)).disabled(!model.canStepPeriodForward)
                        .accessibilityLabel(model.period == .monthly ? "Next month" : "Next year")
                }
            }.glassEffect(.regular, in: .capsule).fixedSize(horizontal: true, vertical: false)
        }
    }
    // A plain menu reads better than a cycling control: the current choice is
    // the label, and every alternative is one click away.
    private func scopeControl<Selection: Hashable>(_ options: [(Selection, String)], selection: Binding<Selection>, label: String, item: String) -> some View {
        let index = options.firstIndex { $0.0 == selection.wrappedValue } ?? 0
        return Menu {
            ForEach(Array(options.enumerated()), id: \.offset) { offset, option in
                Toggle(option.1, isOn: Binding(get: { offset == index }, set: { _ in selection.wrappedValue = option.0 }))
            }
        } label: {
            // One Text keeps the chevron after the title inside a native menu label.
            (Text(options[index].1) + Text("  ") + Text(Image(systemName: "chevron.down")).font(.system(size: 7, weight: .bold)))
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
        }.menuStyle(.borderlessButton).menuIndicator(.hidden)
            .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 9).frame(minHeight: 22)
            .glassEffect(.regular, in: .capsule).fixedSize()
            .accessibilityLabel(label).accessibilityValue(options[index].1).help("Choose " + item)
    }
    private var performanceScopeSelector: some View {
        scopeControl([(.all, "All accounts"), (.personal, "Personal")] + model.books.map { (.business($0.id), $0.name) },
                     selection: Binding(get: { model.scope }, set: { model.selectScope($0) }), label: "Performance accounts", item: "account")
            .help(performanceCaption)
            .accessibilityHint(performanceCaption)
    }
    private var worthScopeOptions: [(ValuationScope, String)] {
        var options: [(ValuationScope, String)] = [(.allTracked, allScopeTitle)]
        if shows(.banks) && showsHoldings { options.append((.banks, "Bank balances")) }
        options += (session.document?.portfolios.filter { $0.isActive(at: selectedInterval.end) } ?? []).map { (.portfolio($0.id), $0.name) }
        return options
    }
    private var worthScopeSelector: some View {
        scopeControl(worthScopeOptions, selection: $scope, label: "Net worth accounts", item: "asset group")
    }
    private var monthContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if detail == "personal" {
                personalContent
            } else if let row = selectedBusiness {
                headline(eyebrow("Company profit / loss"))
                if let profit = row.observation?.profitUSD {
                    UpOnlyAmount(value: profit, signed: true).padding(.top, 10)
                }
                businessDetails(row).padding(.top, 14)
            } else {
            if model.books.isEmpty { headline(eyebrow("Cash flow")) } else { headline(performanceScopeSelector) }
            if let totals = model.availableTotals {
                UpOnlyAmount(value: totals.net, signed: true, tint: totals.net < 0 ? Color(nsColor: .systemRed) : UpOnlyTint.cashFlow).padding(.top, 10)
            } else if case .exchangeRates? = model.state.unavailable {
                nativeMonthContent.padding(.top, 16)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    Text(model.state.unavailable == .invalidAmount ? "Check your amounts" : model.state.unavailable == .noEntries ? "Nothing recorded" : "Not reported yet")
                        .font(.system(size: 18, weight: .semibold))
                    Text(model.state.unavailable == .noEntries ? "Add a transaction or import a bank statement." : "The selected period has no recorded result.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if model.state.unavailable == .noEntries {
                        Button("Add") { session.addingInMenu = true }.buttonStyle(.glassProminent).padding(.top, 4)
                    }
                }.padding(.top, 18)
            }
            if model.availableTotals != nil { Text(performanceCaption).font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 6) }
            if !personalRateGaps.isEmpty {
                if case .exchangeRates? = model.state.unavailable {
                    if model.availableTotals != nil { exchangeRateAction.padding(.top, 12) }
                } else { exchangeRateAction.padding(.top, 12) }
            }
            if model.period == .monthly, !model.pendingAccounting.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.pendingAccounting.joined(separator: ", ") + " · " + model.month.title + " not reported yet")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let latest = model.latestAccountingMonth, latest != model.month {
                        Button("View " + latest.title) { model.select(latest) }.buttonStyle(.bordered).controlSize(.small)
                    }
                }.padding(.top, 8)
            }
                if personalRateGaps.isEmpty || monthPoints.contains(where: { $0.value != nil }) {
                UpOnlyChart(points: monthPoints, includesZero: true, showsAllMarkers: true, selected: model.period == .monthly ? model.month.description : nil, tint: UpOnlyTint.cashFlow) { id in
                    if let month = MonthKey(id) { model.drillInto(month) }
                }.padding(.top, 20)
                }
                VStack(spacing: 6) {
                    if case .business = model.scope {
                        if let row = model.state.businesses.first {
                            if let revenue = row.observation?.revenueUSD { UpOnlyValueRow(label: "Revenue", value: UpOnlyFormat.exactMoney(revenue)) }
                            if let expenses = row.observation?.expensesUSD { UpOnlyValueRow(label: "Costs", value: UpOnlyFormat.exactMoney(-expenses)) }
                            Button { detail = "business:" + row.id } label: {
                                UpOnlyValueRow(label: row.ownershipLabel == "Historical ownership" ? "Your share" : "Your share · " + row.ownershipLabel, value: row.share.map(UpOnlyFormat.exactMoney) ?? (row.book.months.isEmpty ? "Needs refresh" : "Not reported"), chevron: true)
                            }.buttonStyle(.bordered)
                        }
                    } else {
                        Button { detail = "personal" } label: {
                            UpOnlyValueRow(label: "Personal", value: model.personalState.totals.map { UpOnlyFormat.exactMoney($0.net) } ?? "Not recorded", chevron: true)
                        }.buttonStyle(.bordered).accessibilityLabel("Personal income and spending")
                        ForEach(model.state.businesses) { row in
                            Button { detail = "business:" + row.id } label: {
                                UpOnlyValueRow(label: row.book.name, value: row.share.map(UpOnlyFormat.exactMoney) ?? (row.book.months.isEmpty ? "Needs refresh" : "Not reported"), chevron: true)
                            }.buttonStyle(.bordered)
                        }
                    }
                }.padding(.top, 10)
            }
        }
        .onChange(of: model.scope) { detail = nil }
    }
    private var performanceCaption: String {
        let basis: String
        if case .business = model.scope { basis = "Company profit / loss" } else { basis = "Income minus spending" }
        if model.state.missingMonths > 0 || model.state.isEstimated || (model.state.totals == nil && model.availableTotals != nil) { return basis + " · Partial" }
        return basis
    }
    private func businessDetails(_ row: BusinessContribution) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let revenue = row.observation?.revenueUSD { UpOnlyValueRow(label: "Revenue", value: UpOnlyFormat.exactMoney(revenue)) }
            if let expenses = row.observation?.expensesUSD { UpOnlyValueRow(label: "Costs", value: UpOnlyFormat.exactMoney(-expenses)) }
            if row.observation == nil { Text("Not reported for this period").font(.system(size: 12)).foregroundStyle(.secondary) }
            UpOnlyValueRow(label: row.ownershipLabel == "Historical ownership" ? "Your share" : "Your share · " + row.ownershipLabel, value: row.share.map(UpOnlyFormat.exactMoney) ?? (row.book.months.isEmpty ? "Needs refresh" : "Not reported"))
        }
    }
    private var monthEntryCount: Int { session.document?.entries.filter { $0.month == model.month.description }.count ?? 0 }
    private func companyFigure(_ title: String, _ value: Decimal?, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            UpOnlyPrivateText(value.map(UpOnlyFormat.exactMoney) ?? "—").font(.system(size: 14, weight: .medium).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.8)
                .foregroundStyle(tint ?? .primary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    /// Revenue, expenses, profit and your share summed over the months in the selected range.
    private func rangeTotals(_ book: BusinessBook) -> (revenue: Decimal?, expenses: Decimal?, profit: Decimal?, share: Decimal?, caption: String) {
        let end = MonthKey.current()
        var months: [MonthKey] = [end]
        while months.count < worthRange.months { months.insert(months[0].previous, at: 0) }
        let rows = months.compactMap { key in book.months.first { $0.month == key.description } }
        guard !rows.isEmpty else { return (nil, nil, nil, nil, "No accounting for the " + worthRange.phrase + ".") }
        let profit = rows.reduce(Decimal(0)) { $0 + $1.profitUSD }
        let revenue = rows.allSatisfy { $0.revenueUSD != nil } ? rows.reduce(Decimal(0)) { $0 + ($1.revenueUSD ?? 0) } : nil
        let expenses = rows.allSatisfy { $0.expensesUSD != nil } ? rows.reduce(Decimal(0)) { $0 + ($1.expensesUSD ?? 0) } : nil
        let share = rows.reduce(Decimal?.some(0)) { sum, row in
            guard let sum, let portion = book.ownership(at: row.month).flatMap({ try? $0.portion(row.profitUSD) }) else { return nil }
            return sum + portion
        }
        let missing = months.count - rows.count
        var caption = rows.count == 1 ? months.last!.title : (rows.first!.month) + " to " + (rows.last!.month)
        if let first = MonthKey(rows.first!.month), let last = MonthKey(rows.last!.month) { caption = rows.count == 1 ? first.title : first.title + " to " + last.title }
        if missing > 0 { caption += " · \(missing) month\(missing == 1 ? "" : "s") without accounting" }
        if rows.contains(where: \.estimated) { caption += " · current month is provisional" }
        return (revenue, expenses, profit, share, caption)
    }
    /// Monthly profit for the months inside the net worth range, so both company charts cover the same span.
    private var rangeMonthPoints: [UpOnlyChartPoint] {
        let end = MonthKey.current()
        var months: [MonthKey] = [end]
        while months.count < worthRange.months { months.insert(months[0].previous, at: 0) }
        let showYear = months.first?.year != end.year
        return months.map { key in
            let row = model.history.first { $0.month == key } ?? (key, nil, false)
            return UpOnlyChartPoint(id: key.description, label: String(key.shortName.prefix(3)) + (showYear ? " " + String(key.year).suffix(2) : ""), value: row.net, provisional: !row.settled, detailLabel: key.title)
        }
    }
    private var monthPoints: [UpOnlyChartPoint] {
        model.chartHistory.map {
            UpOnlyChartPoint(id: $0.month.description, label: String($0.month.shortName.prefix(3)) + (model.period != .allTime ? "" : " " + String($0.month.year).suffix(2)), value: $0.net, provisional: !$0.settled, detailLabel: $0.month.title)
        }
    }
    private var selectedBusiness: BusinessContribution? {
        guard let detail else { return nil }
        if let row = model.state.businesses.first(where: { "business:" + $0.id == detail }) { return row }
        guard let book = model.books.first(where: { "business:" + $0.id == detail }) else { return nil }
        return BusinessContribution(book: book, observation: nil, share: nil, ownershipLabel: "Historical ownership")
    }
    private var personalContent: some View {
        let state = model.personalState
        let entries = model.personalEntries
        return VStack(alignment: .leading, spacing: 14) {
            headline(eyebrow("Income minus spending"))
            if let totals = state.totals {
                UpOnlyAmount(value: totals.net, signed: true, tint: totals.net < 0 ? Color(nsColor: .systemRed) : UpOnlyTint.cashFlow)
                    .help(state.isEstimated ? "Based on recorded entries; this month is not yet complete." : "Income minus spending")
                HStack(spacing: 20) {
                    personalSubtotal("Income", value: totals.personalIncome)
                    personalSubtotal("Spending", value: -totals.personalSpend)
                }
                if personalAccountGroups.count > 1 { personalAccountBreakdown }
            } else if entries.isEmpty {
                Text("No personal entries for this period").font(.headline).fixedSize(horizontal: false, vertical: true)
            }
            if !personalRateGaps.isEmpty { exchangeRateAction }
            let points = model.personalChartHistory.map {
                UpOnlyChartPoint(id: $0.month.description, label: String($0.month.shortName.prefix(3)) + (model.period == .allTime ? " " + String($0.month.year).suffix(2) : ""), value: $0.net, provisional: !$0.settled, detailLabel: $0.month.title)
            }
            if points.contains(where: { $0.value != nil }) {
                UpOnlyChart(points: points, includesZero: true, showsAllMarkers: true, selected: model.period == .monthly ? model.month.description : nil, tint: UpOnlyTint.cashFlow) { id in
                    if let month = MonthKey(id) { model.drillInto(month) }
                }
            }
            HStack {
                Text("Transactions").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(entries.isEmpty ? "Add" : "See all") { manage("Entries") }.buttonStyle(.bordered).accessibilityLabel("Edit personal transactions")
            }
            if !entries.isEmpty {
                UpOnlyMenuScroll(maxHeight: 150) {
                    VStack(alignment: .leading, spacing: 10) {
                        let groups = Dictionary(grouping: entries, by: \.month)
                        let accountGroups = personalAccountGroups
                        ForEach(groups.keys.sorted(by: >), id: \.self) { month in
                            VStack(alignment: .leading, spacing: 10) {
                                if model.period != .monthly {
                                    Text(MonthKey(month)?.title ?? month).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                                }
                                if accountGroups.count > 1 {
                                    // Several bank accounts feed Personal, so each month is split by account.
                                    ForEach(accountGroups) { group in
                                        let rows = (groups[month] ?? []).filter { $0.accountID == group.id }
                                        if !rows.isEmpty {
                                            Text(group.name).font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
                                                .padding(.top, 2).accessibilityLabel(group.name + " transactions")
                                            ForEach(rows) { entry in
                                                UpOnlyValueRow(label: entry.label, value: personalEntryAmount(entry))
                                            }
                                        }
                                    }
                                } else {
                                    ForEach(groups[month] ?? []) { entry in
                                        UpOnlyValueRow(label: entry.label, value: personalEntryAmount(entry))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }.padding(.top, 8)
    }
    /// Bank accounts represented in the visible personal entries, in the order they were added.
    /// Manual entries share one "Added by hand" group; it is listed last.
    private var personalAccountGroups: [PersonalAccountGroup] {
        let entries = model.personalEntries
        let accounts = session.document?.accounts ?? []
        var groups = accounts.filter { account in entries.contains { $0.accountID == account.id } }
            .map { PersonalAccountGroup(id: $0.id, name: $0.name) }
        if entries.contains(where: { $0.accountID == nil }) { groups.append(PersonalAccountGroup(id: nil, name: "Added by hand")) }
        return groups
    }
    private var personalAccountBreakdown: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("By account").font(.system(size: 11)).foregroundStyle(.secondary)
            ForEach(personalAccountGroups) { group in
                let rows = model.personalEntries.filter { $0.accountID == group.id }
                let usd = rows.reduce(Decimal?.some(0)) { sum, entry in
                    guard let sum, let value = personalEntryUSD(entry) else { return nil }
                    return (try? MoneyInput.add(sum, value)) ?? nil
                }
                UpOnlyValueRow(label: group.name, value: usd.map { UpOnlyFormat.exactMoney($0) } ?? "Rate needed")
                    .accessibilityLabel(group.name + " income minus spending")
            }
        }
    }
    private func personalSubtotal(_ title: String, value: Decimal) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            UpOnlyPrivateText(UpOnlyFormat.exactMoney(value)).font(.system(size: 14, weight: .medium)).monospacedDigit().fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func personalEntryUSD(_ entry: Entry) -> Decimal? {
        let signed = entry.kind == .expense ? -entry.amount : entry.amount
        guard let doc = session.document, let month = MonthKey(entry.month), let rate = MonthlyLedger.rate(currency: entry.currency, month: month, document: doc) else { return nil }
        return try? MoneyInput.multiply(signed, rate)
    }
    private func personalEntryAmount(_ entry: Entry) -> String {
        guard let usd = personalEntryUSD(entry) else {
            let signed = entry.kind == .expense ? -entry.amount : entry.amount
            return UpOnlyFormat.currencyMoney(signed, currency: entry.currency) + " " + entry.currency
        }
        return UpOnlyFormat.exactMoney(usd)
    }
    private var worthContent: some View {
        let valuation = result
        let points = worthPoints
        return VStack(alignment: .leading, spacing: 0) {
            if worthScopeOptions.count > 1 { headline(worthScopeSelector) } else { headline(eyebrow(selectedPortfolio?.name ?? "Net worth")) }
            if let valuation, !valuation.isUnavailable, let value = valuation.total ?? valuation.lastComplete?.value {
                UpOnlyAmount(value: value).padding(.top, 10)
            }
            if valuation?.isUnavailable == false, !worthCaption.isEmpty { Text(worthCaption).fixedSize(horizontal: false, vertical: true).font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 6) }
            if valuation?.missing.contains(where: { $0.reason == "ownership" }) == true {
                Text("Ownership history is needed to calculate your share.").font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 10)
                Button("Open Prices & rates") { manage("Sources") }.buttonStyle(.bordered)
            }
            if valuation?.missing.contains(where: { $0.reason == "fx" }) == true {
                exchangeRateAction.padding(.top, 16)
            }
            if let valuation, !valuation.isUnavailable, valuation.total == nil {
                VStack(alignment: .leading, spacing: 10) {
                    let unpriced = valuation.components.filter { $0.missing == "quote" }
                    if !unpriced.isEmpty {
                        Text("Prices needed").font(.system(size: 13, weight: .medium))
                        Text("No price yet for " + unpriced.map(\.label).joined(separator: ", ") + ". Crypto prices need a free CoinGecko key.").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Set up prices") { manage("Sources") }
                            .buttonStyle(.glassProminent).buttonBorderShape(.capsule).controlSize(.regular)
                    }
                    ForEach(valuation.components.filter { $0.missing != nil && $0.missing != "fx" && $0.missing != "quote" }, id: \.id) { component in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(component.label).font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                            Text(component.missing == "balance" ? "Add this account’s balance to calculate your net worth." : component.missing == "quote" ? "A price for the selected date is needed to value this holding." : "This amount needs correcting.")
                                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Button(component.missing == "balance" ? "Add balance" : component.missing == "quote" ? "Set up prices" : "Review amount") {
                                if component.missing == "balance" {
                                    session.startImport(.bankBalances, prefill: true, accountID: component.id); session.addingInMenu = true
                                } else { manage(component.missing == "quote" ? "Sources" : "Accounts") }
                            }.buttonStyle(.glassProminent).buttonBorderShape(.capsule).controlSize(.small)
                        }
                    }
                }.padding(.top, 16)
            }
            if points.contains(where: { $0.value != nil }) {
                UpOnlyChart(points: points, tint: UpOnlyTint.netWorth).padding(.top, 20)
            }
            VStack(spacing: 6) {
                ForEach(bankGroups(valuation)) { group in
                    Button { openCompany(group) } label: {
                        HStack(spacing: 8) {
                            if let image = group.image { UpOnlyProfileImage(data: image, name: group.name, size: 24) }
                            else { UpOnlySymbolBadge(symbol: "building.columns.fill", size: 24) }
                            let total = groupTotal(group, valuation)
                            UpOnlyValueRow(label: group.name, value: total.map(UpOnlyFormat.exactMoney) ?? "Needs update", chevron: true, primaryLabel: true)
                        }.padding(.vertical, 3).contentShape(Rectangle())
                    }.buttonStyle(.bordered).accessibilityLabel(group.name + (group.businessID == nil ? " bank balance" : " assets"))
                        .accessibilityValue(session.privacyMode ? "Hidden value" : groupTotal(group, valuation).map(UpOnlyFormat.exactMoney) ?? "Needs update")
                }
                if case .allTracked = scope {
                    // A company's own portfolios live on the company page and in its row total.
                    ForEach(session.document?.portfolios.filter { $0.isActive(at: selectedInterval.end) && $0.ownerBusinessID == nil } ?? []) { portfolio in
                        Button { scope = .portfolio(portfolio.id) } label: {
                            HStack(spacing: 10) {
                                UpOnlySymbolBadge(symbol: portfolio.kind == .metals ? TrackedKind.metals.symbol : TrackedKind.crypto.symbol, tint: portfolio.kind == .metals ? UpOnlyTint.metals : UpOnlyTint.crypto, size: 24)
                                worthRowLabel(portfolio)
                            }.padding(.vertical, 3)
                        }.buttonStyle(.bordered)
                    }
                } else if let portfolio = selectedPortfolio, !(valuation?.components.isEmpty ?? true) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Holdings").font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Button(portfolio.kind == .metals ? "Update weights" : "Update holdings") {
                                if session.startImport(portfolio.kind == .metals ? .metals : .holdings, prefill: true, portfolioID: portfolio.id) { session.addingInMenu = true }
                            }.buttonStyle(.bordered).controlSize(.small)
                        }
                        ForEach(valuation?.components ?? [], id: \.id) { component in
                            Divider().opacity(0.5)
                            VStack(alignment: .leading, spacing: 2) {
                                UpOnlyValueRow(label: component.label, value: component.usdValue.map { UpOnlyFormat.exactMoney($0.value) } ?? (component.missing == "quote" ? "Price needed" : "Quantity needed"), primaryLabel: true)
                                if let document = session.document, let caption = UpOnlyFormat.performance(HoldingPerformance.summary(holdingID: component.id, valueUSD: component.usdValue?.value, document: document, at: selectedInterval.end)) {
                                    UpOnlyPrivateText(caption).font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }.padding(12).modifier(UpOnlyContentSurface())
                }
            }.padding(.top, 14)
            if valuation?.isUnavailable ?? true {
                worthEmptyState
            }
        }
    }
    private var worthEmptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                UpOnlySymbolBadge(symbol: selectedPortfolio?.kind == .metals ? TrackedKind.metals.symbol : "chart.line.uptrend.xyaxis", tint: UpOnlyTint.netWorth, size: 30)
                let hasLater = selectedInterval.end < Date() && session.document.map { AssetOwnership.personalValue(at: Date(), scope: scope, document: $0).total != nil } == true
                VStack(alignment: .leading, spacing: 4) {
                    Text(hasLater ? "Nothing recorded yet for " + (model.period == .monthly ? model.month.title : "this period") : "Nothing here yet").font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    Text(hasLater ? "Your records start later. Jump to the latest to see them." : "No balances or holdings recorded for this period.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            let hasLater = selectedInterval.end < Date() && session.document.map { AssetOwnership.personalValue(at: Date(), scope: scope, document: $0).total != nil } == true
            HStack(spacing: 8) {
                if hasLater { Button("Show latest") { model.selectPeriod(.monthly); model.select(.current()) }.buttonStyle(.glassProminent) }
                let add = Button(selectedPortfolio?.kind == .metals ? "Add gold or silver" : selectedPortfolio != nil ? "Add a coin" : "Add") {
                    if let portfolio = selectedPortfolio {
                        guard session.startImport(portfolio.kind == .metals ? .metals : .holdings, portfolioID: portfolio.id) else { return }
                    }
                    session.addingInMenu = true
                }
                if hasLater { add.buttonStyle(.bordered) } else { add.buttonStyle(.glassProminent) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14).modifier(UpOnlyContentSurface())
    }
    /// Bank cash plus, for a company, the holdings in portfolios it owns.
    private func groupTotal(_ group: BankBalanceGroup, _ valuation: ValuationResult?) -> Decimal? {
        guard let businessID = group.businessID, let document = session.document else { return group.total }
        let owned = Set(document.portfolios.filter { $0.ownerBusinessID == businessID }.map(\.id))
        let holdings = (valuation?.components ?? []).filter { component in
            component.kind == .holding && document.holdings.first { $0.id == component.id }.map { owned.contains($0.portfolioID) } == true
        }
        guard let cash = group.total, let assets = AssetOwnership.sum(holdings) else { return nil }
        return try? MoneyInput.add(cash, assets)
    }
    private func bankGroups(_ valuation: ValuationResult?) -> [BankBalanceGroup] {
        guard let document = session.document else { return [] }
        return BankBalanceGroup.groups(valuation?.components ?? [], document: document)
    }
    private struct CompanySelection {
        var group: BankBalanceGroup
        var previousScope: PerformanceScope
    }
    private func openCompany(_ group: BankBalanceGroup) {
        companySelection = CompanySelection(group: group, previousScope: model.scope)
        model.selectScope(group.businessID.map(PerformanceScope.business) ?? .personal)
    }
    private func companyContent(_ selection: CompanySelection) -> some View {
        let document = session.document
        let raw = document.map { NetWorthCalculator.value(at: selectedInterval.end, scope: .allTracked, document: $0) }
        let companyID = selection.group.businessID
        let bankValues = (raw?.components ?? []).filter { component in
            guard component.kind == .bank, let document else { return false }
            if let companyID { return AssetOwnership.businessID(for: component, in: document) == companyID }
            return selection.group.components.contains { $0.id == component.id }
        }
        // Personal portfolios already appear on the overview; only a company's own holdings belong here.
        let portfolios = companyID == nil ? [] : document?.portfolios.filter { $0.isActive(at: selectedInterval.end) && $0.ownerBusinessID == companyID } ?? []
        let book = model.books.first { $0.id == companyID }
        let total = bankValues.isEmpty ? nil : AssetOwnership.sum(bankValues)
        let share = document.flatMap { doc in bankValues.isEmpty ? nil : AssetOwnership.personalTotal(bankValues, at: selectedInterval.end, document: doc) }
        let points = groupPoints(selection)
        let ownership = book?.ownership(at: AssetOwnership.month(at: selectedInterval.end).description)
        let partOwner = ownership.map { $0.numerator != $0.denominator } ?? false
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                headline(eyebrow(companyID == nil ? "All bank accounts" : "Bank balance")).padding(.bottom, 2)
                if let total { UpOnlyAmount(value: total) }
                else {
                    Text("Balance needed").font(.system(size: 18, weight: .semibold))
                    Text("Add a balance to value this account.").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if partOwner, let share, total != nil {
                UpOnlyValueRow(label: "Your share" + (ownership.map { " · " + $0.label } ?? ""), value: UpOnlyFormat.exactMoney(share))
            }
            if let companyID, let book = model.books.first(where: { $0.id == companyID }) {
                let totals = rangeTotals(book)
                HStack(alignment: .top, spacing: 12) {
                    companyFigure("Net revenue", totals.revenue)
                    companyFigure("Expenses", totals.expenses.map { -$0 })
                    companyFigure(partOwner ? "Your share" : "Profit / loss", partOwner ? totals.share : totals.profit, tint: (partOwner ? totals.share : totals.profit).map { $0 < 0 ? Color(nsColor: .systemRed) : UpOnlyTint.cashFlow })
                }
            } else if companyID != nil { Text("Accounting unavailable for this period").font(.system(size: 12)).foregroundStyle(.secondary) }
            let hasBalanceChart = points.contains(where: { $0.value != nil })
            if hasBalanceChart || companyID != nil {
                // One chart; the toggle chooses balance history or monthly profit.
                let showProfit = companyChart == .profit && companyID != nil
                HStack(alignment: .center, spacing: 8) {
                    if companyID != nil && hasBalanceChart {
                        Picker("Chart", selection: $companyChart) {
                            Text("Balance").tag(CompanyChart.balance)
                            Text("Profit / loss").tag(CompanyChart.profit)
                        }.pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize().accessibilityLabel("Company chart")
                    } else {
                        Text(showProfit ? "Profit / loss" : "Bank balance").font(.system(size: 12, weight: .semibold))
                    }
                    Spacer(minLength: 0)
                }.padding(.top, 6)
                if showProfit || !hasBalanceChart {
                    UpOnlyChart(points: rangeMonthPoints, includesZero: true, showsAllMarkers: true,
                                selected: nil, tint: UpOnlyTint.cashFlow,
                                onSelect: { if let month = MonthKey($0) { model.drillInto(month) } })
                } else {
                    UpOnlyChart(points: points, tint: UpOnlyTint.netWorth)
                }
            }
            // Largest balance first; empty currencies fold away so the list stays short.
            let sorted = bankValues.sorted { ($0.usdValue?.value ?? -1) > ($1.usdValue?.value ?? -1) }
            let empty = sorted.filter { $0.nativeAmount?.value == 0 && $0.missing == nil }
            let emptyIDs = Set(empty.map(\.id))
            let shown = showEmptyBalances ? sorted : sorted.filter { !emptyIDs.contains($0.id) }
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(bankValues.count > 1 ? "Balances" : "Balance").font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 8)
                    if !empty.isEmpty {
                        Button(showEmptyBalances ? "Hide empty" : "\(empty.count) empty") { showEmptyBalances.toggle() }
                            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }.padding(.bottom, 4)
                let banks = document.map { BankBalanceGroup.banks(shown, document: $0) } ?? []
                ForEach(banks) { bank in
                    let single = bank.components.count == 1
                    Divider().opacity(0.4)
                    // One line per bank. A multi-currency bank lists its currencies beneath, indented.
                    HStack(alignment: .center, spacing: 10) {
                        if let image = bank.image { UpOnlyProfileImage(data: image, name: bank.name, size: 22) }
                        else { UpOnlySymbolBadge(symbol: "building.columns.fill", size: 22) }
                        Text(bank.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        if single, let component = bank.components.first, component.currency != "USD", let native = component.nativeAmount {
                            UpOnlyPrivateText(UpOnlyFormat.currencyMoney(native.value, currency: component.currency)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        UpOnlyPrivateText(bank.total.map(UpOnlyFormat.exactMoney) ?? (bank.components.contains { $0.missing == "fx" } ? "Rate needed" : "Add balance"))
                            .font(.system(size: 13, weight: single ? .medium : .regular).monospacedDigit()).foregroundStyle(single ? .primary : .secondary).lineLimit(1)
                    }.padding(.vertical, 9).contentShape(Rectangle())
                        .onTapGesture { if single, let component = bank.components.first, session.startImport(.bankBalances, prefill: true, accountID: component.id) { session.addingInMenu = true } }
                        .help(single ? "Update this balance" : "")
                    if !single {
                        ForEach(bank.components, id: \.id) { component in
                            Button {
                                if session.startImport(.bankBalances, prefill: true, accountID: component.id) { session.addingInMenu = true }
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(component.currency).font(.system(size: 12, weight: .medium)).frame(width: 34, alignment: .leading)
                                    if component.currency != "USD", let native = component.nativeAmount {
                                        UpOnlyPrivateText(UpOnlyFormat.currencyMoney(native.value, currency: component.currency)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 8)
                                    UpOnlyPrivateText(component.usdValue.map { UpOnlyFormat.exactMoney($0.value) } ?? (component.missing == "fx" ? "Rate needed" : "Add balance"))
                                        .font(.system(size: 13, weight: .medium).monospacedDigit()).lineLimit(1)
                                        .foregroundStyle(component.nativeAmount?.value == 0 ? .secondary : .primary)
                                }.padding(.vertical, 5).padding(.leading, 32).contentShape(Rectangle())
                            }.buttonStyle(.plain).help("Update this balance")
                                .accessibilityLabel("Update " + component.label + " balance")
                        }
                    }
                }
            }.padding(.horizontal, 12).padding(.vertical, 10).modifier(UpOnlyContentSurface())
            ForEach(portfolios) { portfolio in
                Button { companySelection = nil; model.selectScope(selection.previousScope); scope = .portfolio(portfolio.id) } label: {
                    worthRowLabel(portfolio)
                }.buttonStyle(.bordered)
            }
            if let book {
                DisclosureGroup("Accounting details") {
                    VStack(alignment: .leading, spacing: 8) {
                        if let row = model.state.businesses.first(where: { $0.id == book.id }) { businessDetails(row) }
                        Text(book.basis)
                        ForEach(model.state.warnings, id: \.self) { Text($0) }
                        if let url = URL(string: book.sourceURL), url.scheme == "https" { Link("Open accounting sheet", destination: url).buttonStyle(.bordered) }
                    }.font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
                }.font(.system(size: 12))
            }
        }
    }
    // Daily history of just this group's bank balances, from the saved valuations.
    private func groupPoints(_ selection: CompanySelection) -> [UpOnlyChartPoint] {
        guard let document = session.document else { return [] }
        let ids = Set(selection.group.components.map(\.id))
        let companyID = selection.group.businessID
        return dailyPoints { sample in
            let parts = sample.components.filter { component in
                guard component.kind == .bank else { return false }
                if let companyID { return AssetOwnership.businessID(for: component, in: document) == companyID }
                return ids.contains(component.id)
            }
            guard !parts.isEmpty, parts.allSatisfy({ $0.usdValue != nil }) else { return nil }
            return AssetOwnership.sum(parts).map { ($0, nil) }
        }
    }
    private func worthRowLabel(_ portfolio: Portfolio) -> some View {
        let valuation = session.document.map { NetWorthCalculator.value(at: selectedInterval.end, scope: .portfolio(portfolio.id), document: $0) }
        return UpOnlyValueRow(label: portfolio.name, value: valuation?.total.map(UpOnlyFormat.exactMoney) ?? "Review holdings", chevron: true, primaryLabel: true)
    }
    private var selectedPortfolio: Portfolio? {
        guard session.destination == 1, case .portfolio(let id) = scope else { return nil }
        return session.document?.portfolio(id: id)
    }
    private var showsHoldings: Bool { session.document?.showsHoldings == true }
    private var allScopeTitle: String { "All assets" }
    private var scopeTitle: String {
        switch scope {
        case .allTracked: allScopeTitle
        case .banks: "Bank balances"
        case .portfolio(let id): session.document?.portfolio(id: id)?.name ?? "Portfolio"
        }
    }
    private func worthRow(_ name: String, scope: ValuationScope) -> some View {
        let valuation = session.document.map { AssetOwnership.personalValue(at: selectedInterval.end, scope: scope, document: $0) }
        return Button { self.scope = scope } label: {
            UpOnlyValueRow(label: name, value: valuation?.total.map(UpOnlyFormat.money) ?? (valuation?.isUnavailable != false ? "—" : "Needs update"), chevron: true)
        }.buttonStyle(.bordered)
    }
    private var worthCaption: String {
        guard let result, !result.isUnavailable else { return "No value recorded" }
        if result.total == nil {
            if let last = result.lastComplete { return "Last complete value · " + last.at.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: UTCDay.timeZone)) }
            return ""
        }
        if !result.stale.isEmpty { return "Some values may be out of date" }
        if let doc = session.document, let first = visibleSamples.first {
            let old = AssetOwnership.personalValue(at: min(selectedInterval.end, UTCDay.start(of: first.utcDay).addingTimeInterval(86399)), scope: scope, document: doc)
            if let change = NetWorthCalculator.change(from: old, to: result) {
                if session.privacyMode { return "Change hidden " + periodPhrase }
                return (change.amount > 0 ? "+" : "") + UpOnlyFormat.money(change.amount) + " " + periodPhrase
            }
        }
        return "As of " + UpOnlyFormat.utcDay(selectedInterval.end)
    }
    private var visibleSamples: [DailyValuation] {
        guard let document = session.document else { return [] }
        return DashboardPeriod.samples(in: selectedInterval, scope: scope, document: document)
    }
    private var worthPoints: [UpOnlyChartPoint] {
        dailyPoints { sample in
            guard let document = session.document else { return nil }
            if sample.isComplete {
                return AssetOwnership.personalTotal(sample.components, at: sample.utcDay, document: document).map { ($0, nil) }
            }
            // A day with an unpriced holding still shows what could be valued, marked as an estimate.
            let valued = sample.components.filter { $0.usdValue != nil && $0.missing == nil }
            let unpriced = sample.components.filter { $0.usdValue == nil || $0.missing != nil }.map(\.label)
            guard !valued.isEmpty, !unpriced.isEmpty, let total = AssetOwnership.personalTotal(valued, at: sample.utcDay, document: document) else { return nil }
            return (total, "Excludes " + unpriced.joined(separator: ", ") + " (no price that day)")
        }
    }
    /// One point per day between the first and last sample. `value` returns the day's figure and, when the
    /// figure is an estimate, a note saying what it leaves out.
    private func dailyPoints(_ value: (DailyValuation) -> (Decimal, String?)?) -> [UpOnlyChartPoint] {
        let samples = visibleSamples
        guard let first = samples.first, let last = samples.last else { return [] }
        var byDay: [Date: DailyValuation] = [:]
        for sample in samples { byDay[UTCDay.start(of: sample.utcDay)] = sample }
        var points: [UpOnlyChartPoint] = []
        var day = UTCDay.start(of: first.utcDay)
        let end = UTCDay.start(of: last.utcDay)
        while day <= end && points.count < 10000 {
            let figure = byDay[day].flatMap(value)
            points.append(UpOnlyChartPoint(id: String(day.timeIntervalSince1970), label: UpOnlyFormat.utcDay(day), value: figure?.0, partial: figure?.1 != nil, note: figure?.1))
            day = day.addingTimeInterval(86400)
        }
        return points
    }
}

struct UpOnlyAmount: View {
    @Environment(UpOnlySession.self) private var session
    var value: Decimal
    var signed = false
    var tint: Color = .primary
    var body: some View {
        if session.privacyMode {
            Text("••••").font(.system(size: 40, weight: .semibold)).foregroundStyle(.primary)
                .accessibilityLabel("Hidden value")
        } else {
        ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text((value < 0 ? "−" : signed && value > 0 ? "+" : "") + "$").fixedSize(horizontal: false, vertical: true)
                .font(.system(size: 24, weight: .medium))
            Text(UpOnlyFormat.money(abs(value)).replacingOccurrences(of: "$", with: "")).fixedSize(horizontal: false, vertical: true)
                .font(.system(size: 40, weight: .semibold).monospacedDigit()).tracking(-1.3)
        }.fixedSize()
            Text(UpOnlyFormat.money(value)).fixedSize(horizontal: false, vertical: true).font(.system(size: 24, weight: .semibold).monospacedDigit())
        }.foregroundStyle(tint)
            .accessibilityElement(children: .ignore).accessibilityLabel(UpOnlyFormat.money(value))
        }
    }
}

struct UpOnlyValueRow: View {
    var label: String
    var value: String
    var chevron = false
    var imageData: Data?
    var primaryLabel = false
    var body: some View {
        ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let imageData { UpOnlyProfileImage(data: imageData, name: label, size: 22) }
            Text(label).fixedSize().foregroundStyle(primaryLabel ? Color.primary : Color.secondary)
            Spacer(minLength: 8)
            UpOnlyPrivateText(value).fixedSize().monospacedDigit().foregroundStyle(.primary)
            if chevron { Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary) }
        }
            HStack(alignment: .top, spacing: 8) {
                if let imageData { UpOnlyProfileImage(data: imageData, name: label, size: 22) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(label).fixedSize(horizontal: false, vertical: true).foregroundStyle(primaryLabel ? Color.primary : Color.secondary)
                    UpOnlyPrivateText(value).fixedSize(horizontal: false, vertical: true).monospacedDigit().foregroundStyle(.primary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if chevron { Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary) }
            }.padding(.vertical, 4)
        }.font(.system(size: 13)).frame(maxWidth: .infinity, minHeight: 28, alignment: .leading).contentShape(Rectangle())
    }
}

// Attach Apple's authentication view before requesting evaluation. The same context
// then authorizes the existing protected Keychain read; no app-managed credential UI.
private struct UpOnlyAuthenticationIcon: View {
    let context: LAContext
    let password: () -> Void
    let ready: @MainActor @Sendable () -> Void
    var body: some View {
        UpOnlyEmbeddedAuthentication(context: context, ready: ready)
            .accessibilityHidden(true)
            .overlay {
                UpOnlyPasswordClick(action: password)
            }
    }
}

// The system password dialog can leave the menu visible but inactive. Accept
// its first mouse click as an action as well as activation, including retries.
private struct UpOnlyPasswordClick: NSViewRepresentable {
    let action: () -> Void
    func makeNSView(context: Context) -> UpOnlyPasswordButton {
        let button = UpOnlyPasswordButton()
        button.title = ""
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.setAccessibilityLabel("Use Mac password")
        button.toolTip = "Click to use your Mac password"
        button.target = button
        button.action = #selector(UpOnlyPasswordButton.clicked)
        button.onClick = action
        return button
    }
    func updateNSView(_ button: UpOnlyPasswordButton, context: Context) { button.onClick = action }
}

private final class UpOnlyPasswordButton: NSButton {
    var onClick: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    @objc func clicked() { onClick?() }
}

private struct UpOnlyEmbeddedAuthentication: NSViewControllerRepresentable {
    let context: LAContext
    let ready: @MainActor @Sendable () -> Void
    func makeNSViewController(context coordinator: Context) -> UpOnlyAuthenticationViewController {
        UpOnlyAuthenticationViewController(context: context, ready: ready)
    }
    func updateNSViewController(_ controller: UpOnlyAuthenticationViewController, context: Context) {}
}

// Embedded Touch ID pauses while its app is inactive. A menu-bar panel can be
// visible without activating its accessory app, so attachment alone is not ready.
final class UpOnlyAuthenticationViewController: NSViewController {
    private let authenticationContext: LAContext
    private var ready: (@MainActor @Sendable () -> Void)?
    private var activationObserver: NSObjectProtocol?
    init(context: LAContext, ready: @escaping @MainActor @Sendable () -> Void) {
        authenticationContext = context
        self.ready = ready
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func loadView() {
        view = LAAuthenticationView(context: authenticationContext, controlSize: .small)
    }
    override func viewDidAppear() {
        super.viewDidAppear()
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.startWhenVisible() }
        }
        NSApp.activate()
        view.window?.makeKey()
        DispatchQueue.main.async { [weak self] in self?.startWhenVisible() }
    }
    private func startWhenVisible() {
        guard NSApp.isActive, let window = view.window, window.isVisible, let ready else { return }
        window.makeKey()
        self.ready = nil
        ready()
    }
    override func viewDidDisappear() {
        super.viewDidDisappear()
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
    }
    deinit {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }
}

struct UpOnlyPrivacyButton: View {
    var inMenu = false
    @Environment(UpOnlySession.self) private var session
    var body: some View {
        if inMenu { button }
        else { button.buttonStyle(UpOnlyToolbarButtonStyle()) }
    }
    private var button: some View {
        Button {
            Task {
                let token = session.sessionToken
                do { try await session.togglePrivacyMode() }
                catch {
                    if session.sessionToken == token, session.state == .unlocked {
                        session.message = "Couldn’t save privacy mode. Please try again."
                    }
                }
            }
        } label: {
            if inMenu { Label(session.privacyMode ? "Show values" : "Hide values", systemImage: session.privacyMode ? "eye.slash" : "eye") }
            else { Image(systemName: session.privacyMode ? "eye.slash" : "eye").font(.system(size: 13, weight: .medium)).frame(width: 16, height: 16) }
        }.foregroundStyle(session.privacyMode ? Color.accentColor : Color.primary)
            .accessibilityLabel(session.privacyMode ? "Show values" : "Hide values")
            .accessibilityValue(session.privacyMode ? "Privacy mode on" : "Privacy mode off")
            .accessibilityIdentifier("PrivacyMode")
            .help(session.privacyMode ? "Show values (⇧⌘P)" : "Hide values (⇧⌘P)")
            .keyboardShortcut("p", modifiers: [.command, .shift]).disabled(session.isBusy)
    }
}

/// Replace the text, not merely its pixels, so hidden values are absent from accessibility.
struct UpOnlyPrivateText: View {
    @Environment(UpOnlySession.self) private var session
    let value: String
    init(_ value: String) { self.value = value }
    var body: some View {
        if session.privacyMode { Text("••••").accessibilityLabel("Hidden value") }
        else { Text(value) }
    }
}

/// Native secure entry retains editing and paste without exposing a financial amount.
struct UpOnlyValueField: View {
    @Environment(UpOnlySession.self) private var session
    let placeholder: String
    @Binding var text: String
    init(_ placeholder: String, text: Binding<String>) { self.placeholder = placeholder; _text = text }
    var body: some View {
        if session.privacyMode { SecureField(placeholder, text: $text) }
        else { TextField(placeholder, text: $text, axis: .vertical) }
    }
}

// Equal hit regions and one shared glass surface keep toolbar actions aligned.
struct UpOnlyToolbarButtonStyle: ButtonStyle {
    var size: CGFloat = 32
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(width: size, height: size)
            .contentShape(Rectangle())
            .background(.primary.opacity(configuration.isPressed ? 0.14 : 0), in: Capsule())
            .opacity(isEnabled ? 1 : 0.4)
    }
}

// macOS substitutes a native menu label, so padding inside its label closure is
// discarded. Size the menu itself before applying its glass surface.
struct UpOnlyPillMenu: ViewModifier {
    func body(content: Content) -> some View {
        content.menuStyle(.borderlessButton).menuIndicator(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10).frame(minHeight: 26)
            .glassEffect(.regular, in: .capsule)
    }
}
private struct PersonalAccountGroup: Identifiable, Hashable {
    var id: UUID?
    var name: String
}
/// How much net worth history the chart shows. The headline value is always today's.
enum WorthRange: CaseIterable {
    case month, quarter, year, twoYears, fiveYears
    var title: String {
        switch self { case .month: "This month"; case .quarter: "Last 3 months"; case .year: "Last 12 months"; case .twoYears: "Last 24 months"; case .fiveYears: "Last 5 years" }
    }
    var phrase: String { title.lowercased() }
    /// Whole months shown on monthly charts, ending with the current month.
    var months: Int {
        switch self { case .month: 1; case .quarter: 3; case .year: 12; case .twoYears: 24; case .fiveYears: 60 }
    }
    var seconds: TimeInterval {
        switch self { case .month: 30 * 86400; case .quarter: 91 * 86400; case .year: 365 * 86400; case .twoYears: 730 * 86400; case .fiveYears: 1826 * 86400 }
    }
}
