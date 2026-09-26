import SwiftUI

/// One coin or metal on its own page: what it's worth and how it has done, over the range and against what was paid;
/// its price, cost and dates; every purchase with how that buy has done since; and how the amount held has changed.
extension UpOnlyUnlockedPanel {
    /// The holding a holding page shows.
    var selectedHolding: Holding? {
        guard case .holding(let id) = session.dashboardSelection else { return nil }
        return session.document?.holdings.first { $0.id == id }
    }
    /// "BTC", or a metal's name, as the portfolio's table writes it.
    func holdingSymbol(_ holding: Holding) -> String {
        if let metal = PreciousMetal.asset(holding.assetID) { return metal.rawValue }
        let id = holding.assetID.rawValue
        let symbol = (session.catalog.first { $0.id == id } ?? ImportCoins.common.first { $0.id == id })?.symbol.uppercased() ?? ""
        return symbol.isEmpty ? holding.assetName : symbol
    }
    func holdingContent(_ holding: Holding) -> some View {
        let document = session.document
        let interval = selectedInterval
        let metal = PreciousMetal.asset(holding.assetID) != nil
        let symbol = holdingSymbol(holding)
        let scope = ValuationScope.portfolio(holding.portfolioID)
        let valuation = document.map { NetWorthCalculator.value(at: interval.end, scope: scope, document: $0) }
        let component = valuation?.components.first { $0.id == holding.id }
        let value = component?.usdValue?.value
        let quantity = component?.nativeAmount?.value ?? document?.effectiveQuantity(holdingID: holding.id, at: interval.end)
        let performance = document.map { HoldingPerformance.summary(holdingID: holding.id, valueUSD: value, document: $0, at: interval.end) }
        let points = holdingSeries(holding, scope: scope, interval: interval, liveComponents: valuation?.components ?? [], live: value)
        let change = periodChange(points, now: value)
        let stats = [change.map { changeStat($0) }, performance.flatMap { HoldingPerformance.total([$0]) }.map(allTimeStat)].compactMap { $0 }
        return VStack(alignment: .leading, spacing: 0) {
            if let value {
                UpOnlyAmount(value: value, cents: true)
            } else {
                Text(component?.missing == "quote" ? "Price needed" : "Quantity needed").font(UpOnlyType.title)
            }
            // How much, at what price, after the coin's logo: the price is public, so privacy mode only hides the amount.
            if let quantity {
                HStack(spacing: 5) {
                    UpOnlyAssetBadge(assetID: holding.assetID.rawValue, symbol: symbol, size: 16).padding(.trailing, 1)
                    UpOnlyPrivateText(UpOnlyFormat.quantityText(quantity, symbol: symbol, metal: metal))
                    if let value, let price = UpOnlyFormat.unitPrice(quantity: quantity, valueUSD: value, metal: metal) { Text("at " + price) }
                }.font(UpOnlyType.body.monospacedDigit()).foregroundStyle(.secondary).padding(.top, 4)
            }
            if !stats.isEmpty { headlineStats(stats).padding(.top, 10) }
            if points.contains(where: { $0.value != nil }) {
                VStack(alignment: .leading, spacing: 12) {
                    UpOnlyChart(points: points, tint: trendTint(points), plotHeight: chartPlotHeight, bridgesGaps: true)
                    rangeControl
                }.padding(.top, 18)
            }
            if let document, let performance {
                holdingDetails(holding, document: document, quantity: quantity, value: value, performance: performance, metal: metal).padding(.top, 18)
                holdingPurchases(holding, document: document, quantity: quantity, value: value, symbol: symbol, metal: metal).padding(.top, 18)
                holdingHistory(holding, document: document, symbol: symbol, metal: metal).padding(.top, 18)
            }
        }
    }
    /// This holding's value over the range, drawn as finely as its portfolio's page draws the portfolio.
    func holdingSeries(_ holding: Holding, scope: ValuationScope, interval: DateInterval, liveComponents: [ValuationComponent], live: Decimal?) -> [UpOnlyChartPoint] {
        guard let document = session.document else { return [] }
        let samples = DashboardPeriod.samples(in: interval, scope: scope, document: document)
        let estimates = session.chartEstimates() ?? ChartEstimates(document: document)
        let figure = { (components: [ValuationComponent], moment: Date?, day: Date) -> (Decimal, String?)? in
            estimates.total(components.filter { $0.id == holding.id }, day: day, at: moment).map { ($0.total, nil) }
        }
        if let fine = intradaySeries(scope: scope, interval: interval, samples: samples, liveComponents: liveComponents, live: live, { figure($0, $1, $1) }) { return fine }
        if worthRange.hourly { return hourlySeries(scope: scope, interval: interval, live: live) { figure($0, $1, $1) } }
        return dailySeries(samples, interval: interval, live: live) { figure($0.components, nil, $0.utcDay) }
    }
    /// Four tiles, two by two, as market apps show a holding: its price (and move over the range), what one cost on
    /// average, what was paid in all, and how long it has been held.
    func holdingDetails(_ holding: Holding, document: VaultDocument, quantity: Decimal?, value: Decimal?, performance: HoldingPerformance, metal: Bool) -> some View {
        let price = quantity.flatMap { q in value.flatMap { UpOnlyFormat.unitPrice(quantity: q, valueUSD: $0, metal: metal) } }
        let move = (session.chartEstimates() ?? ChartEstimates(document: document)).priceChange(holding.assetID, since: selectedInterval.start, now: selectedInterval.end)
        // What one unit cost on average, over the part of the holding the purchases cover.
        let covered = performance.coveredQuantity ?? quantity
        let average = performance.costUSD.flatMap { cost in covered.flatMap { q in q > 0 ? UpOnlyFormat.unitPrice(quantity: q, valueUSD: cost, metal: metal) : nil } }
        // Held since the first buy, or the first amount recorded when that's earlier.
        let since = ((document.purchases ?? []).filter { $0.holdingID == holding.id }.map(\.at) + [performance.since].compactMap { $0 }).min()
        return Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                UpOnlyStatTile(title: "Price", value: price ?? "—", detail: move.map(UpOnlyFormat.arrowPercent), detailTint: move.map { UpOnlyTint.signed(UpOnlyFormat.roundedPercent($0)) })
                UpOnlyStatTile(title: "Avg. buy price", value: average ?? "—")
            }
            GridRow {
                UpOnlyStatTile(title: "Cost basis", value: performance.costUSD.map(UpOnlyFormat.exactMoney) ?? "—", isPrivate: true,
                               detail: performance.coveredQuantity != nil ? "For part of it" : nil)
                UpOnlyStatTile(title: "Held since", value: since.map(UpOnlyFormat.utcDate) ?? "—", detail: since.map { Self.heldFor($0) })
            }
        }
    }
    /// "1 yr 6 mo", "5 mo", "12 days".
    static func heldFor(_ since: Date, now: Date = Date()) -> String {
        let parts = UTCDay.calendar.dateComponents([.year, .month, .day], from: UTCDay.start(of: since), to: UTCDay.today(now: now))
        let years = parts.year ?? 0, months = parts.month ?? 0, days = parts.day ?? 0
        if years > 0 { return "\(years) yr" + (months > 0 ? " \(months) mo" : "") }
        if months > 0 { return "\(months) mo" }
        return days == 1 ? "1 day" : "\(days) days"
    }
    /// Every buy, newest first: when, how much at what price, what it's worth at today's price, and its gain or loss.
    func holdingPurchases(_ holding: Holding, document: VaultDocument, quantity: Decimal?, value: Decimal?, symbol: String, metal: Bool) -> some View {
        let lots = (document.purchases ?? []).filter { $0.holdingID == holding.id }.sorted { $0.at > $1.at }
        // Today's price for one unit as the holding is counted (grams for metal).
        let unit = quantity.flatMap { q in value.flatMap { v in q > 0 ? v / q : nil } }
        return VStack(alignment: .leading, spacing: 6) {
            Text("Purchases").font(UpOnlyType.section)
            ManageCard {
                ForEach(Array(lots.enumerated()), id: \.element.id) { index, lot in
                    let costUSD = HoldingPerformance.purchaseRate(lot.currency, at: lot.at, document: document, now: Date()).map { lot.paid.value * $0 }
                    let worth = unit.map { lot.quantity.value * $0 }
                    let gain = worth.flatMap { w in costUSD.flatMap { c in c > 0 ? (w - c) / c : nil } }
                    // When, then how much at what price; on the right, what that buy has made or lost since.
                    let profit = worth.flatMap { w in costUSD.map { w - $0 } }
                    UpOnlyRow(title: UpOnlyFormat.utcDate(lot.at),
                              caption: UpOnlyFormat.quantityText(lot.quantity.value, symbol: symbol, metal: metal)
                                + (buyPrice(lot, costUSD: costUSD, metal: metal).map { " at " + $0 } ?? ""),
                              captionIsPrivate: true,
                              value: profit.map { UpOnlyFormat.movement($0, fraction: nil, cents: true) } ?? "Price needed", change: gain) {
                        UpOnlyAssetBadge(assetID: holding.assetID.rawValue, symbol: symbol, size: 32)
                    }
                }
                UpOnlyRow(title: lots.isEmpty ? "Add what you paid" : "Add a purchase", caption: lots.isEmpty ? "See the gain or loss on each buy" : nil, chevron: true, action: { openHoldingEditor(.purchases(holding.id)) }) {
                    UpOnlySymbolBadge(symbol: "plus", tint: .accentColor, size: 32)
                }
            }
        }
    }
    /// What one unit cost in that buy, in whole dollars from $100 ("$67,500"), per ounce for metal; in the currency
    /// paid when there's no rate for it.
    func buyPrice(_ lot: PurchaseLot, costUSD: Decimal?, metal: Bool) -> String? {
        let units = metal ? lot.quantity.value / PreciousMetal.gramsPerTroyOunce : lot.quantity.value
        guard units > 0 else { return nil }
        let each = (costUSD ?? lot.paid.value) / units
        let text = costUSD == nil ? UpOnlyFormat.currencyMoney(each, currency: lot.currency) : each >= 100 ? UpOnlyFormat.money(each) : UpOnlyFormat.exactMoney(each)
        return text + (metal ? "/ozt" : "")
    }
    /// How the amount held has changed, newest first: each update and what it added or took away.
    @ViewBuilder func holdingHistory(_ holding: Holding, document: VaultDocument, symbol: String, metal: Bool) -> some View {
        let changes = document.quantities.filter { $0.holdingID == holding.id }
            .sorted { QuantityObservation.ordering($0, $1) }
        if changes.count > 1 {
            let recent = Array(changes.enumerated().reversed().prefix(6))
            VStack(alignment: .leading, spacing: 6) {
                Text("Quantity history").font(UpOnlyType.section)
                ManageCard {
                    ForEach(Array(recent.enumerated()), id: \.offset) { position, entry in
                        let (index, change) = entry
                        let before = index > 0 ? changes[index - 1].quantity.value : 0
                        let delta = change.quantity.value - before
                        // The date is the title; amounts are hidden in privacy mode.
                        UpOnlyRow(title: UpOnlyFormat.utcDate(change.effectiveAt),
                                  caption: "Now " + UpOnlyFormat.quantityText(change.quantity.value, symbol: symbol, metal: metal), captionIsPrivate: true,
                                  value: index == 0 ? "First" : (delta >= 0 ? "+" : "−") + UpOnlyFormat.quantityText(abs(delta), symbol: symbol, metal: metal)) {
                            UpOnlySymbolBadge(symbol: delta >= 0 ? "arrow.up.right" : "arrow.down.right", tint: delta >= 0 ? UpOnlyTint.gain : UpOnlyTint.loss, size: 32)
                        }
                    }
                }
            }
        }
    }
    /// A holding's form on Manage (its purchases, or moving it); closing the form comes back here.
    func openHoldingEditor(_ request: UpOnlySession.HoldingRequest) {
        session.requestedHoldingEditor = request
        session.managementSection = "Portfolios"; session.managementInMenu = true
    }
}
