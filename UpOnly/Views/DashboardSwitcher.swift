import SwiftUI

/// The switcher behind the title: everything, each bank group, portfolio and company, and income & spending, each
/// with its value, its change over the chart's range and its share of the whole. Picking one shows it; the title box
/// closes it.
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
        // Each group is a card of rows, as on the pages themselves; empty groups aren't shown.
        let sections = ["Accounts", "Crypto", "Gold & silver", "Companies"].map { title in (title: title, rows: rows.filter { $0.section == title }) }.filter { !$0.rows.isEmpty }
        return VStack(alignment: .leading, spacing: 14) {
            if showsNetWorth { switcherCard([all]) }
            ForEach(sections, id: \.title) { section in
                VStack(alignment: .leading, spacing: 6) {
                    Text(section.title).font(UpOnlyType.section)
                    switcherCard(section.rows)
                }
            }
            if shows(.cashFlow) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Cash flow").font(UpOnlyType.section)
                    switcherCard([cashFlow])
                }
            }
            // Adding and managing read as rows too, rather than a pair of big buttons.
            VStack(spacing: 0) {
                switcherAction("plus", "Add an account, coin or metal") { showingSwitcher = false; session.addingInMenu = true }
                Divider().opacity(0.5)
                switcherAction("slider.horizontal.3", "Manage accounts & portfolios") { showingSwitcher = false; manage("Manage") }
            }.padding(.horizontal, UpOnlyLayout.cardInset).padding(.vertical, 2).modifier(UpOnlyContentSurface())
        }
    }
    /// Rows in one card, divided as the home list is. The chosen row's own highlight replaces the lines beside it.
    func switcherCard(_ rows: [SelectionRow]) -> some View {
        let current = session.dashboardSelection
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider().opacity(row.selection == current || rows[index - 1].selection == current ? 0 : 0.5) }
                switcherRow(row)
            }
        }.padding(.horizontal, UpOnlyLayout.cardInset).padding(.vertical, 2).modifier(UpOnlyContentSurface())
    }
    func switcherAction(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                UpOnlySymbolBadge(symbol: symbol, tint: .accentColor, size: 28)
                Text(title).font(UpOnlyType.row.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            }.padding(.vertical, 9).contentShape(Rectangle())
        }.buttonStyle(UpOnlyRowButtonStyle())
    }
    /// Icon, name and share of the whole on the left; value over its change on the right.
    /// The All row gives the change in dollars too; the narrower rows below give the percentage, as on the home rows.
    func switcherRow(_ row: SelectionRow) -> some View {
        let chosen = row.selection == session.dashboardSelection
        let move = row.change.map { change -> String in
            if row.selection != .all, let fraction = change.fraction { return UpOnlyFormat.arrowPercent(fraction) }
            return session.privacyMode ? UpOnlyFormat.hiddenMovement(change.amount, fraction: change.fraction) : UpOnlyFormat.movement(change.amount, fraction: change.fraction, cents: true)
        }
        let spokenMove = row.change.map { change in
            [row.selection == .all && !session.privacyMode ? UpOnlyFormat.movement(change.amount, fraction: nil, cents: true) : nil,
             change.fraction.map(UpOnlyFormat.percent)].compactMap { $0 }.joined(separator: ", ") + (worthRange == .all ? " since the first saved value" : " over the " + worthRange.phrase)
        }
        return Button { select(row.selection) } label: {
            HStack(spacing: 10) {
                if let image = row.image { UpOnlyProfileImage(data: image, name: row.name, size: 28) }
                else { UpOnlySymbolBadge(symbol: row.symbol, tint: row.tint, size: 28) }
                // The name, with its share of your total underneath; it gives way before the figures do.
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name).font(UpOnlyType.row.weight(chosen ? .semibold : .medium)).lineLimit(1).truncationMode(.middle)
                    if let share = row.share, !session.privacyMode {
                        Text(share == 0 ? "<1% of total" : "\(share)% of total").font(UpOnlyType.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                    }
                }.frame(minWidth: 90, alignment: .leading)  // a huge amount shrinks before the name disappears
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    UpOnlyPrivateText(row.valueText).font(UpOnlyType.row.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
                    if let move, let change = row.change {
                        Text(move).font(UpOnlyType.caption.weight(.medium).monospacedDigit()).foregroundStyle(UpOnlyTint.signed(change.amount)).lineLimit(1).minimumScaleFactor(0.8)
                    } else if let detail = row.detail { Text(detail).font(UpOnlyType.caption).foregroundStyle(.secondary) }
                }.layoutPriority(1)
                Image(systemName: "checkmark.circle.fill").font(.system(size: 15)).symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor).opacity(chosen ? 1 : 0).frame(width: 16)
            }.padding(.vertical, 9).contentShape(Rectangle())
                // The chosen row: a soft accent panel inside the card, its name in semibold and a filled check.
                .background {
                    if chosen {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.1))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 1))
                            .padding(.horizontal, -8).padding(.vertical, 2)
                    }
                }
        }.buttonStyle(UpOnlyRowButtonStyle())
            .accessibilityLabel(row.name).accessibilityAddTraits(chosen ? .isSelected : [])
            .accessibilityValue([session.privacyMode ? "Hidden value" : row.valueText, spokenMove, row.detail,
                                 session.privacyMode ? nil : row.share.map { "\($0)% of your total" }].compactMap { $0 }.joined(separator: ", "))
    }
}
