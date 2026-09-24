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

/// The unlocked dashboard: tabs, header, attention row and the shared pieces its pages use.
/// Cash flow, Net worth and company pages live in DashboardCashFlow, DashboardNetWorth and DashboardCompany.
struct UpOnlyUnlockedPanel: View {
    @Environment(UpOnlySession.self) var session
    var model: PopoverModel
    @State var scope: ValuationScope = .allTracked
    @State var detail: String?
    @State var companySelection: CompanySelection?
    /// The company page a portfolio was opened from, so the portfolio's Back returns there.
    @State var portfolioReturn: CompanySelection?
    @State var worthRange: WorthRange = .year
    @State var companyChart: CompanyChart = .balance
    @State var companyFocus: CompanyFocus = .all
    enum CompanyChart { case balance, profit }
    /// Net worth is always today's value; the range only sets how much history the chart shows.
    /// Cash flow keeps the month, year or all-time selector.
    var isWorthPage: Bool { !(session.destination == 0 && shows(.cashFlow)) }
    var selectedInterval: DateInterval {
        guard isWorthPage else { return model.selectedInterval() }
        let now = Date()
        return DateInterval(start: now.addingTimeInterval(-worthRange.seconds), end: now)
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
        // The banner only shows on the overview, so it is only worked out there.
        let attention = companySelection == nil && detail == nil && selectedPortfolio == nil ? attentionItems : []
        return VStack(spacing: 0) {
            navigationHeader.padding(.top, 14).padding(.bottom, 16)
            if !attention.isEmpty { attentionBanner(attention).padding(.bottom, 16) }
            if let companySelection { companyContent(companySelection) }
            else if !hasData, shows(.cashFlow) || showsNetWorth { addFirstData }
            else if session.destination == 0 && shows(.cashFlow) { monthContent }
            else if showsNetWorth { worthContent }
            else { addFirstData }
            if let message = session.message {
                Text(message).fixedSize(horizontal: false, vertical: true).font(UpOnlyType.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10).padding(.bottom, 10)
            }
        }.padding(.horizontal, UpOnlyLayout.inset).padding(.bottom, 16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("UpOnlyUnlocked")
        .onChange(of: session.document?.settings.tracked) { _, _ in scope = .allTracked; detail = nil }
        .onChange(of: session.document?.portfolios) { _, _ in
            if case .portfolio(let id) = scope, session.document?.portfolio(id: id)?.isArchived != false { scope = .allTracked; portfolioReturn = nil }
        }
    }
    @ViewBuilder var navigationHeader: some View {
        if let selection = companySelection {
            UpOnlyPageHeader(title: companyName(selection), backLabel: "Back to net worth", profileImage: selection.group.image) {
                model.selectScope(selection.previousScope); companySelection = nil
            }
        } else if let portfolio = selectedPortfolio {
            UpOnlyPageHeader(title: portfolio.name, backLabel: portfolioReturn.map { "Back to " + companyName($0) } ?? "Back to net worth") {
                scope = .allTracked
                if let company = portfolioReturn { portfolioReturn = nil; openCompany(company.group) }
            }
        } else if let detail {
            UpOnlyPageHeader(title: detail == "personal" ? "Personal" : selectedBusiness?.book.name ?? "Company",
                             backLabel: "Back to cash flow") { self.detail = nil }
        } else {
            HStack(spacing: 8) {
                if shows(.cashFlow) && showsNetWorth {
                    Picker("Dashboard section", selection: Binding(get: { session.destination }, set: { session.destination = $0; detail = nil })) {
                        Text("Net worth").tag(1)
                        Text("Cash flow").tag(0)
                    }.pickerStyle(.segmented).controlSize(.regular).font(UpOnlyType.body).labelsHidden().fixedSize()
                } else if shows(.cashFlow) { destination("Cash flow", value: 0) }
                else if showsNetWorth { destination("Net worth", value: 1) }
                Spacer(minLength: 0)
                addButton
                dashboardActions
            }.frame(minHeight: 32)
        }
    }
    func companyName(_ selection: CompanySelection) -> String {
        model.books.first { $0.id == selection.group.businessID }?.name ?? selection.group.name
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
    func destination(_ title: String, value: Int) -> some View {
        Button { session.destination = value; detail = nil } label: {
            Text(title).fixedSize(horizontal: false, vertical: true).font(UpOnlyType.body.weight(session.destination == value ? .semibold : .regular))
                .foregroundStyle(session.destination == value ? .primary : .secondary)
        }.buttonStyle(.bordered).controlSize(.small).tint(session.destination == value ? Color.accentColor : Color.secondary).accessibilityAddTraits(session.destination == value ? .isSelected : [])
    }
    // The tab above already names the page, so the empty state is just the invitation.
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
    /// 1M 3M 1Y 2Y 5Y, directly under the chart as in Delta: equal widths, the chosen one filled.
    func rangeChips(tint: Color) -> some View {
        HStack(spacing: 4) {
            ForEach(WorthRange.allCases, id: \.self) { range in
                let chosen = worthRange == range
                Button { worthRange = range } label: {
                    Text(range.title).font(.system(size: 11, weight: chosen ? .semibold : .medium))
                        .foregroundStyle(chosen ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .background(chosen ? tint.opacity(0.16) : .clear, in: Capsule()).contentShape(Capsule())
                }.buttonStyle(.plain)
                    .accessibilityLabel(range.spokenTitle).accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }.accessibilityElement(children: .contain).accessibilityLabel("Chart range")
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
    func worthScopeOptions(at date: Date) -> [(ValuationScope, String)] {
        var options: [(ValuationScope, String)] = [(.allTracked, "All assets")]
        if shows(.banks) && showsHoldings { options.append((.banks, "Bank balances")) }
        options += (session.document?.portfolios.filter { $0.isActive(at: date) } ?? []).map { (.portfolio($0.id), $0.name) }
        return options
    }
    /// One point per chart stop from the start of the range to the last sample, and the baseline for the change line:
    /// the first sample in the range that is fully valued, unless that is today's. `value` returns a sample's figure and,
    /// when the figure is an estimate, a note saying what it leaves out.
    func dailySeries(_ samples: [DailyValuation], interval: DateInterval, baselineMatches: (DailyValuation) -> Bool = { _ in true },
                             _ value: (DailyValuation) -> (Decimal, String?)?) -> (points: [UpOnlyChartPoint], baseline: Baseline?) {
        let stops = DashboardChart.stops(sampleDays: samples.map(\.utcDay), rangeStart: interval.start, strideDays: worthRange.chartStepDays)
        let labels = DashboardChart.axisLabels(stops.map { $0.day }, range: worthRange)
        let points = stops.enumerated().map { index, stop -> UpOnlyChartPoint in
            let sample = stop.sample.map { samples[$0] }
            let figure = sample.flatMap(value)
            return UpOnlyChartPoint(id: String(stop.day.timeIntervalSince1970), label: UpOnlyFormat.utcDay(stop.day), value: figure?.0,
                                    detailLabel: UpOnlyFormat.utcDate(sample?.utcDay ?? stop.day), partial: figure?.1 != nil, note: figure?.1, axisLabel: labels[index])
        }
        let today = UTCDay.start(of: interval.end)
        var baseline: Baseline?
        for sample in samples where UTCDay.start(of: sample.utcDay) < today && baselineMatches(sample) {
            if let figure = value(sample), figure.1 == nil { baseline = Baseline(sample: sample, value: figure.0); break }
        }
        return (points, baseline)
    }
    var selectedPortfolio: Portfolio? {
        guard session.destination == 1, case .portfolio(let id) = scope else { return nil }
        return session.document?.portfolio(id: id)
    }
    var showsHoldings: Bool { session.document?.showsHoldings == true }

    // MARK: Rows

    /// One bank, company or portfolio row. Every list on the dashboard uses it, so they all look and read the same.
    struct AssetRow: Identifiable {
        enum Trailing { case chevron, space, button(symbol: String, label: String, action: () -> Void) }
        var id: String
        var name: String
        var detail: String? = nil
        /// The detail line is an amount, hidden in privacy mode.
        var detailIsAmount = false
        var value: String
        /// The row's own change over the chart range, as a fraction.
        var change: Decimal? = nil
        var image: Data? = nil
        var symbol: String
        var tint: Color
        var selected = false
        var trailing = Trailing.chevron
        var action: () -> Void
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
                        if let change = row.change, !session.privacyMode {
                            Text(UpOnlyFormat.percent(change)).font(UpOnlyType.caption.weight(.medium).monospacedDigit())
                                .foregroundStyle(UpOnlyTint.signed(change)).lineLimit(1)
                        }
                    }.layoutPriority(1)
                    if case .chevron = row.trailing {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                    }
                }.padding(.vertical, 8).contentShape(Rectangle())
            }.buttonStyle(UpOnlyRowButtonStyle(selected: row.selected))
                .accessibilityLabel(row.name).accessibilityValue(spokenValue(row))
                .accessibilityAddTraits(row.selected ? .isSelected : [])
            switch row.trailing {
            case .chevron: EmptyView()
            case .space: Color.clear.frame(width: 24, height: 24)
            case .button(let symbol, let label, let action):
                Button(action: action) {
                    Image(systemName: symbol).font(.system(size: 11, weight: .medium)).frame(width: 24, height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(.secondary).help(label).accessibilityLabel(label)
            }
        }
    }
    /// "<value>, <detail>, +18.0% over the past year": the name is the label, so VoiceOver reads "<name>, <value>".
    func spokenValue(_ row: AssetRow) -> String {
        if session.privacyMode { return "Hidden value" }
        var parts = [row.value]
        if let detail = row.detail { parts.append(detail) }
        if let change = row.change { parts.append(UpOnlyFormat.percent(change) + " over the " + worthRange.phrase) }
        return parts.joined(separator: ", ")
    }
}
