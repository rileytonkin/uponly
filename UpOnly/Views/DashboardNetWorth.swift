import SwiftUI

/// Net worth: today's value, its change over the range, allocation, the chart and the asset rows.
extension UpOnlyUnlockedPanel {
    /// The first fully valued sample in the range: what the change line and the row changes are measured from.
    struct Baseline {
        var sample: DailyValuation
        var value: Decimal
    }
    /// Everything the net worth page shows, worked out once per render.
    struct WorthSnapshot {
        var interval: DateInterval
        var valuation: ValuationResult? = nil
        var points: [UpOnlyChartPoint] = []
        var baseline: Baseline? = nil
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
        // The change compares like with like: an account or portfolio added during the range isn't a gain, so the
        // baseline is the first day that already had everything counted today.
        let accounts = Set(valuation.includedAccountIDs), portfolios = Set(valuation.includedPortfolioIDs)
        let series = dailySeries(samples, interval: interval, baselineMatches: { Set($0.includedAccountIDs) == accounts && Set($0.includedPortfolioIDs) == portfolios }) { sample in
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
        return WorthSnapshot(interval: interval, valuation: valuation,
                             points: series.points, baseline: series.baseline,
                             hasHistory: !samples.isEmpty || document.dailyValuations.contains { $0.scope == scope },
                             day: DayChange.total(now: valuation, then: earlier),
                             allTime: HoldingPerformance.scope(owned, document: document, at: interval.end))
    }
    var worthContent: some View {
        let snapshot = worthSnapshot()
        let valuation = snapshot.valuation
        let available = valuation.map { !$0.isUnavailable } ?? false
        let portfolio = selectedPortfolio
        let options = worthScopeOptions(at: snapshot.interval.end)
        // A detail page's name is already its title, so only a company's share is worth saying above the figure.
        let ownerShare = portfolio.flatMap { ownerShareTitle($0, at: snapshot.interval.end) }
        let showsPill = portfolio == nil && options.count > 1
        return VStack(alignment: .leading, spacing: 0) {
            if showsPill {
                scopeControl(options, selection: Binding(get: { scope }, set: { portfolioReturn = nil; scope = $0 }), label: "Net worth accounts", item: "asset group")
                    .frame(minHeight: 26, alignment: .leading)
            } else if let ownerShare { eyebrow(ownerShare).frame(minHeight: 26, alignment: .leading) }
            if let valuation, available, let value = valuation.total ?? valuation.lastComplete?.value {
                // The eye sits by the number it hides.
                HStack(alignment: .center, spacing: 4) {
                    UpOnlyAmount(value: value, cents: true)
                    UpOnlyPrivacyButton()
                    Spacer(minLength: 0)
                }.padding(.top, showsPill || ownerShare != nil ? 10 : 0)
            }
            if let valuation, available {
                VStack(alignment: .leading, spacing: 3) {
                    if valuation.total == nil, let last = valuation.lastComplete {
                        Text("Last complete value · " + UpOnlyFormat.utcDate(last.at)).font(UpOnlyType.body).foregroundStyle(.secondary)
                    } else {
                        // Two fixed answers: what moved today, and how the holdings stand against what was paid.
                        // Neither changes with the chart range.
                        if let day = snapshot.day { metricLine("24h", text: UpOnlyFormat.movement(day.amount, fraction: day.fraction, cents: true), amount: day.amount) }
                        if let allTime = snapshot.allTime {
                            let covered = allTime.covered < allTime.total ? " · \(allTime.covered) of \(allTime.total) holdings" : ""
                            metricLine("All-time", text: UpOnlyFormat.movement(allTime.gain, fraction: allTime.cost > 0 ? allTime.gain / allTime.cost : nil, cents: false),
                                       amount: allTime.gain, note: "on " + UpOnlyFormat.money(allTime.cost) + " paid" + covered)
                        }
                    }
                    if let stale = staleNote(valuation) {
                        Text(stale.text).font(UpOnlyType.caption).foregroundStyle(.secondary).lineLimit(2).help(stale.detail)
                    }
                }.fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                if portfolio == nil, scope == .allTracked, let parts = allocation(valuation, at: snapshot.interval.end) {
                    allocationBar(parts).padding(.top, 12)
                }
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
                    if let valuation, let delta = change(from: snapshot.baseline, to: valuation.total, interval: snapshot.interval) {
                        Text(delta.text).font(UpOnlyType.caption.weight(.medium).monospacedDigit()).foregroundStyle(delta.tint)
                    }
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
                if !rows.isEmpty { assetList(rows).padding(.top, 14) }
            }
            if !available {
                worthEmptyState.padding(.top, 14)
            }
        }
    }
    /// "Past year  +$4,599  ▲ 50.5%", or "Since Jul 3 …" when the first full valuation came after the range began.
    func change(from baseline: Baseline?, to current: Decimal?, interval: DateInterval) -> (text: String, tint: Color)? {
        guard let baseline, let current else { return nil }
        let day = UTCDay.start(of: baseline.sample.utcDay)
        let sameYear = UTCDay.calendar.component(.year, from: day) == UTCDay.calendar.component(.year, from: interval.end)
        let phrase = day > UTCDay.start(of: interval.start) ? "Since " + (sameYear ? UpOnlyFormat.utcDay(day) : UpOnlyFormat.utcDate(day)) : worthRange.spokenTitle
        if session.privacyMode { return (phrase + "  Change hidden", .secondary) }
        let amount = current - baseline.value
        return (phrase + "  " + UpOnlyFormat.movement(amount, fraction: baseline.value > 0 ? amount / baseline.value : nil, cents: false), UpOnlyTint.signed(amount))
    }
    /// "24h  +$66.59  ▲ 1.3%": a label, then the signed figure in green or red. Privacy mode hides the figure.
    func metricLine(_ label: String, text: String, amount: Decimal, note: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(UpOnlyType.body).foregroundStyle(.secondary).frame(width: 50, alignment: .leading)
            Text(session.privacyMode ? "Change hidden" : text).font(UpOnlyType.body.weight(.medium).monospacedDigit())
                .foregroundStyle(session.privacyMode ? Color.secondary : UpOnlyTint.signed(amount)).lineLimit(1).minimumScaleFactor(0.8)
            if let note, !session.privacyMode { Text(note).font(UpOnlyType.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail) }
        }.accessibilityElement(children: .ignore).accessibilityLabel(label == "24h" ? "Change in 24 hours" : "All-time profit")
            .accessibilityValue(session.privacyMode ? "Hidden value" : text + (note.map { ", " + $0 } ?? ""))
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
    /// Banks, crypto and metal as shares of today's net worth, when at least two of them hold value.
    func allocation(_ valuation: ValuationResult, at date: Date) -> [AllocationPart]? {
        guard let document = session.document, valuation.total != nil else { return nil }
        let portfolioKind = Dictionary(document.holdings.compactMap { holding in document.portfolio(id: holding.portfolioID).map { (holding.id, $0.kind) } },
                                       uniquingKeysWith: { first, _ in first })
        let kinds: [(kind: TrackedKind, name: String, tint: Color)] = [(.banks, "Banks", UpOnlyTint.netWorth), (.crypto, "Crypto", UpOnlyTint.crypto), (.metals, "Gold & silver", UpOnlyTint.metals)]
        let values = kinds.map { kind -> Decimal in
            let parts = valuation.components.filter { $0.kind == .bank ? kind.kind == .banks : portfolioKind[$0.id] == kind.kind }
            return parts.isEmpty ? 0 : AssetOwnership.personalTotal(parts, at: date, document: document) ?? 0
        }
        guard values.filter({ $0 > 0 }).count >= 2 else { return nil }
        let total = values.filter { $0 > 0 }.reduce(Decimal(0), +)
        let shares = DashboardChart.percentages(values)
        return kinds.indices.filter { values[$0] > 0 }.map { index in
            AllocationPart(name: kinds[index].name, tint: kinds[index].tint, percent: shares[index], fraction: NSDecimalNumber(decimal: values[index] / total).doubleValue)
        }
    }
    struct AllocationPart {
        var name: String
        var tint: Color
        var percent: Int
        var fraction: Double
    }
    /// A thin bar split by kind, with a one-line legend. Privacy mode keeps the bar but drops the percentages.
    func allocationBar(_ parts: [AllocationPart]) -> some View {
        // A share too small to round to 1% still exists; say so rather than "0%".
        func share(_ part: AllocationPart) -> String { session.privacyMode ? "" : part.percent == 0 ? " <1%" : " \(part.percent)%" }
        return
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                let width = max(0, geometry.size.width - CGFloat(parts.count - 1))
                HStack(spacing: 1) {
                    ForEach(parts, id: \.name) { part in Rectangle().fill(part.tint).frame(width: width * CGFloat(part.fraction)) }
                }
            }.frame(height: 6).clipShape(Capsule())
            HStack(spacing: 12) {
                ForEach(parts, id: \.name) { part in
                    HStack(spacing: 4) {
                        Circle().fill(part.tint).frame(width: 6, height: 6)
                        Text(part.name + share(part))
                    }
                }
            }.font(UpOnlyType.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }.accessibilityElement(children: .ignore).accessibilityLabel("Allocation")
            .accessibilityValue(parts.map { $0.name + share($0) }.joined(separator: ", "))
    }
    /// Bank groups, then personal portfolios. A company's portfolios live on its page and in its row, unless the
    /// company has no bank account to show them under; then they're listed here with the company's name.
    func overviewRows(_ snapshot: WorthSnapshot) -> [AssetRow] {
        guard let document = session.document, let valuation = snapshot.valuation, !valuation.isUnavailable else { return [] }
        let baseline = snapshot.baseline?.sample
        let groups = BankBalanceGroup.groups(valuation.components, document: document)
        var rows = groups.map { group -> AssetRow in
            let parts = group.components + (group.businessID.map { companyHoldings(valuation.components, companyID: $0) } ?? [])
            let total = AssetOwnership.sum(parts)
            return AssetRow(id: group.id, name: group.name, value: total.map(UpOnlyFormat.exactMoney) ?? "Needs update", change: rowChange(parts, total: total, baseline: baseline),
                            image: group.image, symbol: "building.columns.fill", tint: UpOnlyTint.netWorth) { openCompany(group) }
        }
        guard scope == .allTracked else { return rows }
        let companies = Set(groups.compactMap(\.businessID))
        let portfolioOf = Dictionary(document.holdings.map { ($0.id, $0.portfolioID) }, uniquingKeysWith: { first, _ in first })
        for portfolio in document.portfolios where portfolio.isActive(at: snapshot.interval.end) {
            let owner = portfolio.ownerBusinessID.flatMap { $0.isEmpty ? nil : $0 }
            if let owner, companies.contains(owner) { continue }
            let parts = valuation.components.filter { $0.kind == .holding && portfolioOf[$0.id] == portfolio.id }
            let total = parts.isEmpty ? nil : AssetOwnership.sum(parts)
            let company = owner.flatMap { id in model.books.first { $0.id == id }?.name }
            rows.append(AssetRow(id: portfolio.id.uuidString, name: portfolio.name + (company.map { " · " + $0 } ?? ""),
                                 value: parts.isEmpty ? "No holdings" : total.map(UpOnlyFormat.exactMoney) ?? "Price needed",
                                 change: rowChange(parts, total: total, baseline: baseline),
                                 symbol: portfolio.kind == .metals ? TrackedKind.metals.symbol : TrackedKind.crypto.symbol,
                                 tint: portfolio.kind == .metals ? UpOnlyTint.metals : UpOnlyTint.crypto) { portfolioReturn = nil; scope = .portfolio(portfolio.id) })
        }
        return rows
    }
    /// A row's change over the range: its parts today against the same parts in the baseline sample. Nil when unknown.
    func rowChange(_ parts: [ValuationComponent], total: Decimal?, baseline: DailyValuation?) -> Decimal? {
        guard let total, let baseline, !parts.isEmpty else { return nil }
        let ids = Set(parts.map(\.id))
        let then = baseline.components.filter { ids.contains($0.id) }
        // Only when every part existed then; a newly added account isn't a gain.
        guard then.count == parts.count, let start = AssetOwnership.sum(then), start > 0 else { return nil }
        return (total - start) / start
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
