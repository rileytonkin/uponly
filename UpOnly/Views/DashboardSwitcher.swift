import SwiftUI

/// The switcher behind the title: everything, each bank group, portfolio and company, and income & spending, each
/// with its value, its change over the chart's range and its share of the whole. Picking one shows it; the title box
/// closes it. Adding and managing are the + and … beside the title, as on every page.
extension UpOnlyUnlockedPanel {
    struct SelectionRow: Identifiable {
        var id: String
        var selection: UpOnlySession.DashboardSelection
        var section: String
        var name: String
        var image: Data? = nil
        /// A portfolio's largest holding, whose logo stands for it.
        var logo: String? = nil
        var symbol: String
        var tint: Color
        var value: Decimal?
        var valueText: String
        var change: PeriodChange? = nil
        /// Your part of the value: a company's at your ownership share. The breakdown is worked out from it.
        var personal: Decimal? = nil
        /// A second line: a part-owned company's share ("You own 50%"), or income & spending's "This month".
        var detail: String? = nil
    }
    /// What a group without a total is waiting for: a rate, a balance or a price.
    static func needed(_ parts: [ValuationComponent]) -> String {
        let missing = Set(parts.compactMap(\.missing))
        return missing.contains("balance") ? "Balance needed" : missing.contains("fx") ? "Rate needed" : missing.contains("quote") ? "Price needed" : "Needs update"
    }
    /// Bank groups, portfolios and companies, valued now and where the range starts. A company's portfolios count in
    /// its row, unless it has no bank account to show them under; then they're listed on their own with its name.
    func selectionRows(current: [ValuationComponent], start: (day: Date, components: [ValuationComponent])?, at date: Date) -> [SelectionRow] {
        guard let document = session.document else { return [] }
        let before = start?.components ?? []
        let groups = BankBalanceGroup.groups(current, document: document)
        let groupsBefore = Dictionary(BankBalanceGroup.groups(before, document: document).map { ($0.id, $0.components) }, uniquingKeysWith: { first, _ in first })
        var rows = groups.map { group -> SelectionRow in
            let parts = group.components + (group.businessID.map { companyHoldings(current, companyID: $0) } ?? [])
            let then = (groupsBefore[group.id] ?? []) + (group.businessID.map { companyHoldings(before, companyID: $0) } ?? [])
            let total = AssetOwnership.sum(parts)
            let name = group.businessID.map(companyName) ?? group.name
            // A company's row shows the whole company; say when only part of it is yours, as All assets counts.
            let owned = group.businessID.flatMap { id in document.businessAccounting?.first { $0.id == id }?.ownership(at: AssetOwnership.month(at: date).description) }
                .flatMap { $0.numerator < $0.denominator ? "You own " + $0.label : nil }
            return SelectionRow(id: group.id, selection: .bankGroup(group.id), section: group.businessID == nil ? "Accounts" : "Companies", name: name,
                                image: group.businessID == nil ? session.personalImage : group.image, symbol: group.businessID == nil ? "building.columns.fill" : "building.2.fill", tint: group.businessID == nil ? UpOnlyTint.netWorth : UpOnlyTint.company,
                                value: total, valueText: total.map(UpOnlyFormat.exactMoney) ?? Self.needed(parts), change: PeriodChange(parts: parts, then: then),
                                personal: AssetOwnership.personalTotal(parts, at: date, document: document), detail: owned)
        }
        let companies = Set(groups.compactMap(\.businessID))
        let portfolioOf = Dictionary(document.holdings.map { ($0.id, $0.portfolioID) }, uniquingKeysWith: { first, _ in first })
        for portfolio in document.portfolios where portfolio.isActive(at: date) {
            let owner = portfolio.ownerBusinessID.flatMap { $0.isEmpty ? nil : $0 }
            if let owner, companies.contains(owner) { continue }
            let parts = current.filter { $0.kind == .holding && portfolioOf[$0.id] == portfolio.id }
            let then = before.filter { $0.kind == .holding && portfolioOf[$0.id] == portfolio.id }
            let total = parts.isEmpty ? nil : AssetOwnership.sum(parts)
            let company = owner.flatMap { id in model.books.first { $0.id == id }?.name }
            let largest = parts.max { ($0.usdValue?.value ?? 0) < ($1.usdValue?.value ?? 0) }.flatMap { part in document.holdings.first { $0.id == part.id }?.assetID.rawValue }
            rows.append(SelectionRow(id: portfolio.id.uuidString, selection: .portfolio(portfolio.id), section: portfolio.kind == .metals ? "Metals" : "Crypto",
                                     name: portfolio.name + (company.map { " · " + $0 } ?? ""), logo: largest,
                                     symbol: portfolio.kind == .metals ? TrackedKind.metals.symbol : TrackedKind.crypto.symbol,
                                     tint: portfolio.kind == .metals ? UpOnlyTint.metals : UpOnlyTint.crypto,
                                     value: total, valueText: parts.isEmpty ? "No holdings" : total.map(UpOnlyFormat.exactMoney) ?? "Price needed",
                                     change: PeriodChange(parts: parts, then: then), personal: parts.isEmpty ? nil : AssetOwnership.personalTotal(parts, at: date, document: document)))
        }
        return rows
    }
    var switcherPage: some View {
        let interval = worthInterval(.allTracked)
        let document = session.document
        // Your share of everything, the same figure as the All assets page; its components value every row.
        let personal = document.map { AssetOwnership.personalValue(at: interval.end, scope: .allTracked, document: $0) }
        let estimates = document.map(ChartEstimates.init)
        let start = document.flatMap { doc in estimates.flatMap { rangeStart(scope: .allTracked, interval: interval, document: doc, estimates: $0) } }
        let rows = personal.map { selectionRows(current: $0.components, start: start, at: interval.end) } ?? []
        let then = start.flatMap { start in estimates?.personalTotal(start.components, day: start.day)?.total }
        let allChange = personal?.total.flatMap { now in then.map { PeriodChange(from: $0, to: now) } }
        // The same figure as the page it opens, which starts on all accounts.
        let month = document.flatMap { MonthlyLedger.evaluate(.current(), document: $0).totals?.net }
        let all = SelectionRow(id: "all", selection: .all, section: "", name: "All assets", symbol: "square.grid.2x2.fill", tint: UpOnlyTint.netWorth,
                               value: personal?.total, valueText: personal?.total.map(UpOnlyFormat.exactMoney) ?? "—", change: allChange)
        let cashFlow = SelectionRow(id: "cashflow", selection: .cashFlow, section: "Cash flow", name: "Income & spending", symbol: "arrow.up.arrow.down",
                                    tint: UpOnlyTint.cashFlow, value: month, valueText: month.map { ($0 > 0 ? "+" : "") + UpOnlyFormat.money($0) } ?? "Nothing yet", detail: "This month")
        // One card of rows, the same rows as the home list: everything, then each group, then income & spending.
        // The chosen one has a check; adding and managing stay with the + and … by the title.
        let list = (showsNetWorth ? [all] : []) + ["Accounts", "Crypto", "Metals", "Companies"].flatMap { section in rows.filter { $0.section == section } }
            + (shows(.cashFlow) ? [cashFlow] : [])
        let slices = allocation(rows)
        // The switcher opens at the home page's height; the breakdown takes whatever the list leaves, so there's no
        // empty space under the list (and with a long list it stays at its smallest and the page scrolls).
        let room = (session.dashboardHeight ?? 0) - headerHeight - 16 - switcherListHeight - 10
        return VStack(spacing: 10) {
            // What your total is made of, first. Its shares are the legend's, so the rows don't repeat them.
            if slices.count > 1, !session.privacyMode || session.standInFactor != nil {
                UpOnlyBreakdown(slices: slices, diameter: min(112, max(78, room - 32)), height: room > 110 ? min(room, 180) : nil)
            }
            assetList(list.map(switcherRow))
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { switcherListHeight = $0 }
        }
    }
    /// One slice of the breakdown: a kind of asset and your part of it.
    struct Slice: Identifiable { var id: String; var name: String; var value: Decimal; var tint: Color }
    /// Your total by kind: bank balances, crypto, metals and companies (at your share).
    func allocation(_ rows: [SelectionRow]) -> [Slice] {
        [("Accounts", "Bank balances", UpOnlyTint.netWorth), ("Crypto", "Crypto", UpOnlyTint.crypto),
         ("Metals", "Metals", UpOnlyTint.metals), ("Companies", "Companies", UpOnlyTint.company)].compactMap { section, name, tint in
            let value = rows.filter { $0.section == section }.compactMap(\.personal).reduce(Decimal(0), +)
            return value > 0 ? Slice(id: section, name: name, value: value, tint: tint) : nil
        }
    }
    /// A switcher row is a home row: icon, name (with a part-owned company's share, or "This month"), and value over
    /// its change over the range. The page showing is the highlighted row.
    func switcherRow(_ row: SelectionRow) -> AssetRow {
        let chosen = row.selection == session.dashboardSelection
        return AssetRow(id: row.id, name: row.name, detail: row.detail, value: row.valueText, change: row.change?.fraction,
                        image: row.image, logo: row.logo, symbol: row.symbol, tint: row.tint, selected: chosen, trailing: .none) { select(row.selection) }
    }
}

/// The breakdown at the top of the switcher: a donut that sweeps in, the largest share at its centre, and a legend
/// with each kind's share beside it, in one card like the list below.
struct UpOnlyBreakdown: View {
    let slices: [UpOnlyUnlockedPanel.Slice]
    /// The donut's size, and the card's height when it fills the room the list leaves.
    var diameter: CGFloat = 78
    var height: CGFloat? = nil
    @State private var shown = false
    var body: some View {
        let percents = DashboardChart.percentages(slices.map(\.value))
        let values = slices.map { NSDecimalNumber(decimal: $0.value).doubleValue }
        let total = max(values.reduce(0, +), 1)
        let ends = values.indices.map { values[...$0].reduce(0, +) / total }
        let largest = percents.indices.max { percents[$0] < percents[$1] } ?? 0
        // Square-ended segments with a hairline gap: round ends would reach past their own slice into the next.
        let gap = slices.count > 1 ? 0.012 : 0
        let line = diameter > 90 ? 12.0 : 10.0
        return HStack(spacing: 20) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.06), lineWidth: line)
                ForEach(slices.indices, id: \.self) { index in
                    let start = (index == 0 ? 0 : ends[index - 1]) + gap / 2, end = max(start, ends[index] - gap / 2)
                    Circle().trim(from: start, to: shown ? end : start)
                        .stroke(LinearGradient(colors: [slices[index].tint, slices[index].tint.opacity(0.78)], startPoint: .top, endPoint: .bottom),
                                style: StrokeStyle(lineWidth: line, lineCap: .butt))
                }
                VStack(spacing: 0) {
                    Text(percents[largest] == 0 ? "<1%" : "\(percents[largest])%").font(.system(size: diameter > 90 ? 19 : 15, weight: .semibold).monospacedDigit())
                    Text(slices[largest].name).font(.system(size: diameter > 90 ? 10 : 9, weight: .medium)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                }.frame(width: diameter - 2 * line - 6).rotationEffect(.degrees(90))
            }.rotationEffect(.degrees(-90)).frame(width: diameter, height: diameter).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: diameter > 90 ? 10 : 7) {
                ForEach(slices.indices, id: \.self) { index in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2.5).fill(slices[index].tint).frame(width: 10, height: 10)
                        Text(slices[index].name).font(UpOnlyType.body).foregroundStyle(.primary.opacity(0.85)).lineLimit(1).minimumScaleFactor(0.85)
                        Spacer(minLength: 8)
                        Text(percents[index] == 0 ? "<1%" : "\(percents[index])%").font(UpOnlyType.body.weight(.semibold).monospacedDigit())
                    }.accessibilityElement(children: .ignore).accessibilityLabel(slices[index].name)
                        .accessibilityValue(percents[index] == 0 ? "less than 1% of your total" : "\(percents[index])% of your total")
                }
            }
        }.padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: height, alignment: .leading).modifier(UpOnlyContentSurface())
            .accessibilityElement(children: .contain).accessibilityLabel("Breakdown")
            .onAppear { withAnimation(.spring(response: 0.7, dampingFraction: 0.9)) { shown = true } }
    }
}
