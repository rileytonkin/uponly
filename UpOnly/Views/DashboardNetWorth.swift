import SwiftUI

/// Net worth: today's value, how it changed over the range and against what was paid, the chart and the rows below.
extension UpOnlyUnlockedPanel {
    /// Everything the net worth page shows, worked out once per render.
    struct WorthSnapshot {
        var interval: DateInterval
        var valuation: ValuationResult? = nil
        var points: [UpOnlyChartPoint] = []
        /// Today's total against the chart's first value.
        var change: RangeChange? = nil
        /// Every part where the range starts, for each All assets row's own change. Only worked out there.
        var start: (day: Date, components: [ValuationComponent])? = nil
        /// Prices for the holdings table's changes over the range.
        var estimates: ChartEstimates? = nil
        /// Any saved history for this scope, even outside the range, so the range can still be changed.
        var hasHistory = false
        /// Profit against what was paid, over the holdings with recorded purchases.
        var allTime: (gain: Decimal, cost: Decimal, covered: Int, total: Int)? = nil
        /// Each holding's cost and gain, worked out once for the All-time line and the holdings table.
        var performance: [UUID: HoldingPerformance] = [:]
    }
    func worthSnapshot() -> WorthSnapshot {
        let interval = selectedInterval
        guard let document = session.document else { return WorthSnapshot(interval: interval) }
        let samples = DashboardPeriod.samples(in: interval, scope: scope, document: document)
        let valuation = AssetOwnership.personalValue(at: interval.end, scope: scope, document: document)
        let estimates = session.chartEstimates() ?? ChartEstimates(document: document)
        // Whatever a saved day lacks (a price, a rate, a balance, a company's share that month) is filled from the
        // nearest saved values, so the line never dips or cuts across for want of one.
        func figure(_ result: (total: Decimal, estimated: [String])?) -> (Decimal, String?)? {
            result.map { ($0.total, nil) }
        }
        let yourShare = { (components: [ValuationComponent], moment: Date) in figure(estimates.personalTotal(components, day: moment, at: moment)) }
        // Finest first: intraday prices once fetched, then the saved hours of the past day, then saved days.
        let points = intradaySeries(scope: scope, interval: interval, samples: samples, liveComponents: valuation.components, live: valuation.total, yourShare)
            ?? (worthRange.hourly
                ? hourlySeries(scope: scope, interval: interval, live: valuation.total, yourShare)
                : dailySeries(samples, interval: interval, live: valuation.total) { figure(estimates.personalTotal($0.components, day: $0.utcDay)) })
        // A company's holdings count at your share in the total, so profit on cost is only summed for personal portfolios.
        let personal = Set(document.portfolios.filter { ($0.ownerBusinessID ?? "").isEmpty }.map(\.id))
        let portfolioOf = Dictionary(document.holdings.map { ($0.id, $0.portfolioID) }, uniquingKeysWith: { first, _ in first })
        let holdings = valuation.components.filter { $0.kind == .holding }
        let performance = Dictionary(holdings.map { ($0.id, HoldingPerformance.summary(holdingID: $0.id, valueUSD: $0.usdValue?.value, document: document, at: interval.end)) },
                                     uniquingKeysWith: { first, _ in first })
        let owned = holdings.filter { $0.usdValue != nil && portfolioOf[$0.id].map(personal.contains) == true }
        return WorthSnapshot(interval: interval, valuation: valuation, points: points, change: periodChange(points, now: valuation.total),
                             start: scope == .allTracked ? rangeStart(scope: scope, interval: interval, document: document, estimates: estimates) : nil,
                             estimates: estimates, hasHistory: !samples.isEmpty || document.dailyValuations.contains { $0.scope == scope },
                             allTime: HoldingPerformance.total(owned.compactMap { performance[$0.id] }), performance: performance)
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
                UpOnlyAmount(value: value, cents: true).padding(.top, ownerShare != nil ? 10 : 0)
            }
            if let valuation, available {
                VStack(alignment: .leading, spacing: 5) {
                    if valuation.total == nil, let last = valuation.lastComplete {
                        Text("Last complete value · " + UpOnlyFormat.utcDate(last.at)).font(UpOnlyType.body).foregroundStyle(.secondary)
                    } else {
                        // How the total moved over the chart's range, beside how the holdings stand against what was paid.
                        let stats = [snapshot.change.map { changeStat($0) }, snapshot.allTime.map(allTimeStat)].compactMap { $0 }
                        if !stats.isEmpty { headlineStats(stats) }
                    }
                    if let stale = staleNote(valuation) {
                        Text(stale.text).font(UpOnlyType.caption).foregroundStyle(.secondary).lineLimit(2).help(stale.detail)
                    }
                }.fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            }
            if let valuation, valuation.missing.contains(where: { $0.reason == "ownership" }) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(ownershipMessage(valuation, at: snapshot.interval.end)).font(UpOnlyType.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Open Accounts") { manage("Accounts") }.buttonStyle(.upOnlySecondary).controlSize(.small)
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
                        Text("No price yet for " + unpriced.map(\.label).joined(separator: ", ") + ". Check that Crypto prices are on in Settings.").font(UpOnlyType.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Set up prices") { manage("Sources") }
                            .buttonStyle(.upOnlyPrimary).controlSize(.regular)
                    }
                    ForEach(valuation.components.filter { $0.missing != nil && $0.missing != "fx" && $0.missing != "quote" }, id: \.id) { component in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(component.label).font(UpOnlyType.section).fixedSize(horizontal: false, vertical: true)
                            Text(component.missing == "balance" ? "Add this account’s balance to calculate your net worth." : "This amount needs correcting.")
                                .font(UpOnlyType.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Button(component.missing == "balance" ? "Add balance" : "Review amount") {
                                if component.missing == "balance" { showImport(session.startImport(.bankBalances, prefill: true, accountID: component.id)) }
                                else { manage("Accounts") }
                            }.buttonStyle(.upOnlyPrimary).controlSize(.small)
                        }
                    }
                }.padding(.top, 16)
            }
            if snapshot.hasHistory {
                VStack(alignment: .leading, spacing: 10) {
                    rangeControl
                    if snapshot.points.contains(where: { $0.value != nil }) {
                        UpOnlyChart(points: snapshot.points, tint: trendTint(snapshot.points), plotHeight: chartPlotHeight, bridgesGaps: true)
                    } else {
                        Text("No saved values" + worthRange.within + ".").font(UpOnlyType.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(.top, 18)
            }
            if let portfolio {
                if let valuation, available { holdingsList(portfolio, valuation: valuation, snapshot: snapshot).padding(.top, 16) }
            } else {
                let rows = overviewRows(snapshot)
                if !rows.isEmpty { assetList(rows).padding(.top, 16) }
            }
            if !available {
                worthEmptyState.padding(.top, 14)
            }
        }
    }
    /// "All-time  ▲ 31.2%  +$1,310": profit on cost, which doesn't change with the range. What it's measured on (what
    /// was paid, and how many holdings have a cost) is the tooltip, marked when only some holdings count. Privacy mode
    /// keeps the percentage and hides the amounts.
    func allTimeStat(_ allTime: (gain: Decimal, cost: Decimal, covered: Int, total: Int)) -> HeadlineStat {
        let fraction = allTime.cost > 0 ? allTime.gain / allTime.cost : nil
        let amount = session.privacyMode ? UpOnlyFormat.hiddenMovement(allTime.gain, fraction: nil) : UpOnlyFormat.movement(allTime.gain, fraction: nil, cents: false)
        let partial = allTime.covered < allTime.total
        let note = [session.privacyMode ? nil : "On " + UpOnlyFormat.money(allTime.cost) + " paid", partial ? "\(allTime.covered) of \(allTime.total) holdings have a cost" : nil]
            .compactMap { $0 }.joined(separator: " · ")
        let spoken = [session.privacyMode ? "amount hidden" : UpOnlyFormat.movement(allTime.gain, fraction: nil, cents: false), fraction.map(UpOnlyFormat.percent), note.isEmpty ? nil : note]
            .compactMap { $0 }.joined(separator: ", ")
        guard let fraction else { return HeadlineStat(label: "All-time", value: amount, tint: UpOnlyTint.signed(allTime.gain), help: note, spoken: spoken) }
        return HeadlineStat(label: "All-time", value: UpOnlyFormat.arrowPercent(fraction), tint: UpOnlyTint.signed(allTime.gain), detail: amount,
                            help: note, spoken: "All-time profit, " + spoken)
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
    /// The All assets rows: the same list as the switcher, each with its change over the range, each opening its page.
    func overviewRows(_ snapshot: WorthSnapshot) -> [AssetRow] {
        guard let valuation = snapshot.valuation, !valuation.isUnavailable, scope == .allTracked else { return [] }
        return selectionRows(current: valuation.components, start: snapshot.start, at: snapshot.interval.end).map { row in
            // A part-owned company shows your share, as the total counts it, with the whole company under it.
            AssetRow(id: row.id, name: row.name, detail: row.detail, detailIsAmount: true, value: row.valueText, change: row.change?.fraction, image: row.image, logo: row.logo, symbol: row.symbol, tint: row.tint) { select(row.selection, .drill) }
        }
    }
    /// One holding in a portfolio's table: what it is, its market price and move over the range, and what you hold.
    struct HoldingLine: Identifiable {
        var id: UUID
        var assetID: String
        var ticker: String
        var name: String
        var price: String?
        var change: Decimal?
        var value: Decimal?
        var valueText: String
        var quantity: String?
        var caption: String?
    }
    /// Privacy mode doesn't order by value: the order alone would say which holding is biggest.
    var effectiveHoldingSort: HoldingSort { session.privacyMode && holdingSort == .value ? .name : holdingSort }
    func holdingLines(_ portfolio: Portfolio, valuation: ValuationResult, snapshot: WorthSnapshot) -> [HoldingLine] {
        guard let document = session.document else { return [] }
        let metal = portfolio.kind == .metals
        let date = snapshot.interval.end
        let lines = valuation.components.compactMap { component -> HoldingLine? in
            guard let holding = document.holdings.first(where: { $0.id == component.id }) else { return nil }
            let id = holding.assetID.rawValue
            let metalKind = PreciousMetal.asset(holding.assetID)
            let symbol = metalKind?.rawValue ?? (session.catalog.first(where: { $0.id == id }) ?? ImportCoins.common.first(where: { $0.id == id }))?.symbol.uppercased() ?? ""
            let quantity = component.nativeAmount?.value
            let value = component.usdValue?.value
            return HoldingLine(
                id: component.id, assetID: id,
                // Metals read by name ("Gold"), coins by ticker ("BTC"); the full name is on hover.
                ticker: metalKind?.name ?? (symbol.isEmpty ? holding.assetName : symbol), name: metalKind != nil ? symbol : holding.assetName,
                price: quantity.flatMap { q in value.flatMap { UpOnlyFormat.unitPrice(quantity: q, valueUSD: $0, metal: metal) } },
                change: snapshot.estimates?.priceChange(holding.assetID, since: snapshot.interval.start, now: date),
                value: value,
                valueText: value.map(UpOnlyFormat.exactMoney) ?? (component.missing == "quote" ? "Price needed" : "Quantity needed"),
                quantity: quantity.map { UpOnlyFormat.quantityText($0, symbol: symbol.isEmpty ? holding.assetName : symbol, metal: metal) },
                caption: UpOnlyFormat.performance(snapshot.performance[component.id] ?? HoldingPerformance.summary(holdingID: component.id, valueUSD: value, document: document, at: date), metal: metal))
        }
        switch effectiveHoldingSort {
        case .value: return lines.sorted { ($0.value ?? -1) > ($1.value ?? -1) }
        case .change: return lines.sorted { ($0.change ?? -.greatestFiniteMagnitude) > ($1.change ?? -.greatestFiniteMagnitude) }
        case .name: return lines.sorted { $0.ticker.localizedStandardCompare($1.ticker) == .orderedAscending }
        }
    }
    /// The portfolio's holdings as a market app lists them: Asset │ Price │ Value, one row per coin or metal. A row
    /// opens that holding's update; the … menu updates them all.
    func holdingsList(_ portfolio: Portfolio, valuation: ValuationResult, snapshot: WorthSnapshot) -> some View {
        let lines = holdingLines(portfolio, valuation: valuation, snapshot: snapshot)
        return VStack(alignment: .leading, spacing: 0) {
            // Every holding at zero still leaves a way to update them.
            if lines.isEmpty { Text("Every holding is at zero.").font(UpOnlyType.caption).foregroundStyle(.secondary).padding(.bottom, 4) }
            else {
                // Column heads; the value head chooses the order.
                HStack(spacing: 8) {
                    Text("Asset").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Price").frame(width: 96, alignment: .trailing)
                    Menu {
                        ForEach(HoldingSort.allCases, id: \.self) { sort in
                            Toggle(sort.title, isOn: Binding(get: { effectiveHoldingSort == sort }, set: { _ in holdingSort = sort }))
                                .disabled(sort == .value && session.privacyMode)
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text(effectiveHoldingSort.title)
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                        }.font(UpOnlyType.caption).foregroundStyle(.secondary)
                    }
                        // A plain menu keeps the column head's size and colour; the chevron says it can be changed.
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().frame(width: 96, alignment: .trailing)
                        .accessibilityLabel("Sort holdings").accessibilityValue(effectiveHoldingSort.title)
                }.font(UpOnlyType.caption).foregroundStyle(.secondary).padding(.bottom, 2)
                // Clicking a holding opens its own page; updating them all is in the … menu.
                ForEach(lines) { line in
                    Button { select(.holding(line.id), .drill) } label: {
                        holdingRow(line)
                    }.buttonStyle(UpOnlyRowButtonStyle()).accessibilityHint("Open " + line.name)
                }
            }
        }
    }
    /// Asset and how much of it │ price and its move over the range │ value, centred on the row. Prices and moves are
    /// public market data, so privacy mode hides only what you hold.
    func holdingRow(_ line: HoldingLine) -> some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(spacing: 10) {
                UpOnlyAssetBadge(assetID: line.assetID, symbol: line.ticker, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.ticker).font(UpOnlyType.row.weight(.semibold)).lineLimit(1).truncationMode(.tail)
                    if let quantity = line.quantity {
                        UpOnlyPrivateText(quantity).font(UpOnlyType.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 2) {
                Text(line.price ?? "—").font(UpOnlyType.row.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
                if let change = line.change {
                    Text(UpOnlyFormat.arrowPercent(change)).font(UpOnlyType.caption.weight(.medium).monospacedDigit()).foregroundStyle(UpOnlyTint.signed(change))
                }
            }.frame(width: 96, alignment: .trailing)
            UpOnlyPrivateText(line.valueText).font(UpOnlyType.row.weight(.semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
                .frame(width: 96, alignment: .trailing)
        }.padding(.vertical, 8).contentShape(Rectangle())
            // The name, and what was paid when it's known, on hover rather than as another line under every row.
            .help([line.name.isEmpty ? nil : line.name, session.privacyMode ? nil : line.caption].compactMap { $0 }.joined(separator: " · "))
            .accessibilityElement(children: .ignore).accessibilityLabel(line.ticker + (line.name.isEmpty ? "" : ", " + line.name))
            .accessibilityValue(spokenHolding(line))
    }
    /// "price $59,000.00, up 2.1% over the past month, value $5,900.00, 0.1 BTC".
    func spokenHolding(_ line: HoldingLine) -> String {
        var parts: [String] = []
        if let price = line.price { parts.append("price " + price) }
        if let change = line.change {
            let percent = UpOnlyFormat.magnitude(change), rounded = UpOnlyFormat.roundedPercent(change)
            parts.append((rounded > 0 ? "up " + percent + " " : rounded < 0 ? "down " + percent + " " : "unchanged ") + (worthRange == .all ? "since the first saved value" : "over the " + worthRange.phrase))
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
            }.buttonStyle(.upOnlyPrimary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14).modifier(UpOnlyContentSurface())
    }
}
