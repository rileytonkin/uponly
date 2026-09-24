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
                UpOnlyMenuScroll(maxHeight: menuHeight) { panelContent }
                    .frame(width: 344).fixedSize(horizontal: false, vertical: true)
            }
        }
        .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.regular)
        .background { Color(nsColor: .windowBackgroundColor).ignoresSafeArea() }
        .background(UpOnlyPanelKeyboard(close: {
            if session.showingSwitcher { session.showingSwitcher = false }
            else if let closeMenu { closeMenu() } else { dismiss() }
        }).frame(width: 0, height: 0))
        .background {
            if session.state == .unlocked, session.unlockTiming != nil {
                UpOnlyUnlockDisplayProbe { session.recordUnlockedMenuDisplay() }.frame(width: 1, height: 1)
            }
        }
        .onAppear { if !menuLifecycleManaged { session.menuOpened() } }
        .onDisappear { if !menuLifecycleManaged { session.surfaceClosed() } }
    }
    /// All assets sets the height and never scrolls; every other dashboard page, the switcher included, opens at the
    /// same height and scrolls within it, so the menu doesn't jump between pages. Setup and Add keep their own.
    private var menuHeight: CGFloat {
        let screen = max(480, (NSScreen.main?.visibleFrame.height ?? 900) - 40)
        guard session.document?.settings.setupComplete == true, !session.addingInMenu else { return min(600, screen) }
        if session.dashboardSelection == .all && !session.showingSwitcher { return screen }
        return min(session.dashboardHeight ?? 600, screen)
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

/// The unlocked dashboard: the switcher title, attention row and the shared pieces its pages use. Cash flow, net worth,
/// company pages and the switcher live in DashboardCashFlow, DashboardNetWorth, DashboardCompany and DashboardSwitcher.
struct UpOnlyUnlockedPanel: View {
    @Environment(UpOnlySession.self) var session
    var model: PopoverModel
    @State var detail: String?
    var showingSwitcher: Bool {
        get { session.showingSwitcher }
        nonmutating set { session.showingSwitcher = newValue }
    }
    @State var worthRange: WorthRange = .year
    @State var holdingSort: HoldingSort = .value
    /// How a portfolio's holdings table is ordered.
    enum HoldingSort: CaseIterable {
        case value, change, name
        var title: String { switch self { case .value: "Value"; case .change: "24h change"; case .name: "Name" } }
    }
    @State var companyChart: CompanyChart = .balance
    @State var companyFocus: CompanyFocus = .all
    enum CompanyChart { case balance, profit }
    /// The net worth scope of the current selection: a portfolio, or everything (bank groups have their own page).
    var scope: ValuationScope {
        if case .portfolio(let id) = session.dashboardSelection { return .portfolio(id) }
        return .allTracked
    }
    /// Switches what the dashboard shows. A bank group's page reads its company's accounting, so Income & spending's
    /// account choice is put aside there and given back afterwards.
    func select(_ selection: UpOnlySession.DashboardSelection) {
        detail = nil; companyFocus = .all; showingSwitcher = false
        let leavingGroup = selectedGroupID != nil
        if case .bankGroup(let id) = selection {
            if !leavingGroup { session.cashFlowScope = model.scope }
            model.selectScope(id == "personal" ? .personal : .business(id))
        } else if leavingGroup {
            model.selectScope(session.cashFlowScope ?? .all); session.cashFlowScope = nil
        }
        session.dashboardSelection = selection
    }
    /// The bank group page being shown: "personal" or a company's id.
    var selectedGroupID: String? {
        if case .bankGroup(let id) = session.dashboardSelection { return id }
        return nil
    }
    /// The switcher's title: what the page below is about.
    var selectionTitle: String {
        switch session.dashboardSelection {
        case .all: "All assets"
        case .cashFlow: "Income & spending"
        case .portfolio(let id): session.document?.portfolio(id: id)?.name ?? "Portfolio"
        case .bankGroup(let id): id == "personal" ? "Bank balances" : companyName(id)
        }
    }
    /// A company's accounting name, else the name of the bank profile its accounts come from.
    func companyName(_ id: String) -> String {
        if let book = model.books.first(where: { $0.id == id }) { return book.name }
        guard let document = session.document else { return "Company" }
        return document.accounts.first { AssetOwnership.businessID(for: $0, in: document) == id }.map(AssetOwnership.profileName) ?? "Company"
    }
    /// Net worth is always today's value; the range only sets how much history the chart shows.
    /// Cash flow keeps the month, year or all-time selector.
    var isWorthPage: Bool { !(session.destination == 0 && shows(.cashFlow)) }
    var selectedInterval: DateInterval {
        guard isWorthPage else { return model.selectedInterval() }
        return worthInterval(scope)
    }
    /// The chart range for a net worth scope. All starts at that scope's first saved value.
    func worthInterval(_ scope: ValuationScope) -> DateInterval {
        let now = Date()
        if let seconds = worthRange.seconds { return DateInterval(start: now.addingTimeInterval(-seconds), end: now) }
        let first = session.document?.dailyValuations.lazy.filter { $0.scope == scope }.map(\.utcDay).min() ?? now
        return DateInterval(start: min(UTCDay.start(of: first), now), end: now)
    }

    func shows(_ kind: TrackedKind) -> Bool { session.document?.shows(kind) == true }
    var showsNetWorth: Bool { session.document?.showsNetWorth == true }
    func manage(_ section: String) {
        if section == "Entries" { session.entryMonthForManagement = model.period == .monthly ? model.month.description : "" }
        session.managementSection = section
        session.managementInMenu = true
    }
    /// After `startImport`: one row opens the guided form and several open the table. A refused start means an
    /// unfinished draft is still open; showing it, with its message, beats a button that silently does nothing.
    func showImport(_ started: Bool) {
        guard started else { session.managementInMenu = true; return }
        if (session.importDraft?.rows.count ?? 0) > 1 {
            session.importTableMode = true; session.importReturnsHome = true; session.managementInMenu = true
        } else { session.addingInMenu = true }
    }
    var hasData: Bool {
        guard let document = session.document else { return false }
        return !document.accounts.isEmpty || !document.entries.isEmpty || !document.holdings.isEmpty || !(document.businessAccounting ?? []).isEmpty
    }
    var body: some View {
        let group = showingSwitcher ? nil : selectedGroupID
        let home = session.dashboardSelection == .all && !showingSwitcher
        // The banner only shows on the overview and cash flow, so it is only worked out there.
        let attention = !showingSwitcher && group == nil && detail == nil && selectedPortfolio == nil ? attentionItems : []
        return VStack(spacing: 0) {
            navigationHeader.padding(.top, 14).padding(.bottom, 16)
            if showingSwitcher { switcherPage }
            else {
                if !attention.isEmpty { attentionBanner(attention).padding(.bottom, 16) }
                if let group { companyContent(group) }
                else if !hasData, shows(.cashFlow) || showsNetWorth { addFirstData }
                else if session.destination == 0 && shows(.cashFlow) { monthContent }
                else if showsNetWorth { worthContent }
                else { addFirstData }
                if let message = session.message {
                    Text(message).fixedSize(horizontal: false, vertical: true).font(UpOnlyType.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10).padding(.bottom, 10)
                }
            }
        }.padding(.horizontal, UpOnlyLayout.inset).padding(.bottom, 16)
        // All assets sets the height every other page opens at (the session checks the selection still exists).
        .frame(minHeight: home ? nil : session.dashboardHeight, alignment: .top)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            if home, height > 0, session.dashboardHeight != ceil(height) { session.dashboardHeight = ceil(height) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("UpOnlyUnlocked")
    }
    /// One title for every page: the switcher box and the name of what's showing. Cash flow's drill-ins keep a Back.
    @ViewBuilder var navigationHeader: some View {
        if let detail, !showingSwitcher {
            UpOnlyPageHeader(title: detail == "personal" ? "Personal" : selectedBusiness?.book.name ?? "Company",
                             backLabel: "Back to income & spending") { self.detail = nil }
        } else {
            // The eye sits by the title, so it's in the same place on every page.
            HStack(spacing: 4) {
                switcherTitle
                UpOnlyPrivacyButton()
                Spacer(minLength: 8)
                HStack(spacing: 8) { addButton; dashboardActions }
            }.frame(minHeight: 32)
        }
    }
    var switcherTitle: some View {
        Button { showingSwitcher.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: showingSwitcher ? "xmark" : "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary).frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                Text(selectionTitle).font(UpOnlyType.pageTitle).lineLimit(1).truncationMode(.middle)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(showingSwitcher ? "Close" : "Showing " + selectionTitle).accessibilityHint(showingSwitcher ? "" : "Choose all assets, a portfolio or income & spending")
            .accessibilityIdentifier("DashboardSwitcher").keyboardShortcut("k", modifiers: .command)
            .help("Choose what to show (⌘K)")
    }
    var syncNeedsAttention: Bool {
        if !session.backgroundIssues.isEmpty { return true }
        #if UPONLY_PERSONAL
        return session.accountingError != nil || (session.document?.settings.automaticWise == true && session.wiseError != nil)
        #else
        return false
        #endif
    }
    var attentionItems: [String] {
        guard hasData, let document = session.document else { return syncNeedsAttention ? ["A source couldn’t refresh"] : [] }
        let report = model.attention(in: document, includePerformance: true)
        var items: [String] = []
        if !report.balances.isEmpty { items.append(report.balances.count == 1 ? "Balance needed for " + report.balances[0].name : "\(report.balances.count) balances needed") }
        if !report.quantities.isEmpty { items.append(report.quantities.count == 1 ? "Quantity needed for " + report.quantities[0].assetName : "\(report.quantities.count) quantities needed") }
        if report.pricesNeeded { items.append("Prices or exchange rates missing") }
        let months = report.spendingMonths
        if !months.isEmpty { items.append(months.count == 1 ? "Check " + months[0].title : "\(months.count) months to check") }
        if !report.accountingNames.isEmpty { items.append("Accounting incomplete") }
        if syncNeedsAttention { items.append("A source couldn’t refresh") }
        return items
    }
    func attentionBanner(_ items: [String]) -> some View {
        Button { manage("Needs attention") } label: {
            HStack(spacing: 10) {
                Circle().fill(.orange).frame(width: 7, height: 7).accessibilityHidden(true)
                Text(items.count == 1 ? items[0] : "\(items.count) things need attention").font(UpOnlyType.body.weight(.medium)).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            }.padding(.horizontal, 14).padding(.vertical, 9).contentShape(Capsule())
        }.buttonStyle(.plain).glassEffect(.regular, in: .capsule).accessibilityIdentifier("DataAttention")
            .accessibilityLabel("Needs attention").accessibilityValue(items.joined(separator: ", "))
    }
    var addButton: some View {
        Button { session.addingInMenu = true } label: {
            Image(systemName: "plus").font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
                .frame(width: 32, height: 32).contentShape(Circle())
        }
        .buttonStyle(.plain).glassEffect(.regular, in: .circle)
        .accessibilityLabel("Add").accessibilityIdentifier("AddInfo").help("Add a balance, holding, transaction or statement")
    }
    var dashboardActions: some View {
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
    // The title above already names the page, so the empty state is just the invitation.
    var addFirstData: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Start with one balance").font(UpOnlyType.title)
                Text("A bank account, some crypto, gold or silver, or an income and spending statement. Add more any time with the plus button.")
                    .font(UpOnlyType.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Button { session.addingInMenu = true } label: { Text("Add").frame(maxWidth: .infinity) }
                .buttonStyle(.glassProminent).controlSize(.large)
        }.padding(.bottom, 4)
    }
    var personalRateGaps: [(MonthKey, [String])] {
        guard session.destination == 0, let document = session.document else { return [] }
        if case .business = model.scope { return [] }
        return model.attentionMonths.reversed().compactMap { month in
            if case .exchangeRates(let currencies)? = MonthlyLedger.personal(month, document: document).unavailable { return (month, currencies) }
            return nil
        }
    }
    func exchangeRateAction(_ currencies: [String], month: MonthKey) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Exchange rate missing").font(UpOnlyType.section)
            Text("To show this in USD, Up Only needs " + currencies.joined(separator: ", ") + " rates for " + month.title + ".")
                .font(UpOnlyType.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let issue = currencies.compactMap({ session.fxIssues[$0] }).first {
                Text(issue).font(UpOnlyType.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Menu("Exchange rates") {
                Button(session.document?.settings.automaticFX == true ? "Get " + month.shortName + " rates" : "Enable exchange rates") {
                    Task { await session.repairExchangeRates(month: month, currencies: currencies) }
                }.disabled(session.isBusy || session.refreshing).accessibilityIdentifier("RepairExchangeRates")
                Button("Add rate manually") {
                    session.entryMonthForManagement = month.description
                    session.requestedRateCurrency = currencies.first
                    session.managementSection = "Entries"; session.managementInMenu = true
                }.disabled(session.isBusy)
            }.modifier(UpOnlyPillMenu()).accessibilityLabel("Resolve exchange rates")
        }.padding(UpOnlyLayout.cardInset).frame(maxWidth: .infinity, alignment: .leading).modifier(UpOnlyContentSurface())
    }
    func nativeMonthContent(_ gap: (MonthKey, [String])) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            exchangeRateAction(gap.1, month: gap.0)
            if model.period == .monthly {
                DisclosureGroup("Amounts in " + model.month.title) {
                    if let document = session.document, let rows = try? MonthlyLedger.nativeTotals(model.month, document: document) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(rows) { row in
                                VStack(spacing: 4) {
                                    UpOnlyValueRow(label: row.currency + " income", value: UpOnlyFormat.currencyMoney(row.totals.moneyIn, currency: row.currency))
                                    UpOnlyValueRow(label: row.currency + " spending", value: UpOnlyFormat.currencyMoney(-row.totals.moneyOut, currency: row.currency))
                                }
                            }
                        }.padding(.top, 8)
                    }
                }.font(UpOnlyType.body)
            }
            Button("View transactions") { manage("Entries") }.buttonStyle(.bordered).controlSize(.small)
        }
    }
    // Every page opens the same way: what the number is on the left and, on Cash flow, the period on the right.
    // Net worth pages choose their range under the chart instead.
    func headline<Eyebrow: View>(_ eyebrow: Eyebrow) -> some View {
        HStack(alignment: .center, spacing: 8) {
            eyebrow
            Spacer(minLength: 8)
            if !isWorthPage { periodSelector.layoutPriority(1) }
        }.frame(minHeight: 26)
    }
    /// 1W 1M 3M 1Y All above the chart: one track with the chosen segment raised, as market apps do.
    var rangeControl: some View {
        HStack(spacing: 2) {
            ForEach(WorthRange.allCases, id: \.self) { range in
                let chosen = worthRange == range
                Button { worthRange = range } label: {
                    Text(range.title).font(.system(size: 11, weight: chosen ? .semibold : .medium).monospacedDigit())
                        .foregroundStyle(chosen ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity, minHeight: 22)
                        .background {
                            if chosen { Capsule().fill(Color(nsColor: .controlBackgroundColor)).shadow(color: .black.opacity(0.12), radius: 1, y: 0.5) }
                        }
                        .contentShape(Capsule())
                }.buttonStyle(.plain)
                    .accessibilityLabel(range.spokenTitle).accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }.padding(2).background(Color.primary.opacity(0.06), in: Capsule())
            .accessibilityElement(children: .contain).accessibilityLabel("Chart range")
    }
    func eyebrow(_ title: String) -> some View {
        Text(title).font(UpOnlyType.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
    }
    var compactPeriodTitle: String {
        switch model.period {
        case .monthly: UpOnlyFormat.monthName(model.month) + " " + String(model.month.year)
        case .annual: String(model.month.year)
        case .allTime: "All time"
        }
    }
    var periodSelector: some View {
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
                } label: { Text(compactPeriodTitle).font(UpOnlyType.body.weight(.medium)).lineLimit(1) }
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
    // the label, and every alternative is one click away. A long name truncates in the middle rather than
    // pushing the pill past the panel's edges.
    func scopeControl<Selection: Hashable>(_ options: [(Selection, String)], selection: Binding<Selection>, label: String, item: String) -> some View {
        let index = options.firstIndex { $0.0 == selection.wrappedValue } ?? 0
        return Menu {
            ForEach(Array(options.enumerated()), id: \.offset) { offset, option in
                Toggle(option.1, isOn: Binding(get: { offset == index }, set: { _ in selection.wrappedValue = option.0 }))
            }
        } label: {
            // One Text keeps the chevron after the title inside a native menu label.
            Text("\(options[index].1)  \(Text(Image(systemName: "chevron.down")).font(.system(size: 7, weight: .bold)))")
                .font(UpOnlyType.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }.modifier(UpOnlyPillMenu(height: 22))
            .accessibilityLabel(label).accessibilityValue(options[index].1).help("Choose " + item)
    }
    var performanceScopeSelector: some View {
        scopeControl([(.all, "All accounts"), (.personal, "Personal")] + model.books.map { (.business($0.id), $0.name) },
                     selection: Binding(get: { model.scope }, set: { model.selectScope($0) }), label: "Cash flow accounts", item: "account")
            .help(performanceBasis)
            .accessibilityHint(performanceBasis)
    }
    /// One point per chart stop from the start of the range to the last sample, ending at `live`, the figure shown
    /// above the chart, so the line finishes where the headline says. `value` returns a sample's figure and, when
    /// it's an estimate, a note saying what was estimated.
    func dailySeries(_ samples: [DailyValuation], interval: DateInterval, live: Decimal? = nil, _ value: (DailyValuation) -> (Decimal, String?)?) -> [UpOnlyChartPoint] {
        let stops = DashboardChart.stops(sampleDays: samples.map(\.utcDay), rangeStart: interval.start, strideDays: worthRange.chartStepDays(span: interval.duration))
        var days = stops.map(\.day)
        var sampleDays = stops.map { $0.sample.map { samples[$0].utcDay } }
        var figures = stops.map { stop in stop.sample.flatMap { value(samples[$0]) } }
        if let live, let last = days.last {
            let today = UTCDay.start(of: interval.end)
            if UTCDay.isSameDay(last, today) { figures[figures.count - 1] = (live, nil); sampleDays[sampleDays.count - 1] = today }
            else { days.append(today); sampleDays.append(today); figures.append((live, nil)) }
        }
        let labels = DashboardChart.axisMarks(days, range: worthRange)
        return days.indices.map { index in
            UpOnlyChartPoint(id: String(days[index].timeIntervalSince1970), label: UpOnlyFormat.utcDay(days[index]), value: figures[index]?.0,
                             detailLabel: UpOnlyFormat.utcDate(sampleDays[index] ?? days[index]), note: figures[index]?.1, date: sampleDays[index], axisLabel: labels[index])
        }
    }
    /// The past 24 hours hour by hour, each valued as the app would have shown it then (the latest prices, rates and
    /// balances saved by that hour), ending at `live`. `key` names the page, for reusing the hours until the next one.
    func hourlySeries(scope: ValuationScope, interval: DateInterval, key: String, live: Decimal?, _ value: (ValuationResult) -> (Decimal, String?)?) -> [UpOnlyChartPoint] {
        guard let document = session.document else { return [] }
        let calendar = Calendar.current
        let cacheKey = key + "|\(session.documentRevision)|\(Int(interval.end.timeIntervalSince1970 / 3600))"
        var points: [UpOnlyChartPoint]
        if let cached = session.hourlyCache[cacheKey] { points = cached }
        else {
            // From exactly 24 hours ago, then on each hour, so the axis can mark every six hours.
            var moments = [interval.start]
            if var hour = calendar.nextDate(after: interval.start, matching: DateComponents(minute: 0, second: 0), matchingPolicy: .nextTime) {
                while hour < interval.end.addingTimeInterval(-60) { moments.append(hour); hour = hour.addingTimeInterval(3600) }
            }
            let marks = DashboardChart.hourMarks(moments, calendar: calendar)
            points = moments.indices.map { index in
                let moment = moments[index]
                let figure = value(NetWorthCalculator.value(at: moment, scope: scope, document: document, now: moment))
                return UpOnlyChartPoint(id: "h" + String(Int(moment.timeIntervalSince1970)), label: UpOnlyFormat.localHour(moment, calendar: calendar), value: figure?.0,
                                        detailLabel: UpOnlyFormat.localMoment(moment, calendar: calendar), note: figure?.1, date: moment, axisLabel: marks[index])
            }
            if session.hourlyCache.count > 24 { session.hourlyCache = [:] }
            session.hourlyCache[cacheKey] = points
        }
        if let live { points.append(UpOnlyChartPoint(id: "now", label: "Now", value: live, detailLabel: "Now", date: interval.end)) }
        return points
    }
    var selectedPortfolio: Portfolio? {
        guard case .portfolio(let id) = scope else { return nil }
        return session.document?.portfolio(id: id)
    }
    /// Where the range's changes start: the chart's first earlier day that can be valued in full, with every part as
    /// it stood then (a missing price, rate or balance estimated from the nearest saved ones). Nil without one.
    func rangeStart(scope: ValuationScope, interval: DateInterval, document: VaultDocument, estimates: ChartEstimates) -> (day: Date, components: [ValuationComponent])? {
        if worthRange.hourly {
            // 24 hours: everything as the app would have shown it then.
            let then = interval.start
            let start = estimates.filled(NetWorthCalculator.value(at: then, scope: scope, document: document, now: then).components, day: then, at: then)
            return start.complete ? (then, start.components) : nil
        }
        let samples = DashboardPeriod.samples(in: interval, scope: scope, document: document)
        let stops = DashboardChart.stops(sampleDays: samples.map(\.utcDay), rangeStart: interval.start, strideDays: worthRange.chartStepDays(span: interval.duration))
        for stop in stops {
            guard let index = stop.sample, !UTCDay.isSameDay(samples[index].utcDay, interval.end) else { continue }
            let day = estimates.filled(samples[index].components, day: samples[index].utcDay)
            if day.complete { return (samples[index].utcDay, day.components) }
        }
        return nil
    }
    /// Today's figure against the chart's first value: the start of the range, or of the history when that's later.
    /// `since` names the period for the line ("prev 1M"); `span` gives the dates for hover and VoiceOver ("over the
    /// past month", "since Aug 30"). Nil without an earlier value.
    struct RangeChange {
        var change: PeriodChange
        var since: String
        var span: String
    }
    func periodChange(_ points: [UpOnlyChartPoint], now: Decimal?) -> RangeChange? {
        guard let now, let index = points.firstIndex(where: { $0.value != nil }), let previous = points[index].value,
              let day = points[index].date, !UTCDay.isSameDay(day, Date()) else { return nil }
        let date = worthRange.showsYear ? UpOnlyFormat.utcDate(day) : UpOnlyFormat.utcDay(day)
        return RangeChange(change: PeriodChange(from: previous, to: now), since: worthRange.previous,
                           span: index == 0 && worthRange != .all ? "over the " + worthRange.phrase : "since " + date)
    }
    /// "(↑ 21.0%)  vs $10,000.00 prev 1M": the change over the range, as on the admin dashboard. The percentage
    /// stays in privacy mode; the amounts don't.
    func changeLine(_ range: RangeChange) -> some View {
        let change = range.change
        let previous = session.privacyMode ? "••••" : UpOnlyFormat.exactMoney(change.previous)
        let moved = session.privacyMode ? UpOnlyFormat.hiddenMovement(change.amount, fraction: nil) : UpOnlyFormat.movement(change.amount, fraction: nil, cents: true)
        return HStack(spacing: 7) {
            if let fraction = change.fraction { UpOnlyChangeBadge(fraction: fraction) }
            else { Text(moved).font(UpOnlyType.body.weight(.medium).monospacedDigit()).foregroundStyle(UpOnlyTint.signed(change.amount)) }
            Text("vs " + previous + " " + range.since).font(UpOnlyType.body.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
        }.help(session.privacyMode ? "" : moved + " " + range.span)
            .accessibilityElement(children: .ignore).accessibilityLabel("Change " + range.span)
            .accessibilityValue([session.privacyMode ? "amount hidden" : moved, change.fraction.map(UpOnlyFormat.percent), session.privacyMode ? nil : "from " + previous]
                .compactMap { $0 }.joined(separator: ", "))
    }

    // MARK: Rows

    /// One bank, company or portfolio row. Every list on the dashboard uses it, so they all look and read the same.
    struct AssetRow: Identifiable {
        enum Trailing { case chevron, space, check(Bool), button(symbol: String, label: String, action: () -> Void) }
        var id: String
        var name: String
        var detail: String? = nil
        /// The detail line is an amount, hidden in privacy mode.
        var detailIsAmount = false
        var value: String
        /// The row's own move over the last 24 hours, as a fraction.
        var change: Decimal? = nil
        var image: Data? = nil
        var symbol: String
        var tint: Color
        var selected = false
        var trailing = Trailing.chevron
        var action: () -> Void
        /// Highlighted (a company page's focus) or checked (the switcher's current page).
        var isChosen: Bool {
            if case .check(true) = trailing { return true }
            return selected
        }
    }
    func assetList(_ rows: [AssetRow]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider().opacity(0.5) }
                assetRow(row)
            }
        }.padding(.horizontal, UpOnlyLayout.cardInset).padding(.vertical, 2).modifier(UpOnlyContentSurface())
    }
    func assetRow(_ row: AssetRow) -> some View {
        HStack(spacing: 6) {
            Button(action: row.action) {
                HStack(spacing: 10) {
                    if let image = row.image { UpOnlyProfileImage(data: image, name: row.name, size: 24) }
                    else { UpOnlySymbolBadge(symbol: row.symbol, tint: row.tint, size: 24) }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.name).font(UpOnlyType.row.weight(.medium)).foregroundStyle(.primary).lineLimit(1).truncationMode(.middle)
                        if let detail = row.detail {
                            Text(row.detailIsAmount && session.privacyMode ? "••••" : detail).font(UpOnlyType.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }.frame(minWidth: 96, alignment: .leading)  // a huge amount shrinks before the name disappears
                    Spacer(minLength: 8)
                    // Value over its change, as in Delta, so the name keeps the width.
                    VStack(alignment: .trailing, spacing: 1) {
                        UpOnlyPrivateText(row.value).font(UpOnlyType.row.monospacedDigit()).foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.7)
                        // Moves stay visible in privacy mode: a percentage doesn't say how much you hold.
                        if let change = row.change {
                            Text(UpOnlyFormat.arrowPercent(change)).font(UpOnlyType.caption.weight(.medium).monospacedDigit())
                                .foregroundStyle(UpOnlyTint.signed(change)).lineLimit(1)
                        }
                    }.layoutPriority(1)
                    if case .chevron = row.trailing {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                    }
                    // The switcher's chosen row: a check in the chevron's place, the same width chosen or not.
                    if case .check(let chosen) = row.trailing {
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.accentColor).opacity(chosen ? 1 : 0).frame(width: 12)
                    }
                }.padding(.vertical, 8).contentShape(Rectangle())
            }.buttonStyle(UpOnlyRowButtonStyle(selected: row.selected))
                .accessibilityLabel(row.name).accessibilityValue(spokenValue(row))
                .accessibilityAddTraits(row.isChosen ? .isSelected : [])
            switch row.trailing {
            case .chevron, .check: EmptyView()
            case .space: Color.clear.frame(width: 24, height: 24)
            case .button(let symbol, let label, let action):
                Button(action: action) {
                    Image(systemName: symbol).font(.system(size: 11, weight: .medium)).frame(width: 24, height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(.secondary).help(label).accessibilityLabel(label)
            }
        }
    }
    /// "<value>, <detail>, +0.4% over the past 30 days": the name is the label, so VoiceOver reads "<name>, <value>".
    func spokenValue(_ row: AssetRow) -> String {
        var parts = [session.privacyMode ? "Hidden value" : row.value]
        if let detail = row.detail, !(row.detailIsAmount && session.privacyMode) { parts.append(detail) }
        if let change = row.change { parts.append(UpOnlyFormat.percent(change) + (worthRange == .all ? " since the first saved value" : " over the " + worthRange.phrase)) }
        return parts.joined(separator: ", ")
    }
}
