import Foundation

/// Coin prices: Binance first (one request for every price), CoinGecko for the rest, and each source's history,
/// day prices and chart candles.
extension PublicPrices {
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
    static func quotes(ids: [String], key: String) async throws -> [QuoteObservation] { try await cryptoQuotes(ids: ids, key: key).quotes }
    /// Every price Binance trades against USDT, from one request that names no coin, kept for a minute so the refresh,
    /// the charts and the Add form share it. Binance's other requests (history, charts, a day's price, a single price)
    /// name the coin's trading pair.
    static func binanceBook() async throws -> [String: Decimal] {
        if let cached = await BinanceBook.shared.fresh() { return cached }
        let data = try await request(host: "api.binance.com", path: "/api/v3/ticker/price", query: [], limit: 4 * 1024 * 1024)
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw PriceError.invalidResponse }
        var book: [String: Decimal] = [:]
        for row in rows {
            guard let symbol = row["symbol"] as? String, symbol.hasSuffix("USDT"), let text = row["price"] as? String,
                  let price = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), MoneyInput.isFinite(price), price > 0 else { continue }
            book[symbol] = price
        }
        guard !book.isEmpty else { throw PriceError.invalidResponse }
        await BinanceBook.shared.store(book)
        return book
    }
    /// Current coin prices, Binance first: one request for all its prices, used for coins whose ticker is known to be
    /// theirs (CoinGecko's top coins) and, when a saved price is given, agrees with it. CoinGecko's top-coins list
    /// prices the rest, and everything when Binance can't be reached (it blocks some countries, the US among them).
    static func cryptoQuotes(ids: [String], key: String, saved: [String: Decimal] = [:]) async throws -> (quotes: [QuoteObservation], symbols: [String: String]) {
        let wanted = Set(ids)
        var symbols = knownSymbols, quotes: [QuoteObservation] = []
        if let book = try? await binanceBook() {
            let now = Date()
            for id in wanted.sorted() {
                guard let symbol = knownSymbols[id], let pair = binancePair(symbol), let price = book[pair] else { continue }
                // A price far from the last saved one means the ticker isn't this coin here; CoinGecko decides.
                if let last = saved[id], last > 0, abs(NSDecimalNumber(decimal: price / last).doubleValue - 1) > 0.5 { continue }
                quotes.append(QuoteObservation(assetID: CanonicalAssetID(rawValue: id), priceUSD: PreciseDecimal(price), providerTime: now, fetchedAt: now, provider: "Binance"))
            }
        }
        let rest = wanted.subtracting(quotes.map(\.assetID.rawValue))
        if !rest.isEmpty {
            do {
                let listed = try await marketQuotes(ids: rest.sorted(), key: key)
                quotes += listed.quotes
                symbols.merge(listed.symbols) { _, latest in latest }
            } catch { if quotes.isEmpty { throw error } }
        }
        return (quotes, symbols)
    }
    /// Current prices, naming as few of your coins as it can: the 250 largest by market cap in one request, then the
    /// next 250 if a coin is still missing, and a coin outside those is asked for by name (history requests always name
    /// the coin). Also returns each listed coin's ticker, for finding its long history on an exchange. An ID that isn't
    /// valid is left out, so it can't cost the others their prices.
    static func marketQuotes(ids: [String], key: String) async throws -> (quotes: [QuoteObservation], symbols: [String: String]) {
        var wanted = Set(ids.compactMap { try? MoneyInput.canonicalAssetID($0) })
        var result: [QuoteObservation] = [], symbols: [String: String] = [:]
        // Each request stands alone: one that fails (a rate limit, a timeout) keeps what the others priced.
        var failure: Error?
        for page in 1...2 where !wanted.isEmpty && failure == nil {
            do {
                let data = try await request(host: "api.coingecko.com", path: "/api/v3/coins/markets", query: [URLQueryItem(name: "vs_currency", value: "usd"), URLQueryItem(name: "order", value: "market_cap_desc"), URLQueryItem(name: "per_page", value: "250"), URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "precision", value: "full")], key: key, limit: 4 * 1024 * 1024)
                let listed = try decodeMarkets(data, wanted: wanted, fetchedAt: Date())
                result += listed.quotes; symbols.merge(listed.symbols) { first, _ in first }
                wanted.subtract(listed.quotes.map(\.assetID.rawValue))
            } catch { try Task.checkCancellation(); failure = error }
        }
        let rest = wanted.sorted()
        for start in stride(from: 0, to: rest.count, by: 100) where failure == nil {
            let batch = Array(rest[start..<min(start + 100, rest.count)])
            do {
                let data = try await request(host: "api.coingecko.com", path: "/api/v3/simple/price", query: [URLQueryItem(name: "ids", value: batch.joined(separator: ",")), URLQueryItem(name: "vs_currencies", value: "usd"), URLQueryItem(name: "include_last_updated_at", value: "true"), URLQueryItem(name: "precision", value: "full")], key: key)
                result += try decodeQuotes(data, requested: Set(batch), fetchedAt: Date())
            } catch { try Task.checkCancellation(); failure = error }
        }
        if let failure, result.isEmpty { throw failure }
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

    /// A past day's typical price in dollars, per coin or per gram of gold, for filling in what a buy cost when its
    /// time isn't known: the day's volume-weighted average on Binance (what was actually paid on average), else the
    /// average of CoinGecko's prices through that day (within the past year). Gold: Binance's PAXG. Nil when none.
    static func dayPrice(assetID: String, symbol: String?, day: Date, today: Decimal?, key: String, now: Date = Date()) async -> Decimal? {
        let start = UTCDay.start(of: day), end = start.addingTimeInterval(86400)
        guard end <= now else { return nil }
        func binanceAverage(_ pair: String) async -> Decimal? {
            guard let data = try? await request(host: "api.binance.com", path: "/api/v3/klines", query: [URLQueryItem(name: "symbol", value: pair), URLQueryItem(name: "interval", value: "1d"), URLQueryItem(name: "startTime", value: String(Int64(start.timeIntervalSince1970 * 1000))), URLQueryItem(name: "endTime", value: String(Int64(end.timeIntervalSince1970 * 1000) - 1)), URLQueryItem(name: "limit", value: "1")]),
                  let rows = try? JSONSerialization.jsonObject(with: data) as? [[Any]], let row = rows.first, row.count >= 8 else { return nil }
            func number(_ index: Int) -> Decimal? { (row[index] as? String).flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) } }
            // Quote volume over base volume is the day's average price; a day without trades falls back to its close.
            if let volume = number(5), volume > 0, let quoteVolume = number(7), quoteVolume > 0 { return quoteVolume / volume }
            return number(4).flatMap { $0 > 0 ? $0 : nil }
        }
        if let metal = PreciousMetal.asset(CanonicalAssetID(rawValue: assetID)) {
            guard metal == .gold, let ounce = await binanceAverage("PAXGUSDT") else { return nil }
            return try? PriceHistory.pricePerGram(ounce)
        }
        // Binance first: its pair, checked against today's price, or trusted as one of CoinGecko's top coins' tickers.
        if let symbol, let pair = binancePair(symbol) {
            var checks = knownSymbols[assetID] == symbol.lowercased()
            if let today { checks = await binanceMatches(pair: pair, reference: today, now: now) }
            if checks, let average = await binanceAverage(pair) { return average }
        }
        if now.timeIntervalSince(start) < 364 * 86400, let segment = try? pathSegment(assetID),
           let data = try? await request(host: "api.coingecko.com", path: "/api/v3/coins/" + segment + "/market_chart/range", query: [URLQueryItem(name: "vs_currency", value: "usd"), URLQueryItem(name: "from", value: String(Int(start.timeIntervalSince1970))), URLQueryItem(name: "to", value: String(Int(end.timeIntervalSince1970)))], key: key),
           let history = try? JSONDecoder().decode(PriceHistory.CryptoHistory.self, from: data) {
            let prices = history.prices.compactMap { pair -> Decimal? in
                guard pair.count == 2, let millis = pair[0], let price = pair[1], price > 0 else { return nil }
                let time = Date(timeIntervalSince1970: NSDecimalNumber(decimal: millis).doubleValue / 1000)
                return time >= start && time < end ? price : nil
            }
            if !prices.isEmpty { return prices.reduce(0, +) / Decimal(prices.count) }
        }
        return nil
    }
    /// A coin's current price from its Binance pair: the fallback when CoinGecko is busy or unreachable.
    static func binancePrice(symbol: String) async -> Decimal? {
        guard let pair = binancePair(symbol),
              let data = try? await request(host: "api.binance.com", path: "/api/v3/ticker/price", query: [URLQueryItem(name: "symbol", value: pair)]),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let text = object["price"] as? String,
              let price = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), MoneyInput.isFinite(price), price > 0 else { return nil }
        return price
    }
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
    /// Prices through the last day, week or month for the finer charts, oldest first. Binance's candles when the coin's
    /// pair checks out against `reference` (today's saved price); gold through PAXG, a token backed by an ounce of
    /// gold, scaled to the saved spot price; otherwise CoinGecko's own chart. Nothing for other metals.
    static func intraday(_ asset: CanonicalAssetID, symbol: String?, reference: Decimal?, range: WorthRange, now: Date, coinGeckoKey: String) async throws -> ChartEstimates.Series {
        guard let seconds = range.seconds, let step = range.intradayStep, let interval = range.candleInterval else { return [] }
        let start = now.addingTimeInterval(-seconds - step)
        let limit = String(Int(seconds / step) + 2)
        func candles(_ pair: String) async throws -> ChartEstimates.Series {
            let data = try await request(host: "api.binance.com", path: "/api/v3/klines", query: [URLQueryItem(name: "symbol", value: pair), URLQueryItem(name: "interval", value: interval), URLQueryItem(name: "startTime", value: String(Int64(start.timeIntervalSince1970 * 1000))), URLQueryItem(name: "limit", value: limit)])
            return try decodeCandles(data, now: now)
        }
        if let metal = PreciousMetal.asset(asset) {
            guard metal == .gold, let reference, reference > 0 else { return [] }
            let ounces = try await candles("PAXGUSDT")
            guard let last = ounces.last?.value, last > 0 else { return [] }
            // The token's shape, at the saved spot price's level: PAXG trades a little off spot.
            let scale = reference / (last / PreciousMetal.gramsPerTroyOunce)
            guard NSDecimalNumber(decimal: scale).doubleValue > 0.85, NSDecimalNumber(decimal: scale).doubleValue < 1.15 else { return [] }
            return ounces.map { ($0.time, $0.value / PreciousMetal.gramsPerTroyOunce * scale) }
        }
        if let symbol, let pair = binancePair(symbol), let reference, reference > 0, let series = try? await candles(pair), let last = series.last?.value {
            let ratio = NSDecimalNumber(decimal: last / reference).doubleValue
            if ratio > 0.85 && ratio < 1.15 { return series }
        }
        let data = try await request(host: "api.coingecko.com", path: "/api/v3/coins/" + pathSegment(asset.rawValue) + "/market_chart/range", query: [URLQueryItem(name: "vs_currency", value: "usd"), URLQueryItem(name: "from", value: String(Int(start.timeIntervalSince1970))), URLQueryItem(name: "to", value: String(Int(now.timeIntervalSince1970))), URLQueryItem(name: "precision", value: "full")], key: coinGeckoKey)
        return try decodeChartPrices(data, now: now)
    }
    /// Binance candles as prices through time: each candle's open at its start, and the last one's latest close now.
    static func decodeCandles(_ data: Data, now: Date) throws -> ChartEstimates.Series {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[Any]], rows.count <= 1000 else { throw PriceError.invalidResponse }
        var series: ChartEstimates.Series = []
        for row in rows {
            guard row.count >= 5, let open = (row[0] as? NSNumber)?.doubleValue, let text = row[1] as? String,
                  let price = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), MoneyInput.isFinite(price), price > 0 else { continue }
            let time = Date(timeIntervalSince1970: open / 1000)
            guard time <= now else { continue }
            series.append((time, price))
        }
        if let last = rows.last, last.count >= 5, let text = last[4] as? String, let close = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), close > 0 {
            series.append((now, close))
        }
        return series.sorted { $0.time < $1.time }
    }
    /// CoinGecko's chart points (every five minutes over a day, hourly over longer), oldest first.
    static func decodeChartPrices(_ data: Data, now: Date) throws -> ChartEstimates.Series {
        let response = try JSONDecoder().decode(PriceHistory.CryptoHistory.self, from: data)
        guard response.prices.count <= 30000 else { throw PriceError.invalidResponse }
        return response.prices.compactMap { pair -> (time: Date, value: Decimal)? in
            guard pair.count == 2, let millis = pair[0], let price = pair[1], MoneyInput.isFinite(price), price > 0 else { return nil }
            let time = Date(timeIntervalSince1970: NSDecimalNumber(decimal: millis).doubleValue / 1000)
            return time <= now.addingTimeInterval(300) ? (time, price) : nil
        }.sorted { $0.time < $1.time }
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

/// The last Binance price list and when it came, shared for a minute.
actor BinanceBook {
    static let shared = BinanceBook()
    private var book: [String: Decimal] = [:]
    private var fetched = Date.distantPast
    func fresh(now: Date = Date()) -> [String: Decimal]? { now.timeIntervalSince(fetched) < 60 && !book.isEmpty ? book : nil }
    func store(_ next: [String: Decimal], now: Date = Date()) { book = next; fetched = now }
}
