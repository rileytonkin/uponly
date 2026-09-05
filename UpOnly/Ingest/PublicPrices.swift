import Foundation

nonisolated struct CatalogCoin: Codable, Identifiable, Sendable, Hashable {
    var id: String
    var symbol: String
    var name: String
}
nonisolated enum PriceError: LocalizedError {
    case unavailable, invalidResponse, credentials, rateLimited
    var errorDescription: String? {
        switch self {
        case .unavailable: "The price provider is unavailable. Saved observations are unchanged."
        case .invalidResponse: "The provider returned an invalid response. Saved observations are unchanged."
        case .credentials: "Check your CoinGecko Demo API key in Sources."
        case .rateLimited: "The provider’s request limit was reached. Up Only will retry at the next refresh."
        }
    }
}
private final class NoPriceRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
nonisolated enum PublicPrices {
    static func request(host: String, path: String, query: [URLQueryItem], key: String = "", limit: Int = 2 * 1024 * 1024) async throws -> Data {
        guard ["api.coingecko.com", "api.frankfurter.dev"].contains(host), key.utf8.count <= 512,
              !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw PriceError.invalidResponse }
        var components = URLComponents(); components.scheme = "https"; components.host = host; components.path = path; components.queryItems = query
        guard let url = components.url else { throw PriceError.invalidResponse }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 40
        let session = URLSession(configuration: configuration, delegate: NoPriceRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.setValue("application/json", forHTTPHeaderField: "Accept")
        if host == "api.coingecko.com", !key.isEmpty { request.setValue(key, forHTTPHeaderField: "x-cg-demo-api-key") }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw PriceError.invalidResponse }
        if http.statusCode == 429 { throw PriceError.rateLimited }
        if host == "api.coingecko.com", [401, 403].contains(http.statusCode) { throw PriceError.credentials }
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
    struct Rates: Decodable { var base: String; var date: String; var rates: [String: Decimal] }
    static func fx(currencies: Set<String>) async throws -> [FXObservation] {
        var result: [FXObservation] = []
        for currency in currencies.sorted() where currency != "USD" {
            let code = try MoneyInput.normalizeCurrency(currency)
            let data = try await request(host: "api.frankfurter.dev", path: "/v1/latest", query: [URLQueryItem(name: "base", value: code), URLQueryItem(name: "symbols", value: "USD")])
            let response = try JSONDecoder().decode(Rates.self, from: data)
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = UTCDay.timeZone; formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
            guard response.base == code, let rate = response.rates["USD"], let date = formatter.date(from: response.date), formatter.string(from: date) == response.date, date <= Date() else { throw PriceError.invalidResponse }
            try MoneyInput.requirePositiveFinite(rate)
            result.append(FXObservation(sourceCurrency: code, targetCurrency: "USD", rate: PreciseDecimal(rate), providerTime: date, fetchedAt: Date(), provider: "Frankfurter"))
        }
        return result
    }
}
