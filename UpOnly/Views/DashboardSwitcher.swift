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
        var symbol: String
        var tint: Color
        var value: Decimal?
        var valueText: String
        var change: PeriodChange? = nil
        /// Your part of the value: a company's at your ownership share. Shares of the whole are worked out from it.
        var personal: Decimal? = nil
        var share: Int? = nil
        /// A second line when there's no change to show ("this month").
        var detail: String? = nil
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
            return SelectionRow(id: group.id, selection: .bankGroup(group.id), section: group.businessID == nil ? "Accounts" : "Companies", name: name,
                                image: group.image, symbol: group.businessID == nil ? "building.columns.fill" : "building.2.fill", tint: UpOnlyTint.netWorth,
                                value: total, valueText: total.map(UpOnlyFormat.exactMoney) ?? "Needs update", change: PeriodChange(parts: parts, then: then),
                                personal: AssetOwnership.personalTotal(parts, at: date, document: document))
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
            rows.append(SelectionRow(id: portfolio.id.uuidString, selection: .portfolio(portfolio.id), section: portfolio.kind == .metals ? "Gold & silver" : "Crypto",
                                     name: portfolio.name + (company.map { " · " + $0 } ?? ""),
                                     symbol: portfolio.kind == .metals ? TrackedKind.metals.symbol : TrackedKind.crypto.symbol,
                                     tint: portfolio.kind == .metals ? UpOnlyTint.metals : UpOnlyTint.crypto,
                                     value: total, valueText: parts.isEmpty ? "No holdings" : total.map(UpOnlyFormat.exactMoney) ?? "Price needed",
                                     change: PeriodChange(parts: parts, then: then), personal: parts.isEmpty ? nil : AssetOwnership.personalTotal(parts, at: date, document: document)))
        }
        // Shares of your total, once there's more than one row to share it: a half-owned company counts at half.
        if rows.count > 1 {
            let shares = DashboardChart.percentages(rows.map { $0.personal ?? 0 })
            for index in rows.indices where (rows[index].personal ?? 0) > 0 { rows[index].share = shares[index] }
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
                                    tint: UpOnlyTint.cashFlow, value: month, valueText: month.map { ($0 > 0 ? "+" : "") + UpOnlyFormat.money($0) } ?? "—", detail: "this month")
        // One card of rows, the same rows as the home list: everything, then each group, then income & spending.
        // The chosen one has a check; adding and managing stay with the + and … by the title.
        let list = (showsNetWorth ? [all] : []) + ["Accounts", "Crypto", "Gold & silver", "Companies"].flatMap { section in rows.filter { $0.section == section } }
            + (shows(.cashFlow) ? [cashFlow] : [])
        return assetList(list.map(switcherRow))
    }
    /// A switcher row is a home row: icon, name with its share of your total (or "this month") underneath, and value
    /// over its change over the range. The chosen one has a check where the home rows have a chevron.
    func switcherRow(_ row: SelectionRow) -> AssetRow {
        let chosen = row.selection == session.dashboardSelection
        let share = session.privacyMode ? nil : row.share.map { $0 == 0 ? "<1% of total" : "\($0)% of total" }
        return AssetRow(id: row.id, name: row.name, detail: share ?? row.detail, value: row.valueText, change: row.change?.fraction,
                        image: row.image, symbol: row.symbol, tint: row.tint, trailing: .check(chosen)) { select(row.selection) }
    }
}
