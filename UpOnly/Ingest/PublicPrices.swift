import Foundation

nonisolated struct CatalogCoin: Codable, Identifiable, Sendable, Hashable {
    var id: String
    var symbol: String
    var name: String
    /// CoinGecko market-cap rank when known; lower is bigger.
    var rank: Int?
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
/// Hosts that answered 429, and when they may be called again.
private final class ProviderPauses: @unchecked Sendable {
    private let lock = NSLock()
    private var until: [String: Date] = [:]
    func isPaused(_ host: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return (until[host] ?? .distantPast) > Date()
    }
    func pause(_ host: String, for seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        until[host] = max(until[host] ?? .distantPast, Date().addingTimeInterval(seconds))
    }
}
nonisolated enum PublicPrices {
    /// One session for every provider call, so up to 80 exchange-rate requests share connections.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 40
        return URLSession(configuration: configuration, delegate: NoPriceRedirects(), delegateQueue: nil)
    }()
    private static let pauses = ProviderPauses()
    /// Being offline or cancelled says nothing about a source, so it must never count as a failed attempt.
    static func isOffline(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        guard let error = error as? URLError else { return false }
        // A timeout is one slow request, not a lost connection; it fails that item alone.
        return [.cancelled, .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed].contains(error.code)
    }
    static func request(host: String, path: String, query: [URLQueryItem], key: String = "", limit: Int = 2 * 1024 * 1024) async throws -> Data {
        guard ["api.coingecko.com", "api.frankfurter.dev", "api.gold-api.com", "api.binance.com", "forex-data-feed.swissquote.com"].contains(host), key.utf8.count <= 512,
              !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw PriceError.invalidResponse }
        guard !pauses.isPaused(host) else { throw PriceError.rateLimited }
        var components = URLComponents(); components.scheme = "https"; components.host = host; components.path = path; components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw PriceError.invalidResponse }
        var request = URLRequest(url: url); request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("UpOnly/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        if host == "api.coingecko.com", !key.isEmpty { request.setValue(key, forHTTPHeaderField: "x-cg-demo-api-key") }
        if host == "api.gold-api.com", !key.isEmpty { request.setValue(key, forHTTPHeaderField: "x-api-key") }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw PriceError.invalidResponse }
        if http.statusCode == 429 {
            // Honour Retry-After (seconds or an HTTP date); without it, wait out CoinGecko's one-minute window.
            let header = (http.value(forHTTPHeaderField: "Retry-After") ?? "").trimmingCharacters(in: .whitespaces)
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            let wait = TimeInterval(header) ?? formatter.date(from: header)?.timeIntervalSinceNow ?? 60
            pauses.pause(host, for: min(max(wait, 1), 3600))
            throw PriceError.rateLimited
        }
        if host == "api.coingecko.com", [401, 403].contains(http.statusCode) { throw PriceError.credentials }
        if host == "api.gold-api.com", [401, 403].contains(http.statusCode) { throw PriceError.metalCredentials }
        guard http.statusCode == 200, response.expectedContentLength <= limit else { throw PriceError.unavailable }
        var body: [UInt8] = []; body.reserveCapacity(Int(max(response.expectedContentLength, 0)))
        for try await byte in bytes {
            guard body.count < limit else { throw PriceError.invalidResponse }
            body.append(byte)
            if body.count % 65536 == 0 { try Task.checkCancellation() }
        }
        try Task.checkCancellation()
        return Data(body)
    }
    /// CoinGecko's search endpoint: a few hundred kilobytes at most, ranked by market cap, instead of the whole 16 MB coin list.
    static func searchCoins(_ query: String, key: String) async throws -> [CatalogCoin] {
        struct Hit: Decodable { var id: String; var name: String; var symbol: String; var market_cap_rank: Int? }
        struct Response: Decodable { var coins: [Hit] }
        let data = try await request(host: "api.coingecko.com", path: "/api/v3/search", query: [URLQueryItem(name: "query", value: query)], key: key)
        let hits = try JSONDecoder().decode(Response.self, from: data).coins
        var seen = Set<String>()
        return hits.filter { hit in
            (try? MoneyInput.canonicalAssetID(hit.id)) == hit.id && !hit.name.isEmpty && hit.name.count <= 150 && hit.symbol.count <= 30 && seen.insert(hit.id).inserted
        }.map { CatalogCoin(id: $0.id, symbol: $0.symbol, name: $0.name, rank: $0.market_cap_rank) }
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
    static func quotes(ids: [String], key: String) async throws -> [QuoteObservation] { try await marketQuotes(ids: ids, key: key).quotes }
    /// Current prices without naming the coins you hold: the 250 largest by market cap in one request, then the next
    /// 250 if a coin is still missing, and only a coin outside those is asked for by name. Also returns each listed
    /// coin's ticker, for finding its long history on an exchange.
    static func marketQuotes(ids: [String], key: String) async throws -> (quotes: [QuoteObservation], symbols: [String: String]) {
        var wanted = Set(try ids.map(MoneyInput.canonicalAssetID))
        var result: [QuoteObservation] = [], symbols: [String: String] = [:]
        for page in 1...2 where !wanted.isEmpty {
            let data = try await request(host: "api.coingecko.com", path: "/api/v3/coins/markets", query: [URLQueryItem(name: "vs_currency", value: "usd"), URLQueryItem(name: "order", value: "market_cap_desc"), URLQueryItem(name: "per_page", value: "250"), URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "precision", value: "full")], key: key, limit: 4 * 1024 * 1024)
            let listed = try decodeMarkets(data, wanted: wanted, fetchedAt: Date())
            result += listed.quotes; symbols.merge(listed.symbols) { first, _ in first }
            wanted.subtract(listed.quotes.map(\.assetID.rawValue))
        }
        let rest = wanted.sorted()
        for start in stride(from: 0, to: rest.count, by: 100) {
            let batch = Array(rest[start..<min(start + 100, rest.count)])
            let data = try await request(host: "api.coingecko.com", path: "/api/v3/simple/price", query: [URLQueryItem(name: "ids", value: batch.joined(separator: ",")), URLQueryItem(name: "vs_currencies", value: "usd"), URLQueryItem(name: "include_last_updated_at", value: "true"), URLQueryItem(name: "precision", value: "full")], key: key)
            result += try decodeQuotes(data, requested: Set(batch), fetchedAt: Date())
        }
        return (result, symbols)
    }
    struct MarketRow: Decodable { var id: String; var symbol: String; var current_price: Decimal?; var last_updated: String? }
    /// The market list's prices for the coins asked about, and every listed coin's ticker.
    static func decodeMarkets(_ data: Data, wanted: Set<String>, fetchedAt: Date) throws -> (quotes: [QuoteObservation], symbols: [String: String]) {
        let rows = try JSONDecoder().decode([MarketRow].self, from: data)
        guard rows.count <= 500 else { throw PriceError.invalidResponse }
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        var quotes: [QuoteObservation] = [], symbols: [String: String] = [:]
        for row in rows where (try? MoneyInput.canonicalAssetID(row.id)) == row.id {
            if row.symbol.count <= 20 { symbols[row.id] = row.symbol.lowercased() }
            guard wanted.contains(row.id), let price = row.current_price, MoneyInput.isFinite(price), price > 0, let text = row.last_updated,
                  let time = fractional.date(from: text) ?? plain.date(from: text), time.timeIntervalSince1970 > 0, time <= fetchedAt.addingTimeInterval(300) else { continue }
            quotes.append(QuoteObservation(assetID: try CanonicalAssetID(row.id), priceUSD: PreciseDecimal(price), providerTime: time, fetchedAt: fetchedAt, provider: "CoinGecko"))
        }
        return (quotes, symbols)
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
    /// A currency's USD rates: the latest, or one a day over `start..<end`. Wise's first when its token is given (it
    /// covers every currency it handles, weekends included); Frankfurter's otherwise, or when Wise can't answer.
    static func rates(_ currency: String, start: Date? = nil, end: Date? = nil, wiseToken: String?) async throws -> [FXObservation] {
        #if UPONLY_PERSONAL
        if let wiseToken {
            do {
                let fromWise = try await WiseAPI.rates(currency, start: start, end: end, token: wiseToken)
                if !fromWise.isEmpty { return fromWise }
            } catch { if isOffline(error) { throw error } }
        }
        #endif
        guard let start, let end else { return try await currencyRate(currency) }
        let code = try MoneyInput.normalizeCurrency(currency)
        let data = try await request(host: "api.frankfurter.dev", path: "/v2/rates", query: [URLQueryItem(name: "base", value: code), URLQueryItem(name: "quotes", value: "USD"), URLQueryItem(name: "from", value: ImportDateFormat.today(start)), URLQueryItem(name: "to", value: ImportDateFormat.today(end.addingTimeInterval(-1)))])
        return try decodeFX(data, currency: code, fetchedAt: Date(), start: start, end: end)
    }
    struct WiseRate: Decodable { var rate: Decimal; var source: String; var target: String; var time: String }
    /// Wise's rates as USD per unit of `currency`: the latest one, or (`daily`) one a day, dated to its UTC day as
    /// Frankfurter's are.
    static func decodeWiseRates(_ data: Data, currency: String, fetchedAt: Date, daily: Bool, start: Date? = nil, end: Date? = nil) throws -> [FXObservation] {
        let rows = try JSONDecoder().decode([WiseRate].self, from: data)
        guard !rows.isEmpty, rows.count <= 5000 else { throw PriceError.invalidResponse }
        let offset = DateFormatter(); offset.locale = Locale(identifier: "en_US_POSIX"); offset.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        let iso = ISO8601DateFormatter()
        var byDay: [Date: FXObservation] = [:]
        for row in rows {
            guard row.source == currency, row.target == "USD", let time = offset.date(from: row.time) ?? iso.date(from: row.time),
                  time.timeIntervalSince1970 > 0, time <= fetchedAt.addingTimeInterval(300) else { throw PriceError.invalidResponse }
            try MoneyInput.requirePositiveFinite(row.rate)
            let day = UTCDay.start(of: time)
            if let start, day < UTCDay.start(of: start).addingTimeInterval(-7 * 86400) { continue }
            if let end, day >= end { continue }
            let observed = daily ? day : time
            if let kept = byDay[day], kept.providerTime >= observed { continue }
            byDay[day] = FXObservation(sourceCurrency: currency, targetCurrency: "USD", rate: PreciseDecimal(row.rate), providerTime: observed, fetchedAt: fetchedAt, provider: "Wise")
        }
        guard !byDay.isEmpty else { throw PriceError.invalidResponse }
        return byDay.values.sorted { $0.providerTime < $1.providerTime }
    }
    static func fx(currencies: Set<String>, fetch: @Sendable (String) async throws -> [FXObservation] = currencyRate) async throws -> PriceUpdate {
        var result = PriceUpdate()
        for currency in currencies.sorted() where currency != "USD" {
            try Task.checkCancellation()
            do { result.rates += try await fetch(currency) }
            catch {
                try Task.checkCancellation()
                if isOffline(error) { throw error }
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
                // CoinGecko's free plan covers the past 365 days; older days come from Binance's daily closes.
                targets.append((.crypto, group.key, first))
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
        var result: [PriceHistoryRequest] = []
        let accountCurrencies = Set(document.accounts.map(\.currency))
        for (source, identifier, first) in targets {
            let key = (source == .fx ? "fx:" : "asset:") + identifier
            let coverage = (document.priceHistoryCoverage ?? []).filter { $0.key == key && ($0.complete || (!reconnected && now.timeIntervalSince($0.checkedAt) < 6 * 3600)) }.sorted { $0.start < $1.start }
            // Every uncovered stretch, split into 90-day chunks.
            var cursor = UTCDay.start(of: first)
            while cursor < end {
                if let covering = coverage.first(where: { $0.start <= cursor && $0.end > cursor }) { cursor = covering.end; continue }
                let gapEnd = min(end, coverage.first { $0.start > cursor }?.start ?? end, cursor.addingTimeInterval(90 * 86400))
                result.append(PriceHistoryRequest(source: source, key: key, identifier: identifier, start: cursor, end: gapEnd))
                cursor = gapEnd
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
        let today = UTCDay.start(of: now)
        // Only past days that gained an observation are recomputed; a rate also carries forward up to seven days.
        var changedDays = Set<Date>()
        func touch(_ day: Date, carry: Int = 0) {
            for offset in 0...carry {
                let date = day.addingTimeInterval(Double(offset) * 86400)
                if date < today { changedDays.insert(date) }
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
extension PublicPrices {
    static func update(document: VaultDocument, now: Date = Date(), reconnected: Bool = false, includeCurrent: Bool = true) async throws -> PriceUpdate {
        var result = PriceUpdate()
        // Wise's rates come first in the private build, when its connection is set up.
        #if UPONLY_PERSONAL
        let wiseToken = document.settings.automaticWise ? (try? WiseConnection.load())?.token : nil
        #else
        let wiseToken: String? = nil
        #endif
        var symbols = PublicPrices.knownSymbols
        let active = document.holdings.filter { $0.isActive(at: now) && document.portfolio(id: $0.portfolioID)?.isActive(at: now) == true }
        let crypto = active.filter { PreciousMetal.asset($0.assetID) == nil }.map { $0.assetID.rawValue }
        let metals = Set(active.compactMap { PreciousMetal.asset($0.assetID) })
        func message(_ error: Error) -> String { (error as? PriceError)?.localizedDescription ?? "A price source is unavailable. Missing history will be retried." }
        // A provider that answered 429 isn't called again in this refresh; going offline stops every remaining request.
        var limited = Set<PriceHistoryRequest.Source>(), offline = false
        func note(_ error: Error, _ source: PriceHistoryRequest.Source) {
            if isOffline(error) { offline = true }
            if (error as? PriceError) == .rateLimited { limited.insert(source) }
        }
        if includeCurrent && document.settings.automaticPrices && crypto.isEmpty { result.sourceIssues["crypto"] = "No coins are tracked yet. Add a crypto holding under Manage." }
        if includeCurrent && document.settings.automaticMetals && metals.isEmpty { result.sourceIssues["metals"] = "No gold or silver is tracked yet. Add a holding under Manage." }
        if includeCurrent && document.settings.automaticPrices && !crypto.isEmpty {
            do {
                let listed = try await marketQuotes(ids: crypto, key: document.settings.coinGeckoKey)
                let quotes = listed.quotes
                symbols.merge(listed.symbols) { _, latest in latest }
                result.quotes += quotes
                let missing = Set(crypto).subtracting(quotes.map(\.assetID.rawValue)).sorted()
                if !missing.isEmpty { result.sourceIssues["crypto"] = "CoinGecko has no price for " + missing.joined(separator: ", ") + ". Check the coin ID matches CoinGecko's." }
            } catch { try Task.checkCancellation(); note(error, .crypto); result.messages.append(message(error)); result.sourceIssues["crypto"] = message(error) }
        }
        if includeCurrent && document.settings.automaticMetals {
            for metal in metals.sorted(by: { $0.rawValue < $1.rawValue }) where !offline && !limited.contains(.metal) {
                do {
                    try await Task.sleep(for: .seconds(1.1))
                    result.quotes.append(try await metalSpot(metal, fetchedAt: now))
                } catch { try Task.checkCancellation(); note(error, .metal); result.messages.append(message(error)); result.sourceIssues["metals"] = message(error) }
            }
            if !metals.isEmpty && document.settings.metalHistoryKey.isEmpty { result.messages.append("Add a free Gold API key in Sources to recover metal price history after time offline.") }
        }
        if includeCurrent && document.settings.automaticFX && !offline {
            do {
                let update = try await fx(currencies: Set(document.accounts.map(\.currency) + document.entries.map(\.currency))) { try await rates($0, wiseToken: wiseToken) }
                result.rates += update.rates; result.messages += update.messages; result.fxIssues = update.fxIssues
            }
            catch { try Task.checkCancellation(); note(error, .fx); result.messages.append(message(error)); result.sourceIssues["fx"] = message(error) }
        }
        // Monthly personal performance needs its dated FX immediately; do not
        // queue years of month-end rates behind unrelated asset history.
        if !offline {
            let historicalFX = try await performanceFX(document: document, now: now, retry: reconnected) { request in
                try await rates(request.identifier, start: request.start, end: request.end, wiseToken: wiseToken)
            }
            result.rates += historicalFX.rates; result.coverage += historicalFX.coverage
            result.messages += historicalFX.messages
            result.fxIssues.merge(historicalFX.fxIssues) { _, latest in latest }
        }
        let pending = PriceHistory.requests(document: document, now: now, reconnected: reconnected)
        var count = 0, metalCount = 0, fxCount = 0, exchangeCount = 0, queued = false
        // Older than CoinGecko's free year: Binance's daily closes, for a coin whose Binance pair checks out.
        let coinGeckoStart = UTCDay.start(of: now).addingTimeInterval(-364 * 86400)
        var matched: [String: Bool] = [:]
        func reference(_ id: String) -> Decimal? {
            (result.quotes + document.quotes).filter { $0.assetID.rawValue == id }.max { $0.providerTime < $1.providerTime }?.priceUSD.value
        }
        for item in pending where !offline && !limited.contains(item.source) {
            if item.source == .crypto, item.start < coinGeckoStart {
                guard exchangeCount < 24 else { queued = true; continue }
                exchangeCount += 1
                do {
                    try Task.checkCancellation()
                    let asset = try CanonicalAssetID(item.identifier)
                    guard let symbol = symbols[item.identifier], let pair = binancePair(symbol), let price = reference(item.identifier) else {
                        // No exchange history to be had: record the stretch as checked so it isn't asked for again soon.
                        result.coverage.append(PriceHistoryCoverage(key: item.key, start: item.start, end: item.end, checkedAt: now, complete: false)); continue
                    }
                    if matched[pair] == nil { matched[pair] = await binanceMatches(pair: pair, reference: price, now: now) }
                    guard matched[pair] == true else {
                        result.coverage.append(PriceHistoryCoverage(key: item.key, start: item.start, end: item.end, checkedAt: now, complete: false)); continue
                    }
                    try await Task.sleep(for: .milliseconds(250))
                    let data = try await request(host: "api.binance.com", path: "/api/v3/klines", query: [URLQueryItem(name: "symbol", value: pair), URLQueryItem(name: "interval", value: "1d"), URLQueryItem(name: "startTime", value: String(Int64(item.start.timeIntervalSince1970 * 1000))), URLQueryItem(name: "endTime", value: String(Int64(item.end.timeIntervalSince1970 * 1000) - 1)), URLQueryItem(name: "limit", value: "1000")])
                    let quotes = try decodeKlines(data, asset: asset, start: item.start, end: item.end, fetchedAt: now)
                    result.quotes += quotes
                    result.coverage.append(PriceHistoryCoverage(key: item.key, start: item.start, end: item.end, checkedAt: now, complete: PriceHistory.isComplete(item, observations: quotes.map(\.providerTime), now: now)))
                } catch {
                    try Task.checkCancellation(); note(error, item.source)
                    if offline { continue }
                    result.coverage.append(PriceHistoryCoverage(key: item.key, start: item.start, end: item.end, checkedAt: now, complete: false))
                }
                continue
            }
            // Exchange rates are cheap and unmetered, so a rebuilt balance history fills in within one refresh.
            // Prices stay at eight calls; at most four metal history calls per hour, leaving headroom on the free ten/hour allowance.
            if item.source == .fx {
                guard fxCount < 80 else { queued = true; continue }
                fxCount += 1
            } else {
                // Metal chunks never count as queued: the hourly gate stops a follow-up round from fetching them anyway.
                guard count < 8 else { queued = queued || item.source == .crypto; continue }
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
                    // Spaced out so a refresh stays well inside the Demo plan's 30 calls a minute.
                    try await Task.sleep(for: .seconds(2))
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
                    let fetched = try await rates(item.identifier, start: item.start, end: item.end, wiseToken: wiseToken)
                    result.rates += fetched; observations = fetched.map(\.providerTime)
                }
                let complete = PriceHistory.isComplete(item, observations: observations, now: now)
                result.coverage.append(PriceHistoryCoverage(key: item.key, start: item.start, end: item.end, checkedAt: now, complete: complete))
                if !complete { result.messages.append("Some dates have no published price. Chart gaps are retained and checked again later.") }
            } catch {
                try Task.checkCancellation(); result.messages.append(message(error))
                // Offline or rate-limited: nothing is recorded, so the chunk is simply fetched at the next refresh.
                note(error, item.source)
                if offline || limited.contains(item.source) { continue }
                if item.source == .fx {
                    result.fxIssues[item.identifier] = "Couldn’t get historical \(item.identifier) → USD rates. Try again or add a rate dated for this period."
                }
                // Back off failures too, retaining the gap and retrying after six hours.
                result.coverage.append(PriceHistoryCoverage(key: item.key, start: item.start, end: item.end, checkedAt: now, complete: false))
            }
        }
        if queued && !offline { result.messages.append("More price history is queued for the next refresh.") }
        result.messages = Array(Set(result.messages)).sorted()
        return result
    }
}

extension PublicPrices {
    struct SwissquoteQuote: Decodable {
        struct Price: Decodable { var spreadProfile: String; var bid: Decimal; var ask: Decimal }
        var spreadProfilePrices: [Price]
        var ts: Double
    }
    /// Swissquote's live quote for a metal in USD an ounce: the newest platform's tightest spread, at mid-price.
    static func decodeSwissquote(_ data: Data, metal: PreciousMetal, fetchedAt: Date) throws -> QuoteObservation {
        let rows = try JSONDecoder().decode([SwissquoteQuote].self, from: data)
        guard rows.count <= 50, let row = rows.max(by: { $0.ts < $1.ts }),
              let price = row.spreadProfilePrices.first(where: { $0.spreadProfile == "prime" }) ?? row.spreadProfilePrices.first,
              MoneyInput.isFinite(price.bid), MoneyInput.isFinite(price.ask), price.bid > 0, price.ask >= price.bid, row.ts.isFinite, row.ts > 0 else { throw PriceError.invalidResponse }
        let time = Date(timeIntervalSince1970: row.ts / 1000)
        guard time <= fetchedAt.addingTimeInterval(300) else { throw PriceError.invalidResponse }
        return QuoteObservation(assetID: metal.assetID, priceUSD: PreciseDecimal(try PriceHistory.pricePerGram((price.bid + price.ask) / 2)), providerTime: time, fetchedAt: fetchedAt, provider: "Swissquote · spot")
    }
    /// A metal's spot price: Gold API's, or Swissquote's when Gold API can't answer (down, limited or changed).
    static func metalSpot(_ metal: PreciousMetal, fetchedAt: Date) async throws -> QuoteObservation {
        do {
            let data = try await request(host: "api.gold-api.com", path: "/price/" + metal.rawValue, query: [])
            return try PriceHistory.decodeMetal(data, metal: metal, fetchedAt: fetchedAt)
        } catch {
            if isOffline(error) { throw error }
            let data = try await request(host: "forex-data-feed.swissquote.com", path: "/public-quotes/bboquotes/instrument/" + metal.rawValue + "/USD", query: [])
            return try decodeSwissquote(data, metal: metal, fetchedAt: fetchedAt)
        }
    }

    /// Binance's pair against USDT for a ticker, or nil when it can't be one.
    static func binancePair(_ symbol: String) -> String? {
        let upper = symbol.uppercased()
        guard (2...12).contains(upper.count), upper.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }), upper != "USDT" else { return nil }
        return upper + "USDT"
    }
    /// Binance daily candles as each day's closing price, for days in `start..<end` that have closed.
    static func decodeKlines(_ data: Data, asset: CanonicalAssetID, start: Date, end: Date, fetchedAt: Date) throws -> [QuoteObservation] {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[Any]], rows.count <= 1000 else { throw PriceError.invalidResponse }
        var result: [QuoteObservation] = []
        for row in rows {
            guard row.count >= 7, let open = (row[0] as? NSNumber)?.doubleValue, let closeText = row[4] as? String, let closeTime = (row[6] as? NSNumber)?.doubleValue,
                  let close = Decimal(string: closeText, locale: Locale(identifier: "en_US_POSIX")), MoneyInput.isFinite(close), close > 0 else { continue }
            let opened = Date(timeIntervalSince1970: open / 1000), closed = Date(timeIntervalSince1970: closeTime / 1000)
            guard opened >= start, opened < end, closed <= fetchedAt else { continue }
            result.append(QuoteObservation(assetID: asset, priceUSD: PreciseDecimal(close), providerTime: closed, fetchedAt: fetchedAt, provider: "Binance · daily close"))
        }
        return result.sorted { $0.providerTime < $1.providerTime }
    }
    /// Whether a Binance pair is the same coin: its latest close within 15% of the price CoinGecko gives, since a
    /// ticker alone can belong to two coins.
    static func binanceMatches(pair: String, reference: Decimal, now: Date) async -> Bool {
        guard reference > 0, let data = try? await request(host: "api.binance.com", path: "/api/v3/klines", query: [URLQueryItem(name: "symbol", value: pair), URLQueryItem(name: "interval", value: "1d"), URLQueryItem(name: "limit", value: "2")]),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[Any]], let last = rows.last, last.count >= 5,
              let text = last[4] as? String, let close = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), close > 0 else { return false }
        let ratio = NSDecimalNumber(decimal: close / reference).doubleValue
        return ratio > 0.85 && ratio < 1.15
    }
    /// Tickers of the 250 largest coins (CoinGecko, September 2026), for finding long history when today's market
    /// list hasn't been fetched in the same update.
    static let knownSymbols: [String: String] = [
        "bitcoin": "btc", "ethereum": "eth", "tether": "usdt", "binancecoin": "bnb", "ripple": "xrp",
        "usd-coin": "usdc", "solana": "sol", "tron": "trx", "zcash": "zec", "hyperliquid": "hype",
        "dogecoin": "doge", "monero": "xmr", "whitebit": "wbt", "usds": "usds", "chainlink": "link",
        "cardano": "ada", "rain": "rain", "leo-token": "leo", "stellar": "xlm", "bitcoin-cash": "bch",
        "near": "near", "uniswap": "uni", "litecoin": "ltc", "ethena-usde": "usde", "dai": "dai",
        "avalanche-2": "avax", "usd1-wlfi": "usd1", "canton-network": "cc", "hedera-hashgraph": "hbar",
        "the-open-network": "gram", "sui": "sui", "shiba-inu": "shib", "global-dollar": "usdg", "bittensor": "tao",
        "crypto-com-chain": "cro", "bitway": "btw", "memecore": "m", "paypal-usd": "pyusd", "tether-gold": "xaut",
        "okb": "okb", "hashnote-usyc": "usyc", "ripple-usd": "rlusd",
        "blackrock-usd-institutional-digital-liquidity-fund": "buidl", "ondo-us-dollar-yield": "usdy",
        "mantle": "mnt", "ondo-finance": "ondo", "aave": "aave", "ethena": "ena", "aster-2": "aster",
        "polkadot": "dot", "morpho": "morpho", "pax-gold": "paxg", "pepe": "pepe", "pump-fun": "pump",
        "world-liberty-financial": "wlfi", "internet-computer": "icp", "sky": "sky", "htx-dao": "htx",
        "usdd": "usdd", "worldcoin-wld": "wld", "ethereum-classic": "etc", "united-stables": "u",
        "spiko-amundi-overnight-swap-fund-eur": "eursafo", "arbitrum": "arb", "bitget-token": "bgb",
        "usdgo": "usdgo", "venice-token": "vvv", "falcon-finance": "usdf", "bfusd": "bfusd", "lighter": "lit",
        "gatechain-token": "gt", "quant-network": "qnt", "polygon-ecosystem-token": "pol", "kaspa": "kas",
        "kucoin-shares": "kcs", "blockchain-capital": "bcap", "pi-network": "pi", "algorand": "algo",
        "jupiter-exchange-solana": "jup", "render-token": "render", "akedo": "ake", "just": "jst", "cosmos": "atom",
        "nexo": "nexo", "pancakeswap-token": "cake", "injective-protocol": "inj", "filecoin": "fil",
        "vechain": "vet", "dash": "dash", "eutbl": "eutbl",
        "superstate-short-duration-us-government-securities-fund-ustb": "ustb", "stable-2": "stable", "gho": "gho",
        "aptos": "apt", "aerodrome-finance": "aero", "ether-fi": "ethfi", "pudgy-penguins": "pengu",
        "flare-networks": "flr", "beldex": "bdx", "xdce-crowd-sale": "xdc",
        "janus-henderson-anemoy-aaa-clo-fund": "jaaa", "blockstack": "stx", "official-trump": "trump",
        "usual-usd": "usd0", "raydium": "ray", "curve-dao-token": "crv", "layerzero": "zro", "ylds": "ylds",
        "pyth-network": "pyth", "true-usd": "tusd", "usdtb": "usdtb", "a7a5": "a7a5", "virtual-protocol": "virtual",
        "euro-coin": "eurc", "fetch-ai": "fet", "celestia": "tia", "pieverse": "pieverse", "bitcoin-cash-sv": "bsv",
        "derive": "drv", "pendle": "pendle", "pons": "pons", "falcon-finance-ff": "ff", "spx6900": "spx",
        "sei-network": "sei", "midnight-3": "night", "hash-2": "hash", "bittorrent": "btt", "tezos": "xtz",
        "unibase": "ub", "sun-token": "sun", "lido-dao": "ldo", "kinesis-gold": "kau",
        "janus-henderson-anemoy-treasury-fund": "jtrsy", "first-digital-usd": "fdusd", "bedrock-token": "br",
        "sofiusd": "sofid", "decred": "dcr", "ousg": "ousg", "apxusd": "apxusd", "kite-2": "kite", "bonk": "bonk",
        "gnosis": "gno", "olympus": "ohm", "terra-luna": "lunc", "ethereum-name-service": "ens", "stonk-3": "stonk",
        "grass": "grass", "re-protocol-reusd": "reusd", "optimism": "op", "arweave": "ar", "monad": "mon",
        "starknet": "strk", "useless-3": "useless", "the-graph": "grt", "conflux-token": "cfx", "floki": "floki",
        "ape-and-pepe": "apepe", "plasma": "xpl", "ribbita-by-virtuals": "tibbir", "jito-governance-token": "jto",
        "apenft": "nft", "kinesis-silver": "kag", "bnb48-club-token": "koge", "syrup": "syrup", "dogwifcoin": "wif",
        "compound-governance-token": "comp", "trust-wallet-token": "twt", "backpack": "bp", "artificial-inu-3": "ai",
        "agora-dollar": "ausd", "zama": "zama", "crvusd": "crvusd", "eigenlayer": "eigen", "usx": "usx",
        "frax": "frax", "jasmycoin": "jasmy", "iota": "iota", "theta-token": "theta", "safo": "safo",
        "build-on": "b", "kaia": "kaia", "usdai": "usdai", "thorchain": "rune", "kamino": "kmno",
        "zebec-network": "zbcn", "tradable-na-rent-financing-platform-sstn": "pc0000031", "akash-network": "akt",
        "mina-protocol": "mina", "chain-2": "xcn", "edgex": "edge", "societe-generale-forge-eurcv": "eurcv",
        "meteora": "met", "fartcoin": "fartcoin", "usa": "usat", "doublezero": "2z", "non-playable-coin": "npc",
        "convex-finance": "cvx", "axie-infinity": "axs", "ecash": "xec", "neo": "neo", "swissborg": "borg",
        "mx-token": "mx", "apyusd": "apyusd", "spiko-us-t-bills-money-market-fund": "ustbl", "vision-3": "vsn",
        "shuffle-2": "shfl", "telcoin": "tel", "chiliz": "chz", "railgun": "rail", "btse-token": "btse",
        "origintrail": "trac", "tradable-apac-diversified-finance-provider-sstn": "pc0000033", "coco-2": "coco",
        "decentraland": "mana", "ultima": "ultima", "sonic-3": "s", "vaulta": "a", "dgrid-ai": "dgai",
        "aioz-network": "aioz", "sentient": "sent", "collector-crypt": "cards", "gmt-token": "gomining",
        "gusd": "gusd", "apecoin": "ape", "cash-cat": "cashcat", "safepal": "sfp", "seeker": "skr",
        "strategy-pp-variable-xstock": "strcx", "meta-2-2": "meta", "1inch": "1inch", "havven": "snx",
        "tradable-latam-fintech-sstn": "pc0000097", "jpycoin": "jpyc", "elrond-erd-2": "egld",
        "basic-attention-token": "bat", "zencash": "zen", "rollbit-coin": "rlb", "immutable-x": "imx",
        "cash-4": "cash", "humanity": "h", "jpysc": "jpysc", "ozone-chain": "ozo", "avant-usd": "avusd",
        "grx-chain": "grx", "stp-network": "awe", "golem": "glm", "bc-token": "bc"
    ]
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
    /// "STANDARD" for the main balance, "SAVINGS" for a jar. Optional so older fixtures decode.
    var type: String?
    /// A jar's name; the main balance has none.
    var name: String?
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
    /// Wise's USD rate for a currency: the latest, or one a day over `start..<end`.
    static func rates(_ currency: String, start: Date?, end: Date?, token: String) async throws -> [FXObservation] {
        let code = try MoneyInput.normalizeCurrency(currency)
        var query = [URLQueryItem(name: "source", value: code), URLQueryItem(name: "target", value: "USD")]
        if let start, let end {
            query += [URLQueryItem(name: "from", value: ImportDateFormat.today(start) + "T00:00"), URLQueryItem(name: "to", value: ImportDateFormat.today(end) + "T00:00"),
                      URLQueryItem(name: "group", value: "day")]
        }
        let data = try await request(path: "/v1/rates", query: query, token: token)
        return try PublicPrices.decodeWiseRates(data, currency: code, fetchedAt: Date(), daily: start != nil, start: start, end: end)
    }
    static func fetch(_ connection: WiseConnection) async throws -> WiseSnapshot {
        var profiles: [WiseProfileSnapshot] = []
        for profile in connection.profiles {
            try Task.checkCancellation()
            // Jars (SAVINGS) hold money too; leaving them out understates the company's cash.
            let balanceData = try await request(path: "/v4/profiles/\(profile.id)/balances", query: [URLQueryItem(name: "types", value: "STANDARD,SAVINGS")], token: connection.token)
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
                    let jar = balance.type == "SAVINGS" ? (balance.name ?? "Jar") : nil
                    var account = Account(name: item.profile.name + " · " + currency + (jar.map { " · " + $0 } ?? ""), currency: currency)
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
                // Offline or rate-limited: stop without a cooldown so these months are tried again at the next refresh.
                if isOffline(error) || (error as? PriceError) == .rateLimited { break }
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
