import Foundation

/// Accounting observations live inside the encrypted vault. Bank movements never
/// substitute for profit, and an absent month is different from a reported zero.
nonisolated struct BusinessMonth: Codable, Sendable, Equatable {
    var month: String
    var profitUSD: Decimal
    var revenueUSD: Decimal?
    var expensesUSD: Decimal?
    var sourceRange: String
    var estimated: Bool = false
    var warning: String?
}
nonisolated struct BusinessBook: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var name: String
    var ownership: [OwnershipPeriod]
    var firstMonth: String
    var sourceURL: String
    var basis: String
    var months: [BusinessMonth] = []
    var fetchedAt: Date
    var modifiedAt: Date?
    var warning: String?
    var transferCounterparties: [String]?
}
nonisolated struct BusinessContribution: Identifiable {
    var book: BusinessBook
    var observation: BusinessMonth?
    var share: Decimal?
    var id: String { book.id }
    var ownershipLabel: String
    var title: String { book.name + " · " + ownershipLabel }
}

nonisolated struct OwnershipPeriod: Codable, Sendable, Equatable {
    var fromMonth: String
    var numerator: Int
    var denominator: Int
    var label: String { numerator == 1 && denominator == 3 ? "⅓" : NSDecimalNumber(decimal: Decimal(numerator) / Decimal(denominator) * 100).stringValue + "%" }
    func portion(_ amount: Decimal) throws -> Decimal {
        guard numerator >= 0, denominator > 0, numerator <= denominator else { throw VaultError.invalidAmount }
        var a = try MoneyInput.multiply(amount, Decimal(numerator)), b = Decimal(denominator), value = Decimal(), rounded = Decimal()
        let status = NSDecimalDivide(&value, &a, &b, .plain)
        guard status == .noError || status == .lossOfPrecision else { throw VaultError.invalidAmount }
        NSDecimalRound(&rounded, &value, 2, .plain)
        try MoneyInput.requireFinite(rounded)
        return rounded
    }
}
extension BusinessBook {
    func ownership(at month: String) -> OwnershipPeriod? { ownership.filter { $0.fromMonth <= month }.max { $0.fromMonth < $1.fromMonth } }
}

/// Successful source updates cannot erase a different company's cached history.
nonisolated enum AccountingHistory {
    static func merging(_ incoming: [BusinessBook], into existing: [BusinessBook]) -> [BusinessBook] {
        var result = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for var book in incoming {
            if let saved = result[book.id] {
                guard book.fetchedAt >= saved.fetchedAt else { continue }
                let received = Set(book.months.map(\.month))
                for var row in saved.months where !received.contains(row.month) {
                    row.estimated = true
                    row.warning = "Showing saved result; the latest sheet refresh did not return this month."
                    book.months.append(row)
                }
                book.months.sort { $0.month < $1.month }
            }
            result[book.id] = book
        }
        return result.values.sorted { $0.name < $1.name }
    }
}

/// Parses labels rather than row numbers: historical Profit First sheets move
/// the totals when clients are added. Currency is the workbook's explicit USD.
nonisolated enum AccountingSheets {
    enum Cell: Decodable, Sendable, Equatable {
        case text(String), number(Decimal), empty
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .empty }
            else if let s = try? c.decode(String.self) { self = .text(s) }
            else { self = .number(try c.decode(Decimal.self)) }
        }
        var text: String { if case .text(let s) = self { return s.trimmingCharacters(in: .whitespacesAndNewlines) }; return "" }
        var number: Decimal? { if case .number(let n) = self { return n }; return nil }
    }
    struct Range: Decodable, Sendable { var range: String; var values: [[Cell]]? }
    struct Batch: Decodable, Sendable { var valueRanges: [Range] }
    static func decode(_ data: Data) throws -> Batch { try JSONDecoder().decode(Batch.self, from: data) }
    static func cell(_ rows: [[Cell]], _ row: Int, _ col: Int) -> Cell {
        guard rows.indices.contains(row), rows[row].indices.contains(col) else { return .empty }
        return rows[row][col]
    }
    static func numeric(_ cell: Cell) throws -> Decimal {
        guard let value = cell.number else { throw ImportFailure("An accounting total is blank or contains an error.") }
        try MoneyInput.requireFinite(value)
        return value
    }
    static func same(_ a: Decimal, _ b: Decimal) -> Bool { abs(a - b) <= Decimal(string: "0.01")! }
    static func profitFirstMonth(_ title: String, rows: [[Cell]] = []) -> MonthKey? {
        guard title.hasSuffix(":PF") else { return nil }
        let name = String(title.dropLast(3))
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        if name.count >= 5, let m = months.firstIndex(of: String(name.prefix(3))), let y = Int(name.suffix(2)) {
            return MonthKey(String(format: "%04d-%02d", 2000 + y, m + 1))
        }
        // Legacy tabs (Jan:PF, Dec2:PF) encode their year as a Sheets date.
        if let serial = cell(rows, 0, 0).number, serial > 40000, serial < 80000 {
            let date = Date(timeIntervalSince1970: (NSDecimalNumber(decimal: serial).doubleValue - 25569) * 86400)
            return MonthKey(String(ImportDateFormat.today(date).prefix(7)))
        }
        return nil
    }
    static func profitFirst(_ range: Range, title: String) throws -> BusinessMonth {
        guard let rows = range.values, let month = profitFirstMonth(title, rows: rows),
              let header = rows.firstIndex(where: { $0.contains { $0.text == "Actual Distr. ($)" || $0.text.hasSuffix(" Actual") } }),
              let col = rows[header].firstIndex(where: { $0.text == "Actual Distr. ($)" || $0.text.hasSuffix(" Actual") }) else {
            throw ImportFailure("The Profit First date or actual-results column needs review.")
        }
        let modern = cell(rows, header, col).text == "Actual Distr. ($)"
        let labelCol = modern ? 0 : col - 2
        guard labelCol >= 0,
              let expenseRow = rows.indices.first(where: { $0 > header && cell(rows, $0, labelCol).text == "Operating Expenses" }),
              let revenueRow = modern ? Optional(header + 1) : rows.indices.first(where: { $0 > header && cell(rows, $0, labelCol).text == "Real Revenue" }) else { throw ImportFailure("Revenue or operating expenses are missing.") }
        let revenue = try numeric(cell(rows, revenueRow, col))
        let expenses = try numeric(cell(rows, expenseRow, col))
        let profit = try MoneyInput.add(revenue, -expenses)
        let allocations = rows.indices.filter { $0 > revenueRow && $0 < expenseRow && ["Profit", "Owner's Pay", "Owner's Dividends", "Directors Salary"].contains(cell(rows, $0, labelCol).text) }
        guard !allocations.isEmpty else { throw ImportFailure("The accounting allocation rows are missing.") }
        let allocated = try allocations.reduce(Decimal(0)) { try MoneyInput.add($0, numeric(cell(rows, $1, col))) }
        var warnings: [String] = []
        if !same(allocated, profit) { warnings.append("Owner allocations do not reconcile. This result uses actual revenue less operating expenses, before payouts.") }
        if let clientHeader = rows.firstIndex(where: { $0.map(\.text).contains("Profit/Loss") }),
           let profitCol = rows[clientHeader].firstIndex(where: { $0.text == "Profit/Loss" }),
           let total = rows.indices.first(where: { $0 > clientHeader && $0 < header && cell(rows, $0, 0).text.uppercased() == "TOTAL" }),
           let listed = cell(rows, total, profitCol).number, !same(listed, profit) {
            warnings.append("The client Profit/Loss total differs from the actual revenue less operating expenses used here. Review the sheet.")
        }
        let warning = warnings.isEmpty ? nil : warnings.joined(separator: " ")
        return BusinessMonth(month: month.description, profitUSD: profit, revenueUSD: revenue, expensesUSD: expenses, sourceRange: "'" + title + "'!" + column(col) + String(revenueRow + 1) + " minus " + column(col) + String(expenseRow + 1), estimated: warning != nil, warning: warning)
    }
    static func pnl(_ range: Range) throws -> [BusinessMonth] {
        guard let rows = range.values,
              let header = rows.firstIndex(where: { $0.contains { MonthKey(String($0.text.prefix(7))) != nil } }),
              let net = rows.indices.first(where: { cell(rows, $0, 0).text.uppercased() == "NET PROFIT" }) else { throw ImportFailure("The P&L month headings or NET PROFIT row are missing.") }
        var months: [BusinessMonth] = []
        for col in rows[header].indices {
            let title = cell(rows, header, col).text
            guard let month = MonthKey(String(title.prefix(7))) else { continue }
            let value = try numeric(cell(rows, net, col))
            guard !months.contains(where: { $0.month == month.description }) else { throw ImportFailure("The P&L contains a duplicate month.") }
            let revenueRow = rows.indices.first { cell(rows, $0, 0).text == "Net proceeds (reaches the bank)" }
            let costsRow = rows.indices.first { cell(rows, $0, 0).text == "Total operating expenses" }
            let cogsRow = rows.indices.first { cell(rows, $0, 0).text == "Hosting / infra (COGS)" }
            let revenue = revenueRow.flatMap { cell(rows, $0, col).number }
            var costs = costsRow.flatMap { cell(rows, $0, col).number }
            if let operating = costs, let cogs = cogsRow.flatMap({ cell(rows, $0, col).number }) { costs = try MoneyInput.add(operating, cogs) }
            if let revenue, let costs, !same(try MoneyInput.add(revenue, -costs), value) { throw ImportFailure("P&L revenue and costs do not reconcile to net profit.") }
            months.append(BusinessMonth(month: month.description, profitUSD: value, revenueUSD: revenue, expensesUSD: costs, sourceRange: "'P&L'!" + column(col) + String(net + 1), estimated: title.lowercased().contains("so far") || month == .current()))
        }
        guard !months.isEmpty else { throw ImportFailure("No accounting months were found.") }
        return months
    }
    static func healthWarning(_ range: Range?) -> String? {
        guard let rows = range?.values, !rows.isEmpty else { return "Accounting checks are unavailable." }
        let lines = rows.map { $0.map(\.text).filter { !$0.isEmpty }.joined(separator: " · ") }
        if lines.contains(where: { $0.uppercased().contains("FAILING") || $0.contains("✗") }) {
            return "The accounting sheet reports a failed check. Profit is provisional; review Data Health."
        }
        if lines.contains(where: { $0.lowercased().contains("estimate") || $0.lowercased().contains("accrued") }) {
            return "Some store revenue is estimated. See the accounting sheet's Data Health checks."
        }
        return nil
    }
    static func column(_ index: Int) -> String {
        var n = index + 1, result = ""
        while n > 0 { n -= 1; result = String(UnicodeScalar(65 + n % 26)!) + result; n /= 26 }
        return result
    }
}

#if UPONLY_PERSONAL
import Security

nonisolated struct AccountingConnection: Codable, Sendable {
    struct Source: Codable, Sendable {
        var id: String
        var name: String
        var sheetID: String
        var layout: String
        var firstMonth: String
        var ownership: [OwnershipPeriod]
        var transferCounterparties: [String]?
    }
    var email: String
    var privateKeyDER: Data
    var sources: [Source]
    static let service = "org.uponly.personal.accounting"
    static func load() throws -> Self {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: "connection", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne, kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { throw ImportFailure("The private accounting connection is unavailable in Keychain.") }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard !value.email.isEmpty, value.sources.count > 0, value.sources.count <= 10,
              Set(value.sources.map(\.id)).count == value.sources.count else { throw ImportFailure("Check the accounting connection configuration.") }
        for source in value.sources {
            guard !source.id.isEmpty, !source.sheetID.isEmpty, source.sheetID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }),
                  ["pnl", "profitFirst"].contains(source.layout), MonthKey(source.firstMonth) != nil,
                  !source.ownership.isEmpty, Set(source.ownership.map(\.fromMonth)).count == source.ownership.count,
                  source.ownership.allSatisfy({ MonthKey($0.fromMonth) != nil && $0.numerator > 0 && $0.denominator >= $0.numerator }) else { throw ImportFailure("Check the accounting source or ownership history.") }
        }
        return value
    }
}
nonisolated struct AccountingFetch: Sendable {
    var books: [BusinessBook]
    var failedSources: [String]
}
nonisolated enum AccountingAPI {
    enum HTTPFailure: Error { case status(Int) }
    static func isRetryable(_ error: Error) -> Bool {
        if case HTTPFailure.status(let status) = error { return status == 429 || (500...599).contains(status) }
        guard let error = error as? URLError else { return false }
        return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .dnsLookupFailed].contains(error.code)
    }
    static func retrying(_ operation: () async throws -> Data, pause: (Int) async throws -> Void = { attempt in try await Task.sleep(for: .milliseconds(300 * (attempt + 1))) }) async throws -> Data {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do { return try await operation() }
            catch {
                guard attempt < 2, isRetryable(error) else { throw error }
                try await pause(attempt)
            }
        }
        throw PriceError.invalidResponse
    }

    static func base64URL(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    static func request(host: String, path: String, query: [URLQueryItem] = [], token: String? = nil, body: Data? = nil) async throws -> Data {
        try await retrying { try await requestOnce(host: host, path: path, query: query, token: token, body: body) }
    }
    private static func requestOnce(host: String, path: String, query: [URLQueryItem], token: String?, body: Data?) async throws -> Data {
        guard ["oauth2.googleapis.com", "sheets.googleapis.com", "www.googleapis.com"].contains(host) else { throw PriceError.invalidResponse }
        var components = URLComponents(); components.scheme = "https"; components.host = host; components.path = path; components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw PriceError.invalidResponse }
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 60
        let session = URLSession(configuration: config, delegate: NoAccountingRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body { request.httpMethod = "POST"; request.httpBody = body; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type") }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw PriceError.invalidResponse }
        guard http.statusCode == 200 else { throw HTTPFailure.status(http.statusCode) }
        var data = Data()
        for try await byte in bytes { guard data.count < 8 * 1024 * 1024 else { throw PriceError.invalidResponse }; data.append(byte) }
        return data
    }
    static func token(_ connection: AccountingConnection) async throws -> String {
        let header = base64URL(Data(#"{"alg":"RS256","typ":"JWT"}"#.utf8))
        let now = Int(Date().timeIntervalSince1970)
        let claims: [String: Any] = ["iss": connection.email, "scope": "https://www.googleapis.com/auth/spreadsheets.readonly https://www.googleapis.com/auth/drive.metadata.readonly", "aud": "https://oauth2.googleapis.com/token", "iat": now, "exp": now + 3600]
        let payload = base64URL(try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys]))
        let message = header + "." + payload
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(connection.privateKeyDER as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate] as CFDictionary, &error),
              let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(message.utf8) as CFData, &error) as Data? else { throw ImportFailure("The accounting signing key could not be read.") }
        var form = URLComponents(); form.queryItems = [URLQueryItem(name: "grant_type", value: "urn:ietf:params:oauth:grant-type:jwt-bearer"), URLQueryItem(name: "assertion", value: message + "." + base64URL(signature))]
        let data = try await request(host: "oauth2.googleapis.com", path: "/token", body: Data((form.percentEncodedQuery ?? "").utf8))
        struct Token: Decodable { var access_token: String }
        return try JSONDecoder().decode(Token.self, from: data).access_token
    }
    struct Metadata: Decodable { struct Sheet: Decodable { struct Properties: Decodable { var title: String }; var properties: Properties }; var sheets: [Sheet] }
    struct FileMetadata: Decodable { var modifiedTime: String }
    static func fetch(_ connection: AccountingConnection) async throws -> [BusinessBook] {
        try await fetchResult(connection).books
    }
    static func fetchResult(_ connection: AccountingConnection) async throws -> AccountingFetch {
        let accessToken = try await token(connection)
        return try await collect(connection.sources) { try await fetchBook($0, token: accessToken) }
    }
    static func collect(_ sources: [AccountingConnection.Source], load: (AccountingConnection.Source) async throws -> BusinessBook) async throws -> AccountingFetch {
        var result = AccountingFetch(books: [], failedSources: [])
        for source in sources {
            try Task.checkCancellation()
            do { result.books.append(try await load(source)) }
            catch {
                if error is CancellationError { throw error }
                try Task.checkCancellation()
                result.failedSources.append(source.name)
                // Keep the expected company visible even on its very first failed fetch.
                // Otherwise a successful sibling could masquerade as a complete personal result.
                result.books.append(BusinessBook(id: source.id, name: source.name, ownership: source.ownership, firstMonth: source.firstMonth,
                                                 sourceURL: "https://docs.google.com/spreadsheets/d/" + source.sheetID + "/edit",
                                                 basis: "Accounting result unavailable.", fetchedAt: .distantPast,
                                                 warning: "This company could not refresh; no saved results are available."))
            }
        }
        guard result.failedSources.count < sources.count else { throw ImportFailure("Couldn’t refresh accounting. Saved results are retained; retry when connected.") }
        return result
    }
    private static func fetchBook(_ source: AccountingConnection.Source, token accessToken: String) async throws -> BusinessBook {
            var book = BusinessBook(id: source.id, name: source.name, ownership: source.ownership, firstMonth: source.firstMonth,
                                    sourceURL: "https://docs.google.com/spreadsheets/d/" + source.sheetID + "/edit",
                                    basis: source.layout == "profitFirst" ? "Actual revenue less operating expenses, before all owner payouts." : "Accounting P&L NET PROFIT, before owner draws.", fetchedAt: Date())
            book.transferCounterparties = source.transferCounterparties ?? OwnerPayments.privateCounterparties[source.id]
            let path = "/v4/spreadsheets/" + source.sheetID
            // Drive timestamps are optional metadata, not a prerequisite for reading profit.
            if let modified = try? await request(host: "www.googleapis.com", path: "/drive/v3/files/" + source.sheetID, query: [URLQueryItem(name: "fields", value: "modifiedTime")], token: accessToken),
               let time = try? JSONDecoder().decode(FileMetadata.self, from: modified).modifiedTime {
                let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                book.modifiedAt = formatter.date(from: time) ?? ISO8601DateFormatter().date(from: time)
            }
            try Task.checkCancellation()
            var titles: [String] = []
            let ranges: [String]
            if source.layout == "profitFirst" {
                let metadata = try await request(host: "sheets.googleapis.com", path: path, query: [URLQueryItem(name: "fields", value: "sheets(properties(title))")], token: accessToken)
                titles = try JSONDecoder().decode(Metadata.self, from: metadata).sheets.map(\.properties.title).filter { $0.hasSuffix(":PF") }
                guard !titles.isEmpty, titles.count <= 600 else { throw PriceError.invalidResponse }
                ranges = titles.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'!A1:L70" }
            } else { ranges = ["'P&L'!A1:AZ70", "'Data Health'!A1:O40"] }
            let query = ranges.map { URLQueryItem(name: "ranges", value: $0) } + [URLQueryItem(name: "valueRenderOption", value: "UNFORMATTED_VALUE")]
            let batch = try AccountingSheets.decode(await request(host: "sheets.googleapis.com", path: path + "/values:batchGet", query: query, token: accessToken))
            guard batch.valueRanges.count == ranges.count else { throw PriceError.invalidResponse }
            if source.layout == "profitFirst" {
                var failures: [String] = []
                for (title, range) in zip(titles, batch.valueRanges) {
                    do { book.months.append(try AccountingSheets.profitFirst(range, title: title)) }
                    catch { failures.append(title) }
                }
                guard Set(book.months.map(\.month)).count == book.months.count else { throw ImportFailure("Accounting contains duplicate months; saved results are unchanged.") }
                if !failures.isEmpty { book.warning = "Some source months need review: " + failures.joined(separator: ", ") }
            } else {
                book.months = try AccountingSheets.pnl(batch.valueRanges[0])
                book.warning = AccountingSheets.healthWarning(batch.valueRanges.last)
            }
            book.months.sort { $0.month < $1.month }
            guard !book.months.isEmpty else { throw ImportFailure("No readable accounting results were found. Saved results are unchanged.") }
            return book
    }
}
private final class NoAccountingRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
#endif

/// Exact configured bank counterparties only. Merchant substrings are not evidence
/// that an expense is already in the books. Ownership profit includes owner draws.
nonisolated enum OwnerPayments {
    // Non-secret, private-build configuration. Credentials stay untouched in Keychain.
    static let privateCounterparties: [String: [String]] = {
        #if UPONLY_PERSONAL
        let url = Config.supportDirectory.appendingPathComponent("payment-counterparties.json")
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16384,
              let data = try? Data(contentsOf: url), let names = try? JSONDecoder().decode([String: [String]].self, from: data),
              names.count <= 10, names.values.allSatisfy({ $0.count <= 20 && $0.allSatisfy { !$0.isEmpty && $0.count <= 100 } }) else { return [:] }
        return names
        #else
        return [:]
        #endif
    }()

    static func reconcile(in document: inout VaultDocument) {
        for index in document.entries.indices {
            let entry = document.entries[index]
            guard entry.source != .manual, entry.bucket == .personal, entry.kindIsUserEdited != true else { continue }
            if isPersonalTransferCounterparty(entry.label, document: document) { document.entries[index].kind = .transfer }
            else if entry.kind == .transfer, isCompanyCounterparty(entry.label, month: entry.month, document: document) {
                // Money a connected company paid you is income in Personal. Earlier versions saved it as a transfer.
                document.entries[index].kind = .income
            }
        }
    }
    /// Classifies an imported personal transaction. Payees marked as always transfers, and money you send to a
    /// connected company, are transfers. Money a connected company pays you stays income; "All" nets it against profit.
    static func classify(_ kind: EntryKind, label: String, month: String, document: VaultDocument) -> EntryKind {
        if isPersonalTransferCounterparty(label, document: document) { return .transfer }
        if kind == .expense, isCompanyCounterparty(label, month: month, document: document) { return .transfer }
        return kind
    }
    static func isPersonalTransferCounterparty(_ label: String, document: VaultDocument) -> Bool {
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        return (document.transferCounterparties ?? []).contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }
    /// Remembers `label` as a transfer payee and reclassifies matching imported personal entries the user has not edited.
    /// Removing a payee keeps existing classifications; a saved entry does not record its original direction.
    static func setTransferCounterparty(_ label: String, enabled: Bool, in document: inout VaultDocument) {
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 500 else { return }
        var names = document.transferCounterparties ?? []
        names.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
        if enabled { names.append(name) }
        document.transferCounterparties = names.isEmpty ? nil : names
        guard enabled else { return }
        for index in document.entries.indices {
            let entry = document.entries[index]
            guard entry.source != .manual, entry.bucket == .personal, entry.kindIsUserEdited != true,
                  entry.label.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(name) == .orderedSame else { continue }
            document.entries[index].kind = .transfer
        }
    }
    static func isCompanyCounterparty(_ label: String, month: String, document: VaultDocument) -> Bool {
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        return (document.businessAccounting ?? []).contains { book in
            guard let ownership = book.ownership(at: month), ownership.numerator > 0 else { return false }
            return (book.transferCounterparties ?? privateCounterparties[book.id] ?? []).contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        }
    }
}
