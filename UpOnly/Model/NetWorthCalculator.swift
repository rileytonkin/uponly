import Foundation

struct MissingValuation: Sendable, Equatable {
    var componentID: UUID
    var reason: String
}

struct StaleValuation: Sendable, Equatable {
    var componentID: UUID
    var asOf: Date
}

struct BalanceChange: Sendable, Equatable {
    var kind: BalanceChangeKind
    var amount: Decimal
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

    var needsUpdate: Bool { total == nil && lastComplete != nil }
}

nonisolated enum NetWorthCalculator {
    static func value(
        at date: Date,
        scope: ValuationScope,
        document: VaultDocument,
        now: Date = Date()
    ) -> ValuationResult {
        let day = UTCDay.start(of: date)
        let isHistorical = day < UTCDay.start(of: now)
        if isHistorical, let stored = document.storedValuation(day: day, scope: scope), stored.isComplete {
            return result(from: stored, at: date)
        }
        return compute(at: date, scope: scope, document: document, now: now, historical: isHistorical)
    }

    static func change(from: ValuationResult, to: ValuationResult) -> BalanceChange? {
        guard from.scope == to.scope,
              from.includedAccountIDs == to.includedAccountIDs,
              from.includedPortfolioIDs == to.includedPortfolioIDs,
              let a = from.total, let b = to.total else { return nil }
        guard let amount = try? MoneyInput.add(b, -a) else { return nil }
        return BalanceChange(kind: .change, amount: amount)
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
        guard let incoming = sample(from: result) else { return document }
        var next = document
        let day = UTCDay.start(of: result.at)
        if !incoming.isComplete {
            let hasComplete = next.dailyValuations.contains {
                UTCDay.start(of: $0.utcDay) == day && $0.scope == result.scope && $0.isComplete
            }
            if hasComplete { return next }
        }
        // A complete value supersedes earlier partial attempts for the day; partial ones only replace each other.
        next.dailyValuations.removeAll {
            UTCDay.start(of: $0.utcDay) == day && $0.scope == result.scope && (incoming.isComplete || !$0.isComplete)
        }
        next.dailyValuations.append(incoming)
        return next
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
        historical: Bool
    ) -> ValuationResult {
        var missing: [MissingValuation] = []
        var stale: [StaleValuation] = []
        let banks: [ValuationComponent]
        let holdings: [ValuationComponent]
        switch scope {
        case .allTracked:
            banks = bankComponents(at: date, document: document, now: now, historical: historical, missing: &missing, stale: &stale)
            holdings = holdingComponents(at: date, scope: scope, document: document, now: now, historical: historical, missing: &missing, stale: &stale)
        case .banks:
            banks = bankComponents(at: date, document: document, now: now, historical: historical, missing: &missing, stale: &stale)
            holdings = []
        case .portfolio:
            banks = []
            holdings = holdingComponents(at: date, scope: scope, document: document, now: now, historical: historical, missing: &missing, stale: &stale)
        }
        let components = banks + holdings
        let includedAccounts = includedAccountIDs(scope: scope, document: document, at: date)
        let includedPortfolios = includedPortfolioIDs(scope: scope, document: document, at: date)
        let observed = hasObservation(scope: scope, document: document, at: date, includedAccounts: includedAccounts, includedPortfolios: includedPortfolios)
        if !observed {
            return ValuationResult(
                at: date,
                scope: scope,
                components: [],
                total: nil,
                lastComplete: lastCompleteSample(in: document, scope: scope, at: date),
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
                total = try components.reduce(Decimal(0)) { try MoneyInput.add($0, $1.usdValue?.value ?? 0) }
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
            lastComplete: total == nil ? lastCompleteSample(in: document, scope: scope, at: date) : (total!, date),
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
        document.dailyValuations
            .filter {
                $0.scope == scope && $0.isComplete && $0.computedAt <= date && UTCDay.start(of: $0.utcDay) <= UTCDay.start(of: date)
            }
            .sorted { lhs, rhs in
                if lhs.computedAt != rhs.computedAt { return lhs.computedAt < rhs.computedAt }
                return lhs.utcDay < rhs.utcDay
            }
            .last
            .flatMap { sample in
                sample.total.map { ($0.value, sample.computedAt) }
            }
    }

    private static func includedAccountIDs(scope: ValuationScope, document: VaultDocument, at date: Date) -> [UUID] {
        switch scope {
        case .portfolio: return []
        case .allTracked, .banks:
            return document.accounts.map(\.id).filter { document.isBankTracked($0, at: date) }.sorted { $0.uuidString < $1.uuidString }
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
        document: VaultDocument,
        at date: Date,
        includedAccounts: [UUID],
        includedPortfolios: [UUID]
    ) -> Bool {
        let hasBank = includedAccounts.contains { accountID in
            document.bankBalances.contains { $0.accountID == accountID && $0.observedAt <= date }
        }
        let holdings = document.holdings.filter { includedPortfolios.contains($0.portfolioID) }
        let hasQuantity = holdings.contains { holding in
            document.quantities.contains { $0.holdingID == holding.id && $0.effectiveAt <= date }
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
        now: Date,
        historical: Bool,
        missing: inout [MissingValuation],
        stale: inout [StaleValuation]
    ) -> [ValuationComponent] {
        var result: [ValuationComponent] = []
        for account in document.accounts where document.isBankTracked(account.id, at: date) {
            let observation = latestBalance(accountID: account.id, at: date, document: document)
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
                document: document,
                historical: historical
            )
            var isStale = false
            if now.timeIntervalSince(observation.observedAt) > VaultLimits.bankStaleAfter {
                isStale = true
                stale.append(StaleValuation(componentID: account.id, asOf: observation.observedAt))
            }
            if let fxStale = converted.fxTime,
               observation.currency != "USD",
               now.timeIntervalSince(fxStale) > VaultLimits.fxStaleAfter {
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
            for holding in document.activeHoldings(in: portfolio.id, at: date) {
                guard let quantity = document.effectiveQuantity(holdingID: holding.id, at: date) else {
                    continue
                }
                if quantity == 0 { continue }
                let quote = latestQuote(
                    assetID: holding.assetID,
                    at: date,
                    document: document,
                    historical: historical
                )
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
                    usd = PreciseDecimal(try MoneyInput.multiply(quantity, quote.priceUSD.value))
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

    private static func latestBalance(
        accountID: UUID,
        at date: Date,
        document: VaultDocument
    ) -> BankBalanceObservation? {
        document.bankBalances
            .filter { $0.accountID == accountID && $0.observedAt <= date }
            .sorted { $0.observedAt < $1.observedAt }
            .last
    }

    private static func latestQuote(
        assetID: CanonicalAssetID,
        at date: Date,
        document: VaultDocument,
        historical: Bool
    ) -> QuoteObservation? {
        let candidates = document.quotes.filter { $0.assetID == assetID && $0.providerTime <= date }
        if historical {
            return candidates
                .filter { UTCDay.isSameDay($0.providerTime, date) }
                .sorted { $0.providerTime < $1.providerTime }
                .last
        }
        return candidates.sorted { $0.providerTime < $1.providerTime }.last
    }

    private static func convert(
        amount: Decimal,
        currency: String,
        at date: Date,
        document: VaultDocument,
        historical: Bool
    ) -> (usd: Decimal?, fxTime: Date?, missing: String?) {
        if currency == "USD" || amount == 0 {
            return (amount, nil, nil)
        }
        let candidates = document.fx.filter {
            $0.sourceCurrency == currency
                && $0.targetCurrency == "USD"
                && $0.providerTime <= date
        }
        let match: FXObservation?
        if historical {
            match = candidates
                .filter { date.timeIntervalSince($0.providerTime) <= 7 * 86400 }
                .sorted { $0.providerTime < $1.providerTime }
                .last
        } else {
            match = candidates.sorted { $0.providerTime < $1.providerTime }.last
        }
        guard let match else { return (nil, nil, "fx") }
        do {
            return (try MoneyInput.multiply(amount, match.rate.value), match.providerTime, nil)
        } catch {
            return (nil, match.providerTime, "overflow")
        }
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
    static func summary(holdingID: UUID, valueUSD: Decimal?, document: VaultDocument, at date: Date = Date()) -> HoldingPerformance {
        var result = HoldingPerformance()
        result.since = document.quantities.filter { $0.holdingID == holdingID }.map(\.effectiveAt).min()
        let lots = (document.purchases ?? []).filter { $0.holdingID == holdingID && $0.at <= date }
        guard !lots.isEmpty else { return result }
        var total: Decimal = 0
        var convertible = true
        for lot in lots {
            guard let rate = MonthlyLedger.rate(currency: lot.currency, month: AssetOwnership.month(at: lot.at), document: document, now: date),
                  let usd = try? MoneyInput.multiply(lot.paid.value, rate), let sum = try? MoneyInput.add(total, usd) else { convertible = false; break }
            total = sum
        }
        if convertible {
            result.costUSD = total
            if let valueUSD, let gain = try? MoneyInput.add(valueUSD, -total) {
                result.gainUSD = gain
                if total > 0 { result.returnFraction = gain / total }
            }
        } else if Set(lots.map(\.currency)).count == 1 {
            var native: Decimal = 0
            for lot in lots { guard let sum = try? MoneyInput.add(native, lot.paid.value) else { return result }; native = sum }
            result.costNative = native; result.costCurrency = lots[0].currency
        }
        return result
    }
}

nonisolated enum HoldingMutations {
    /// Recompute stored daily values from a day in the past, after a backdated quantity or balance.
    static func rebuildHistory(from start: Date, to end: Date? = nil, document: VaultDocument, now: Date) -> VaultDocument {
        var next = document
        let scopes: [ValuationScope] = [.allTracked, .banks] + next.portfolios.map { .portfolio($0.id) }
        let first = max(UTCDay.start(of: start), UTCDay.start(of: now).addingTimeInterval(-2200 * 86400))
        let last = min(UTCDay.start(of: now), end.map { UTCDay.start(of: $0) } ?? UTCDay.start(of: now))
        var day = first
        while day < last {
            // Old samples for the day no longer describe the holdings held then; drop them
            // so a day without saved prices shows as a gap rather than a wrong value.
            next.dailyValuations.removeAll { UTCDay.start(of: $0.utcDay) == day }
            let evaluation = next
            let at = day.addingTimeInterval(86400 - 1)
            for scope in scopes {
                next = NetWorthCalculator.recordingSample(NetWorthCalculator.value(at: at, scope: scope, document: evaluation, now: now), in: next)
            }
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

    static func archiveHolding(id: UUID, at date: Date, document: VaultDocument) throws -> VaultDocument {
        guard document.holding(id: id) != nil else { throw VaultError.unknownHolding }
        var next = document
        if let index = next.holdings.firstIndex(where: { $0.id == id }) {
            next.holdings[index].archivedAt = date
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
    static func month(at date: Date) -> MonthKey {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = UTCDay.timeZone
        return MonthKey.current(now: date, calendar: calendar)
    }
    static func profileName(_ account: Account) -> String {
        var name = account.name
        if account.externalProfileID != nil, name.hasSuffix(" · " + account.currency) {
            name.removeLast(3 + account.currency.count)
        }
        return name
    }
    static func businessID(for account: Account, in document: VaultDocument) -> String? {
        if let explicit = account.ownerBusinessID { return explicit.isEmpty ? nil : explicit }
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
        return try? components.reduce(Decimal.zero) { try MoneyInput.add($0, $1.usdValue!.value) }
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
            guard let next = try? MoneyInput.add(total, share) else { return nil }; total = next
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
        let accounts = Dictionary(uniqueKeysWithValues: document.accounts.map { ($0.id, $0) })
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
    /// Bank-by-bank breakdown of a group: the Wise profile, Monzo, Kast, each with its currency balances.
    static func banks(_ components: [ValuationComponent], document: VaultDocument) -> [BankBalanceGroup] {
        let accounts = Dictionary(uniqueKeysWithValues: document.accounts.map { ($0.id, $0) })
        return Dictionary(grouping: components) { component in accounts[component.id]?.externalProfileID.map { "wise:" + $0 } ?? component.id.uuidString }
            .map { id, values in
                let sorted = values.sorted { ($0.usdValue?.value ?? -1) > ($1.usdValue?.value ?? -1) }
                let account = sorted.first.flatMap { accounts[$0.id] }
                let name = account.map { $0.externalProfileID == nil ? $0.name : AssetOwnership.profileName($0).caseInsensitiveCompare("Personal") == .orderedSame ? "Wise" : AssetOwnership.profileName($0) } ?? "Bank account"
                return BankBalanceGroup(id: id, name: name, image: account?.profileImage, businessID: nil, components: sorted)
            }.sorted { ($0.total ?? -1) > ($1.total ?? -1) }
    }
}

/// Rebuilds an account's balance history from its statements. One real balance (typed in or synced) anchors the
/// series; every transaction with a known day moves it. Days before the earliest statement stay unknown.
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
        guard let account = document.accounts.first(where: { $0.id == accountID }),
              let anchor = document.bankBalances.filter({ $0.accountID == accountID && $0.source != source }).max(by: { $0.observedAt < $1.observedAt }) else { return nil }
        let formatter = dayFormatter()
        var byDay: [Date: Decimal] = [:]
        // Statement rows name the account directly; Wise activity belongs to the profile's balance in its currency.
        let wisePrefix = account.externalProfileID.map { "wise:" + $0 + ":" }
        for entry in document.entries where entry.accountID == accountID
            || (wisePrefix != nil && entry.source == .wise && entry.currency == account.currency && entry.sourceRef?.hasPrefix(wisePrefix!) == true) {
            guard let text = entry.day, let day = formatter.date(from: text), let amount = signed(entry) else { continue }
            byDay[day, default: 0] += amount
        }
        guard !byDay.isEmpty else { return nil }
        let anchorDay = UTCDay.start(of: anchor.observedAt)
        var result: [BankBalanceObservation] = []
        // Backwards: the balance at the end of day D is the anchor less everything that happened after D.
        var running = anchor.amount.value, previousDay = anchorDay
        for day in byDay.keys.filter({ $0 < anchorDay }).sorted(by: >) {
            // Everything after `day` up to and including the anchor's own day has already happened by the anchor.
            running -= byDay.filter { $0.key > day && $0.key <= previousDay }.values.reduce(Decimal(0), +)
            previousDay = day
            result.append(observation(account, amount: running, day: day, now: now))
        }
        // Forwards: statements newer than the anchor extend it.
        var forward = anchor.amount.value
        for day in byDay.keys.filter({ $0 > anchorDay }).sorted() {
            forward += byDay[day] ?? 0
            result.append(observation(account, amount: forward, day: day, now: now))
        }
        return result.sorted { $0.observedAt < $1.observedAt }
    }
    private static func observation(_ account: Account, amount: Decimal, day: Date, now: Date) -> BankBalanceObservation {
        BankBalanceObservation(id: UUID(), accountID: account.id, amount: PreciseDecimal(amount), currency: account.currency,
                               observedAt: min(day.addingTimeInterval(86400 - 1), now), source: source, sourceIdentity: account.id.uuidString + ":derived")
    }
    /// Replaces derived balances for the given accounts and returns the earliest day whose history changed.
    static func apply(accountIDs: Set<UUID>, to document: inout VaultDocument, now: Date = Date()) -> Date? {
        var earliest: Date?
        for accountID in accountIDs {
            let previous = document.bankBalances.filter { $0.accountID == accountID && $0.source == source }
            let derived = derive(accountID: accountID, document: document, now: now) ?? []
            let unchanged = previous.count == derived.count && zip(previous.sorted { $0.observedAt < $1.observedAt }, derived).allSatisfy { $0.observedAt == $1.observedAt && $0.amount.value == $1.amount.value }
            if !unchanged {
                document.bankBalances.removeAll { $0.accountID == accountID && $0.source == source }
                document.bankBalances.append(contentsOf: derived)
                if let first = (previous.map(\.observedAt) + derived.map(\.observedAt)).min() { earliest = min(earliest ?? first, first) }
            }
            // Net worth only counts an account from the day tracking began; the rebuilt history starts earlier.
            // Checked even for an unchanged series, so a series saved before this rule gets its tracking fixed.
            if let firstDerived = derived.map(\.observedAt).min(), document.isBankTracked(accountID, at: now),
               !document.isBankTracked(accountID, at: firstDerived) {
                document.bankTracking.removeAll { $0.accountID == accountID && $0.tracked && $0.effectiveAt > firstDerived }
                document.setBankTracked(accountID, tracked: true, at: UTCDay.start(of: firstDerived))
                earliest = min(earliest ?? firstDerived, firstDerived)
            }
        }
        return earliest
    }
}
