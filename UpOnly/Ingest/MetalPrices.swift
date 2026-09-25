import Foundation

/// Metal prices: Gold API's spot price, with Swissquote as the backup.
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
}
