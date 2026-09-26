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
final class NoPriceRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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
        if includeCurrent && document.settings.automaticPrices && !crypto.isEmpty {
            do {
                // Each coin's last saved price, to check Binance's against.
                let held = Set(crypto)
                var latest: [String: QuoteObservation] = [:]
                for quote in document.quotes where held.contains(quote.assetID.rawValue) && (latest[quote.assetID.rawValue].map { $0.providerTime < quote.providerTime } ?? true) {
                    latest[quote.assetID.rawValue] = quote
                }
                let saved = latest.mapValues(\.priceUSD.value)
                let listed = try await cryptoQuotes(ids: crypto, key: document.settings.coinGeckoKey, saved: saved)
                let quotes = listed.quotes
                symbols.merge(listed.symbols) { _, latest in latest }
                result.quotes += quotes
                let missing = Set(crypto).subtracting(quotes.map(\.assetID.rawValue)).sorted()
                if !missing.isEmpty { result.sourceIssues["crypto"] = "No price for " + missing.joined(separator: ", ") + ". Check the coin ID matches CoinGecko's." }
            } catch { try Task.checkCancellation(); note(error, .crypto); result.messages.append(message(error)); result.sourceIssues["crypto"] = message(error) }
        }
        if includeCurrent && document.settings.automaticMetals {
            for metal in metals.sorted(by: { $0.rawValue < $1.rawValue }) where !offline && !limited.contains(.metal) {
                do {
                    try await Task.sleep(for: .seconds(1.1))
                    result.quotes.append(try await metalSpot(metal, fetchedAt: now))
                } catch { try Task.checkCancellation(); note(error, .metal); result.messages.append(message(error)); result.sourceIssues["metals"] = message(error) }
            }
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
            // Coins: Binance's daily closes first, at any age, for a coin whose pair checks out; CoinGecko covers the
            // past year for the rest, and any recent stretch Binance couldn't serve (it blocks some countries).
            if item.source == .crypto {
                let recent = item.start >= coinGeckoStart
                var pair: String?
                if exchangeCount < 24, let symbol = symbols[item.identifier], let candidate = binancePair(symbol), let price = reference(item.identifier) {
                    if matched[candidate] == nil { matched[candidate] = await binanceMatches(pair: candidate, reference: price, now: now) }
                    if matched[candidate] == true { pair = candidate }
                }
                if let pair {
                    exchangeCount += 1
                    do {
                        try Task.checkCancellation()
                        let asset = try CanonicalAssetID(item.identifier)
                        try await Task.sleep(for: .milliseconds(250))
                        let data = try await request(host: "api.binance.com", path: "/api/v3/klines", query: [URLQueryItem(name: "symbol", value: pair), URLQueryItem(name: "interval", value: "1d"), URLQueryItem(name: "startTime", value: String(Int64(item.start.timeIntervalSince1970 * 1000))), URLQueryItem(name: "endTime", value: String(Int64(item.end.timeIntervalSince1970 * 1000) - 1)), URLQueryItem(name: "limit", value: "1000")])
                        let quotes = try decodeKlines(data, asset: asset, start: item.start, end: item.end, fetchedAt: now)
                        result.quotes += quotes
                        result.coverage.append(PriceHistoryCoverage(key: item.key, start: item.start, end: item.end, checkedAt: now, complete: PriceHistory.isComplete(item, observations: quotes.map(\.providerTime), now: now)))
                        continue
                    } catch {
                        try Task.checkCancellation()
                        if isOffline(error) { offline = true; continue }
                        // A failed Binance call doesn't hold back CoinGecko: a recent stretch falls through to it below.
                        if !recent { result.coverage.append(PriceHistoryCoverage(key: item.key, start: item.start, end: item.end, checkedAt: now, complete: false)); continue }
                    }
                } else if !recent {
                    // No exchange history to be had: record the stretch as checked so it isn't asked for again soon.
                    if exchangeCount >= 24 { queued = true; continue }
                    result.coverage.append(PriceHistoryCoverage(key: item.key, start: item.start, end: item.end, checkedAt: now, complete: false)); continue
                }
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
                    // Spaced out to stay inside CoinGecko's limits: 30 calls a minute with a key, a handful without.
                    try await Task.sleep(for: .seconds(document.settings.coinGeckoKey.isEmpty ? 6 : 2))
                    let data = try await request(host: "api.coingecko.com", path: "/api/v3/coins/" + item.identifier + "/market_chart/range", query: [URLQueryItem(name: "vs_currency", value: "usd"), URLQueryItem(name: "from", value: String(Int(item.start.timeIntervalSince1970))), URLQueryItem(name: "to", value: String(Int(item.end.timeIntervalSince1970))), URLQueryItem(name: "precision", value: "full")], key: document.settings.coinGeckoKey)
                    let quotes = try PriceHistory.decodeCrypto(data, request: item, fetchedAt: now)
                    result.quotes += quotes; observations = quotes.map(\.providerTime)
                case .metal where document.settings.metalHistoryKey.isEmpty:
                    // Without a Gold API key, gold's daily closes from Binance's PAXG (one token is backed by one troy ounce).
                    try await Task.sleep(for: .milliseconds(250))
                    let data = try await request(host: "api.binance.com", path: "/api/v3/klines", query: [URLQueryItem(name: "symbol", value: "PAXGUSDT"), URLQueryItem(name: "interval", value: "1d"), URLQueryItem(name: "startTime", value: String(Int64(item.start.timeIntervalSince1970 * 1000))), URLQueryItem(name: "endTime", value: String(Int64(item.end.timeIntervalSince1970 * 1000) - 1)), URLQueryItem(name: "limit", value: "1000")])
                    let ounces = try decodeKlines(data, asset: PreciousMetal.gold.assetID, start: item.start, end: item.end, fetchedAt: now)
                    let quotes = try ounces.map { quote in
                        var gram = quote; gram.priceUSD = PreciseDecimal(try PriceHistory.pricePerGram(quote.priceUSD.value)); gram.provider = "Binance · PAXG daily close"
                        return gram
                    }
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
