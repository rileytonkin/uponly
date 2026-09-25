import Foundation

struct MissingValuation: Sendable, Equatable {
    var componentID: UUID
    var reason: String
}

struct StaleValuation: Sendable, Equatable {
    var componentID: UUID
    var asOf: Date
}

struct ValuationResult: Sendable, Equatable {
    var at: Date
    var scope: ValuationScope
    var components: [ValuationComponent]
    var total: Decimal?
    var lastComplete: (value: Decimal, at: Date)?
    var missing: [MissingValuation]
    var stale: [StaleValuation]
    var includedAccountIDs: [UUID]
    var includedPortfolioIDs: [UUID]
    var isUnavailable: Bool

    static func == (lhs: ValuationResult, rhs: ValuationResult) -> Bool {
        lhs.at == rhs.at
            && lhs.scope == rhs.scope
            && lhs.components == rhs.components
            && lhs.total == rhs.total
            && lhs.lastComplete?.value == rhs.lastComplete?.value
            && lhs.lastComplete?.at == rhs.lastComplete?.at
            && lhs.missing == rhs.missing
            && lhs.stale == rhs.stale
            && lhs.includedAccountIDs == rhs.includedAccountIDs
            && lhs.includedPortfolioIDs == rhs.includedPortfolioIDs
            && lhs.isUnavailable == rhs.isUnavailable
    }
}

nonisolated enum NetWorthCalculator {
    /// `index` must come from this document; pass one when valuing many moments so it's built once. Without one it's
    /// built here, and only when the day isn't already saved.
    static func value(
        at date: Date,
        scope: ValuationScope,
        document: VaultDocument,
        now: Date = Date(),
        index: ValuationIndex? = nil
    ) -> ValuationResult {
        let day = UTCDay.start(of: date)
        let isHistorical = day < UTCDay.start(of: now)
        if isHistorical, let stored = document.storedValuation(day: day, scope: scope), stored.isComplete {
            return result(from: stored, at: date)
        }
        return compute(at: date, scope: scope, document: document, now: now, historical: isHistorical, index: index ?? ValuationIndex(document: document))
    }

    /// A day's sample while its history is rebuilt: what `value` gives, looked up in `index`. Only for days whose saved
    /// samples were cleared first, so there is none to reuse; a sample keeps no last complete value, so none is searched
    /// for. Both searches scan every saved day, which over years of history cost more than the valuations.
    static func rebuiltSample(at date: Date, scope: ValuationScope, document: VaultDocument, now: Date, index: ValuationIndex) -> DailyValuation? {
        sample(from: compute(at: date, scope: scope, document: document, now: now,
                             historical: UTCDay.start(of: date) < UTCDay.start(of: now), index: index, findsLastComplete: false))
    }

    static func sample(from result: ValuationResult) -> DailyValuation? {
        guard !result.isUnavailable else { return nil }
        return DailyValuation(
            utcDay: UTCDay.start(of: result.at),
            scope: result.scope,
            total: result.total.map(PreciseDecimal.init),
            isComplete: result.total != nil,
            components: result.components,
            computedAt: result.at,
            includedAccountIDs: result.includedAccountIDs,
            includedPortfolioIDs: result.includedPortfolioIDs
        )
    }

    static func recordingSample(_ result: ValuationResult, in document: VaultDocument) -> VaultDocument {
        var next = document
        recordSample(result, in: &next)
        return next
    }

    static func recordSample(_ result: ValuationResult, in document: inout VaultDocument) {
        guard let incoming = sample(from: result) else { return }
        // A complete value supersedes earlier partial attempts for the day; partial ones only replace each other.
        var replaced: [Int] = []
        for (index, stored) in document.dailyValuations.enumerated() where stored.scope == result.scope && UTCDay.start(of: stored.utcDay) == incoming.utcDay {
            if stored.isComplete && !incoming.isComplete { return }
            replaced.append(index)
        }
        for index in replaced.reversed() { document.dailyValuations.remove(at: index) }
        document.dailyValuations.append(incoming)
    }

    private static func result(from stored: DailyValuation, at date: Date) -> ValuationResult {
        var missing: [MissingValuation] = []
        var stale: [StaleValuation] = []
        for component in stored.components {
            if let reason = component.missing {
                missing.append(MissingValuation(componentID: component.id, reason: reason))
            }
            if component.isStale, let asOf = component.quoteTime ?? component.fxTime {
                stale.append(StaleValuation(componentID: component.id, asOf: asOf))
            }
        }
        let lastComplete: (Decimal, Date)?
        if stored.isComplete, let total = stored.total {
            lastComplete = (total.value, stored.computedAt)
        } else {
            lastComplete = nil
        }
        return ValuationResult(
            at: date,
            scope: stored.scope,
            components: stored.components,
            total: stored.isComplete ? stored.total?.value : nil,
            lastComplete: lastComplete,
            missing: missing,
            stale: stale,
            includedAccountIDs: stored.includedAccountIDs,
            includedPortfolioIDs: stored.includedPortfolioIDs,
            isUnavailable: false
        )
    }

    private static func compute(
        at date: Date,
        scope: ValuationScope,
        document: VaultDocument,
        now: Date,
        historical: Bool,
        index: ValuationIndex,
        findsLastComplete: Bool = true
    ) -> ValuationResult {
        var missing: [MissingValuation] = []
        var stale: [StaleValuation] = []
        let banks: [ValuationComponent]
        let holdings: [ValuationComponent]
        switch scope {
        case .allTracked:
            banks = bankComponents(at: date, document: document, historical: historical, index: index, missing: &missing, stale: &stale)
            holdings = holdingComponents(at: date, scope: scope, document: document, now: now, historical: historical, index: index, missing: &missing, stale: &stale)
        case .banks:
            banks = bankComponents(at: date, document: document, historical: historical, index: index, missing: &missing, stale: &stale)
            holdings = []
        case .portfolio:
            banks = []
            holdings = holdingComponents(at: date, scope: scope, document: document, now: now, historical: historical, index: index, missing: &missing, stale: &stale)
        }
        let components = banks + holdings
        let includedAccounts = includedAccountIDs(scope: scope, document: document, at: date, index: index)
        let includedPortfolios = includedPortfolioIDs(scope: scope, document: document, at: date)
        let observed = hasObservation(scope: scope, at: date, index: index, includedAccounts: includedAccounts, includedPortfolios: includedPortfolios)
        if !observed {
            return ValuationResult(
                at: date,
                scope: scope,
                components: [],
                total: nil,
                lastComplete: findsLastComplete ? lastCompleteSample(in: document, scope: scope, at: date) : nil,
                missing: [],
                stale: [],
                includedAccountIDs: includedAccounts,
                includedPortfolioIDs: includedPortfolios,
                isUnavailable: true
            )
        }
        var total: Decimal? = nil
        if missing.isEmpty, components.allSatisfy({ $0.usdValue != nil && $0.missing == nil }) {
            do {
                total = try components.reduce(Decimal(0)) { try MoneyInput.add($0, $1.usdValue?.value ?? 0, allowingRounding: true) }
            } catch {
                missing.append(MissingValuation(componentID: UUID(), reason: "overflow"))
                total = nil
            }
        }
        return ValuationResult(
            at: date,
            scope: scope,
            components: components,
            total: total,
            lastComplete: total.map { (value: $0, at: date) } ?? (findsLastComplete ? lastCompleteSample(in: document, scope: scope, at: date) : nil),
            missing: missing,
            stale: stale,
            includedAccountIDs: includedAccounts,
            includedPortfolioIDs: includedPortfolios,
            isUnavailable: false
        )
    }

    private static func lastCompleteSample(
        in document: VaultDocument,
        scope: ValuationScope,
        at date: Date
    ) -> (value: Decimal, at: Date)? {
        let day = UTCDay.start(of: date)
        return document.dailyValuations.lazy
            .filter {
                $0.scope == scope && $0.isComplete && $0.computedAt <= date && UTCDay.start(of: $0.utcDay) <= day
            }
            .latest { ($0.computedAt, $0.utcDay) < ($1.computedAt, $1.utcDay) }
            .flatMap { sample in
                sample.total.map { ($0.value, sample.computedAt) }
            }
    }

    private static func includedAccountIDs(scope: ValuationScope, document: VaultDocument, at date: Date, index: ValuationIndex) -> [UUID] {
        switch scope {
        case .portfolio: return []
        case .allTracked, .banks:
            return document.accounts.map(\.id).filter { index.isBankTracked($0, at: date) }.sorted { $0.uuidString < $1.uuidString }
        }
    }

    private static func includedPortfolioIDs(scope: ValuationScope, document: VaultDocument, at date: Date) -> [UUID] {
        switch scope {
        case .banks: return []
        case .allTracked:
            return document.portfolios.filter { $0.isActive(at: date) }.map(\.id).sorted { $0.uuidString < $1.uuidString }
        case .portfolio(let id):
            return document.portfolios.contains(where: { $0.id == id && $0.isActive(at: date) }) ? [id] : []
        }
    }

    private static func hasObservation(
        scope: ValuationScope,
        at date: Date,
        index: ValuationIndex,
        includedAccounts: [UUID],
        includedPortfolios: [UUID]
    ) -> Bool {
        let hasBank = includedAccounts.contains { index.hasBalance($0, by: date) }
        // Every holding the portfolios ever had, as before: an archived one still shows the portfolio was observed.
        let hasQuantity = includedPortfolios.contains { portfolioID in
            index.holdings(in: portfolioID).contains { index.hasQuantity($0.id, by: date) }
        }
        switch scope {
        case .banks: return hasBank
        case .portfolio: return hasQuantity
        case .allTracked: return hasBank || hasQuantity
        }
    }

    private static func bankComponents(
        at date: Date,
        document: VaultDocument,
        historical: Bool,
        index: ValuationIndex,
        missing: inout [MissingValuation],
        stale: inout [StaleValuation]
    ) -> [ValuationComponent] {
        var result: [ValuationComponent] = []
        for account in document.accounts where index.isBankTracked(account.id, at: date) {
            let observation = index.balance(account.id, at: date)
            guard let observation else {
                let component = ValuationComponent(
                    id: account.id,
                    kind: .bank,
                    label: account.name,
                    currency: account.currency,
                    nativeAmount: nil,
                    usdValue: nil,
                    quoteTime: nil,
                    fxTime: nil,
                    isStale: false,
                    missing: "balance"
                )
                result.append(component)
                missing.append(MissingValuation(componentID: account.id, reason: "balance"))
                continue
            }
            let converted = convert(
                amount: observation.amount.value,
                currency: observation.currency,
                at: date,
                index: index,
                historical: historical
            )
            // Age is judged at the valuation's own date, so a rebuilt past day isn't stale just for being past.
            var isStale = false
            if date.timeIntervalSince(observation.observedAt) > VaultLimits.bankStaleAfter {
                isStale = true
                stale.append(StaleValuation(componentID: account.id, asOf: observation.observedAt))
            }
            if let fxStale = converted.fxTime,
               observation.currency != "USD",
               date.timeIntervalSince(fxStale) > VaultLimits.fxStaleAfter {
                isStale = true
                stale.append(StaleValuation(componentID: account.id, asOf: fxStale))
            }
            if converted.usd == nil {
                missing.append(MissingValuation(componentID: account.id, reason: converted.missing ?? "fx"))
            }
            result.append(
                ValuationComponent(
                    id: account.id,
                    kind: .bank,
                    label: account.name,
                    currency: observation.currency,
                    nativeAmount: observation.amount,
                    usdValue: converted.usd.map(PreciseDecimal.init),
                    quoteTime: nil,
                    fxTime: converted.fxTime,
                    isStale: isStale,
                    missing: converted.usd == nil ? (converted.missing ?? "fx") : nil
                )
            )
        }
        return result
    }

    private static func holdingComponents(
        at date: Date,
        scope: ValuationScope,
        document: VaultDocument,
        now: Date,
        historical: Bool,
        index: ValuationIndex,
        missing: inout [MissingValuation],
        stale: inout [StaleValuation]
    ) -> [ValuationComponent] {
        let portfolios: [Portfolio]
        switch scope {
        case .allTracked:
            portfolios = document.portfolios.filter { $0.isActive(at: date) }
        case .banks:
            return []
        case .portfolio(let id):
            portfolios = document.portfolios.filter { $0.id == id && $0.isActive(at: date) }
        }
        var result: [ValuationComponent] = []
        for portfolio in portfolios {
            for holding in index.holdings(in: portfolio.id) where holding.isActive(at: date) {
                guard let quantity = index.quantity(holding.id, at: date) else {
                    continue
                }
                if quantity == 0 { continue }
                // A past day takes a price from that day only.
                let quote = index.quote(holding.assetID, at: date, sameDayOnly: historical)
                guard let quote else {
                    result.append(
                        ValuationComponent(
                            id: holding.id,
                            kind: .holding,
                            label: holding.assetName,
                            currency: "USD",
                            nativeAmount: PreciseDecimal(quantity),
                            usdValue: nil,
                            quoteTime: nil,
                            fxTime: nil,
                            isStale: false,
                            missing: "quote"
                        )
                    )
                    missing.append(MissingValuation(componentID: holding.id, reason: "quote"))
                    continue
                }
                var isStale = false
                if !historical, now.timeIntervalSince(quote.providerTime) > VaultLimits.quoteStaleAfter {
                    isStale = true
                    stale.append(StaleValuation(componentID: holding.id, asOf: quote.providerTime))
                }
                let usd: PreciseDecimal?
                do {
                    usd = PreciseDecimal(try MoneyInput.multiply(quantity, quote.priceUSD.value, allowingRounding: true))
                } catch {
                    missing.append(MissingValuation(componentID: holding.id, reason: "overflow"))
                    usd = nil
                }
                result.append(
                    ValuationComponent(
                        id: holding.id,
                        kind: .holding,
                        label: holding.assetName,
                        currency: "USD",
                        nativeAmount: PreciseDecimal(quantity),
                        usdValue: usd,
                        quoteTime: quote.providerTime,
                        fxTime: nil,
                        isStale: isStale,
                        missing: usd == nil ? "overflow" : nil
                    )
                )
            }
        }
        return result
    }

    /// How far back a past day looks for an exchange rate: weekends and holidays publish none.
    static let rateLookback: TimeInterval = 7 * 86400

    private static func convert(
        amount: Decimal,
        currency: String,
        at date: Date,
        index: ValuationIndex,
        historical: Bool
    ) -> (usd: Decimal?, fxTime: Date?, missing: String?) {
        if currency == "USD" || amount == 0 {
            return (amount, nil, nil)
        }
        guard let match = index.rate(currency, at: date, within: historical ? rateLookback : nil) else { return (nil, nil, "fx") }
        do {
            return (try MoneyInput.multiply(amount, match.rate.value, allowingRounding: true), match.providerTime, nil)
        } catch {
            return (nil, match.providerTime, "overflow")
        }
    }
}

/// Each account's balances and tracking, each holding's quantities, each asset's prices and each currency's dollar
/// rates, sorted once, so a valuation finds the one in effect by binary search rather than scanning every observation
/// for every part of every day. Answers exactly as the scans did: ties keep the later record, as `latest(by:)` does.
nonisolated struct ValuationIndex: Sendable {
    private var balances: [UUID: [BankBalanceObservation]]
    private var tracking: [UUID: [BankTrackingObservation]]
    private var trackedAccounts: Set<UUID>
    private var quantities: [UUID: [QuantityObservation]]
    private var quotes: [CanonicalAssetID: [QuoteObservation]]
    private var rates: [String: [FXObservation]]
    /// Each portfolio's holdings in the document's order.
    private var portfolioHoldings: [UUID: [Holding]]

    init(document: VaultDocument) {
        balances = Self.grouped(document.bankBalances, by: \.accountID) { $0.observedAt < $1.observedAt }
        tracking = Self.grouped(document.bankTracking, by: \.accountID) { ($0.effectiveAt, $0.ordinal) < ($1.effectiveAt, $1.ordinal) }
        trackedAccounts = Set(document.trackedBankAccountIDs)
        quantities = Self.grouped(document.quantities, by: \.holdingID, QuantityObservation.ordering)
        // Only prices of held assets and rates of balances' currencies are ever looked up.
        let assets = Set(document.holdings.map(\.assetID)), currencies = Set(document.bankBalances.map(\.currency))
        quotes = Self.grouped(document.quotes.filter { assets.contains($0.assetID) }, by: \.assetID) { $0.providerTime < $1.providerTime }
        rates = Self.grouped(document.fx.filter { $0.targetCurrency == "USD" && currencies.contains($0.sourceCurrency) }, by: \.sourceCurrency) { $0.providerTime < $1.providerTime }
        portfolioHoldings = Dictionary(grouping: document.holdings, by: \.portfolioID)
    }

    /// The latest balance at or before `date`.
    func balance(_ accountID: UUID, at date: Date) -> BankBalanceObservation? { Self.last(balances[accountID], atOrBefore: date) { $0.observedAt } }
    func hasBalance(_ accountID: UUID, by date: Date) -> Bool { balances[accountID]?.first.map { $0.observedAt <= date } ?? false }
    /// `VaultDocument.isBankTracked`: the latest tracking change by `date`; an account with changes only later isn't
    /// tracked yet, and one with none follows the tracked list.
    func isBankTracked(_ accountID: UUID, at date: Date) -> Bool {
        if let last = Self.last(tracking[accountID], atOrBefore: date, { $0.effectiveAt }) { return last.tracked }
        if tracking[accountID] != nil { return false }
        return trackedAccounts.contains(accountID)
    }
    /// `VaultDocument.effectiveQuantity`.
    func quantity(_ holdingID: UUID, at date: Date) -> Decimal? { Self.last(quantities[holdingID], atOrBefore: date) { $0.effectiveAt }?.quantity.value }
    func hasQuantity(_ holdingID: UUID, by date: Date) -> Bool { quantities[holdingID]?.first.map { $0.effectiveAt <= date } ?? false }
    /// The latest price at or before `date`; with `sameDayOnly`, only one from `date`'s UTC day. Only for a held asset.
    func quote(_ assetID: CanonicalAssetID, at date: Date, sameDayOnly: Bool) -> QuoteObservation? {
        guard let quote = Self.last(quotes[assetID], atOrBefore: date, { $0.providerTime }) else { return nil }
        return !sameDayOnly || UTCDay.isSameDay(quote.providerTime, date) ? quote : nil
    }
    /// The latest dollar rate at or before `date`, no older than `lookback` when one is given. Only for a currency some
    /// balance is in.
    func rate(_ currency: String, at date: Date, within lookback: TimeInterval?) -> FXObservation? {
        guard let rate = Self.last(rates[currency], atOrBefore: date, { $0.providerTime }) else { return nil }
        if let lookback, date.timeIntervalSince(rate.providerTime) > lookback { return nil }
        return rate
    }
    func holdings(in portfolioID: UUID) -> [Holding] { portfolioHoldings[portfolioID] ?? [] }

    /// Grouped by `key`, each group sorted by `ordered` and, where that ties, by position, so the last of equals is the
    /// later record.
    private static func grouped<Key: Hashable, Element>(_ items: [Element], by key: (Element) -> Key, _ ordered: (Element, Element) -> Bool) -> [Key: [Element]] {
        var groups: [Key: [(offset: Int, element: Element)]] = [:]
        for (offset, element) in items.enumerated() { groups[key(element), default: []].append((offset, element)) }
        return groups.mapValues { group in
            group.sorted { ordered($0.element, $1.element) || (!ordered($1.element, $0.element) && $0.offset < $1.offset) }.map { $0.element }
        }
    }
    /// The last of `items`, sorted by `time`, whose time is at or before `date`.
    private static func last<Element>(_ items: [Element]?, atOrBefore date: Date, _ time: (Element) -> Date) -> Element? {
        guard let items else { return nil }
        var low = 0, high = items.count
        while low < high { let mid = (low + high) / 2; if time(items[mid]) <= date { low = mid + 1 } else { high = mid } }
        return low > 0 ? items[low - 1] : nil
    }
}

/// Gain against what was paid, from recorded purchase lots. Nothing is inferred
/// when no lot exists; the first dated quantity still marks when the holding began.
nonisolated struct HoldingPerformance: Equatable {
    var since: Date?
    var costUSD: Decimal?
    var costNative: Decimal?
    var costCurrency: String?
    var gainUSD: Decimal?
    var returnFraction: Decimal?
    /// Set when the lots cover less than is held now: the cost is what `coveredQuantity` of `heldQuantity` cost, and no gain is known.
    var coveredQuantity: Decimal?
    var heldQuantity: Decimal?
    static func summary(holdingID: UUID, valueUSD: Decimal?, document: VaultDocument, at date: Date = Date()) -> HoldingPerformance {
        var result = HoldingPerformance()
        result.since = document.quantities.filter { $0.holdingID == holdingID }.map(\.effectiveAt).min()
        guard let basis = costBasis(holdingID: holdingID, document: document, at: date) else { return result }
        let covered = basis.held.map { basis.covered >= $0 } ?? false
        if let held = basis.held, !covered { result.coveredQuantity = basis.covered; result.heldQuantity = held }
        if let cost = basis.costUSD.flatMap(cents) {
            result.costUSD = cost
            if covered, let valueUSD, let gain = try? MoneyInput.add(valueUSD, -cost, allowingRounding: true) {
                result.gainUSD = gain
                if cost > 0 { result.returnFraction = gain / cost }
            }
        } else if let native = basis.costNative.flatMap(cents), let currency = basis.currency {
            result.costNative = native; result.costCurrency = currency
        }
        return result
    }

    /// What is still held of a holding's recorded purchases, and what that cost.
    struct Basis: Equatable {
        /// Quantity still held that has a recorded cost; never more than `held`.
        var covered: Decimal = 0
        /// What `covered` cost in dollars, each purchase at the rate on its day; nil when one has no rate.
        var costUSD: Decimal? = 0
        /// The same in the purchases' own currency, when they all share one; nil when they don't.
        var costNative: Decimal? = 0
        var currency: String?
        /// The quantity held; nil before the first dated quantity.
        var held: Decimal?
    }
    /// Average cost, replayed in date order. A purchase adds its quantity and what it cost. A fall in the quantity held
    /// takes cost out pro rata at the running average, so what's left keeps its average; a holding that goes to zero
    /// starts afresh when bought again. A quantity change comes before a purchase at the same moment, so selling out
    /// and buying back on one day keeps the new purchase. Purchases recording more than is held at the end (a cost
    /// restated for the whole position, or a sale never entered) cost what's held at their average. Unrounded; nil
    /// without a purchase by `date`.
    static func costBasis(holdingID: UUID, document: VaultDocument, at date: Date) -> Basis? {
        let lots = (document.purchases ?? []).enumerated().filter { $0.element.holdingID == holdingID && $0.element.at <= date }
            .sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }.map { $0.element }
        guard !lots.isEmpty else { return nil }
        let changes = document.quantities.enumerated().filter { $0.element.holdingID == holdingID && $0.element.effectiveAt <= date }
            .sorted { QuantityObservation.ordering($0.element, $1.element) || (!QuantityObservation.ordering($1.element, $0.element) && $0.offset < $1.offset) }
            .map { $0.element }
        var basis = Basis()
        // Keeps `part` of `whole` of everything recorded.
        func keep(_ part: Decimal, of whole: Decimal) {
            basis.covered = scaled(basis.covered, part, whole) ?? 0
            basis.costUSD = basis.costUSD.flatMap { scaled($0, part, whole) }
            basis.costNative = basis.costNative.flatMap { scaled($0, part, whole) }
        }
        func apply(_ change: QuantityObservation) {
            let quantity = change.quantity.value
            if quantity == 0 { basis = Basis() } else if let held = basis.held, quantity < held { keep(quantity, of: held) }
            basis.held = quantity
        }
        func add(_ lot: PurchaseLot) {
            guard let covered = try? MoneyInput.add(basis.covered, lot.quantity.value, allowingRounding: true) else { basis.costUSD = nil; basis.costNative = nil; return }
            basis.covered = covered
            basis.costUSD = basis.costUSD.flatMap { total in
                purchaseRate(lot.currency, at: lot.at, document: document, now: date)
                    .flatMap { try? MoneyInput.multiply(lot.paid.value, $0, allowingRounding: true) }
                    .flatMap { try? MoneyInput.add(total, $0, allowingRounding: true) }
            }
            if basis.currency == nil { basis.currency = lot.currency } else if basis.currency != lot.currency { basis.costNative = nil }
            basis.costNative = basis.costNative.flatMap { try? MoneyInput.add($0, lot.paid.value, allowingRounding: true) }
        }
        var next = 0
        for lot in lots {
            while next < changes.count, changes[next].effectiveAt <= lot.at { apply(changes[next]); next += 1 }
            add(lot)
        }
        while next < changes.count { apply(changes[next]); next += 1 }
        if let held = basis.held, basis.covered > held { keep(held, of: basis.covered); basis.covered = held }
        return basis
    }
    /// What `quantity` moved out of a holding cost, as a purchase in `destinationID` on the day of the move, so the
    /// cost goes with the coins. Nil when none of what moved has a recorded cost, or its purchases are in several
    /// currencies without a rate for one of them. The source needs nothing: its lower quantity takes the same share out.
    static func carriedLot(moving quantity: Decimal, from holdingID: UUID, to destinationID: UUID, at date: Date, document: VaultDocument) -> PurchaseLot? {
        guard let basis = costBasis(holdingID: holdingID, document: document, at: date), let held = basis.held, held > 0 else { return nil }
        let part = min(quantity, held)
        guard let covered = scaled(basis.covered, part, held), covered > 0 else { return nil }
        let share: Decimal?, currency: String
        if let usd = basis.costUSD { share = scaled(usd, part, held).flatMap(cents); currency = "USD" }
        else if let native = basis.costNative, let code = basis.currency { share = scaled(native, part, held).flatMap(cents); currency = code }
        else { return nil }
        guard let paid = share else { return nil }
        return PurchaseLot(holdingID: destinationID, quantity: PreciseDecimal(covered), paid: PreciseDecimal(paid), currency: currency, at: date)
    }
    /// Dollars for one unit of `currency` on a purchase's day: the latest rate that day, or in the week before it, as a
    /// balance that day is valued. Not the month's closing rate, which may come weeks after the purchase.
    static func purchaseRate(_ currency: String, at date: Date, document: VaultDocument, now: Date) -> Decimal? {
        if currency == "USD" { return 1 }
        let cutoff = min(UTCDay.start(of: date).addingTimeInterval(86400 - 1), max(date, now))
        return document.fx.lazy
            .filter { $0.sourceCurrency == currency && $0.targetCurrency == "USD" && $0.providerTime <= cutoff && cutoff.timeIntervalSince($0.providerTime) <= NetWorthCalculator.rateLookback }
            .latest { $0.providerTime < $1.providerTime }?.rate.value
    }
    /// `amount × part ÷ whole`, nil when it can't be worked out.
    private static func scaled(_ amount: Decimal, _ part: Decimal, _ whole: Decimal) -> Decimal? {
        guard whole != 0, var product = try? MoneyInput.multiply(amount, part, allowingRounding: true) else { return nil }
        var divisor = whole, result = Decimal()
        let status = NSDecimalDivide(&result, &product, &divisor, .plain)
        return (status == .noError || status == .lossOfPrecision) && !result.isNaN ? result : nil
    }
    private static func cents(_ amount: Decimal) -> Decimal? {
        var value = amount, rounded = Decimal()
        NSDecimalRound(&rounded, &value, 2, .plain)
        return rounded.isNaN ? nil : rounded
    }
}

nonisolated enum HoldingMutations {
    /// Recompute stored daily values from a day in the past, after a backdated quantity or balance.
    static func rebuildHistory(from start: Date, to end: Date? = nil, document: VaultDocument, now: Date) -> VaultDocument {
        var next = document
        next.dropUnstoredValuations()
        let scopes = next.valuationScopes
        let first = max(UTCDay.start(of: start), UTCDay.start(of: now).addingTimeInterval(-2200 * 86400))
        let last = min(UTCDay.start(of: now), end.map { UTCDay.start(of: $0) } ?? UTCDay.start(of: now))
        // Old samples for these days no longer describe the holdings held then; drop them
        // so a day without saved prices shows as a gap rather than a wrong value.
        next.dailyValuations.removeAll { let day = UTCDay.start(of: $0.utcDay); return day >= first && day < last }
        // Only the saved days change below, so one index serves every day.
        let index = ValuationIndex(document: next)
        var day = first
        while day < last {
            let at = day.addingTimeInterval(86400 - 1)
            // Every scope is valued before the day's samples are added, and each (day, scope) is written once.
            let samples = scopes.compactMap { NetWorthCalculator.rebuiltSample(at: at, scope: $0, document: next, now: now, index: index) }
            next.dailyValuations.append(contentsOf: samples)
            day = day.addingTimeInterval(86400)
        }
        return next
    }
    static func setQuantity(
        holdingID: UUID,
        quantity: Decimal,
        at date: Date,
        document: VaultDocument,
        recordedAt: Date = Date()
    ) throws -> VaultDocument {
        try MoneyInput.requireNonNegativeFinite(quantity)
        guard let index = document.holdings.firstIndex(where: { $0.id == holdingID }) else { throw VaultError.unknownHolding }
        // A dated total may be inserted before later observations: it states what was held on that day.
        var next = document
        if next.holdings[index].createdAt > date { next.holdings[index].createdAt = date }
        if let portfolioIndex = next.portfolios.firstIndex(where: { $0.id == next.holdings[index].portfolioID }), next.portfolios[portfolioIndex].createdAt > date {
            next.portfolios[portfolioIndex].createdAt = date
        }
        let ordinal = next.nextOrdinal
        next.nextOrdinal += 1
        next.quantities.append(
            QuantityObservation(
                holdingID: holdingID,
                quantity: PreciseDecimal(quantity),
                effectiveAt: date,
                recordedAt: recordedAt,
                ordinal: ordinal
            )
        )
        return next
    }

    static func archivePortfolio(id: UUID, at date: Date, document: VaultDocument) throws -> VaultDocument {
        guard document.portfolio(id: id) != nil else { throw VaultError.unknownPortfolio }
        var next = document
        if let index = next.portfolios.firstIndex(where: { $0.id == id }) {
            next.portfolios[index].archivedAt = date
        }
        return next
    }

    static func moveHolding(
        assetID: CanonicalAssetID,
        quantity: Decimal,
        from sourceID: UUID,
        to destinationID: UUID,
        at date: Date,
        document: VaultDocument,
        recordedAt: Date = Date()
    ) throws -> VaultDocument {
        try MoneyInput.requirePositiveFinite(quantity)
        guard sourceID != destinationID else { throw VaultError.samePortfolio }
        guard let source = document.portfolio(id: sourceID), source.isActive(at: date) else {
            throw VaultError.unknownPortfolio
        }
        guard let destination = document.portfolio(id: destinationID), destination.isActive(at: date) else {
            throw VaultError.unknownPortfolio
        }
        guard source.kind == destination.kind else { throw VaultError.invalidAssetID }

        guard let sourceHolding = document.holdings.first(where: {
            $0.portfolioID == sourceID && $0.assetID == assetID && $0.isActive(at: date)
        }) else { throw VaultError.unknownHolding }

        let available = document.effectiveQuantity(holdingID: sourceHolding.id, at: date) ?? 0
        guard available >= quantity else { throw VaultError.insufficientQuantity }

        var next = document
        let firstOrdinal = next.nextOrdinal
        next.nextOrdinal += 1
        next.quantities.append(
            QuantityObservation(
                holdingID: sourceHolding.id,
                quantity: PreciseDecimal(try MoneyInput.add(available, -quantity)),
                effectiveAt: date,
                recordedAt: recordedAt,
                ordinal: firstOrdinal
            )
        )

        let destHolding: Holding
        if let existing = next.holdings.first(where: {
            $0.portfolioID == destinationID && $0.assetID == assetID && $0.isActive(at: date)
        }) {
            destHolding = existing
        } else {
            destHolding = Holding(
                portfolioID: destinationID,
                assetID: assetID,
                assetName: sourceHolding.assetName,
                createdAt: date
            )
            next.holdings.append(destHolding)
        }
        let destQuantity = next.effectiveQuantity(holdingID: destHolding.id, at: date) ?? 0
        let secondOrdinal = next.nextOrdinal
        next.nextOrdinal += 1
        next.quantities.append(
            QuantityObservation(
                holdingID: destHolding.id,
                quantity: PreciseDecimal(try MoneyInput.add(destQuantity, quantity)),
                effectiveAt: date,
                recordedAt: recordedAt,
                ordinal: secondOrdinal
            )
        )
        // What the moved coins cost goes with them, worked out from the source as it stood before the move.
        if let lot = HoldingPerformance.carriedLot(moving: quantity, from: sourceHolding.id, to: destHolding.id, at: date, document: document) {
            next.purchases = (next.purchases ?? []) + [lot]
        }
        return next
    }

    static func addHolding(
        portfolioID: UUID,
        assetID: CanonicalAssetID,
        assetName: String,
        quantity: Decimal,
        at date: Date,
        document: VaultDocument
    ) throws -> VaultDocument {
        try MoneyInput.requireNonNegativeFinite(quantity)
        guard let portfolio = document.portfolio(id: portfolioID), portfolio.archivedAt.map({ date < $0 }) ?? true else {
            throw VaultError.unknownPortfolio
        }
        guard (PreciousMetal.asset(assetID) != nil) == (portfolio.kind == .metals) else { throw VaultError.invalidAssetID }
        var next = document
        if let existing = next.holdings.first(where: {
            $0.portfolioID == portfolioID && $0.assetID == assetID && $0.archivedAt.map { date < $0 } ?? true
        }) {
            return try setQuantity(holdingID: existing.id, quantity: quantity, at: date, document: next)
        }
        // A purchase dated before the portfolio existed moves its start back to that day.
        if let portfolioIndex = next.portfolios.firstIndex(where: { $0.id == portfolioID }), next.portfolios[portfolioIndex].createdAt > date {
            next.portfolios[portfolioIndex].createdAt = date
        }
        let holding = Holding(portfolioID: portfolioID, assetID: assetID, assetName: assetName, createdAt: date)
        next.holdings.append(holding)
        let ordinal = next.nextOrdinal
        next.nextOrdinal += 1
        next.quantities.append(
            QuantityObservation(
                holdingID: holding.id,
                quantity: PreciseDecimal(quantity),
                effectiveAt: date,
                recordedAt: date,
                ordinal: ordinal
            )
        )
        return next
    }
}


/// Raw observations and stored snapshots stay full-value. Ownership is applied
/// at the observation date when presenting personal wealth, including old samples.
nonisolated enum AssetOwnership {
    static func month(at date: Date) -> MonthKey { MonthKey.current(now: date) }
    /// The Wise profile's name: everything before " · currency" (and before a jar's name after that).
    static func profileName(_ account: Account) -> String {
        guard account.externalProfileID != nil, let range = account.name.range(of: " · " + account.currency) else { return account.name }
        return String(account.name[..<range.lowerBound])
    }
    /// A Wise jar's name, when the account is a jar rather than the profile's main balance.
    static func jarName(_ account: Account) -> String? {
        guard account.externalProfileID != nil, let range = account.name.range(of: " · " + account.currency + " · ") else { return nil }
        let jar = String(account.name[range.upperBound...])
        return jar.isEmpty ? nil : jar
    }
    static func businessID(for account: Account, in document: VaultDocument) -> String? {
        if let explicit = account.ownerBusinessID { return explicit.isEmpty ? nil : explicit }
        // Only a connected bank profile is named after its company; a typed-in account name is not evidence.
        guard account.externalProfileID != nil else { return nil }
        return (document.businessAccounting ?? []).first {
            $0.name.caseInsensitiveCompare(profileName(account)) == .orderedSame
        }?.id
    }
    static func businessID(for component: ValuationComponent, in document: VaultDocument) -> String? {
        if component.kind == .bank {
            return document.accounts.first { $0.id == component.id }.flatMap { businessID(for: $0, in: document) }
        }
        return document.holdings.first { $0.id == component.id }
            .flatMap { document.portfolio(id: $0.portfolioID)?.ownerBusinessID }
    }
    static func sum(_ components: [ValuationComponent]) -> Decimal? {
        guard components.allSatisfy({ $0.usdValue != nil && $0.missing == nil }) else { return nil }
        return try? components.reduce(Decimal.zero) { try MoneyInput.add($0, $1.usdValue!.value, allowingRounding: true) }
    }
    static func personalTotal(_ components: [ValuationComponent], at date: Date, document: VaultDocument) -> Decimal? {
        let groups = Dictionary(grouping: components) { businessID(for: $0, in: document) ?? "" }
        var total = Decimal.zero
        for (owner, values) in groups {
            guard let full = sum(values) else { return nil }
            let share: Decimal
            if owner.isEmpty { share = full }
            else {
                guard let book = document.businessAccounting?.first(where: { $0.id == owner }),
                      let ownership = book.ownership(at: month(at: date).description),
                      let portion = try? ownership.portion(full) else { return nil }
                share = portion
            }
            guard let next = try? MoneyInput.add(total, share, allowingRounding: true) else { return nil }; total = next
        }
        return total
    }
    static func personalValue(at date: Date, scope: ValuationScope, document: VaultDocument, now: Date = Date()) -> ValuationResult {
        var raw = NetWorthCalculator.value(at: date, scope: scope, document: document, now: now)
        if raw.total != nil {
            raw.total = personalTotal(raw.components, at: date, document: document)
            if raw.total == nil { raw.missing.append(MissingValuation(componentID: UUID(), reason: "ownership")) }
        }
        // Never reuse a legacy full-company headline as a personal fallback.
        raw.lastComplete = raw.total.map { ($0, date) }
        if raw.total == nil {
            let samples = document.dailyValuations.filter {
                $0.scope == scope && $0.isComplete && $0.utcDay <= date && $0.computedAt <= now
            }.sorted { $0.utcDay > $1.utcDay }
            for sample in samples {
                if let total = personalTotal(sample.components, at: sample.utcDay, document: document) {
                    raw.lastComplete = (total, sample.utcDay); break
                }
            }
        }
        return raw
    }
}

nonisolated struct BankBalanceGroup: Identifiable {
    var id: String
    var name: String
    var image: Data?
    var businessID: String?
    var components: [ValuationComponent]
    var total: Decimal? { AssetOwnership.sum(components) }
    /// One row per company, plus a single "Bank balances" row holding every personal account.
    static func groups(_ components: [ValuationComponent], document: VaultDocument) -> [BankBalanceGroup] {
        let accounts = Dictionary(document.accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Dictionary(grouping: components.filter { $0.kind == .bank }) { component in
            accounts[component.id].flatMap { AssetOwnership.businessID(for: $0, in: document) } ?? "personal"
        }.map { id, values in
            let sorted = values.sorted { $0.id.uuidString < $1.id.uuidString }
            let account = sorted.first.flatMap { accounts[$0.id] }
            if id == "personal" { return BankBalanceGroup(id: id, name: "Bank balances", image: nil, businessID: nil, components: sorted) }
            return BankBalanceGroup(id: id, name: account.map(AssetOwnership.profileName) ?? "Bank account",
                                    image: account?.profileImage, businessID: id, components: sorted)
        }.sorted {
            if ($0.businessID == nil) != ($1.businessID == nil) { return $0.businessID == nil }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    /// Bank-by-bank breakdown of a group: the Wise profile, Monzo, Card Co, each with its currency balances.
    static func banks(_ components: [ValuationComponent], document: VaultDocument) -> [BankBalanceGroup] {
        let accounts = Dictionary(document.accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Dictionary(grouping: components) { component in accounts[component.id]?.externalProfileID.map { "wise:" + $0 } ?? component.id.uuidString }
            .map { id, values in
                let sorted = values.sorted { ($0.usdValue?.value ?? -1) > ($1.usdValue?.value ?? -1) }
                let account = sorted.first.flatMap { accounts[$0.id] }
                // A Wise profile is just "Wise" here: the personal one is called Personal by Wise, and a company's
                // profile carries the company's name, which the page already shows.
                let name = account.map { $0.externalProfileID == nil ? $0.name : "Wise" } ?? "Bank account"
                return BankBalanceGroup(id: id, name: name, image: account?.profileImage, businessID: nil, components: sorted)
            }.sorted { ($0.total ?? -1) > ($1.total ?? -1) }
    }
}

/// Rebuilds an account's balance history from its statements. One real balance (typed in or synced) anchors the
/// series; every transaction with a known day moves it. Days before the earliest statement stay unknown, and a
/// statement account is only anchored by a balance from within a month of its last statement day.
nonisolated enum BalanceReconstruction {
    static let source = "Statements"
    static func signed(_ entry: Entry) -> Decimal? {
        if let outflow = entry.outflow { return outflow ? -entry.amount : entry.amount }
        switch entry.kind { case .expense: return -entry.amount; case .income, .refund: return entry.amount; case .transfer: return nil }
    }
    static func dayFormatter() -> DateFormatter {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = UTCDay.timeZone; formatter.dateFormat = "yyyy-MM-dd"; return formatter
    }
    /// Derived end-of-day balances for one account, or nil when there is no anchor or no dated statements.
    static func derive(accountID: UUID, document: VaultDocument, now: Date = Date()) -> [BankBalanceObservation]? {
        guard let account = document.accounts.first(where: { $0.id == accountID }) else { return nil }
        let formatter = dayFormatter()
        var byDay: [Date: Decimal] = [:]
        // Statement rows name the account directly; Wise activity belongs to the profile's balance in its currency.
        // Wise activity is money moving through the main balance; a jar's balance comes only from the sync.
        // Rows in another currency don't move this balance.
        let wisePrefix = AssetOwnership.jarName(account) == nil ? account.externalProfileID.map { "wise:" + $0 + ":" } : nil
        for entry in document.entries where entry.currency == account.currency && (entry.accountID == accountID
            || (wisePrefix != nil && entry.source == .wise && entry.sourceRef?.hasPrefix(wisePrefix!) == true)) {
            guard let text = entry.day, let day = formatter.date(from: text), let amount = signed(entry) else { continue }
            byDay[day, default: 0] += amount
        }
        guard let lastDay = byDay.keys.max() else { return nil }
        // Wise syncs every day. Statements only cover up to their last transaction: a balance from weeks later
        // would stretch them across months nobody imported, so it can't anchor them.
        // A month allows for a statement imported a week or two after it ends (Monzo's ended Aug 30 and its balance
        // was typed in on Sep 9); a week dropped months of real history.
        let reach = account.externalProfileID == nil ? lastDay.addingTimeInterval(31 * 86400) : Date.distantFuture
        guard let anchor = document.bankBalances.filter({ $0.accountID == accountID && $0.source != source && $0.observedAt < reach })
            .max(by: { $0.observedAt < $1.observedAt }) else { return nil }
        let anchorDay = UTCDay.start(of: anchor.observedAt)
        var result: [BankBalanceObservation] = []
        // Backwards: the balance at the end of day D is the anchor less everything that happened after D,
        // up to and including the anchor's own day.
        var running = anchor.amount.value
        for day in byDay.keys.filter({ $0 <= anchorDay }).sorted(by: >) {
            if day < anchorDay { result.append(observation(account, amount: running, day: day, now: now)) }
            running -= byDay[day] ?? 0
        }
        // Forwards: statements newer than the anchor extend it, but not across a month or more with no statement rows:
        // that's months nobody imported, and carrying the balance over them would invent one. (Wise syncs everything,
        // so a quiet month there is real and its history carries on.)
        var forward = anchor.amount.value, previousDay = anchorDay
        for day in byDay.keys.filter({ $0 > anchorDay }).sorted() {
            if account.externalProfileID == nil, day.timeIntervalSince(previousDay) > 31 * 86400 { break }
            forward += byDay[day] ?? 0
            result.append(observation(account, amount: forward, day: day, now: now))
            previousDay = day
        }
        return result.sorted { $0.observedAt < $1.observedAt }
    }
    private static func observation(_ account: Account, amount: Decimal, day: Date, now: Date) -> BankBalanceObservation {
        BankBalanceObservation(id: UUID(), accountID: account.id, amount: PreciseDecimal(amount), currency: account.currency,
                               observedAt: min(day.addingTimeInterval(86400 - 1), now), source: source, sourceIdentity: account.id.uuidString + ":derived")
    }
    /// Replaces derived balances for the given accounts and returns the earliest day whose history changed,
    /// or nil when nothing changed.
    static func apply(accountIDs: Set<UUID>, to document: inout VaultDocument, now: Date = Date()) -> Date? {
        var earliest: Date?
        for accountID in accountIDs {
            let previous = document.bankBalances.filter { $0.accountID == accountID && $0.source == source }.sorted { $0.observedAt < $1.observedAt }
            let derived = derive(accountID: accountID, document: document, now: now) ?? []
            // Rows match by day and amount: today's row is stamped with the time it was derived, which alone is no change,
            // so an unchanged series keeps its saved rows.
            let unchanged = previous.count == derived.count && zip(previous, derived).allSatisfy { UTCDay.isSameDay($0.observedAt, $1.observedAt) && $0.amount.value == $1.amount.value }
            if !unchanged {
                document.bankBalances.removeAll { $0.accountID == accountID && $0.source == source }
                document.bankBalances.append(contentsOf: derived)
                if let first = (previous.map(\.observedAt) + derived.map(\.observedAt)).min() { earliest = min(earliest ?? first, first) }
            }
            // Net worth only counts an account from the day tracking began; the rebuilt history starts earlier.
            // Checked even for an unchanged series, so a series saved before this rule gets its tracking fixed.
            // Later tracking changes stay: they still decide the days after them.
            if let firstDerived = derived.first?.observedAt, document.isBankTracked(accountID, at: now),
               document.backdateBankTracking(accountID, to: UTCDay.start(of: firstDerived)) {
                earliest = min(earliest ?? firstDerived, firstDerived)
            }
        }
        return earliest
    }
}

/// A change over the chart's range: today's figure against the one the range starts from.
nonisolated struct PeriodChange: Equatable {
    var amount: Decimal
    /// Nil when the range started from nothing.
    var fraction: Decimal?
    /// The figure the range started from.
    var previous: Decimal
    init(from previous: Decimal, to current: Decimal) {
        self.previous = previous
        amount = current - previous
        fraction = previous > 0 ? (current - previous) / previous : nil
    }
    /// Only the parts there both then and now: an account or coin added during the range isn't a gain, nor one gone
    /// since a loss. Nil when no part is in both, or one of them can't be valued on either side.
    init?(parts current: [ValuationComponent], then earlier: [ValuationComponent]) {
        let before = Set(earlier.map(\.id)), after = Set(current.map(\.id))
        let kept = current.filter { before.contains($0.id) }, was = earlier.filter { after.contains($0.id) }
        guard !kept.isEmpty, let now = AssetOwnership.sum(kept), let then = AssetOwnership.sum(was) else { return nil }
        self.init(from: then, to: now)
    }
}

extension HoldingPerformance {
    /// Profit against what was paid, over the holdings whose purchases cover what's held now. `covered` of `total`
    /// holdings count; nil when none has a recorded cost. Only holdings valued in USD today are considered.
    static func scope(_ components: [ValuationComponent], document: VaultDocument, at date: Date) -> (gain: Decimal, cost: Decimal, covered: Int, total: Int)? {
        total(components.filter { $0.kind == .holding && $0.usdValue != nil }.map { summary(holdingID: $0.id, valueUSD: $0.usdValue?.value, document: document, at: date) })
    }
    /// The same from summaries already worked out, one per holding valued in USD.
    static func total(_ summaries: [HoldingPerformance]) -> (gain: Decimal, cost: Decimal, covered: Int, total: Int)? {
        var gain = Decimal(0), cost = Decimal(0), covered = 0
        for summary in summaries {
            guard let paid = summary.costUSD, let profit = summary.gainUSD else { continue }
            gain += profit; cost += paid; covered += 1
        }
        return covered > 0 ? (gain, cost, covered, summaries.count) : nil
    }
}

/// Everything a chart needs to value a saved day in full. A saved day can lack a coin's price or a currency's rate
/// (not saved that day), an account's balance (none recorded yet), or a company's ownership share (not recorded for
/// that month). Leaving such a day out, or counting only what has a value, is what made charts dip, jump or cut
/// straight across months. Each gap is estimated from the nearest saved values instead, and named, so the hover can
/// say what was estimated. The saved days themselves are never changed.
nonisolated struct ChartEstimates {
    /// How far from a saved value a price, rate or balance may be carried when there is nothing on the other side,
    /// and the longest gap a price or rate is drawn across.
    static let window: TimeInterval = 90 * 86400
    /// A saved value this close is used as it is, rather than drawn between its neighbours.
    static let near: TimeInterval = 3 * 86400
    typealias Series = [(time: Date, value: Decimal)]
    private var quotes: [String: Series] = [:]
    private var rates: [String: Series] = [:]
    private var balances: [UUID: [(time: Date, value: Decimal, currency: String)]] = [:]
    private var assets: [UUID: CanonicalAssetID] = [:]
    /// Each account's or holding's company ("" for yours), worked out once rather than per day.
    private var owners: [UUID: String] = [:]
    private var books: [String: BusinessBook] = [:]
    init(document: VaultDocument) {
        for quote in document.quotes { quotes[quote.assetID.rawValue, default: []].append((quote.providerTime, quote.priceUSD.value)) }
        for key in quotes.keys { quotes[key]?.sort { $0.time < $1.time } }
        for rate in document.fx where rate.targetCurrency == "USD" { rates[rate.sourceCurrency, default: []].append((rate.providerTime, rate.rate.value)) }
        for key in rates.keys { rates[key]?.sort { $0.time < $1.time } }
        for balance in document.bankBalances { balances[balance.accountID, default: []].append((balance.observedAt, balance.amount.value, balance.currency)) }
        for key in balances.keys { balances[key]?.sort { $0.time < $1.time } }
        assets = Dictionary(document.holdings.map { ($0.id, $0.assetID) }, uniquingKeysWith: { first, _ in first })
        for account in document.accounts { owners[account.id] = AssetOwnership.businessID(for: account, in: document) ?? "" }
        let portfolioOwner = Dictionary(document.portfolios.map { ($0.id, $0.ownerBusinessID ?? "") }, uniquingKeysWith: { first, _ in first })
        for holding in document.holdings { owners[holding.id] = portfolioOwner[holding.portfolioID] ?? "" }
        books = Dictionary((document.businessAccounting ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
    /// The observation nearest `moment` within `window`, the earlier one on a tie.
    static func nearest(_ series: Series, to moment: Date, within window: TimeInterval = window) -> (time: Date, value: Decimal)? {
        let (before, after) = neighbours(series, moment)
        let pick: (time: Date, value: Decimal)?
        switch (before, after) {
        case let (b?, a?): pick = moment.timeIntervalSince(b.time) <= a.time.timeIntervalSince(moment) ? b : a
        case let (b?, nil): pick = b
        case let (nil, a?): pick = a
        default: pick = nil
        }
        guard let pick, abs(pick.time.timeIntervalSince(moment)) <= window else { return nil }
        return pick
    }
    /// The latest observation at or before `moment`, or the first when `moment` comes before them all.
    static func latest(_ series: Series, at moment: Date) -> Decimal? {
        let (before, after) = neighbours(series, moment)
        return before?.value ?? after?.value
    }
    /// A price or rate for a moment: a saved one within `near`; otherwise a straight line between the saved ones on
    /// either side when they're at most `window` apart; otherwise, with nothing on one side, the nearest within
    /// `window`. A longer gap between saved values stays a gap. Returns the dates it came from.
    static func estimate(_ series: Series, at moment: Date) -> (value: Decimal, from: Date, to: Date?)? {
        if let close = nearest(series, to: moment, within: near) { return (close.value, close.time, nil) }
        let (before, after) = neighbours(series, moment)
        if let before, let after {
            let span = after.time.timeIntervalSince(before.time)
            guard span <= window else { return nil }
            let part = Decimal(moment.timeIntervalSince(before.time) / span)
            return (before.value + (after.value - before.value) * part, before.time, after.time)
        }
        return nearest(series, to: moment).map { ($0.value, $0.time, nil) }
    }
    private static func neighbours(_ series: Series, _ moment: Date) -> (before: (time: Date, value: Decimal)?, after: (time: Date, value: Decimal)?) {
        var low = 0, high = series.count
        while low < high { let mid = (low + high) / 2; if series[mid].time <= moment { low = mid + 1 } else { high = mid } }
        return (low > 0 ? series[low - 1] : nil, low < series.count ? series[low] : nil)
    }
    private static func source(_ found: (value: Decimal, from: Date, to: Date?), _ noun: String) -> String {
        found.to.map { " between its " + dayName(found.from) + " and " + dayName($0) + " " + noun + "s" } ?? " at its " + dayName(found.from) + " " + noun
    }
    /// The day's components with each missing price, rate or balance estimated, the names of what was estimated, and
    /// whether every part now has a value.
    /// `moment` is when within the day to estimate for: midday unless given (an hour of the 24-hour chart).
    func filled(_ components: [ValuationComponent], day: Date, at moment: Date? = nil) -> (components: [ValuationComponent], estimated: [String], complete: Bool) {
        let moment = moment ?? UTCDay.start(of: day).addingTimeInterval(12 * 3600)
        var result: [ValuationComponent] = [], estimated: [String] = [], complete = true
        for component in components {
            guard component.missing != nil || component.usdValue == nil else { result.append(component); continue }
            var copy = component, note: String?
            switch (component.kind, component.missing) {
            case (.holding, "quote"?):
                if let amount = component.nativeAmount?.value, let id = assets[component.id], let series = quotes[id.rawValue], let found = Self.estimate(series, at: moment),
                   let usd = try? MoneyInput.multiply(amount, found.value, allowingRounding: true) {
                    copy.usdValue = PreciseDecimal(usd); copy.quoteTime = found.from; note = component.label + Self.source(found, "price")
                }
            case (.bank, "fx"?):
                if let amount = component.nativeAmount?.value, let series = rates[component.currency], let found = Self.estimate(series, at: moment),
                   let usd = try? MoneyInput.multiply(amount, found.value, allowingRounding: true) {
                    copy.usdValue = PreciseDecimal(usd); copy.fxTime = found.from; note = component.label + Self.source(found, "rate")
                }
            case (.bank, "balance"?):
                // No balance recorded yet on this day: the first one recorded after it, within the window.
                if let later = balances[component.id]?.first(where: { $0.time > moment && $0.time.timeIntervalSince(moment) <= Self.window }),
                   let rate = later.currency == "USD" ? Decimal(1) : rates[later.currency].flatMap({ Self.estimate($0, at: moment)?.value }),
                   let usd = try? MoneyInput.multiply(later.value, rate, allowingRounding: true) {
                    copy.nativeAmount = PreciseDecimal(later.value); copy.usdValue = PreciseDecimal(usd)
                    note = component.label + " at its " + Self.dayName(later.time) + " balance"
                }
            default: break
            }
            guard let note else { result.append(component); complete = false; continue }
            copy.missing = nil
            result.append(copy); estimated.append(note)
        }
        return (result, estimated, complete)
    }
    /// A day's full total, every part estimated where it must be. Nil when a part still can't be valued.
    func total(_ components: [ValuationComponent], day: Date, at moment: Date? = nil) -> (total: Decimal, estimated: [String])? {
        let day = filled(components, day: day, at: moment)
        guard day.complete, let total = AssetOwnership.sum(day.components) else { return nil }
        return (total, day.estimated)
    }
    /// Your share of a day: a company's parts at its ownership that month, or at the nearest month recorded when
    /// that one isn't. Nil when a part still can't be valued or a company has no ownership recorded at all.
    func personalTotal(_ components: [ValuationComponent], day: Date, at moment: Date? = nil) -> (total: Decimal, estimated: [String])? {
        let filled = filled(components, day: day, at: moment)
        guard filled.complete else { return nil }
        var estimated = filled.estimated, total = Decimal.zero
        let month = AssetOwnership.month(at: day).description
        for (owner, parts) in Dictionary(grouping: filled.components, by: { owners[$0.id] ?? "" }) {
            guard let full = AssetOwnership.sum(parts) else { return nil }
            var share = full
            if !owner.isEmpty {
                guard let book = books[owner] else { return nil }
                var ownership = book.ownership(at: month)
                if ownership == nil, let first = book.ownership.min(by: { $0.fromMonth < $1.fromMonth }) {
                    ownership = first
                    estimated.append(book.name + " at your " + (MonthKey(first.fromMonth)?.title ?? first.fromMonth) + " share of " + first.label)
                }
                guard let ownership, let portion = try? ownership.portion(full) else { return nil }
                share = portion
            }
            guard let next = try? MoneyInput.add(total, share, allowingRounding: true) else { return nil }
            total = next
        }
        return (total, estimated)
    }
    /// A coin or metal's price now against its price nearest `start`, as a fraction; nil without both.
    func priceChange(_ assetID: CanonicalAssetID, since start: Date, now: Date) -> Decimal? {
        guard let series = quotes[assetID.rawValue], let then = Self.nearest(series, to: start), then.value > 0,
              let latest = series.last(where: { $0.time <= now }), latest.time > then.time else { return nil }
        return (latest.value - then.value) / then.value
    }
    static func dayName(_ date: Date) -> String { dayFormatter.string(from: date) }
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US")
        formatter.calendar = UTCDay.calendar; formatter.timeZone = UTCDay.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()
}
