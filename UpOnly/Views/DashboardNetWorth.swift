import SwiftUI

/// Net worth: today's value, what moved in 24 hours and against what was paid, the chart and the rows below it.
extension UpOnlyUnlockedPanel {
    /// Everything the net worth page shows, worked out once per render.
    struct WorthSnapshot {
        var interval: DateInterval
        var valuation: ValuationResult? = nil
        var points: [UpOnlyChartPoint] = []
        /// The same scope valued as of 24 hours ago, for the 24h line and each row's move.
        var earlier: ValuationResult? = nil
        /// Any saved history for this scope, even outside the range, so the range can still be changed.
        var hasHistory = false
        /// Today's total against 24 hours ago, like for like and on fresh prices; nil when that can't be known.
        var day: (amount: Decimal, fraction: Decimal?)? = nil
        /// Profit against what was paid, over the holdings with recorded purchases.
        var allTime: (gain: Decimal, cost: Decimal, covered: Int, total: Int)? = nil
    }
    func worthSnapshot() -> WorthSnapshot {
        let interval = selectedInterval
        guard let document = session.document else { return WorthSnapshot(interval: interval) }
        let samples = DashboardPeriod.samples(in: interval, scope: scope, document: document)
        let valuation = AssetOwnership.personalValue(at: interval.end, scope: scope, document: document)
        let points = dailySeries(samples, interval: interval) { sample in
            if sample.isComplete {
                return AssetOwnership.personalTotal(sample.components, at: sample.utcDay, document: document).map { ($0, nil) }
            }
            // A day with an unpriced holding still shows what could be valued, marked as an estimate.
            let valued = sample.components.filter { $0.usdValue != nil && $0.missing == nil }
            let unpriced = sample.components.filter { $0.usdValue == nil || $0.missing != nil }.map(\.label)
            guard !valued.isEmpty, !unpriced.isEmpty, let total = AssetOwnership.personalTotal(valued, at: sample.utcDay, document: document) else { return nil }
            return (total, "Excludes " + unpriced.joined(separator: ", ") + " (no price that day)")
        }
        // The value as the app would have shown it 24 hours ago: the latest prices, rates and balances at that moment.
        let then = interval.end.addingTimeInterval(-DayChange.window)
        let earlier = AssetOwnership.personalValue(at: then, scope: scope, document: document, now: then)
        // A company's holdings count at your share in the total, so profit on cost is only summed for personal portfolios.
        let personal = Set(document.portfolios.filter { ($0.ownerBusinessID ?? "").isEmpty }.map(\.id))
        let portfolioOf = Dictionary(document.holdings.map { ($0.id, $0.portfolioID) }, uniquingKeysWith: { first, _ in first })
        let owned = valuation.components.filter { $0.kind == .holding && portfolioOf[$0.id].map(personal.contains) == true }
        return WorthSnapshot(interval: interval, valuation: valuation, points: points, earlier: earlier,
                             hasHistory: !samples.isEmpty || document.dailyValuations.contains { $0.scope == scope },
                             day: DayChange.total(now: valuation, then: earlier),
                             allTime: HoldingPerformance.scope(owned, document: document, at: interval.end))
    }
    var worthContent: some View {
        let snapshot = worthSnapshot()
        let valuation = snapshot.valuation
        let available = valuation.map { !$0.isUnavailable } ?? false
        let portfolio = selectedPortfolio
        // The title already names the page, so only a company's share is worth saying above the figure.
        let ownerShare = portfolio.flatMap { ownerShareTitle($0, at: snapshot.interval.end) }
        return VStack(alignment: .leading, spacing: 0) {
            if let ownerShare { eyebrow(ownerShare).frame(minHeight: 26, alignment: .leading) }
            if let valuation, available, let value = valuation.total ?? valuation.lastComplete?.value {
                // The eye sits by the number it hides.
                HStack(alignment: .center, spacing: 4) {
                    UpOnlyAmount(value: value, cents: true)
                    UpOnlyPrivacyButton()
                    Spacer(minLength: 0)
                }.padding(.top, ownerShare != nil ? 10 : 0)
            }
            if let valuation, available {
                VStack(alignment: .leading, spacing: 3) {
                    if valuation.total == nil, let last = valuation.lastComplete {
                        Text("Last complete value · " + UpOnlyFormat.utcDate(last.at)).font(UpOnlyType.body).foregroundStyle(.secondary)
                    } else {
                        // Two fixed answers: what moved today, and how the holdings stand against what was paid.
                        // Neither changes with the chart range.
                        if let day = snapshot.day { metricLine("24h", amount: day.amount, fraction: day.fraction, cents: true) }
                        if let allTime = snapshot.allTime {
                            let covered = allTime.covered < allTime.total ? " · \(allTime.covered) of \(allTime.total) holdings" : ""
                            metricLine("All-time", amount: allTime.gain, fraction: allTime.cost > 0 ? allTime.gain / allTime.cost : nil, cents: false,
                                       note: "on " + UpOnlyFormat.money(allTime.cost) + " paid" + covered)
                        }
                    }
                    if let stale = staleNote(valuation) {
                        Text(stale.text).font(UpOnlyType.caption).foregroundStyle(.secondary).lineLimit(2).help(stale.detail)
                    }
                }.fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            }
            if let valuation, valuation.missing.contains(where: { $0.reason == "ownership" }) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(ownershipMessage(valuation, at: snapshot.interval.end)).font(UpOnlyType.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Open Accounts") { manage("Accounts") }.buttonStyle(.bordered).controlSize(.small)
                }.padding(.top, 12)
            }
            if let valuation, valuation.missing.contains(where: { $0.reason == "fx" }) {
                exchangeRateAction(Set(valuation.components.filter { $0.missing == "fx" }.map(\.currency)).sorted(), month: AssetOwnership.month(at: snapshot.interval.end))
                    .padding(.top, 16)
            }
            if let valuation, available, valuation.total == nil {
                VStack(alignment: .leading, spacing: 10) {
                    let unpriced = valuation.components.filter { $0.missing == "quote" }
                    if !unpriced.isEmpty {
                        Text("Prices needed").font(UpOnlyType.section)
                        Text("No price yet for " + unpriced.map(\.label).joined(separator: ", ") + ". Crypto prices need a free CoinGecko key.").font(UpOnlyType.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Set up prices") { manage("Sources") }
                            .buttonStyle(.glassProminent).buttonBorderShape(.capsule).controlSize(.regular)
                    }
                    ForEach(valuation.components.filter { $0.missing != nil && $0.missing != "fx" && $0.missing != "quote" }, id: \.id) { component in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(component.label).font(UpOnlyType.section).fixedSize(horizontal: false, vertical: true)
                            Text(component.missing == "balance" ? "Add this account’s balance to calculate your net worth." : "This amount needs correcting.")
                                .font(UpOnlyType.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Button(component.missing == "balance" ? "Add balance" : "Review amount") {
                                if component.missing == "balance" { showImport(session.startImport(.bankBalances, prefill: true, accountID: component.id)) }
                                else { manage("Accounts") }
                            }.buttonStyle(.glassProminent).buttonBorderShape(.capsule).controlSize(.small)
                        }
                    }
                }.padding(.top, 16)
            }
            if snapshot.hasHistory {
                VStack(alignment: .leading, spacing: 10) {
                    rangeControl
                    if snapshot.points.contains(where: { $0.value != nil }) {
                        UpOnlyChart(points: snapshot.points, tint: trendTint(snapshot.points), spansRange: true)
                    } else {
                        Text("No saved values" + worthRange.within + ".").font(UpOnlyType.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(.top, 18)
            }
            if let portfolio {
                if let valuation, available { holdingsCard(portfolio, valuation: valuation, at: snapshot.interval.end).padding(.top, 14) }
            } else {
                let rows = overviewRows(snapshot)
                if !rows.isEmpty { assetList(rows).padding(.top, 16) }
            }
            if !available {
                worthEmptyState.padding(.top, 14)
            }
        }
    }
    /// "24h  +$66.59  ▲ 1.3%": a label, then the signed figure in green or red. Privacy mode hides the amount but
    /// keeps the percentage ("−•••••  ▼ 3.9%"), which says how things moved without saying how much you hold.
    func metricLine(_ label: String, amount: Decimal, fraction: Decimal?, cents: Bool, note: String? = nil) -> some View {
        let text = session.privacyMode ? UpOnlyFormat.hiddenMovement(amount, fraction: fraction) : UpOnlyFormat.movement(amount, fraction: fraction, cents: cents)
        let percent = fraction.map { UpOnlyFormat.percent($0) }
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(UpOnlyType.body).foregroundStyle(.secondary).frame(width: 50, alignment: .leading)
            Text(text).font(UpOnlyType.body.weight(.medium).monospacedDigit()).foregroundStyle(UpOnlyTint.signed(amount)).lineLimit(1).minimumScaleFactor(0.8)
            if let note, !session.privacyMode { Text(note).font(UpOnlyType.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail) }
        }.accessibilityElement(children: .ignore).accessibilityLabel(label == "24h" ? "Change in 24 hours" : "All-time profit")
            .accessibilityValue(session.privacyMode ? (percent.map { "Amount hidden, " + $0 } ?? "Hidden value") : text + (note.map { ", " + $0 } ?? ""))
    }
    /// Green when the line ends at or above where it starts, red when below, the neutral tint with too little data.
    func trendTint(_ points: [UpOnlyChartPoint]) -> Color {
        DashboardChart.risesOrHolds(points.compactMap(\.value)).map { $0 ? UpOnlyTint.gain : UpOnlyTint.loss } ?? UpOnlyTint.netWorth
    }
    /// Prices and exchange rates that are out of date. A bank balance's age is normal and isn't mentioned.
    func staleNote(_ valuation: ValuationResult) -> (text: String, detail: String)? {
        let components = Dictionary(valuation.components.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var names: [String] = []
        for stale in valuation.stale {
            guard let component = components[stale.componentID] else { continue }
            let name = component.kind == .holding ? component.label + " price" : component.fxTime == stale.asOf ? component.currency + " rate" : nil
            if let name, !names.contains(name) { names.append(name) }
        }
        guard !names.isEmpty else { return nil }
        let detail = "May be out of date: " + names.joined(separator: ", ")
        return (names.count <= 2 ? detail : "\(names.count) prices and rates may be out of date", detail)
    }
    /// Names the companies whose ownership isn't known for the month, so the user knows what to fix.
    func ownershipMessage(_ valuation: ValuationResult, at date: Date) -> String {
        guard let document = session.document else { return "" }
        let month = AssetOwnership.month(at: date)
        let owners = Set(valuation.components.compactMap { AssetOwnership.businessID(for: $0, in: document) })
        let names = owners.filter { id in document.businessAccounting?.first { $0.id == id }?.ownership(at: month.description) == nil }
            .map { id in document.businessAccounting?.first { $0.id == id }?.name ?? "a company" }.sorted()
        let who = names.isEmpty ? "a company" : names.joined(separator: ", ")
        return "Your share of " + who + " for " + month.title + " isn’t known, so the total can’t include it. Check which accounts belong to it in Accounts."
    }
    func ownerShareTitle(_ portfolio: Portfolio, at date: Date) -> String? {
        guard let owner = portfolio.ownerBusinessID, !owner.isEmpty, let book = model.books.first(where: { $0.id == owner }) else { return nil }
        return "Your share of " + book.name + (book.ownership(at: AssetOwnership.month(at: date).description).map { " · " + $0.label } ?? "")
    }
    /// The All assets rows: the same list as the switcher, each opening its page.
    func overviewRows(_ snapshot: WorthSnapshot) -> [AssetRow] {
        guard let valuation = snapshot.valuation, !valuation.isUnavailable, scope == .allTracked else { return [] }
        return selectionRows(current: valuation, earlier: snapshot.earlier, at: snapshot.interval.end).filter { $0.selection != .cashFlow }.map { row in
            AssetRow(id: row.id, name: row.name, value: row.valueText, change: row.day?.fraction, image: row.image, symbol: row.symbol, tint: row.tint) { select(row.selection) }
        }
    }
    /// One holding in a portfolio's table: what it is, its market price and 24-hour move, and what you hold.
    struct HoldingLine: Identifiable {
        var id: UUID
        var assetID: String
        var ticker: String
        var name: String
        var price: String?
        var dayChange: Decimal?
        var value: Decimal?
        var valueText: String
        var quantity: String?
        var caption: String?
    }
    func holdingLines(_ portfolio: Portfolio, valuation: ValuationResult, at date: Date) -> [HoldingLine] {
        guard let document = session.document else { return [] }
        let metal = portfolio.kind == .metals
        let lines = valuation.components.compactMap { component -> HoldingLine? in
            guard let holding = document.holdings.first(where: { $0.id == component.id }) else { return nil }
            let id = holding.assetID.rawValue
            let metalKind = PreciousMetal.asset(holding.assetID)
            let symbol = metalKind?.rawValue ?? (session.catalog.first(where: { $0.id == id }) ?? ImportCoins.common.first(where: { $0.id == id }))?.symbol.uppercased() ?? ""
            let quantity = component.nativeAmount?.value
            let value = component.usdValue?.value
            return HoldingLine(
                id: component.id, assetID: id,
                // Metals read by name ("Gold", XAU underneath); coins by ticker ("BTC", Bitcoin underneath).
                ticker: metalKind?.name ?? (symbol.isEmpty ? holding.assetName : symbol), name: metalKind != nil ? symbol : holding.assetName,
                price: quantity.flatMap { q in value.flatMap { UpOnlyFormat.unitPrice(quantity: q, valueUSD: $0, metal: metal) } },
                dayChange: DayChange.price(assetID: holding.assetID, quotes: document.quotes, now: date),
                value: value,
                valueText: value.map(UpOnlyFormat.exactMoney) ?? (component.missing == "quote" ? "Price needed" : "Quantity needed"),
                quantity: quantity.map { UpOnlyFormat.quantityText($0, symbol: symbol.isEmpty ? holding.assetName : symbol, metal: metal) },
                caption: UpOnlyFormat.performance(HoldingPerformance.summary(holdingID: component.id, valueUSD: value, document: document, at: date), metal: metal))
        }
        switch holdingSort {
        case .value: return lines.sorted { ($0.value ?? -1) > ($1.value ?? -1) }
        case .change: return lines.sorted { ($0.dayChange ?? -.greatestFiniteMagnitude) > ($1.dayChange ?? -.greatestFiniteMagnitude) }
        case .name: return lines.sorted { $0.ticker.localizedStandardCompare($1.ticker) == .orderedAscending }
        }
    }
    func holdingsCard(_ portfolio: Portfolio, valuation: ValuationResult, at date: Date) -> some View {
        let lines = holdingLines(portfolio, valuation: valuation, at: date)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Holdings").font(UpOnlyType.section)
                Spacer()
                Button(portfolio.kind == .metals ? "Update weights" : "Update holdings") {
                    showImport(session.startImport(portfolio.kind == .metals ? .metals : .holdings, prefill: true, portfolioID: portfolio.id))
                }.buttonStyle(.bordered).controlSize(.small)
            }
            // Every holding at zero still leaves a way to update them.
            if lines.isEmpty { Text("Every holding is at zero.").font(UpOnlyType.caption).foregroundStyle(.secondary) }
            else {
                // Column heads; the value head chooses the order.
                HStack(spacing: 8) {
                    Text("Asset").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Price").frame(width: 92, alignment: .trailing)
                    Menu {
                        ForEach(HoldingSort.allCases, id: \.self) { sort in
                            Toggle(sort.title, isOn: Binding(get: { holdingSort == sort }, set: { _ in holdingSort = sort }))
                        }
                    } label: { Text(holdingSort == .value ? "Value ⌄" : holdingSort.title + " ⌄") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 96, alignment: .trailing)
                        .accessibilityLabel("Sort holdings").accessibilityValue(holdingSort.title)
                }.font(UpOnlyType.caption).foregroundStyle(.secondary).padding(.top, 2)
            }
            ForEach(lines) { line in
                Divider().opacity(0.5)
                holdingRow(line)
            }
        }.padding(UpOnlyLayout.cardInset).modifier(UpOnlyContentSurface())
    }
    /// Asset │ price and 24h move │ value and quantity. Prices and moves are public market data, so privacy mode
    /// hides only what you hold.
    func holdingRow(_ line: HoldingLine) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                HStack(spacing: 8) {
                    UpOnlyAssetBadge(assetID: line.assetID, symbol: line.ticker, size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(line.ticker).font(UpOnlyType.row.weight(.semibold)).lineLimit(1)
                        if !line.name.isEmpty { Text(line.name).font(UpOnlyType.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(line.price ?? "—").font(UpOnlyType.row.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
                    if let change = line.dayChange {
                        Text(UpOnlyFormat.arrowPercent(change)).font(UpOnlyType.caption.weight(.medium).monospacedDigit()).foregroundStyle(UpOnlyTint.signed(change))
                    }
                }.frame(width: 92, alignment: .trailing)
                VStack(alignment: .trailing, spacing: 1) {
                    UpOnlyPrivateText(line.valueText).font(UpOnlyType.row.weight(.medium).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
                    if let quantity = line.quantity { UpOnlyPrivateText(quantity).font(UpOnlyType.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7) }
                }.frame(width: 96, alignment: .trailing)
            }
            if let caption = line.caption { UpOnlyPrivateText(caption).font(UpOnlyType.caption).foregroundStyle(.secondary).padding(.leading, 34) }
        }.padding(.vertical, 2)
            .accessibilityElement(children: .ignore).accessibilityLabel(line.ticker + (line.name.isEmpty ? "" : ", " + line.name))
            .accessibilityValue(spokenHolding(line))
    }
    /// "price $59,000.00, up 2.1% in 24 hours, value $5,900.00, 0.1 BTC".
    func spokenHolding(_ line: HoldingLine) -> String {
        var parts: [String] = []
        if let price = line.price { parts.append("price " + price) }
        if let change = line.dayChange {
            let percent = UpOnlyFormat.arrowPercent(change).replacingOccurrences(of: "▲ ", with: "").replacingOccurrences(of: "▼ ", with: "")
            parts.append((change > 0 ? "up " : change < 0 ? "down " : "unchanged ") + (change == 0 ? "" : percent + " ") + "in 24 hours")
        }
        if session.privacyMode { parts.append("value hidden") }
        else {
            parts.append("value " + line.valueText)
            if let quantity = line.quantity { parts.append(quantity) }
            if let caption = line.caption { parts.append(caption) }
        }
        return parts.joined(separator: ", ")
    }
    var worthEmptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                UpOnlySymbolBadge(symbol: selectedPortfolio?.kind == .metals ? TrackedKind.metals.symbol : "chart.line.uptrend.xyaxis", tint: UpOnlyTint.netWorth, size: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Nothing here yet").font(UpOnlyType.title).fixedSize(horizontal: false, vertical: true)
                    Text("No balances or holdings recorded yet.").font(UpOnlyType.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Button(selectedPortfolio?.kind == .metals ? "Add gold or silver" : selectedPortfolio != nil ? "Add a coin" : "Add") {
                if let portfolio = selectedPortfolio { showImport(session.startImport(portfolio.kind == .metals ? .metals : .holdings, portfolioID: portfolio.id)) }
                else { session.addingInMenu = true }
            }.buttonStyle(.glassProminent)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14).modifier(UpOnlyContentSurface())
    }
}
