import SwiftUI

/// The switcher behind the title: everything, each bank group, portfolio and company, and income & spending, each
/// with its value, its 24-hour move and its share of the whole. Picking one shows it; the title box closes it.
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
        var day: (amount: Decimal, fraction: Decimal?)? = nil
        var share: Int? = nil
        /// A second line when there's no 24-hour move to show ("this month").
        var detail: String? = nil
    }
    /// Bank groups, portfolios and companies, valued now and 24 hours ago. A company's portfolios count in its row,
    /// unless it has no bank account to show them under; then they're listed on their own with the company's name.
    func selectionRows(current: ValuationResult, earlier: ValuationResult?, at date: Date) -> [SelectionRow] {
        guard let document = session.document else { return [] }
        let before = earlier?.components ?? []
        func day(_ parts: [ValuationComponent]) -> (amount: Decimal, fraction: Decimal?)? {
            earlier == nil ? nil : DayChange.parts(parts, earlier: before, now: date)
        }
        let groups = BankBalanceGroup.groups(current.components, document: document)
        var rows = groups.map { group -> SelectionRow in
            let parts = group.components + (group.businessID.map { companyHoldings(current.components, companyID: $0) } ?? [])
            let total = AssetOwnership.sum(parts)
            let name = group.businessID.flatMap { id in model.books.first { $0.id == id }?.name } ?? group.name
            return SelectionRow(id: group.id, selection: .bankGroup(group.id), section: group.businessID == nil ? "Accounts" : "Companies", name: name,
                                image: group.image, symbol: group.businessID == nil ? "building.columns.fill" : "building.2.fill", tint: UpOnlyTint.netWorth,
                                value: total, valueText: total.map(UpOnlyFormat.exactMoney) ?? "Needs update", day: day(parts))
        }
        let companies = Set(groups.compactMap(\.businessID))
        let portfolioOf = Dictionary(document.holdings.map { ($0.id, $0.portfolioID) }, uniquingKeysWith: { first, _ in first })
        for portfolio in document.portfolios where portfolio.isActive(at: date) {
            let owner = portfolio.ownerBusinessID.flatMap { $0.isEmpty ? nil : $0 }
            if let owner, companies.contains(owner) { continue }
            let parts = current.components.filter { $0.kind == .holding && portfolioOf[$0.id] == portfolio.id }
            let total = parts.isEmpty ? nil : AssetOwnership.sum(parts)
            let company = owner.flatMap { id in model.books.first { $0.id == id }?.name }
            rows.append(SelectionRow(id: portfolio.id.uuidString, selection: .portfolio(portfolio.id), section: portfolio.kind == .metals ? "Gold & silver" : "Crypto",
                                     name: portfolio.name + (company.map { " · " + $0 } ?? ""),
                                     symbol: portfolio.kind == .metals ? TrackedKind.metals.symbol : TrackedKind.crypto.symbol,
                                     tint: portfolio.kind == .metals ? UpOnlyTint.metals : UpOnlyTint.crypto,
                                     value: total, valueText: parts.isEmpty ? "No holdings" : total.map(UpOnlyFormat.exactMoney) ?? "Price needed", day: parts.isEmpty ? nil : day(parts)))
        }
        // Shares of what's listed, once there's more than one row to share it.
        if rows.count > 1 {
            let shares = DashboardChart.percentages(rows.map { $0.value ?? 0 })
            for index in rows.indices where (rows[index].value ?? 0) > 0 { rows[index].share = shares[index] }
        }
        return rows
    }
    var switcherPage: some View {
        let now = Date(), then = now.addingTimeInterval(-DayChange.window)
        let document = session.document
        let current = document.map { NetWorthCalculator.value(at: now, scope: .allTracked, document: $0) }
        let earlier = document.map { NetWorthCalculator.value(at: then, scope: .allTracked, document: $0, now: then) }
        let rows = current.map { selectionRows(current: $0, earlier: earlier, at: now) } ?? []
        // The All row is your share of everything, the same figure as the All assets page.
        let personal = document.map { AssetOwnership.personalValue(at: now, scope: .allTracked, document: $0) }
        let personalEarlier = document.map { AssetOwnership.personalValue(at: then, scope: .allTracked, document: $0, now: then) }
        let allDay = personal.flatMap { value in personalEarlier.flatMap { DayChange.total(now: value, then: $0) } }
        let month = document.flatMap { MonthlyLedger.personal(.current(), document: $0).totals?.net }
        return VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 0) {
                if showsNetWorth {
                    switcherRow(SelectionRow(id: "all", selection: .all, section: "", name: "All assets", symbol: "square.grid.2x2.fill", tint: UpOnlyTint.netWorth,
                                             value: personal?.total, valueText: personal?.total.map(UpOnlyFormat.exactMoney) ?? "—", day: allDay))
                }
                ForEach(["Accounts", "Crypto", "Gold & silver", "Companies"], id: \.self) { section in
                    let members = rows.filter { $0.section == section }
                    if !members.isEmpty {
                        Text(section.uppercased()).font(UpOnlyType.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12).padding(.bottom, 2)
                        ForEach(members) { switcherRow($0) }
                    }
                }
                if shows(.cashFlow) {
                    Text("CASH FLOW").font(UpOnlyType.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12).padding(.bottom, 2)
                    switcherRow(SelectionRow(id: "cashflow", selection: .cashFlow, section: "Cash flow", name: "Income & spending", symbol: "arrow.up.arrow.down",
                                             tint: UpOnlyTint.cashFlow, value: month,
                                             valueText: month.map { ($0 > 0 ? "+" : "") + UpOnlyFormat.money($0) } ?? "—", detail: "this month"))
                }
            }
            HStack(spacing: 10) {
                Button { showingSwitcher = false; manage("Manage") } label: { Label("Manage", systemImage: "pencil").frame(maxWidth: .infinity) }
                Button { showingSwitcher = false; session.addingInMenu = true } label: { Label("New", systemImage: "plus").frame(maxWidth: .infinity) }
            }.controlSize(.large).padding(.top, 16)
        }
    }
    /// Icon and name on the left; value over its 24-hour move on the right, and the share of the whole beside it.
    /// The All row gives the move in dollars too; the narrower rows below give the percentage, as on the home rows.
    func switcherRow(_ row: SelectionRow) -> some View {
        let chosen = row.selection == session.dashboardSelection
        let move = row.day.map { day -> String in
            if row.selection != .all, let fraction = day.fraction { return UpOnlyFormat.arrowPercent(fraction) }
            return session.privacyMode ? UpOnlyFormat.hiddenMovement(day.amount, fraction: day.fraction) : UpOnlyFormat.movement(day.amount, fraction: day.fraction, cents: true)
        }
        return Button { select(row.selection) } label: {
            HStack(spacing: 10) {
                if let image = row.image { UpOnlyProfileImage(data: image, name: row.name, size: 28) }
                else { UpOnlySymbolBadge(symbol: row.symbol, tint: row.tint, size: 28) }
                Text(row.name).font(UpOnlyType.row.weight(chosen ? .semibold : .medium)).lineLimit(1).truncationMode(.middle).layoutPriority(1)
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    UpOnlyPrivateText(row.valueText).font(UpOnlyType.row.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
                    if let move, let day = row.day {
                        Text(move).font(UpOnlyType.caption.weight(.medium).monospacedDigit()).foregroundStyle(UpOnlyTint.signed(day.amount)).lineLimit(1).minimumScaleFactor(0.8)
                    } else if let detail = row.detail { Text(detail).font(UpOnlyType.caption).foregroundStyle(.secondary) }
                }
                if let share = row.share, !session.privacyMode {
                    Text(share == 0 ? "<1%" : "\(share)%").font(UpOnlyType.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 30, alignment: .trailing)
                }
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.tint).opacity(chosen ? 1 : 0).frame(width: 12)
            }.padding(.vertical, 7).contentShape(Rectangle())
        }.buttonStyle(UpOnlyRowButtonStyle(selected: chosen))
            .accessibilityLabel(row.name).accessibilityAddTraits(chosen ? .isSelected : [])
            .accessibilityValue([session.privacyMode ? "Hidden value" : row.valueText, row.day?.fraction.map { UpOnlyFormat.percent($0) + " in 24 hours" }, session.privacyMode ? nil : row.share.map { "\($0)% of the total" }]
                .compactMap { $0 }.joined(separator: ", "))
    }
}
