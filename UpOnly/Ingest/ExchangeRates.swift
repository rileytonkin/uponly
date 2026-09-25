import Foundation

/// Exchange rates: Frankfurter's reference rates (Wise's first in the private build), and the dated month-end
/// rates monthly figures need.
extension PublicPrices {
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

extension PublicPrices {
    /// Fetch only the week needed for each missing monthly result. A multi-year
    /// query exceeds the decoder's bounded response size and made Retry useless.
    static func monthlyFXRequests(document: VaultDocument, now: Date, month: MonthKey? = nil,
                                  currencies: [String]? = nil, retry: Bool = false) -> [PriceHistoryRequest] {
        guard document.settings.automaticFX else { return [] }
        let rows = document.entries.filter { $0.bucket == .personal && $0.kind != .transfer && $0.amount != 0 && $0.currency != "USD" }
        var pairs = Set(rows.compactMap { row -> String? in
            guard let key = MonthKey(row.month), key <= MonthKey.current(now: now), month == nil || key == month,
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
