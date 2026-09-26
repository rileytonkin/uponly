import Foundation

nonisolated enum PriceHistory {
    static func requests(document: VaultDocument, now: Date, reconnected: Bool = false) -> [PriceHistoryRequest] {
        let end = UTCDay.start(of: now)
        // Each target's stretches: an asset only while held, so a coin or metal that was sold (its holding or portfolio
        // archived) isn't asked for again after its last day.
        var targets: [(PriceHistoryRequest.Source, String, [(start: Date, end: Date)])] = []
        for group in Dictionary(grouping: document.holdings, by: { $0.assetID.rawValue }) {
            let held = group.value.compactMap { holding -> (start: Date, end: Date)? in
                guard let portfolio = document.portfolio(id: holding.portfolioID) else { return nil }
                let until = [holding.archivedAt, portfolio.archivedAt].compactMap { $0 }.min().map { UTCDay.start(of: $0).addingTimeInterval(86400) } ?? end
                return (UTCDay.start(of: holding.createdAt), min(until, end))
            }
            guard !held.isEmpty else { continue }
            let isMetal = PreciousMetal.asset(CanonicalAssetID(rawValue: group.key)) != nil
            // Gold's history needs no key (Binance's PAXG); other metals need Gold API's, else gaps are filled between saved prices.
            if isMetal && document.settings.automaticMetals && (!document.settings.metalHistoryKey.isEmpty || group.key == PreciousMetal.gold.assetID.rawValue) {
                targets.append((.metal, group.key, held))
            } else if !isMetal && document.settings.automaticPrices && (try? MoneyInput.canonicalAssetID(group.key)) == group.key {
                // CoinGecko's free plan covers the past 365 days; older days come from Binance's daily closes. An ID that
                // isn't a valid coin ID is never asked for.
                targets.append((.crypto, group.key, held))
            }
        }
        if document.settings.automaticFX {
            let currencies = Set(document.accounts.map(\.currency) + document.entries.map(\.currency)).subtracting(["USD"])
            for currency in currencies {
                let balances = document.bankBalances.filter { $0.currency == currency }.map(\.observedAt)
                let entries = document.entries.filter { $0.currency == currency }.compactMap { try? ImportDateFormat.iso.date($0.month + "-01") }
                if let first = (balances + entries).min() { targets.append((.fx, currency, [(UTCDay.start(of: first), end)])) }
            }
        }
        var result: [PriceHistoryRequest] = []
        let accountCurrencies = Set(document.accounts.map(\.currency))
        for (source, identifier, stretches) in targets {
            let key = (source == .fx ? "fx:" : "asset:") + identifier
            let coverage = (document.priceHistoryCoverage ?? []).filter { $0.key == key && ($0.complete || (!reconnected && now.timeIntervalSince($0.checkedAt) < 6 * 3600)) }.sorted { $0.start < $1.start }
            // Held stretches that overlap (two portfolios holding the same coin) are merged, so no day is asked for twice.
            var merged: [(start: Date, end: Date)] = []
            for stretch in stretches.sorted(by: { $0.start < $1.start }) where stretch.start < stretch.end {
                if let last = merged.last, stretch.start <= last.end { merged[merged.count - 1].end = max(last.end, stretch.end) } else { merged.append(stretch) }
            }
            for stretch in merged {
                // Every uncovered stretch, split into 90-day chunks.
                var cursor = stretch.start
                while cursor < stretch.end {
                    if let covering = coverage.first(where: { $0.start <= cursor && $0.end > cursor }) { cursor = covering.end; continue }
                    let gapEnd = min(stretch.end, coverage.first { $0.start > cursor }?.start ?? stretch.end, cursor.addingTimeInterval(90 * 86400))
                    result.append(PriceHistoryRequest(source: source, key: key, identifier: identifier, start: cursor, end: gapEnd))
                    cursor = gapEnd
                }
            }
        }
        // Recent days are what the chart shows first, so newest chunks go first. Currencies of real accounts
        // come before ones that only appear in old entries.
        return result.sorted { a, b in
            let ap = a.source != .fx || accountCurrencies.contains(a.identifier), bp = b.source != .fx || accountCurrencies.contains(b.identifier)
            if ap != bp { return ap }
            return a.end == b.end ? a.key < b.key : a.end > b.end
        }
    }
    static func pricePerGram(_ pricePerOunce: Decimal) throws -> Decimal {
        try MoneyInput.requirePositiveFinite(pricePerOunce)
        var a = pricePerOunce, b = PreciousMetal.gramsPerTroyOunce, raw = Decimal(), rounded = Decimal()
        let status = NSDecimalDivide(&raw, &a, &b, .plain)
        guard status == .noError || status == .lossOfPrecision else { throw PriceError.invalidResponse }
        // Prices are estimates. Weight conversions remain exact; only the derived unit price is rounded.
        NSDecimalRound(&rounded, &raw, 12, .plain)
        try MoneyInput.requirePositiveFinite(rounded)
        return rounded
    }
    struct MetalPrice: Decodable { var symbol: String; var currency: String; var price: Decimal; var updatedAt: String }
    static func decodeMetal(_ data: Data, metal: PreciousMetal, fetchedAt: Date) throws -> QuoteObservation {
        let row = try JSONDecoder().decode(MetalPrice.self, from: data)
        let formatter = ISO8601DateFormatter()
        guard row.symbol == metal.rawValue, row.currency == "USD", let date = formatter.date(from: row.updatedAt), date.timeIntervalSince1970 > 0, date <= fetchedAt.addingTimeInterval(300) else { throw PriceError.invalidResponse }
        return QuoteObservation(assetID: metal.assetID, priceUSD: PreciseDecimal(try pricePerGram(row.price)), providerTime: date, fetchedAt: fetchedAt, provider: "Gold API · spot")
    }
    struct CryptoHistory: Decodable { var prices: [[Decimal?]] }
    static func decodeCrypto(_ data: Data, request: PriceHistoryRequest, fetchedAt: Date) throws -> [QuoteObservation] {
        let response = try JSONDecoder().decode(CryptoHistory.self, from: data)
        guard response.prices.count <= 30000 else { throw PriceError.invalidResponse }
        let asset = try CanonicalAssetID(request.identifier)
        var days: [Date: QuoteObservation] = [:]
        for pair in response.prices {
            try Task.checkCancellation()
            // A null, zero or out-of-range point is skipped (the day stays a gap) instead of discarding the whole chunk.
            guard pair.count == 2, let millis = pair[0], let price = pair[1], MoneyInput.isFinite(millis), MoneyInput.isFinite(price), millis > 0, price > 0 else { continue }
            let timestamp = NSDecimalNumber(decimal: millis).doubleValue / 1000
            guard timestamp.isFinite else { continue }
            let date = Date(timeIntervalSince1970: timestamp)
            guard date >= request.start, date < request.end, date <= fetchedAt else { continue }
            let day = UTCDay.start(of: date)
            if days[day].map({ $0.providerTime >= date }) == true { continue }
            days[day] = QuoteObservation(assetID: asset, priceUSD: PreciseDecimal(price), providerTime: date, fetchedAt: fetchedAt, provider: "CoinGecko · historical")
        }
        guard !days.isEmpty || response.prices.isEmpty else { throw PriceError.invalidResponse }
        return days.values.sorted { $0.providerTime < $1.providerTime }
    }
    struct MetalDay: Decodable { var day: String; var avg_price: Decimal }
    static func decodeMetals(_ data: Data, request: PriceHistoryRequest, fetchedAt: Date) throws -> [QuoteObservation] {
        let metal = try PreciousMetal.resolve(request.identifier)
        let rows = try JSONDecoder().decode([MetalDay].self, from: data)
        guard rows.count <= 100 else { throw PriceError.invalidResponse }
        var seen = Set<Date>()
        return try rows.map { row in
            let day = try ImportDateFormat.iso.date(row.day)
            guard day >= request.start, day < request.end, seen.insert(day).inserted else { throw PriceError.invalidResponse }
            let end = day.addingTimeInterval(86400 - 1)
            guard end < fetchedAt else { throw PriceError.invalidResponse }
            return QuoteObservation(assetID: metal.assetID, priceUSD: PreciseDecimal(try pricePerGram(row.avg_price)), providerTime: end, fetchedAt: fetchedAt, provider: "Gold API · daily average")
        }.sorted { $0.providerTime < $1.providerTime }
    }
    /// A fetched chunk is done once every day has a price, or once it ended more than three days ago: days
    /// still missing then are publication gaps (weekends, holidays, before a coin was listed), not worth refetching.
    static func isComplete(_ request: PriceHistoryRequest, observations: [Date], now: Date) -> Bool {
        Set(observations.map { UTCDay.start(of: $0) }).count == Int(request.end.timeIntervalSince(request.start) / 86400) || now.timeIntervalSince(request.end) > 3 * 86400
    }
    private struct DayKey: Hashable { var id: String; var day: Date }
    static func applying(_ update: PriceUpdate, to document: VaultDocument, now: Date) throws -> VaultDocument {
        var next = document
        // Prices are kept by UTC day, the market's; today's value is saved with each change, so only days already over
        // are recomputed.
        let today = UTCDay.start(of: now), openDay = UTCDay.firstOpenDay(now: now)
        // Only past days that gained an observation are recomputed; a rate also carries forward up to seven days.
        var changedDays = Set<Date>()
        func touch(_ day: Date, carry: Int = 0) {
            for offset in 0...carry {
                let date = day.addingTimeInterval(Double(offset) * 86400)
                if date < openDay { changedDays.insert(date) }
            }
        }
        var quoteKeys = Set(next.quotes.map { $0.assetID.rawValue + ":" + String($0.providerTime.timeIntervalSince1970) })
        for quote in update.quotes where quoteKeys.insert(quote.assetID.rawValue + ":" + String(quote.providerTime.timeIntervalSince1970)).inserted {
            next.quotes.append(quote); touch(UTCDay.start(of: quote.providerTime))
        }
        // A past day keeps only each asset's last quote, which is all a daily valuation reads. Today and yesterday keep
        // every quote, so a 24-hour change has a real price from 24 hours ago.
        let intraday = today.addingTimeInterval(-86400)
        var lastOfDay: [DayKey: Date] = [:]
        for quote in next.quotes where quote.providerTime < intraday {
            let key = DayKey(id: quote.assetID.rawValue, day: UTCDay.start(of: quote.providerTime))
            lastOfDay[key] = max(lastOfDay[key] ?? quote.providerTime, quote.providerTime)
        }
        var kept = Set<DayKey>()
        next.quotes = next.quotes.filter { quote in
            let key = DayKey(id: quote.assetID.rawValue, day: UTCDay.start(of: quote.providerTime))
            return key.day >= intraday || (quote.providerTime == lastOfDay[key] && kept.insert(key).inserted)
        }
        // One rate per currency and UTC day. A rate fetched while its day was still open is provisional (Frankfurter
        // blends in providers as they publish), so a later fetch replaces it; once fetched after the day closed it stays.
        var rateIndex: [DayKey: Int] = [:]
        for (index, rate) in next.fx.enumerated() { rateIndex[DayKey(id: rate.sourceCurrency, day: UTCDay.start(of: rate.providerTime))] = index }
        for rate in update.rates {
            let key = DayKey(id: rate.sourceCurrency, day: UTCDay.start(of: rate.providerTime))
            if let index = rateIndex[key] {
                let existing = next.fx[index]
                guard existing.provider != "Manual", rate.fetchedAt > existing.fetchedAt, UTCDay.start(of: existing.fetchedAt) <= key.day else { continue }
                next.fx[index] = rate
            } else {
                rateIndex[key] = next.fx.count; next.fx.append(rate)
            }
            touch(key.day, carry: 7)
        }
        next.priceHistoryCoverage = coalesced((next.priceHistoryCoverage ?? []) + update.coverage)
        next.dropUnstoredValuations()
        let scopes = next.valuationScopes
        // A backfill can improve an existing partial-day valuation. Recompute only affected days.
        for day in changedDays.sorted() {
            try Task.checkCancellation()
            var evaluation = next
            evaluation.dailyValuations.removeAll { UTCDay.start(of: $0.utcDay) == day }
            let at = day.addingTimeInterval(86400 - 1)
            for scope in scopes {
                NetWorthCalculator.recordSample(NetWorthCalculator.value(at: at, scope: scope, document: evaluation, now: now), in: &next)
            }
        }
        return next
    }
    /// Each key's complete intervals merged into runs; an incomplete interval is kept (its latest check only)
    /// while some of it is still uncovered, since it only delays the retry of that gap.
    static func coalesced(_ coverage: [PriceHistoryCoverage]) -> [PriceHistoryCoverage] {
        var result: [PriceHistoryCoverage] = []
        for (_, intervals) in Dictionary(grouping: coverage, by: \.key).sorted(by: { $0.key < $1.key }) {
            var complete: [PriceHistoryCoverage] = []
            for interval in intervals.filter(\.complete).sorted(by: { $0.start < $1.start }) {
                if let last = complete.last, interval.start <= last.end {
                    complete[complete.count - 1].end = max(last.end, interval.end)
                    complete[complete.count - 1].checkedAt = max(last.checkedAt, interval.checkedAt)
                } else { complete.append(interval) }
            }
            var open: [PriceHistoryCoverage] = []
            for interval in intervals where !interval.complete && !complete.contains(where: { $0.start <= interval.start && $0.end >= interval.end }) {
                if let index = open.firstIndex(where: { $0.start == interval.start && $0.end == interval.end }) {
                    if interval.checkedAt >= open[index].checkedAt { open[index] = interval }
                } else { open.append(interval) }
            }
            result += complete + open.sorted { $0.start < $1.start }
        }
        return result
    }
}
