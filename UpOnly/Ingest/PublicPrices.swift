import Foundation

nonisolated struct CatalogCoin: Codable, Identifiable, Sendable, Hashable {
    var id: String
    var symbol: String
    var name: String
}
nonisolated enum PriceError: LocalizedError {
    case unavailable, invalidResponse, credentials, metalCredentials, rateLimited
    var errorDescription: String? {
        switch self {
        case .unavailable: "The price provider is unavailable. Saved observations are unchanged."
        case .invalidResponse: "The provider returned an invalid response. Saved observations are unchanged."
        case .credentials: "Check your CoinGecko Demo API key in Sources."
        case .metalCredentials: "Add or check your free Gold API history key in Sources."
        case .rateLimited: "The provider’s request limit was reached. Up Only will retry at the next refresh."
        }
    }
}
private final class NoPriceRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
nonisolated enum PublicPrices {
    static func request(host: String, path: String, query: [URLQueryItem], key: String = "", limit: Int = 2 * 1024 * 1024) async throws -> Data {
        guard ["api.coingecko.com", "api.frankfurter.dev", "api.gold-api.com"].contains(host), key.utf8.count <= 512,
              !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw PriceError.invalidResponse }
        var components = URLComponents(); components.scheme = "https"; components.host = host; components.path = path; components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw PriceError.invalidResponse }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 40
        let session = URLSession(configuration: configuration, delegate: NoPriceRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("UpOnly/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        if host == "api.coingecko.com", !key.isEmpty { request.setValue(key, forHTTPHeaderField: "x-cg-demo-api-key") }
        if host == "api.gold-api.com", !key.isEmpty { request.setValue(key, forHTTPHeaderField: "x-api-key") }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw PriceError.invalidResponse }
        if http.statusCode == 429 { throw PriceError.rateLimited }
        if host == "api.coingecko.com", [401, 403].contains(http.statusCode) { throw PriceError.credentials }
        if host == "api.gold-api.com", [401, 403].contains(http.statusCode) { throw PriceError.metalCredentials }
        guard http.statusCode == 200, response.expectedContentLength <= limit else { throw PriceError.unavailable }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { throw PriceError.invalidResponse }; data.append(byte)
        }
        return data
    }
    static func catalog(key: String) async throws -> [CatalogCoin] {
        let data = try await request(host: "api.coingecko.com", path: "/api/v3/coins/list", query: [], key: key, limit: 16 * 1024 * 1024)
        let coins = try JSONDecoder().decode([CatalogCoin].self, from: data)
        guard coins.count <= 100000 else { throw PriceError.invalidResponse }
        var seen = Set<String>()
        return coins.filter { coin in
            (try? MoneyInput.canonicalAssetID(coin.id)) == coin.id && !coin.name.isEmpty && coin.name.count <= 150 && coin.symbol.count <= 30 && seen.insert(coin.id).inserted && !coin.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    struct Price: Decodable { var usd: Decimal?; var last_updated_at: Double? }
    static func decodeQuotes(_ data: Data, requested: Set<String>, fetchedAt: Date) throws -> [QuoteObservation] {
        let response = try JSONDecoder().decode([String: Price].self, from: data)
        return try response.compactMap { id, row in
            guard requested.contains(id) else { throw PriceError.invalidResponse }
            guard let value = row.usd, let timestamp = row.last_updated_at else { return nil }
            try MoneyInput.requirePositiveFinite(value)
            guard timestamp.isFinite, timestamp > 0 else { throw PriceError.invalidResponse }
            let time = Date(timeIntervalSince1970: timestamp)
            guard time <= fetchedAt.addingTimeInterval(300) else { throw PriceError.invalidResponse }
            return QuoteObservation(assetID: try CanonicalAssetID(id), priceUSD: PreciseDecimal(value), providerTime: time, fetchedAt: fetchedAt, provider: "CoinGecko")
        }
    }
    static func quotes(ids: [String], key: String) async throws -> [QuoteObservation] {
        var result: [QuoteObservation] = []
        let identifiers = Array(Set(try ids.map(MoneyInput.canonicalAssetID))).sorted()
        for start in stride(from: 0, to: identifiers.count, by: 100) {
            let batch = Array(identifiers[start..<min(start+100, identifiers.count)])
            let data = try await request(host: "api.coingecko.com", path: "/api/v3/simple/price", query: [URLQueryItem(name: "ids", value: batch.joined(separator: ",")), URLQueryItem(name: "vs_currencies", value: "usd"), URLQueryItem(name: "include_last_updated_at", value: "true"), URLQueryItem(name: "precision", value: "full")], key: key)
            result += try decodeQuotes(data, requested: Set(batch), fetchedAt: Date())
        }
        return result
    }
    struct RateV2: Decodable { var date: String; var base: String; var quote: String; var rate: Decimal }
    static func decodeFX(_ data: Data, currency: String, fetchedAt: Date, start: Date? = nil, end: Date? = nil) throws -> [FXObservation] {
        let rows = try JSONDecoder().decode([RateV2].self, from: data)
        guard !rows.isEmpty, rows.count <= 100 else { throw PriceError.invalidResponse }
        var seen = Set<Date>()
        return try rows.map { row in
            let day = try ImportDateFormat.iso.date(row.date)
            guard row.base == currency, row.quote == "USD", day <= fetchedAt, seen.insert(day).inserted,
                  start.map({ day >= $0.addingTimeInterval(-7 * 86400) }) ?? true,
                  end.map({ day < $0 }) ?? true else { throw PriceError.invalidResponse }
            try MoneyInput.requirePositiveFinite(row.rate)
            return FXObservation(sourceCurrency: currency, targetCurrency: "USD", rate: PreciseDecimal(row.rate), providerTime: day, fetchedAt: fetchedAt, provider: "Frankfurter")
        }.sorted { $0.providerTime < $1.providerTime }
    }
    static func currencyRate(_ currency: String) async throws -> [FXObservation] {
        let code = try MoneyInput.normalizeCurrency(currency)
        let data = try await request(host: "api.frankfurter.dev", path: "/v2/rates", query: [URLQueryItem(name: "base", value: code), URLQueryItem(name: "quotes", value: "USD")])
        return try decodeFX(data, currency: code, fetchedAt: Date())
    }
    static func fx(currencies: Set<String>, fetch: @Sendable (String) async throws -> [FXObservation] = currencyRate) async throws -> PriceUpdate {
        var result = PriceUpdate()
        for currency in currencies.sorted() where currency != "USD" {
            try Task.checkCancellation()
            do { result.rates += try await fetch(currency) }
            catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                result.fxIssues[currency] = "Couldn’t get the \(currency) → USD rate. Try again or add a dated rate."
                result.messages.append(result.fxIssues[currency]!)
            }
        }
        return result
    }

}


nonisolated struct PriceHistoryCoverage: Codable, Sendable, Equatable {
    var key: String
    var start: Date
    var end: Date // exclusive UTC midnight
    var checkedAt: Date
    var complete: Bool
}
nonisolated struct PriceHistoryRequest: Sendable {
    enum Source: Sendable { case crypto, metal, fx }
    var source: Source
    var key: String
    var identifier: String
    var start: Date
    var end: Date
}
nonisolated struct PriceUpdate: Codable, Sendable {
    var quotes: [QuoteObservation] = []
    var rates: [FXObservation] = []
    var coverage: [PriceHistoryCoverage] = []
    var messages: [String] = []
    var fxIssues: [String: String] = [:]
    /// Per-source problems from the last update, keyed "crypto", "metals" or "fx", for the Sources page.
    var sourceIssues: [String: String] = [:]
}
nonisolated enum PriceHistory {
    static func requests(document: VaultDocument, now: Date, reconnected: Bool = false) -> [PriceHistoryRequest] {
        let end = UTCDay.start(of: now)
        var targets: [(PriceHistoryRequest.Source, String, Date)] = []
        for group in Dictionary(grouping: document.holdings, by: { $0.assetID.rawValue }) {
            guard let first = group.value.map(\.createdAt).min() else { continue }
            let isMetal = PreciousMetal.asset(CanonicalAssetID(rawValue: group.key)) != nil
            if isMetal && document.settings.automaticMetals && !document.settings.metalHistoryKey.isEmpty {
                targets.append((.metal, group.key, first))
            } else if !isMetal && document.settings.automaticPrices {
                // Demo API has a rolling 365-day window; already stored older data is retained.
                targets.append((.crypto, group.key, max(first, end.addingTimeInterval(-364 * 86400))))
            }
        }
        if document.settings.automaticFX {
            let currencies = Set(document.accounts.map(\.currency) + document.entries.map(\.currency)).subtracting(["USD"])
            for currency in currencies {
                let balances = document.bankBalances.filter { $0.currency == currency }.map(\.observedAt)
                let entries = document.entries.filter { $0.currency == currency }.compactMap { try? ImportDateFormat.iso.date($0.month + "-01") }
                if let first = (balances + entries).min() { targets.append((.fx, currency, first)) }
            }
        }
        var result: [PriceHistoryRequest] = [], fxRequests: [PriceHistoryRequest] = []
        let accountCurrencies = Set(document.accounts.map(\.currency))
        for (source, identifier, first) in targets {
            let key = (source == .fx ? "fx:" : "asset:") + identifier
            let coverage = (document.priceHistoryCoverage ?? []).filter { $0.key == key && ($0.complete || (!reconnected && now.timeIntervalSince($0.checkedAt) < 6 * 3600)) }.sorted { $0.start < $1.start }
            if source == .fx {
                // Every uncovered stretch, split into 90-day chunks. Recent days are what the chart needs first.
                var cursor = UTCDay.start(of: first)
                while cursor < end {
                    if let covering = coverage.first(where: { $0.start <= cursor && $0.end > cursor }) { cursor = covering.end; continue }
                    let gapEnd = min(end, coverage.first { $0.start > cursor }?.start ?? end, cursor.addingTimeInterval(90 * 86400))
                    fxRequests.append(PriceHistoryRequest(source: source, key: key, identifier: identifier, start: cursor, end: gapEnd))
                    cursor = gapEnd
                }
                continue
            }
            var start = UTCDay.start(of: first)
            for interval in coverage {
                if interval.start <= start && interval.end > start { start = interval.end }
            }
            guard start < end else { continue }
            let nextCovered = coverage.first { $0.start > start }?.start ?? end
            result.append(PriceHistoryRequest(source: source, key: key, identifier: identifier, start: start, end: min(end, nextCovered, start.addingTimeInterval(90 * 86400))))
        }
        // Old requests rotate behind untouched assets if an endpoint has persistent gaps.
        result.sort { a, b in
            let aa = document.priceHistoryCoverage?.filter { $0.key == a.key }.map(\.checkedAt).max() ?? .distantPast
            let bb = document.priceHistoryCoverage?.filter { $0.key == b.key }.map(\.checkedAt).max() ?? .distantPast
            return aa == bb ? a.key < b.key : aa < bb
        }
        // Currencies of real accounts before ones that only appear in old entries; newest chunks first.
        fxRequests.sort { a, b in
            let ap = accountCurrencies.contains(a.identifier), bp = accountCurrencies.contains(b.identifier)
            if ap != bp { return ap }
            return a.end == b.end ? a.identifier < b.identifier : a.end > b.end
        }
        return result + fxRequests
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
    struct CryptoHistory: Decodable { var prices: [[Decimal]] }
    static func decodeCrypto(_ data: Data, request: PriceHistoryRequest, fetchedAt: Date) throws -> [QuoteObservation] {
        let response = try JSONDecoder().decode(CryptoHistory.self, from: data)
        guard response.prices.count <= 30000 else { throw PriceError.invalidResponse }
        var days: [Date: QuoteObservation] = [:]
        for pair in response.prices {
            try Task.checkCancellation()
            guard pair.count == 2 else { throw PriceError.invalidResponse }
            try MoneyInput.requirePositiveFinite(pair[0]); try MoneyInput.requirePositiveFinite(pair[1])
            let timestamp = NSDecimalNumber(decimal: pair[0]).doubleValue / 1000
            guard timestamp.isFinite else { throw PriceError.invalidResponse }
            let date = Date(timeIntervalSince1970: timestamp)
            guard date >= request.start, date <= request.end, date <= fetchedAt else { throw PriceError.invalidResponse }
            if date == request.end { continue }
            let day = UTCDay.start(of: date)
            if days[day].map({ $0.providerTime >= date }) == true { continue }
            days[day] = QuoteObservation(assetID: try CanonicalAssetID(request.identifier), priceUSD: PreciseDecimal(pair[1]), providerTime: date, fetchedAt: fetchedAt, provider: "CoinGecko · historical")
        }
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
    struct FXHistory: Decodable { var base: String; var rates: [String: [String: Decimal]] }
    static func decodeFX(_ data: Data, request: PriceHistoryRequest, fetchedAt: Date) throws -> [FXObservation] {
        let response = try JSONDecoder().decode(FXHistory.self, from: data)
        guard response.base == request.identifier, response.rates.count <= 100 else { throw PriceError.invalidResponse }
        return try response.rates.map { key, rates in
            let date = try ImportDateFormat.iso.date(key)
            guard let rate = rates["USD"], date >= request.start.addingTimeInterval(-7 * 86400), date < request.end, date <= fetchedAt else { throw PriceError.invalidResponse }
            try MoneyInput.requirePositiveFinite(rate)
            return FXObservation(sourceCurrency: request.identifier, targetCurrency: "USD", rate: PreciseDecimal(rate), providerTime: date, fetchedAt: fetchedAt, provider: "Frankfurter · historical")
        }.sorted { $0.providerTime < $1.providerTime }
    }
    static func applying(_ update: PriceUpdate, to document: VaultDocument, now: Date) throws -> VaultDocument {
        var next = document
        var quoteKeys = Set(next.quotes.map { $0.assetID.rawValue + ":" + String($0.providerTime.timeIntervalSince1970) })
        for quote in update.quotes where quoteKeys.insert(quote.assetID.rawValue + ":" + String(quote.providerTime.timeIntervalSince1970)).inserted { next.quotes.append(quote) }
        var rateKeys = Set(next.fx.map { $0.sourceCurrency + ":" + String($0.providerTime.timeIntervalSince1970) })
        for rate in update.rates where rateKeys.insert(rate.sourceCurrency + ":" + String(rate.providerTime.timeIntervalSince1970)).inserted { next.fx.append(rate) }
        for interval in update.coverage {
            next.priceHistoryCoverage = (next.priceHistoryCoverage ?? []).filter { !($0.key == interval.key && $0.start == interval.start && $0.end == interval.end) } + [interval]
        }
        var changedDays = Set((update.quotes.map(\.providerTime) + update.rates.map(\.providerTime)).map { UTCDay.start(of: $0) }).filter { $0 < UTCDay.start(of: now) }
        for interval in update.coverage {
            for timestamp in stride(from: interval.start.timeIntervalSince1970, to: interval.end.timeIntervalSince1970, by: 86400) {
                changedDays.insert(Date(timeIntervalSince1970: timestamp))
            }
        }
        let scopes: [ValuationScope] = [.allTracked, .banks] + next.portfolios.map { .portfolio($0.id) }
        // A backfill can improve an existing partial-day valuation. Recompute only affected days.
        for day in changedDays.sorted() {
            try Task.checkCancellation()
            var evaluation = next
            evaluation.dailyValuations.removeAll { UTCDay.start(of: $0.utcDay) == day }
            let at = day.addingTimeInterval(86400 - 1)
            for scope in scopes {
                let value = NetWorthCalculator.value(at: at, scope: scope, document: evaluation, now: now)
                next = NetWorthCalculator.recordingSample(value, in: next)
            }
        }
        return next
    }
}
extension PublicPrices {
    static func update(document: VaultDocument, now: Date = Date(), reconnected: Bool = false, includeCurrent: Bool = true) async throws -> PriceUpdate {
        var result = PriceUpdate()
        let active = document.holdings.filter { $0.isActive(at: now) && document.portfolio(id: $0.portfolioID)?.isActive(at: now) == true }
        let crypto = active.filter { PreciousMetal.asset($0.assetID) == nil }.map { $0.assetID.rawValue }
        let metals = Set(active.compactMap { PreciousMetal.asset($0.assetID) })
        func message(_ error: Error) -> String { (error as? PriceError)?.localizedDescription ?? "A price source is unavailable. Missing history will be retried." }
        if includeCurrent && document.settings.automaticPrices && crypto.isEmpty { result.sourceIssues["crypto"] = "No coins are tracked yet. Add a crypto holding under Manage." }
        if includeCurrent && document.settings.automaticMetals && metals.isEmpty { result.sourceIssues["metals"] = "No gold or silver is tracked yet. Add a holding under Manage." }
        if includeCurrent && document.settings.automaticPrices && !crypto.isEmpty {
            do {
                let quotes = try await quotes(ids: crypto, key: document.settings.coinGeckoKey)
                result.quotes += quotes
                let missing = Set(crypto).subtracting(quotes.map(\.assetID.rawValue)).sorted()
                if !missing.isEmpty { result.sourceIssues["crypto"] = "CoinGecko has no price for " + missing.joined(separator: ", ") + ". Check the coin ID matches CoinGecko's." }
            } catch { try Task.checkCancellation(); result.messages.append(message(error)); result.sourceIssues["crypto"] = message(error) }
        }
        if includeCurrent && document.settings.automaticMetals {
            for metal in metals.sorted(by: { $0.rawValue < $1.rawValue }) {
                do {
                    try await Task.sleep(for: .seconds(1.1))
                    let data = try await request(host: "api.gold-api.com", path: "/price/" + metal.rawValue, query: [])
                    result.quotes.append(try PriceHistory.decodeMetal(data, metal: metal, fetchedAt: now))
                } catch { try Task.checkCancellation(); result.messages.append(message(error)); result.sourceIssues["metals"] = message(error) }
            }
            if !metals.isEmpty && document.settings.metalHistoryKey.isEmpty { result.messages.append("Add a free Gold API key in Sources to recover metal price history after time offline.") }
        }
        if includeCurrent && document.settings.automaticFX {
            do {
                let update = try await fx(currencies: Set(document.accounts.map(\.currency) + document.entries.map(\.currency)))
                result.rates += update.rates; result.messages += update.messages; result.fxIssues = update.fxIssues
            }
            catch { try Task.checkCancellation(); result.messages.append(message(error)); result.sourceIssues["fx"] = message(error) }
        }
        // Monthly personal performance needs its dated FX immediately; do not
        // queue years of month-end rates behind unrelated asset history.
        let historicalFX = try await performanceFX(document: document, now: now, retry: reconnected)
        result.rates += historicalFX.rates; result.coverage += historicalFX.coverage
        result.messages += historicalFX.messages
        result.fxIssues.merge(historicalFX.fxIssues) { _, latest in latest }
        let pending = PriceHistory.requests(document: document, now: now, reconnected: reconnected)
        var count = 0, metalCount = 0, fxCount = 0
        for item in pending {
            // Exchange rates are cheap and unmetered, so a rebuilt balance history fills in within one refresh.
            // Prices stay at four calls; at most four metal history calls per hour, leaving headroom on the free ten/hour allowance.
            if item.source == .fx {
                guard fxCount < 80 else { continue }
                fxCount += 1
            } else {
                guard count < 4 else { continue }
                if item.source == .metal {
                    if metalCount >= 4 { continue }
                    let last = (document.priceHistoryCoverage ?? []).filter { $0.key.hasPrefix("asset:metal-") }.map(\.checkedAt).max()
                    if let last, now.timeIntervalSince(last) < 3600 { continue }
                    metalCount += 1
                }
                count += 1
            }
            do {
                try Task.checkCancellation()
                let observations: [Date]
                switch item.source {
                case .crypto:
                    let data = try await request(host: "api.coingecko.com", path: "/api/v3/coins/" + item.identifier + "/market_chart/range", query: [URLQueryItem(name: "vs_currency", value: "usd"), URLQueryItem(name: "from", value: String(Int(item.start.timeIntervalSince1970))), URLQueryItem(name: "to", value: String(Int(item.end.timeIntervalSince1970))), URLQueryItem(name: "precision", value: "full")], key: document.settings.coinGeckoKey)
                    let quotes = try PriceHistory.decodeCrypto(data, request: item, fetchedAt: now)
                    result.quotes += quotes; observations = quotes.map(\.providerTime)
                case .metal:
                    let metal = try PreciousMetal.resolve(item.identifier)
                    try await Task.sleep(for: .seconds(1.1))
                    let data = try await request(host: "api.gold-api.com", path: "/history", query: [URLQueryItem(name: "symbol", value: metal.rawValue), URLQueryItem(name: "startTimestamp", value: String(Int(item.start.timeIntervalSince1970))), URLQueryItem(name: "endTimestamp", value: String(Int(item.end.timeIntervalSince1970) - 1)), URLQueryItem(name: "groupBy", value: "day"), URLQueryItem(name: "aggregation", value: "avg"), URLQueryItem(name: "orderBy", value: "asc")], key: document.settings.metalHistoryKey)
                    let quotes = try PriceHistory.decodeMetals(data, request: item, fetchedAt: now)
                    result.quotes += quotes; observations = quotes.map(\.providerTime)
                case .fx:
                    let data = try await request(host: "api.frankfurter.dev", path: "/v2/rates", query: [URLQueryItem(name: "base", value: item.identifier), URLQueryItem(name: "quotes", value: "USD"), URLQueryItem(name: "from", value: ImportDateFormat.today(item.start)), URLQueryItem(name: "to", value: ImportDateFormat.today(item.end.addingTimeInterval(-1)))])
                    let rates = try decodeFX(data, currency: item.identifier, fetchedAt: now, start: item.start, end: item.end)
                    result.rates += rates; observations = rates.map(\.providerTime)
                }
                let complete = Set(observations.map { UTCDay.start(of: $0) }).count == Int(item.end.timeIntervalSince(item.start) / 86400)
                result.coverage.append(PriceHistoryCoverage(key: item.key, start: item.start, end: item.end, checkedAt: now, complete: complete))
                if !complete { result.messages.append("Some dates have no published price. Chart gaps are retained and checked again later.") }
            } catch {
                try Task.checkCancellation(); result.messages.append(message(error))
                if item.source == .fx {
                    result.fxIssues[item.identifier] = "Couldn’t get historical \(item.identifier) → USD rates. Try again or add a rate dated for this period."
                }
                // Back off failures too, retaining the gap and retrying after six hours.
                result.coverage.append(PriceHistoryCoverage(key: item.key, start: item.start, end: item.end, checkedAt: now, complete: false))
            }
        }
        if pending.count > count + fxCount { result.messages.append("More price history is queued for the next refresh.") }
        if document.settings.automaticPrices && document.holdings.contains(where: { PreciousMetal.asset($0.assetID) == nil && $0.createdAt < now.addingTimeInterval(-365 * 86400) }) {
            result.messages.append("CoinGecko Demo can recover the past 365 days. Previously saved older observations remain available.")
        }
        result.messages = Array(Set(result.messages)).sorted()
        return result
    }
}

#if UPONLY_PERSONAL
import Security

// Compiled exclusively into the owner's local build. Credentials and profile IDs are never bundled.
nonisolated struct WiseConfiguredProfile: Codable, Sendable, Identifiable {
    var id: Int64
    var name: String
    var bucket: Bucket
    var image: Data?
}
nonisolated struct WiseConnection: Codable, Sendable {
    var token: String
    var profiles: [WiseConfiguredProfile]
    static let keychainService = "org.uponly.personal.wise"
    static func load() throws -> WiseConnection {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: keychainService, kSecAttrAccount as String: "connection",
                                  kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne, kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            throw ImportFailure("Your private Wise connection is not available in this Mac’s Keychain.")
        }
        let connection = try JSONDecoder().decode(WiseConnection.self, from: data)
        guard !connection.token.isEmpty, !connection.profiles.isEmpty, connection.profiles.count <= 10,
              Set(connection.profiles.map(\.id)).count == connection.profiles.count else { throw ImportFailure("Check the private Wise connection configuration.") }
        return connection
    }
}
nonisolated struct WiseAmount: Codable, Sendable { var value: Decimal; var currency: String }
nonisolated struct WiseBalance: Codable, Sendable {
    var id: Int64
    var currency: String
    var amount: WiseAmount
}
nonisolated struct WiseActivity: Codable, Sendable {
    struct Resource: Codable, Sendable { var type: String; var id: String }
    var id: String
    var type: String
    var resource: Resource?
    var title: String?
    var description: String?
    var primaryAmount: String?
    var secondaryAmount: String?
    var status: String
    var createdOn: String
}
nonisolated struct WiseActivityPage: Decodable, Sendable { var cursor: String?; var activities: [WiseActivity] }
nonisolated struct WiseProfileSnapshot: Sendable {
    var profile: WiseConfiguredProfile
    var balances: [WiseBalance]
    var activities: [WiseActivity]
}
nonisolated struct WiseSnapshot: Sendable { var profiles: [WiseProfileSnapshot]; var fetchedAt: Date }
nonisolated enum WiseAPI {
    static func request(path: String, query: [URLQueryItem] = [], token: String) async throws -> Data {
        guard path.hasPrefix("/v"), !path.contains(".."), token.utf8.count <= 4096,
              !token.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw ImportFailure("Invalid Wise request.") }
        var url = URLComponents(); url.scheme = "https"; url.host = "api.wise.com"; url.path = path; url.queryItems = query
        guard let endpoint = url.url else { throw ImportFailure("Invalid Wise request.") }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil; config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 25; config.timeoutIntervalForResource = 45
        let session = URLSession(configuration: config, delegate: NoPriceRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: endpoint); request.httpMethod = "GET"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization"); request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw ImportFailure("Wise returned an unreadable response.") }
        if response.statusCode == 429 { throw ImportFailure("Wise is limiting requests. Your saved records are unchanged; try again later.") }
        if [401, 403].contains(response.statusCode) { throw ImportFailure("Wise access needs attention. Check the read-only token or account authorization.") }
        guard response.statusCode == 200, response.expectedContentLength <= 4 * 1024 * 1024 else { throw ImportFailure("Wise could not refresh. Your saved records are unchanged.") }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 4 * 1024 * 1024 else { throw ImportFailure("Wise returned too much data in one response.") }
            data.append(byte)
        }
        return data
    }
    static func fetch(_ connection: WiseConnection) async throws -> WiseSnapshot {
        var profiles: [WiseProfileSnapshot] = []
        for profile in connection.profiles {
            try Task.checkCancellation()
            let balanceData = try await request(path: "/v4/profiles/\(profile.id)/balances", query: [URLQueryItem(name: "types", value: "STANDARD")], token: connection.token)
            let balances = try JSONDecoder().decode([WiseBalance].self, from: balanceData)
            var activities: [WiseActivity] = [], cursor: String?, cursors = Set<String>(), complete = false
            for _ in 0..<200 {
                var query = [URLQueryItem(name: "size", value: "100")]
                if let cursor { query.append(URLQueryItem(name: "nextCursor", value: cursor)) }
                let data = try await request(path: "/v1/profiles/\(profile.id)/activities", query: query, token: connection.token)
                let page = try JSONDecoder().decode(WiseActivityPage.self, from: data)
                activities += page.activities
                guard activities.count <= 20000 else { throw ImportFailure("Wise history exceeds this sync’s limit. Saved records are unchanged.") }
                guard let next = page.cursor, !next.isEmpty else { complete = true; break }
                guard cursors.insert(next).inserted else { throw ImportFailure("Wise repeated a history page. Try syncing again.") }
                cursor = next
            }
            guard complete else { throw ImportFailure("Wise history is incomplete. Saved records are unchanged.") }
            profiles.append(WiseProfileSnapshot(profile: profile, balances: balances, activities: activities))
        }
        return WiseSnapshot(profiles: profiles, fetchedAt: Date())
    }
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func amount(_ text: String?) throws -> (value: Decimal, currency: String, incoming: Bool)? {
        let clean = plain(text ?? "").replacingOccurrences(of: "−", with: "-")
        guard !clean.isEmpty else { return nil }
        let regex = try NSRegularExpression(pattern: "^([+-]?)\\s*([0-9,]+(?:\\.[0-9]+)?)\\s*([A-Z]{3})$")
        guard let match = regex.firstMatch(in: clean, range: NSRange(clean.startIndex..., in: clean)) else { throw ImportFailure("A Wise activity amount could not be read exactly. Saved records are unchanged.") }
        func group(_ index: Int) -> String { Range(match.range(at: index), in: clean).map { String(clean[$0]) } ?? "" }
        return (try ImportNumberFormat.point.decimal(group(2)), try MoneyInput.normalizeCurrency(group(3)), group(1) == "+")
    }
    static func apply(_ snapshot: WiseSnapshot, to document: VaultDocument) throws -> VaultDocument {
        var next = document
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainFormatter = ISO8601DateFormatter()
        var sharedTransfers: [String: Set<Int64>] = [:]
        for item in snapshot.profiles {
            for activity in item.activities where activity.type == "TRANSFER" && activity.status == "COMPLETED" {
                if let resource = activity.resource { sharedTransfers[resource.id, default: []].insert(item.profile.id) }
            }
        }
        for item in snapshot.profiles {
            let profileID = String(item.profile.id)
            for balance in item.balances {
                let currency = try MoneyInput.normalizeCurrency(balance.currency)
                guard balance.amount.currency == currency else { throw ImportFailure("Wise returned mismatched balance currencies.") }
                try MoneyInput.requireFinite(balance.amount.value)
                let externalBalance = String(balance.id)
                let accountID: UUID
                if let index = next.accounts.firstIndex(where: { $0.externalProfileID == profileID && $0.externalBalanceID == externalBalance }) {
                    accountID = next.accounts[index].id; next.accounts[index].profileImage = item.profile.image
                } else {
                    var account = Account(name: item.profile.name + " · " + currency, currency: currency)
                    account.ownerBusinessID = next.accounts.first { $0.externalProfileID == profileID }?.ownerBusinessID
                    account.externalProfileID = profileID; account.externalBalanceID = externalBalance; account.profileImage = item.profile.image
                    next.accounts.append(account); accountID = account.id
                    next.setBankTracked(accountID, tracked: true, at: snapshot.fetchedAt)
                }
                if !next.bankBalances.contains(where: { $0.accountID == accountID && $0.observedAt == snapshot.fetchedAt }) {
                    next.bankBalances.append(BankBalanceObservation(id: UUID(), accountID: accountID, amount: PreciseDecimal(balance.amount.value), currency: currency, observedAt: snapshot.fetchedAt, source: "Wise", sourceIdentity: profileID + ":" + externalBalance))
                }
            }
            for activity in item.activities {
                try Task.checkCancellation()
                let reference = "wise:" + profileID + ":" + activity.id
                if ["CANCELLED", "CANCELED", "REVERSED", "FAILED"].contains(activity.status) {
                    next.entries.removeAll { $0.source == .wise && $0.sourceRef == reference }; continue
                }
                guard activity.status == "COMPLETED", activity.type != "CARD_CHECK" else { continue }
                guard let primary = try amount(activity.primaryAmount) else { continue }
                let secondaryText = plain(activity.secondaryAmount ?? "")
                let secondary = secondaryText.contains(where: \.isNumber) ? try amount(secondaryText) : nil
                let income = primary.incoming || ["DEPOSIT", "RECEIVED", "REFUND", "INTEREST", "CASHBACK"].contains { activity.type.contains($0) }
                // Outgoing activity's secondary amount is the amount debited from the source balance.
                // Incoming activity uses the credited primary currency. Currency-list subtitles are not amounts.
                let recorded = !income ? secondary ?? primary : primary
                let amount = recorded.value
                if amount == 0 { continue }
                guard let date = formatter.date(from: activity.createdOn) ?? plainFormatter.date(from: activity.createdOn), date <= snapshot.fetchedAt.addingTimeInterval(300) else { throw ImportFailure("A Wise transaction date is invalid.") }
                let monthText = String(ImportDateFormat.today(date).prefix(7))
                guard let month = MonthKey(monthText) else { throw ImportFailure("A Wise transaction month is invalid.") }
                let ownTransfer = activity.type == "INTERBALANCE" || activity.resource.map { (sharedTransfers[$0.id]?.count ?? 0) > 1 } == true
                let label = plain(activity.title ?? activity.description ?? "Wise transaction")
                guard label.count <= 500, !activity.id.isEmpty else { throw ImportFailure("A Wise activity has invalid details.") }
                let existing = next.entries.firstIndex { $0.source == .wise && $0.sourceRef == reference }
                let refund = income && ["REFUND", "CASHBACK"].contains { activity.type.contains($0) }
                var kind: EntryKind = ownTransfer ? .transfer : refund ? .refund : income ? .income : .expense
                if item.profile.bucket == .personal { kind = OwnerPayments.classify(kind, label: label, month: month.description, document: next) }
                if let index = existing {
                    // Retain explicit user classification while refreshing provider amounts/status.
                    next.entries[index].amount = amount; next.entries[index].currency = recorded.currency
                    next.entries[index].month = month.description; next.entries[index].label = label
                    next.entries[index].day = ImportDateFormat.today(date); next.entries[index].outflow = !income
                    if next.entries[index].kindIsUserEdited != true { next.entries[index].kind = kind }
                } else {
                    var entry = Entry(month: month, bucket: item.profile.bucket, kind: kind, amount: amount, currency: recorded.currency, label: label.isEmpty ? "Wise transaction" : label, source: .wise, sourceRef: reference)
                    entry.day = ImportDateFormat.today(date); entry.outflow = !income
                    next.entries.append(entry)
                }
            }
        }
        next.track(.banks); if next.entries.contains(where: { $0.source == .wise }) { next.track(.cashFlow) }
        // Synced balances anchor a day-by-day history rebuilt from the activity list.
        _ = BalanceReconstruction.apply(accountIDs: Set(next.accounts.filter { $0.externalProfileID != nil }.map(\.id)), to: &next, now: snapshot.fetchedAt)
        return next
    }
}
#endif


extension PublicPrices {
    /// Fetch only the week needed for each missing monthly result. A multi-year
    /// query exceeds the decoder's bounded response size and made Retry useless.
    static func monthlyFXRequests(document: VaultDocument, now: Date, month: MonthKey? = nil,
                                  currencies: [String]? = nil, retry: Bool = false) -> [PriceHistoryRequest] {
        guard document.settings.automaticFX else { return [] }
        let rows = document.entries.filter { $0.bucket == .personal && $0.kind != .transfer && $0.amount != 0 && $0.currency != "USD" }
        var pairs = Set(rows.compactMap { row -> String? in
            guard let key = MonthKey(row.month), key <= AssetOwnership.month(at: now), month == nil || key == month,
                  MonthlyLedger.rate(currency: row.currency, month: key, document: document, now: now) == nil else { return nil }
            return key.description + ":" + row.currency
        })
        if let month, let currencies { pairs.formUnion(currencies.filter { $0 != "USD" }.map { month.description + ":" + $0 }) }
        return pairs.sorted(by: >).compactMap { pair in
            let parts = pair.split(separator: ":"); guard let month = MonthKey(String(parts[0])) else { return nil }
            let currency = String(parts[1]), key = "monthly-fx:" + pair
            if !retry, let checked = document.priceHistoryCoverage?.filter({ $0.key == key && !$0.complete }).map(\.checkedAt).max(), now.timeIntervalSince(checked) < 3600 { return nil }
            let cutoff = DashboardPeriod.interval(month: month, period: .monthly, now: now).end
            let end = UTCDay.start(of: cutoff).addingTimeInterval(86400)
            return PriceHistoryRequest(source: .fx, key: key, identifier: currency, start: end.addingTimeInterval(-7 * 86400), end: end)
        }.prefix(12).map { $0 }
    }
    static func performanceFX(document: VaultDocument, now: Date, month: MonthKey? = nil, currencies: [String]? = nil,
                              retry: Bool = false,
                              fetch: @Sendable (PriceHistoryRequest) async throws -> [FXObservation] = monthlyFX) async throws -> PriceUpdate {
        var result = PriceUpdate()
        for request in monthlyFXRequests(document: document, now: now, month: month, currencies: currencies, retry: retry) {
            try Task.checkCancellation()
            do {
                let rates = try await fetch(request)
                guard rates.contains(where: { $0.sourceCurrency == request.identifier && $0.targetCurrency == "USD" && $0.providerTime >= request.start && $0.providerTime < request.end }) else { throw PriceError.invalidResponse }
                result.rates += rates
                result.coverage.append(PriceHistoryCoverage(key: request.key, start: request.start, end: request.end, checkedAt: now, complete: true))
            } catch {
                try Task.checkCancellation()
                result.fxIssues[request.identifier] = "Couldn’t get the dated " + request.identifier + " rate. Try again or add it manually."
                result.messages.append(result.fxIssues[request.identifier]!)
                result.coverage.append(PriceHistoryCoverage(key: request.key, start: request.start, end: request.end, checkedAt: now, complete: false))
            }
        }
        return result
    }
    static func monthlyFX(_ request: PriceHistoryRequest) async throws -> [FXObservation] {
        let data = try await self.request(host: "api.frankfurter.dev", path: "/v2/rates", query: [URLQueryItem(name: "base", value: request.identifier), URLQueryItem(name: "quotes", value: "USD"), URLQueryItem(name: "from", value: ImportDateFormat.today(request.start)), URLQueryItem(name: "to", value: ImportDateFormat.today(request.end.addingTimeInterval(-1)))])
        return try decodeFX(data, currency: request.identifier, fetchedAt: Date(), start: request.start, end: request.end)
    }
}
