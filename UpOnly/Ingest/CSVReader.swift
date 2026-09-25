import Foundation

nonisolated enum CSVReader {
    /// Rows of cells. Rows whose cells are all blank (Excel's trailing `,,,,` lines) are dropped.
    /// Allows a header row plus 20,000 data rows. Sloppy quoting is read rather than rejected: spaces around a quoted
    /// field are dropped, a quote inside an unquoted field (`12" pizza`) is an ordinary character, and text after a
    /// closing quote is kept. Only a quoted field left open at the end of the file fails.
    static func parse(_ text: String, delimiter: Character = ",") throws -> [[String]] {
        var rows: [[String]] = [], row: [String] = []
        var field = "", fieldLength = 0, quoted = false, afterQuote = false, trailing = ""
        var iterator = text.makeIterator(), pending: Character?
        var characterCount = 0
        func endField() { row.append(field); field = ""; fieldLength = 0; afterQuote = false; trailing = "" }
        func endRow() {
            endField()
            if row.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { rows.append(row) }
            row = []
        }
        while let c = pending ?? iterator.next() {
            pending = nil
            characterCount += 1
            if characterCount.isMultiple(of: 4096) { try Task.checkCancellation() }
            if quoted {
                if c == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\""); fieldLength += 1 }
                        else { quoted = false; afterQuote = true; pending = next }
                    } else { quoted = false; afterQuote = true }
                } else { field.append(c); fieldLength += 1 }
            } else if c == delimiter { endField() }
            else if c == "\n" || c == "\r" || c == "\r\n" { endRow() }
            else if afterQuote {
                // Spaces after a closing quote are dropped; other text is kept, with the spaces before it.
                if c == " " || c == "\t" { trailing.append(c) }
                else { field += trailing + String(c); fieldLength += trailing.count + 1; trailing = "" }
            } else if c == "\"" && field.allSatisfy({ $0 == " " || $0 == "\t" }) {
                // A quote opens a quoted field only at its start, after any spaces.
                field = ""; fieldLength = 0; quoted = true
            } else { field.append(c); fieldLength += 1 }
            if rows.count > 20001 || row.count > 100 || fieldLength > 100000 { throw StatementError.tooLarge }
        }
        guard !quoted else { throw StatementError.invalidCSV }
        if !field.isEmpty || !row.isEmpty || afterQuote { endRow() }
        guard rows.count <= 20001 else { throw StatementError.tooLarge }
        return rows
    }
}

nonisolated enum StatementError: LocalizedError {
    case invalidCSV, tooLarge
    var errorDescription: String? {
        switch self {
        case .invalidCSV: "This CSV couldn’t be read. Export a fresh CSV from your bank or spreadsheet and try again."
        case .tooLarge: "Choose a file under 8 MB, with at most 20,000 rows and 100 columns."
        }
    }
}

// Drafts never leave memory. All three input paths use the same validation and atomic application.
nonisolated enum ImportMode: String, CaseIterable, Sendable {
    case statements, bankBalances, holdings, metals
    var title: String {
        switch self { case .statements: "Statements"; case .bankBalances: "Bank balances"; case .holdings: "Crypto holdings"; case .metals: "Metals" }
    }
    var kind: TrackedKind {
        switch self { case .statements: .cashFlow; case .bankBalances: .banks; case .holdings: .crypto; case .metals: .metals }
    }
    var columns: [ImportColumn] {
        switch self {
        case .statements: [.date, .description, .amount, .debit, .credit, .currency, .transactionID, .type]
        case .bankBalances: [.account, .currency, .balance, .date]
        case .holdings: [.portfolio, .coin, .quantity]
        case .metals: [.portfolio, .coin, .quantity, .unit]
        }
    }
    var isHolding: Bool { self == .holdings || self == .metals }
    var template: String {
        switch self {
        case .statements: "TransactionID,Date,Description,Amount,Currency,Type\nsample-1,2026-01-02,Groceries,12.50,USD,expense\nsample-2,2026-01-03,To savings,-500.00,USD,transfer\n"
        case .bankBalances: "Account,Currency,Balance,ObservedOn\nCurrent account,USD,1250.00,2026-01-02\n"
        case .metals: "Portfolio,Metal,Weight,Unit\nHome safe,Gold,1,ozt\nHome safe,Silver,500,g\n"
        case .holdings: "Portfolio,Coin,Quantity\nMy portfolio,bitcoin,0.125\nMy portfolio,ethereum,2\n"
        }
    }
}
nonisolated enum ImportColumn: String, CaseIterable, Sendable {
    case date, description, amount, debit, credit, currency, transactionID, type, account, balance, portfolio, coin, quantity, unit
    var title: String {
        switch self {
        case .date: "Date"; case .description: "Description"; case .amount: "Amount"; case .debit: "Money out"; case .credit: "Money in"
        case .currency: "Currency"; case .transactionID: "Transaction ID"; case .type: "Type"; case .account: "Account"
        case .balance: "Balance"; case .portfolio: "Portfolio"; case .coin: "Coin / ID"; case .quantity: "Total quantity / weight"; case .unit: "Weight unit"
        }
    }
}
nonisolated enum ImportDateFormat: String, CaseIterable, Sendable {
    case iso = "yyyy-MM-dd", dayFirst = "dd/MM/yyyy", monthFirst = "MM/dd/yyyy", dayFirstDash = "dd-MM-yyyy", dayFirstDot = "dd.MM.yyyy", monzoSearch = "dd/MM/yy, HH:mm"
    /// An example date, which reads better in a picker than a pattern.
    var title: String {
        switch self {
        case .iso: "2026-01-31"; case .dayFirst: "31/01/2026"; case .monthFirst: "01/31/2026"
        case .dayFirstDash: "31-01-2026"; case .dayFirstDot: "31.01.2026"; case .monzoSearch: "31/01/26, 09:30"
        }
    }
    /// The UTC day. Day and month may drop a leading zero (`1/2/2026`), and a time after the date
    /// (`2026-01-02 13:45:00`, `2026-01-02T13:45:00Z`) is accepted and ignored.
    func date(_ raw: String) throws -> Date {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let failure = ImportFailure("Use dates like \(title), or choose the matching date format.")
        var text = Substring(clean), time: Substring = ""
        if let cut = clean.firstIndex(where: { $0 == " " || $0 == "T" || $0 == "," }) {
            text = clean[..<cut]; time = clean[cut...].drop { $0 == " " || $0 == "T" || $0 == "," }
            guard time.contains(":"), time.allSatisfy({ $0.isASCII && ($0.isNumber || ":.+-Z ".contains($0)) }) else { throw failure }
        }
        let separator: Character = switch self { case .iso, .dayFirstDash: "-"; case .dayFirstDot: "."; default: "/" }
        let parts = text.split(separator: separator, omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { throw failure }
        let y = self == .iso ? 0 : 2, m = self == .monthFirst ? 0 : 1, d = self == .iso ? 2 : self == .monthFirst ? 1 : 0
        let short = self == .monzoSearch
        guard parts[y].count == (short ? 2 : 4), (short ? 2...2 : 1...2).contains(parts[m].count), (short ? 2...2 : 1...2).contains(parts[d].count),
              let year = Int(parts[y]), let month = Int(parts[m]), let day = Int(parts[d]) else { throw failure }
        var components = DateComponents(year: short ? 2000 + year : year, month: month, day: day)
        if short {
            // Monzo's search export keeps the time, which decides whether a transaction is in the future.
            let clock = time.split(separator: ":")
            guard clock.count == 2, clock.allSatisfy({ $0.count == 2 }), let hour = Int(clock[0]), let minute = Int(clock[1]), hour < 24, minute < 60 else { throw failure }
            components.hour = hour; components.minute = minute
        }
        // Rejects days a calendar would roll over, such as 30 February.
        guard let date = UTCDay.calendar.date(from: components) else { throw failure }
        let check = UTCDay.calendar.dateComponents([.year, .month, .day], from: date)
        guard check.year == components.year, check.month == month, check.day == day else { throw failure }
        return date
    }
    /// A saved day as it's written, "2026-09-24" (its UTC date); without one, today's date on this Mac.
    static func today(_ day: Date = UTCDay.today()) -> String {
        let parts = UTCDay.calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
    /// The end of today where it's latest (UTC+14), as a UTC day: a date written anywhere today is before it,
    /// even when it's already tomorrow in UTC. Today on this Mac is always before it.
    static func endOfToday(_ now: Date = Date()) -> Date { UTCDay.start(of: now.addingTimeInterval(14 * 3600)).addingTimeInterval(86400) }
    /// The format that reads every date. A known bank's `preferred` format wins outright. When day and month could be
    /// either way round, the reading whose dates are in order and span the shortest time wins; if that can't tell
    /// (one row, or both equally plausible), `unconfirmed` is the first date the readings disagree on, to ask about.
    /// Ties go to ISO, then to day or month first in the order this Mac's region writes them.
    static func detection(_ values: [String], preferred: [ImportDateFormat] = []) -> (format: ImportDateFormat, unconfirmed: String?)? {
        let samples = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !samples.isEmpty else { return nil }
        if let known = preferred.first(where: { format in samples.allSatisfy { (try? format.date($0)) != nil } }) { return (known, nil) }
        var order: [ImportDateFormat] = [.iso, .dayFirst, .monthFirst, .dayFirstDash, .dayFirstDot]
        let pattern = DateFormatter.dateFormat(fromTemplate: "yMd", options: 0, locale: .current) ?? ""
        if let month = pattern.firstIndex(of: "M"), let day = pattern.firstIndex(of: "d"), month < day { order = [.iso, .monthFirst, .dayFirst, .dayFirstDash, .dayFirstDot] }
        var readings: [(format: ImportDateFormat, dates: [Date], ordered: Bool, span: TimeInterval)] = []
        for format in order {
            var dates: [Date] = []
            for sample in samples { guard let date = try? format.date(sample) else { break }; dates.append(date) }
            guard dates.count == samples.count, let first = dates.min(), let last = dates.max() else { continue }
            let pairs = zip(dates, dates.dropFirst())
            readings.append((format, dates, pairs.allSatisfy { $0 <= $1 } || pairs.allSatisfy { $0 >= $1 }, last.timeIntervalSince(first)))
        }
        guard let first = readings.first else { return nil }
        guard readings.count > 1 else { return (first.format, nil) }
        // A statement lists its rows in date order and covers a short time.
        let ranked = readings.enumerated().sorted { a, b in
            if a.element.ordered != b.element.ordered { return a.element.ordered }
            if a.element.span != b.element.span { return a.element.span < b.element.span }
            return a.offset < b.offset
        }.map(\.element)
        let best = ranked[0], other = ranked[1]
        guard let differ = best.dates.indices.first(where: { best.dates[$0] != other.dates[$0] }) else { return (best.format, nil) }
        let decided = best.ordered && (!other.ordered || best.span < other.span)
        return (best.format, decided ? nil : samples[differ])
    }
    static func detect(_ values: [String], preferred: [ImportDateFormat] = []) -> ImportDateFormat? { detection(values, preferred: preferred)?.format }
}
nonisolated enum ImportNumberFormat: String, CaseIterable, Sendable {
    case point = "1,234.56", comma = "1.234,56"
    /// Also reads `+12.34`, `(12.34)`, `12.34-` and `−12.34`, and spaces or apostrophes between thousands.
    /// A `typed` value reads a lone separator that can't be grouping as the decimal mark, so `0,125` and `12,50`
    /// are decimals; only a real ambiguity such as `1,250` follows the format.
    func decimal(_ raw: String, typed: Bool = false) throws -> Decimal {
        var clean = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\u{2212}", with: "-")
        var negative = false
        if clean.hasPrefix("("), clean.hasSuffix(")") { negative = true; clean = String(clean.dropFirst().dropLast()) }
        else if clean.hasPrefix("-") { negative = true; clean.removeFirst() }
        else if clean.hasSuffix("-") { negative = true; clean.removeLast() }
        else if clean.hasPrefix("+") { clean.removeFirst() }
        clean = clean.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { throw ImportFailure("Enter a number.") }
        guard !clean.contains(where: { "+-()".contains($0) }) else { throw ImportFailure("Enter an exact number, without a currency symbol or formula.") }
        let decimalMark: Character = self == .point ? "." : ","
        let grouping: Character = self == .point ? "," : "."
        if typed, !clean.contains(decimalMark), clean.filter({ $0 == grouping }).count == 1 {
            let halves = clean.split(separator: grouping, omittingEmptySubsequences: false)
            let ambiguous = halves[1].count == 3 && (1...3).contains(halves[0].count) && halves[0].first != "0"
            if !ambiguous { clean = clean.replacingOccurrences(of: String(grouping), with: String(decimalMark)) }
        }
        // Spaces (including no-break spaces) and apostrophes only ever separate thousands.
        clean = String(clean.map { " \u{00A0}\u{202F}'’".contains($0) ? grouping : $0 })
        let parts = clean.split(separator: decimalMark, omittingEmptySubsequences: false)
        guard parts.count <= 2 else { throw ImportFailure("Check the number format (\(rawValue)).") }
        let whole = String(parts[0])
        if whole.contains(grouping) {
            let groups = whole.split(separator: grouping, omittingEmptySubsequences: false)
            // No thousands group starts with zero: "0,125" is never 125.
            guard (1...3).contains(groups[0].count), groups[0].first != "0", groups.allSatisfy({ $0.allSatisfy(\.isNumber) }),
                  groups.dropFirst().allSatisfy({ $0.count == 3 }) else { throw ImportFailure("Check the thousands separators.") }
        }
        guard parts.count < 2 || !parts[1].contains(grouping) else { throw ImportFailure("Check the decimal separator.") }
        let normalized = (negative ? "-" : "") + whole.replacingOccurrences(of: String(grouping), with: "") + (parts.count == 2 ? "." + parts[1] : "")
        do { return try MoneyInput.parseExact(normalized) }
        catch { throw ImportFailure("Enter an exact number, without a currency symbol or formula.") }
    }
    /// The format a file's amounts are written in, found as dates are. An amount only one format reads (`12,50`,
    /// `1.234,56` or `12.50`) decides; a semicolon delimiter, used where the comma is the decimal mark, means commas;
    /// then other columns' numbers (a balance, a rate) decide. An amount both read differently (`1.234`) with none of
    /// that to go on is returned as `unconfirmed`, to ask about. `others` is only read when it's needed.
    static func detection(_ values: [String], others: () -> [String], delimiter: Character) -> (format: ImportNumberFormat, unconfirmed: String?) {
        func tally(_ cells: [String]) -> (point: Int, comma: Int, either: String?) {
            var point = 0, comma = 0, either: String?
            for cell in cells {
                let text = cell.trimmingCharacters(in: .whitespacesAndNewlines)
                // Only a number with a separator can tell the formats apart.
                guard text.contains(where: { $0 == "." || $0 == "," }), text.allSatisfy({ $0.isNumber || ".,+-()' ’\u{00A0}\u{202F}\u{2212}".contains($0) }) else { continue }
                let asPoint = try? ImportNumberFormat.point.decimal(text), asComma = try? ImportNumberFormat.comma.decimal(text)
                switch (asPoint, asComma) {
                case (_?, nil): point += 1
                case (nil, _?): comma += 1
                case let (a?, b?) where a != b: if either == nil { either = text }
                default: break
                }
            }
            return (point, comma, either)
        }
        let own = tally(values)
        if own.point != own.comma { return (own.point > own.comma ? .point : .comma, nil) }
        if delimiter == ";" { return (.comma, nil) }
        guard let example = own.either else { return (.point, nil) }
        let file = tally(others())
        if (file.point > 0) != (file.comma > 0) { return (file.point > 0 ? .point : .comma, nil) }
        return (.point, example)
    }
}
nonisolated struct ImportFailure: LocalizedError, Sendable {
    var text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}
nonisolated struct ImportAccount: Sendable, Equatable {
    var existingID: UUID?
    var ownerBusinessID: String?
    var name = ""
    var currency = "USD"
}
nonisolated struct StatementInput: Sendable, Equatable {
    var date = ""
    var label = ""
    var amount = ""
    var debit = ""
    var credit = ""
    var currency = "USD"
    var transactionID = ""
    var kind: EntryKind = .expense
    var originalType = ""
    var kindIsUserEdited = false
}
nonisolated struct BankBalanceInput: Sendable, Equatable {
    var account = ImportAccount()
    var balance = ""
    var date = ImportDateFormat.today()
}
nonisolated struct HoldingInput: Sendable, Equatable {
    var portfolioID: UUID?
    var portfolioName = ""
    var ownerBusinessID: String?
    var coin = ""
    var resolvedCoinID = ""
    var assetName = ""
    var quantity = ""
    var unit = "g"
    var date = ImportDateFormat.today()
    var paid = ""
    var paidCurrency = "USD"
}
nonisolated enum ImportRowContent: Sendable, Equatable {
    case statement(StatementInput), bankBalance(BankBalanceInput), holding(HoldingInput)
}
nonisolated struct ImportDraftRow: Identifiable, Sendable {
    var id = UUID()
    var sourceID: UUID
    var line: Int
    var included = true
    var duplicateApproved = false
    var parseError: String?
    var content: ImportRowContent
    var statement: StatementInput {
        get { if case .statement(let value) = content { return value }; return StatementInput() }
        set { content = .statement(newValue) }
    }
    var bank: BankBalanceInput {
        get { if case .bankBalance(let value) = content { return value }; return BankBalanceInput() }
        set { content = .bankBalance(newValue) }
    }
    var holding: HoldingInput {
        get { if case .holding(let value) = content { return value }; return HoldingInput() }
        set { content = .holding(newValue) }
    }
}
nonisolated struct ImportSourceDraft: Identifiable, Sendable {
    var id = UUID()
    var filename: String
    var bytes: Data
    var grid: [[String]]
    var hasHeader = true
    var mapping: [ImportColumn: Int] = [:]
    var dateFormat: ImportDateFormat = .iso
    var numberFormat: ImportNumberFormat = .point
    /// A date the detected format may have misread (`03/04/2025`), until a format is chosen; saving waits for it.
    var unconfirmedDate: String?
    /// An amount the detected number format may have misread (`1.234`), until a format is chosen.
    var unconfirmedNumber: String?
    /// Card exports list purchases as positive amounts and payments as negative.
    var positiveIsOutflow = false
    var account = ImportAccount()
    var balance = ""
    var balanceDate = ImportDateFormat.today()
    /// The currency of one part of a file split by currency (Wise's transaction history); its account must use it.
    var splitCurrency: String?
    /// Hashes the whole file; evaluation computes it once per source.
    var digest: Data { VaultCrypto.sha256(bytes) }
    /// Typed in by hand rather than read from a file.
    var isManual: Bool { grid.isEmpty }
    /// Amounts in one signed column, with no type column to say which way they go.
    var hasSignedAmount: Bool { mapping[.amount] != nil && mapping[.type] == nil }
    /// Whether any amount is written as negative (`-12.34`, `(12.34)`, `12.34-`), so the file's own signs say which way money went.
    var hasNegativeAmount: Bool {
        guard let column = mapping[.amount] else { return false }
        return grid.dropFirst(hasHeader ? 1 : 0).contains { cells in
            guard column < cells.count else { return false }
            let cell = cells[column].trimmingCharacters(in: .whitespaces)
            return cell.hasPrefix("-") || cell.hasPrefix("\u{2212}") || cell.hasPrefix("(") || cell.hasSuffix("-")
        }
    }
    var headers: [String] {
        guard let first = grid.first else { return [] }
        return first.indices.map { hasHeader ? first[$0] : "Column \($0 + 1)" }
    }
}
nonisolated struct ImportBatchDraft: Identifiable, Sendable {
    var id = UUID()
    var mode: ImportMode
    var sources: [ImportSourceDraft] = []
    var rows: [ImportDraftRow] = []
    static let maxFiles = 50, maxBytes = 32 * 1024 * 1024, maxRows = 50000
    func checkLimits() throws {
        guard sources.count <= Self.maxFiles, sources.reduce(0, { $0 + $1.bytes.count }) <= Self.maxBytes,
              rows.count <= Self.maxRows else { throw ImportFailure("Use at most 50 files, 32 MiB and 50,000 rows in one batch.") }
        for source in sources {
            guard source.bytes.count <= VaultLimits.maxBatchBytes, source.grid.count - (source.hasHeader ? 1 : 0) <= 20000,
                  rows.filter({ $0.sourceID == source.id }).count <= 20000 else { throw StatementError.tooLarge }
        }
    }
    /// Settles every row a review flagged as a possible duplicate at once: each kept as a separate payment, or skipped.
    mutating func settleDuplicates(_ review: ImportEvaluation, keep: Bool) {
        for index in rows.indices where review.states[rows[index].id] == .possibleDuplicate {
            if keep { rows[index].duplicateApproved = true } else { rows[index].included = false }
        }
    }
}
nonisolated enum ImportParser {
    /// Every input is sniffed for its encoding and delimiter.
    static func source(bytes: Data, filename: String, mode: ImportMode) throws -> ImportSourceDraft {
        guard bytes.count <= VaultLimits.maxBatchBytes else { throw StatementError.tooLarge }
        let text = try decode(bytes)
        let clean = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        let separator = delimiter(clean)
        let grid = try CSVReader.parse(clean, delimiter: separator)
        guard let first = grid.first, !first.isEmpty else { throw ImportFailure("This file has no rows.") }
        var source = ImportSourceDraft(filename: filename, bytes: bytes, grid: grid)
        source.hasHeader = looksLikeHeader(guessMapping(first, mode: mode))
        source.mapping = defaultMapping(source, mode: mode)
        let data = grid.dropFirst(source.hasHeader ? 1 : 0)
        if isMonzoSearch(grid) {
            source.dateFormat = .monzoSearch
            source.account.currency = "GBP"
            source.account.name = "Monzo"
        } else if let column = source.mapping[.date] {
            let monzo = isMonzoExport(first), wise = first.contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == "transferwise id" }
            if monzo { source.account.name = "Monzo" } else if wise { source.account.name = "Wise" }
            let dates = data.map { column < $0.count ? $0[column] : "" }
            let detected = ImportDateFormat.detection(dates, preferred: monzo ? [.dayFirst] : wise ? [.dayFirstDash, .dayFirst] : [])
            source.dateFormat = detected?.format ?? (monzo || wise ? .dayFirst : .iso)
            source.unconfirmedDate = detected?.unconfirmed
        }
        let amounts = [ImportColumn.amount, .debit, .credit, .balance, .quantity].compactMap { source.mapping[$0] }
        let numbers = ImportNumberFormat.detection(data.flatMap { cells in amounts.compactMap { $0 < cells.count ? cells[$0] : nil } },
                                                   others: { data.prefix(500).flatMap { cells in cells.indices.filter { !amounts.contains($0) }.map { cells[$0] } } },
                                                   delimiter: separator)
        source.numberFormat = numbers.format; source.unconfirmedNumber = numbers.unconfirmed
        // A card export whose amount column is headed "Charges", or American Express's (with its Card Member column).
        if mode == .statements, source.hasHeader, source.hasSignedAmount, let amount = source.mapping[.amount] {
            source.positiveIsOutflow = isChargeHeader(first[amount]) || first.contains { columnKey($0) == "cardmember" }
        }
        // A new account for this file starts in the file's own currency.
        if mode == .statements, let column = source.mapping[.currency] {
            let codes = Set(data.compactMap { cells in column < cells.count ? (try? MoneyInput.normalizeCurrency(cells[column])) : nil })
            if codes.count == 1, let code = codes.first { source.account.currency = code }
        }
        return source
    }
    /// One draft per file, except Wise's transaction history, which becomes one statement per currency because an
    /// Up Only account holds one currency. Every part keeps the original file for the archive and duplicate check.
    static func sources(bytes: Data, filename: String, mode: ImportMode) throws -> [ImportSourceDraft] {
        let file = try source(bytes: bytes, filename: filename, mode: mode)
        guard mode == .statements, let names = file.grid.first?.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }), isWiseHistory(names) else { return [file] }
        let columns = Dictionary(names.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var parts: [String: [[String]]] = [:]
        for (offset, cells) in file.grid.dropFirst().enumerated() {
            if offset.isMultiple(of: 100) { try Task.checkCancellation() }
            func value(_ name: String) -> String {
                guard let index = columns[name], cells.indices.contains(index) else { return "" }
                return cells[index].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            // Cancelled and refunded transfers moved no money.
            guard value("status").uppercased() == "COMPLETED" else { continue }
            let id = value("id"), finished = value("finished on"), date = finished.isEmpty ? value("created on") : finished
            let from = value("source currency").uppercased(), to = value("target currency").uppercased()
            // The source amount is after fees, so money out also paid the fee when it was charged in that currency.
            let fee = value("source fee currency").uppercased() == from ? value("source fee amount") : ""
            let out = [date, value("target name").isEmpty ? value("reference") : value("target name"), wiseAmount([value("source amount (after fees)"), fee], out: true), from]
            let into = [date, value("source name").isEmpty ? value("reference") : value("source name"), wiseAmount([value("target amount (after fees)")], out: false), to]
            switch value("direction").uppercased() {
            case "OUT": parts[from, default: []].append([id] + out + [""])
            case "IN": parts[to, default: []].append([id] + into + [""])
            // A conversion between your own balances leaves one and arrives in another.
            case "NEUTRAL":
                parts[from, default: []].append([id.isEmpty ? "" : id + ":out"] + out + ["transfer"])
                parts[to, default: []].append([id.isEmpty ? "" : id + ":in"] + into + ["transfer"])
            default: break
            }
        }
        let header = ["TransactionID", "Date", "Description", "Amount", "Currency", "Type"]
        guard !parts.isEmpty else {
            var empty = ImportSourceDraft(filename: filename, bytes: bytes, grid: [header])
            empty.mapping = defaultMapping(empty, mode: mode)
            return [empty]
        }
        return parts.keys.sorted().map { code -> ImportSourceDraft in
            let rows = parts[code] ?? []
            var part = ImportSourceDraft(filename: parts.count > 1 ? filename + " · " + code : filename, bytes: bytes, grid: [header] + rows)
            part.mapping = defaultMapping(part, mode: mode)
            part.dateFormat = ImportDateFormat.detect(rows.map { $0[1] }, preferred: [.iso]) ?? .iso
            part.account = ImportAccount(name: "Wise · " + code, currency: code)
            part.splitCurrency = code
            return part
        }
    }
    /// Wise's unsigned amounts added up, signed by direction. A value that can't be read is kept as written, for review to flag.
    private static func wiseAmount(_ values: [String], out: Bool) -> String {
        var total: Decimal = 0
        for value in values where !value.isEmpty {
            guard let amount = try? ImportNumberFormat.point.decimal(value), let sum = try? MoneyInput.add(total, abs(amount)) else { return value }
            total = sum
        }
        return total == 0 ? "0" : (out ? "-" : "+") + NSDecimalNumber(decimal: total).stringValue
    }
    /// UTF-8 (with or without a byte order mark), UTF-16 with one, or Windows-1252 as older bank exports use.
    static func decode(_ bytes: Data) throws -> String {
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) {
            guard let text = String(data: bytes, encoding: .utf16) else { throw StatementError.invalidCSV }
            return text
        }
        guard let text = String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .windowsCP1252) ?? String(data: bytes, encoding: .isoLatin1),
              !text.contains("\0") else { throw StatementError.invalidCSV }
        return text
    }
    /// Whichever of comma, semicolon (common in Europe) or tab the first line uses most, outside quotes. As in `CSVReader`,
    /// only a quote at a field's start opens a quoted field, so a stray `12"` doesn't swallow the line.
    static func delimiter(_ text: String) -> Character {
        // Tab first, so pasted cells that also contain commas still split on tabs; `max(by:)` keeps the first of a tie.
        let candidates: [Character] = ["\t", ";", ","]
        var counts: [Character: Int] = [:], quoted = false, started = false, fieldStart = true, closed = false
        for c in text {
            if quoted {
                if c == "\"" { quoted = false; closed = true }
                continue
            }
            // A quote right after a closing one is an escaped quote inside the field.
            if c == "\"" && (fieldStart || closed) { quoted = true; closed = false; fieldStart = false; started = true; continue }
            closed = false
            if c == "\n" || c == "\r" || c == "\r\n" { if started { break } else { continue } }
            started = true
            if candidates.contains(c) { counts[c, default: 0] += 1; fieldStart = true } else if c != " " { fieldStart = false }
        }
        guard let best = candidates.max(by: { counts[$0, default: 0] < counts[$1, default: 0] }), counts[best, default: 0] > 0 else { return "," }
        return best
    }
    static func account(for source: ImportSourceDraft, preferred: ImportAccount, saved: [Account]) -> ImportAccount {
        // A file split by currency uses a chosen account only for the part in that account's currency.
        if preferred.existingID != nil || !preferred.name.isEmpty, source.splitCurrency.map({ $0 == preferred.currency }) ?? true { return preferred }
        var inferred = source.account
        // "" marks an account set to Personal, the same as no owner.
        let matches = saved.filter { $0.name.caseInsensitiveCompare(inferred.name) == .orderedSame && $0.currency == inferred.currency && ($0.ownerBusinessID ?? "").isEmpty }
        if matches.count == 1 { inferred.existingID = matches[0].id }
        return inferred
    }
    static func isMonzoSearch(_ grid: [[String]]) -> Bool {
        guard let header = grid.first else { return false }
        return Set(["id", "created", "title", "subtitle", "amount", "currency", "categories"]).isSubset(of: Set(header.map { $0.lowercased() }))
    }
    /// Wise's transaction history export (2023 onwards), whose columns come in any order.
    static func isWiseHistory(_ header: [String]) -> Bool {
        Set(["id", "status", "direction", "source amount (after fees)"]).isSubset(of: Set(header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }))
    }
    /// The Monzo app's full export, recognised by columns no other bank uses together.
    static func isMonzoExport(_ header: [String]) -> Bool {
        Set(["transaction id", "emoji", "local amount"]).isSubset(of: Set(header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }))
    }
    /// Monzo and Wise exports, whose money out is known to be negative.
    static func signsKnown(_ grid: [[String]]) -> Bool {
        guard let header = grid.first else { return false }
        return isMonzoSearch(grid) || isMonzoExport(header) || isWiseHistory(header) || header.contains { columnKey($0) == "transferwiseid" }
    }
    /// A column name as matched: lowercase letters and digits only, so "Money Out" and "money_out" agree.
    static func columnKey(_ name: String) -> String { name.lowercased().filter { $0.isLetter || $0.isNumber } }
    /// A card export's purchases column.
    static func isChargeHeader(_ name: String) -> Bool { ["charge", "charges", "chargeamount", "amountcharged"].contains(columnKey(name)) }
    /// Two known column names, one of them a date or a value, make a header. One alone ("Deposit") can be data.
    static func looksLikeHeader(_ mapping: [ImportColumn: Int]) -> Bool {
        mapping.count >= 2 && mapping.keys.contains { [.date, .amount, .debit, .credit, .balance, .quantity].contains($0) }
    }
    static func guessMapping(_ header: [String], mode: ImportMode) -> [ImportColumn: Int] {
        let aliases: [ImportColumn: [String]] = [
            .date: ["date", "observedon", "observedat", "transactiondate", "created"], .description: ["description", "name", "memo", "narrative", "title"],
            .amount: ["amount", "transactionamount"], .debit: ["debit", "debits", "moneyout", "withdrawal", "withdrawals"],
            .credit: ["credit", "credits", "moneyin", "deposit", "deposits"], .currency: ["currency", "currencycode"],
            .transactionID: ["transactionid", "transferwiseid", "id"], .type: ["type", "kind"],
            .account: ["account", "accountname"], .balance: ["balance", "closingbalance", "currentbalance"],
            .portfolio: ["portfolio", "portfolioname"], .coin: ["coin", "coinid", "coingeckoid", "asset", "symbol", "ticker", "metal"],
            .quantity: ["quantity", "totalquantity", "balance", "amount", "weight"], .unit: ["unit", "weightunit"]
        ]
        var result: [ImportColumn: Int] = [:]
        for (index, name) in header.enumerated() {
            let normalized = columnKey(name)
            for column in mode.columns where aliases[column]?.contains(normalized) == true && result[column] == nil { result[column] = index }
        }
        // A card export's "Charges": beside a Credits column it's Money out; alone it's the amount. A real Amount column wins.
        if mode == .statements, result[.amount] == nil, let charges = header.firstIndex(where: { isChargeHeader($0) }) {
            if result[.credit] == nil { result[.amount] = charges } else if result[.debit] == nil { result[.debit] = charges }
        }
        return result
    }
    /// The header's columns, or the documented order for a file without one. Amount wins over Money in/out, and a
    /// bank's own Type column (card payment, direct debit…) is ignored unless every value is an Up Only type.
    static func defaultMapping(_ source: ImportSourceDraft, mode: ImportMode) -> [ImportColumn: Int] {
        guard let first = source.grid.first else { return [:] }
        var mapping: [ImportColumn: Int] = [:]
        if source.hasHeader { mapping = guessMapping(first, mode: mode) }
        else {
            let order: [ImportColumn] = switch mode {
            case .statements: [.date, .description, .amount, .currency, .type, .transactionID]
            case .bankBalances: [.account, .currency, .balance, .date]
            case .holdings: [.portfolio, .coin, .quantity]
            case .metals: [.portfolio, .coin, .quantity, .unit]
            }
            for (index, column) in order.enumerated() where index < first.count { mapping[column] = index }
        }
        guard mode == .statements else { return mapping }
        if mapping[.amount] != nil { mapping[.debit] = nil; mapping[.credit] = nil }
        if let type = mapping[.type] {
            let values = source.grid.dropFirst(source.hasHeader ? 1 : 0).map { type < $0.count ? $0[type].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : "" }
            if !values.allSatisfy({ $0.isEmpty || EntryKind(rawValue: $0) != nil }) { mapping[.type] = nil }
        }
        return mapping
    }
    static func rows(source: ImportSourceDraft, mode: ImportMode) throws -> [ImportDraftRow] {
        var result: [ImportDraftRow] = []
        let header = source.grid.first ?? [], monzoSearch = isMonzoSearch(source.grid), monzoExport = isMonzoExport(header)
        func headerIndex(_ name: String) -> Int? { header.firstIndex { $0.trimmingCharacters(in: .whitespaces).lowercased() == name } }
        // Monzo's category says what a transaction is better than its sign does.
        let categoryIndex = monzoSearch ? headerIndex("categories") : monzoExport ? headerIndex("category") : nil
        let monzoType = monzoExport ? headerIndex("type") : nil, subtitle = monzoSearch ? headerIndex("subtitle") : nil
        let needed = (source.mapping.values.max() ?? -1) + 1
        for (offset, cells) in source.grid.dropFirst(source.hasHeader ? 1 : 0).enumerated() {
            if offset.isMultiple(of: 100) { try Task.checkCancellation() }
            func field(_ column: ImportColumn) -> String {
                guard let index = source.mapping[column], cells.indices.contains(index) else { return "" }
                return cells[index].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            func cell(_ index: Int?) -> String? { index.flatMap { cells.indices.contains($0) ? cells[$0].trimmingCharacters(in: .whitespaces).lowercased() : nil } }
            let content: ImportRowContent
            var signed: Decimal?
            switch mode {
            case .statements:
                let rawType = field(.type).lowercased()
                var input = StatementInput(date: field(.date), label: field(.description), amount: field(.amount), debit: field(.debit), credit: field(.credit), currency: field(.currency).isEmpty ? source.account.currency : field(.currency), transactionID: field(.transactionID), originalType: rawType)
                signed = (try? ImportBatchProcessor.movement(input, format: source.numberFormat, positiveOut: source.positiveIsOutflow))?.signed
                let inferred: EntryKind = signed.map { $0 < 0 ? .expense : .income } ?? .expense
                let category = cell(categoryIndex)
                let isTransfer = category == "transfers" || cell(monzoType) == "pot transfer"
                // Monzo files a merchant refund under the merchant's own category; only real income is filed under "Income".
                // Cashback is a rebate on spending, not earnings.
                let isRefund = categoryIndex != nil && inferred == .income && (category != "income" || field(.description).lowercased().contains("cashback"))
                input.kind = isTransfer ? .transfer : isRefund ? .refund : EntryKind(rawValue: rawType) ?? inferred
                content = .statement(input)
            case .bankBalances:
                content = .bankBalance(BankBalanceInput(account: ImportAccount(name: field(.account), currency: field(.currency).isEmpty ? "USD" : field(.currency)), balance: field(.balance), date: field(.date).isEmpty ? ImportDateFormat.today() : field(.date)))
            case .holdings, .metals:
                content = .holding(HoldingInput(portfolioName: field(.portfolio), coin: field(.coin), quantity: field(.quantity), unit: mode == .metals ? field(.unit) : "g"))
            }
            var row = ImportDraftRow(sourceID: source.id, line: offset + (source.hasHeader ? 2 : 1), content: content)
            if field(.amount).isEmpty, cell(subtitle)?.hasPrefix("declined") == true { row.included = false }
            // Card checks and other zero-amount rows move no money.
            if signed == 0 { row.included = false }
            // A trailing delimiter adds an empty cell; only missing mapped cells or extra values mean the row is misaligned.
            let extra = cells.count > header.count && cells[header.count...].contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if cells.count < needed || extra { row.parseError = "This row has a different number of cells. Correct the fields or exclude it." }
            result.append(row)
        }
        return result
    }
}
nonisolated enum ImportCoins {
    // Well-known coins with their exact CoinGecko IDs, so search works offline and
    // before any price source is configured. The live catalog adds the rest.
    static let common: [CatalogCoin] = [
        CatalogCoin(id: "bitcoin", symbol: "btc", name: "Bitcoin"),
        CatalogCoin(id: "ethereum", symbol: "eth", name: "Ethereum"),
        CatalogCoin(id: "tether", symbol: "usdt", name: "Tether"),
        CatalogCoin(id: "ripple", symbol: "xrp", name: "XRP"),
        CatalogCoin(id: "binancecoin", symbol: "bnb", name: "BNB"),
        CatalogCoin(id: "solana", symbol: "sol", name: "Solana"),
        CatalogCoin(id: "usd-coin", symbol: "usdc", name: "USDC"),
        CatalogCoin(id: "tron", symbol: "trx", name: "TRON"),
        CatalogCoin(id: "dogecoin", symbol: "doge", name: "Dogecoin"),
        CatalogCoin(id: "cardano", symbol: "ada", name: "Cardano"),
        CatalogCoin(id: "staked-ether", symbol: "steth", name: "Lido Staked Ether"),
        CatalogCoin(id: "hyperliquid", symbol: "hype", name: "Hyperliquid"),
        CatalogCoin(id: "chainlink", symbol: "link", name: "Chainlink"),
        CatalogCoin(id: "avalanche-2", symbol: "avax", name: "Avalanche"),
        CatalogCoin(id: "stellar", symbol: "xlm", name: "Stellar"),
        CatalogCoin(id: "sui", symbol: "sui", name: "Sui"),
        CatalogCoin(id: "bitcoin-cash", symbol: "bch", name: "Bitcoin Cash"),
        CatalogCoin(id: "hedera-hashgraph", symbol: "hbar", name: "Hedera"),
        CatalogCoin(id: "leo-token", symbol: "leo", name: "LEO Token"),
        CatalogCoin(id: "litecoin", symbol: "ltc", name: "Litecoin"),
        CatalogCoin(id: "the-open-network", symbol: "ton", name: "Toncoin"),
        CatalogCoin(id: "shiba-inu", symbol: "shib", name: "Shiba Inu"),
        CatalogCoin(id: "polkadot", symbol: "dot", name: "Polkadot"),
        CatalogCoin(id: "uniswap", symbol: "uni", name: "Uniswap"),
        CatalogCoin(id: "monero", symbol: "xmr", name: "Monero"),
        CatalogCoin(id: "dai", symbol: "dai", name: "Dai"),
        CatalogCoin(id: "pepe", symbol: "pepe", name: "Pepe"),
        CatalogCoin(id: "aave", symbol: "aave", name: "Aave"),
        CatalogCoin(id: "bittensor", symbol: "tao", name: "Bittensor"),
        CatalogCoin(id: "ethena-usde", symbol: "usde", name: "Ethena USDe"),
        CatalogCoin(id: "near", symbol: "near", name: "NEAR Protocol"),
        CatalogCoin(id: "internet-computer", symbol: "icp", name: "Internet Computer"),
        CatalogCoin(id: "aptos", symbol: "apt", name: "Aptos"),
        CatalogCoin(id: "ethereum-classic", symbol: "etc", name: "Ethereum Classic"),
        CatalogCoin(id: "ondo-finance", symbol: "ondo", name: "Ondo"),
        CatalogCoin(id: "pi-network", symbol: "pi", name: "Pi Network"),
        CatalogCoin(id: "okb", symbol: "okb", name: "OKB"),
        CatalogCoin(id: "mantle", symbol: "mnt", name: "Mantle"),
        CatalogCoin(id: "crypto-com-chain", symbol: "cro", name: "Cronos"),
        CatalogCoin(id: "algorand", symbol: "algo", name: "Algorand"),
        CatalogCoin(id: "cosmos", symbol: "atom", name: "Cosmos Hub"),
        CatalogCoin(id: "kaspa", symbol: "kas", name: "Kaspa"),
        CatalogCoin(id: "vechain", symbol: "vet", name: "VeChain"),
        CatalogCoin(id: "render-token", symbol: "render", name: "Render"),
        CatalogCoin(id: "polygon-ecosystem-token", symbol: "pol", name: "Polygon"),
        CatalogCoin(id: "matic-network", symbol: "matic", name: "Polygon (MATIC)"),
        CatalogCoin(id: "filecoin", symbol: "fil", name: "Filecoin"),
        CatalogCoin(id: "arbitrum", symbol: "arb", name: "Arbitrum"),
        CatalogCoin(id: "fetch-ai", symbol: "fet", name: "Artificial Superintelligence Alliance"),
        CatalogCoin(id: "optimism", symbol: "op", name: "Optimism"),
        CatalogCoin(id: "worldcoin-wld", symbol: "wld", name: "Worldcoin"),
        CatalogCoin(id: "bonk", symbol: "bonk", name: "Bonk"),
        CatalogCoin(id: "sei-network", symbol: "sei", name: "Sei"),
        CatalogCoin(id: "injective-protocol", symbol: "inj", name: "Injective"),
        CatalogCoin(id: "celestia", symbol: "tia", name: "Celestia"),
        CatalogCoin(id: "blockstack", symbol: "stx", name: "Stacks"),
        CatalogCoin(id: "immutable-x", symbol: "imx", name: "Immutable"),
        CatalogCoin(id: "maker", symbol: "mkr", name: "Maker"),
        CatalogCoin(id: "the-graph", symbol: "grt", name: "The Graph"),
        CatalogCoin(id: "theta-token", symbol: "theta", name: "Theta Network"),
        CatalogCoin(id: "jupiter-exchange-solana", symbol: "jup", name: "Jupiter"),
        CatalogCoin(id: "bitcoin-cash-sv", symbol: "bsv", name: "Bitcoin SV"),
        CatalogCoin(id: "quant-network", symbol: "qnt", name: "Quant"),
        CatalogCoin(id: "flow", symbol: "flow", name: "Flow"),
        CatalogCoin(id: "tezos", symbol: "xtz", name: "Tezos"),
        CatalogCoin(id: "eos", symbol: "eos", name: "EOS"),
        CatalogCoin(id: "neo", symbol: "neo", name: "NEO"),
        CatalogCoin(id: "iota", symbol: "iota", name: "IOTA"),
        CatalogCoin(id: "the-sandbox", symbol: "sand", name: "The Sandbox"),
        CatalogCoin(id: "decentraland", symbol: "mana", name: "Decentraland"),
        CatalogCoin(id: "axie-infinity", symbol: "axs", name: "Axie Infinity"),
        CatalogCoin(id: "gala", symbol: "gala", name: "Gala"),
        CatalogCoin(id: "apecoin", symbol: "ape", name: "ApeCoin"),
        CatalogCoin(id: "chiliz", symbol: "chz", name: "Chiliz"),
        CatalogCoin(id: "curve-dao-token", symbol: "crv", name: "Curve DAO"),
        CatalogCoin(id: "lido-dao", symbol: "ldo", name: "Lido DAO"),
        CatalogCoin(id: "rocket-pool", symbol: "rpl", name: "Rocket Pool"),
        CatalogCoin(id: "frax-share", symbol: "fxs", name: "Frax Share"),
        CatalogCoin(id: "compound-governance-token", symbol: "comp", name: "Compound"),
        CatalogCoin(id: "havven", symbol: "snx", name: "Synthetix"),
        CatalogCoin(id: "1inch", symbol: "1inch", name: "1inch"),
        CatalogCoin(id: "pancakeswap-token", symbol: "cake", name: "PancakeSwap"),
        CatalogCoin(id: "thorchain", symbol: "rune", name: "THORChain"),
        CatalogCoin(id: "zcash", symbol: "zec", name: "Zcash"),
        CatalogCoin(id: "dash", symbol: "dash", name: "Dash"),
        CatalogCoin(id: "ravencoin", symbol: "rvn", name: "Ravencoin"),
        CatalogCoin(id: "helium", symbol: "hnt", name: "Helium"),
        CatalogCoin(id: "arweave", symbol: "ar", name: "Arweave"),
        CatalogCoin(id: "mina-protocol", symbol: "mina", name: "Mina"),
        CatalogCoin(id: "conflux-token", symbol: "cfx", name: "Conflux"),
        CatalogCoin(id: "kava", symbol: "kava", name: "Kava"),
        CatalogCoin(id: "oasis-network", symbol: "rose", name: "Oasis"),
        CatalogCoin(id: "elrond-erd-2", symbol: "egld", name: "MultiversX"),
        CatalogCoin(id: "ethereum-name-service", symbol: "ens", name: "Ethereum Name Service"),
        CatalogCoin(id: "first-digital-usd", symbol: "fdusd", name: "First Digital USD"),
        CatalogCoin(id: "paypal-usd", symbol: "pyusd", name: "PayPal USD"),
        CatalogCoin(id: "true-usd", symbol: "tusd", name: "TrueUSD"),
        CatalogCoin(id: "frax", symbol: "frax", name: "Frax"),
        CatalogCoin(id: "wrapped-steth", symbol: "wsteth", name: "Wrapped stETH"),
        CatalogCoin(id: "rocket-pool-eth", symbol: "reth", name: "Rocket Pool ETH"),
        CatalogCoin(id: "coinbase-wrapped-staked-eth", symbol: "cbeth", name: "Coinbase Wrapped Staked ETH"),
        CatalogCoin(id: "dogwifcoin", symbol: "wif", name: "dogwifhat"),
        CatalogCoin(id: "floki", symbol: "floki", name: "FLOKI"),
        CatalogCoin(id: "brett", symbol: "brett", name: "Brett"),
        CatalogCoin(id: "popcat", symbol: "popcat", name: "Popcat"),
        CatalogCoin(id: "pudgy-penguins", symbol: "pengu", name: "Pudgy Penguins"),
        CatalogCoin(id: "official-trump", symbol: "trump", name: "Official Trump"),
        CatalogCoin(id: "fartcoin", symbol: "fartcoin", name: "Fartcoin"),
        CatalogCoin(id: "virtual-protocol", symbol: "virtual", name: "Virtuals Protocol"),
        CatalogCoin(id: "ethena", symbol: "ena", name: "Ethena"),
        CatalogCoin(id: "pendle", symbol: "pendle", name: "Pendle"),
        CatalogCoin(id: "eigenlayer", symbol: "eigen", name: "EigenLayer"),
        CatalogCoin(id: "starknet", symbol: "strk", name: "Starknet"),
        CatalogCoin(id: "zksync", symbol: "zk", name: "ZKsync"),
        CatalogCoin(id: "mantra-dao", symbol: "om", name: "MANTRA"),
        CatalogCoin(id: "jasmycoin", symbol: "jasmy", name: "JasmyCoin"),
        CatalogCoin(id: "flare-networks", symbol: "flr", name: "Flare"),
        CatalogCoin(id: "ronin", symbol: "ron", name: "Ronin"),
        CatalogCoin(id: "gnosis", symbol: "gno", name: "Gnosis"),
        CatalogCoin(id: "wormhole", symbol: "w", name: "Wormhole"),
        CatalogCoin(id: "jito-governance-token", symbol: "jto", name: "Jito"),
        CatalogCoin(id: "pyth-network", symbol: "pyth", name: "Pyth Network"),
        CatalogCoin(id: "raydium", symbol: "ray", name: "Raydium"),
        CatalogCoin(id: "bittorrent", symbol: "btt", name: "BitTorrent"),
        CatalogCoin(id: "nexo", symbol: "nexo", name: "Nexo"),
        CatalogCoin(id: "kucoin-shares", symbol: "kcs", name: "KuCoin"),
        CatalogCoin(id: "bitget-token", symbol: "bgb", name: "Bitget Token"),
        CatalogCoin(id: "zilliqa", symbol: "zil", name: "Zilliqa"),
        CatalogCoin(id: "harmony", symbol: "one", name: "Harmony"),
        CatalogCoin(id: "ankr", symbol: "ankr", name: "Ankr"),
        CatalogCoin(id: "audius", symbol: "audio", name: "Audius"),
        CatalogCoin(id: "loopring", symbol: "lrc", name: "Loopring"),
        CatalogCoin(id: "basic-attention-token", symbol: "bat", name: "Basic Attention Token"),
        CatalogCoin(id: "enjincoin", symbol: "enj", name: "Enjin Coin"),
        CatalogCoin(id: "0x", symbol: "zrx", name: "0x Protocol"),
        CatalogCoin(id: "yearn-finance", symbol: "yfi", name: "yearn.finance"),
        CatalogCoin(id: "sushi", symbol: "sushi", name: "Sushi"),
        CatalogCoin(id: "balancer", symbol: "bal", name: "Balancer"),
        CatalogCoin(id: "sonic-3", symbol: "s", name: "Sonic"),
        CatalogCoin(id: "berachain-bera", symbol: "bera", name: "Berachain"),
        CatalogCoin(id: "aerodrome-finance", symbol: "aero", name: "Aerodrome Finance"),
        CatalogCoin(id: "morpho", symbol: "morpho", name: "Morpho"),
        CatalogCoin(id: "ether-fi", symbol: "ethfi", name: "ether.fi"),
        CatalogCoin(id: "hashflow", symbol: "hft", name: "Hashflow"),
        CatalogCoin(id: "akash-network", symbol: "akt", name: "Akash Network"),
        CatalogCoin(id: "astar", symbol: "astr", name: "Astar"),
        CatalogCoin(id: "celo", symbol: "celo", name: "Celo")
    ]
    static func available(document: VaultDocument, catalog: [CatalogCoin]) -> [CatalogCoin] {
        var coins = Dictionary(uniqueKeysWithValues: common.map { ($0.id, $0) })
        for holding in document.holdings where PreciousMetal.asset(holding.assetID) == nil && coins[holding.assetID.rawValue] == nil {
            coins[holding.assetID.rawValue] = CatalogCoin(id: holding.assetID.rawValue, symbol: "", name: holding.assetName)
        }
        for coin in catalog { coins[coin.id] = coin }
        return coins.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    static func suggestions(_ raw: String, coins: [CatalogCoin]) -> [CatalogCoin] {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }
        // Well-known coins come first, in market-cap order, so "btc" shows Bitcoin before the many lookalike tickers.
        let prominence = Dictionary(uniqueKeysWithValues: common.enumerated().map { ($1.id, $0) })
        func rank(_ coin: CatalogCoin) -> (Int, Int) {
            let fields = [coin.id, coin.symbol, coin.name].map { $0.lowercased() }
            let match = fields.contains(query) ? 0 : fields.contains(where: { $0.hasPrefix(query) }) ? 1 : 2
            // Built-in majors first, then CoinGecko's market-cap rank, then everything else.
            return (prominence[coin.id] ?? (coin.rank.map { 1000 + $0 } ?? Int.max), match)
        }
        return Array(coins.filter { coin in
            [coin.id, coin.symbol, coin.name].contains { $0.localizedCaseInsensitiveContains(query) }
        }.sorted {
            let a = rank($0), b = rank($1)
            if a != b { return a < b }
            return $0.name == $1.name ? $0.id < $1.id : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }.prefix(8))
    }
    static func candidates(_ raw: String, coins: [CatalogCoin]) -> [CatalogCoin] {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !clean.isEmpty else { return [] }
        return coins.filter { $0.id.lowercased() == clean || $0.symbol.lowercased() == clean || $0.name.lowercased() == clean }
    }
    static func resolve(_ input: HoldingInput, coins: [CatalogCoin]) throws -> CatalogCoin {
        if !input.resolvedCoinID.isEmpty {
            let id = try CanonicalAssetID(input.resolvedCoinID)
            return coins.first { $0.id == id.rawValue } ?? CatalogCoin(id: id.rawValue, symbol: "", name: input.assetName.isEmpty ? id.rawValue : input.assetName)
        }
        // Exact IDs are sufficient. Symbols, including common tickers, must be explicitly chosen in review.
        let raw = input.coin.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = coins.first(where: { $0.id == raw }) { return exact }
        throw ImportFailure("Choose the exact coin for \(raw.isEmpty ? "this row" : raw), or enter its CoinGecko ID.")
    }
}
nonisolated enum ImportRowState: Sendable, Equatable {
    case ready(String), duplicate, possibleDuplicate, error(String), excluded
    var text: String {
        switch self {
        case .ready(let s), .error(let s): s
        case .duplicate: "Already saved · skipped"
        case .possibleDuplicate: "Same day, description and amount as another transaction. Keep it as a separate payment or skip it."
        case .excluded: "Excluded"
        }
    }
    func displayText(privacy: Bool) -> String {
        if privacy, case .ready(let description) = self, description.contains(" → ") {
            return "Replace current total · Values hidden"
        }
        return text
    }
    var blocksSave: Bool { switch self { case .error, .possibleDuplicate: true; default: false } }
}
nonisolated struct ImportEvaluation: Sendable {
    /// Earliest day whose derived balances changed, so saved history is rebuilt from there.
    var historyStart: Date?
    /// Already-saved rows that learned their transaction day from this import.
    var learnedDays = 0
    var states: [UUID: ImportRowState] = [:]
    var sourceErrors: [UUID: String] = [:]
    /// Statement files with no account chosen yet; their rows wait until one is.
    var needsAccount = Set<UUID>()
    /// Files whose date or number format two readings fit; nothing is saved until one is chosen.
    var needsFormat = Set<UUID>()
    /// Files imported without keeping their original, because the archive of originals is full.
    var unarchivedFiles = 0
    var globalError: String?
    var added = 0
    var document: VaultDocument?
    var hasErrors: Bool { globalError != nil || !sourceErrors.isEmpty || states.values.contains(where: \.blocksSave) }
    var duplicates: Int { states.values.filter { $0 == .duplicate }.count }
    var possibleDuplicates: Int { states.values.filter { $0 == .possibleDuplicate }.count }
    var readyRows: Int { states.values.filter { if case .ready = $0 { return true }; return false }.count }
}
nonisolated enum ImportBatchProcessor {
    /// Bytes of original statement files kept in the vault. The vault writes them base64-encoded twice (in the document,
    /// then in its encrypted envelope), so 40 MiB of originals take about 71 of its 128 MiB. Past this, a file is
    /// remembered by its hash alone and its transactions still import.
    static let archiveBudget = 40 * 1024 * 1024
    private static func cleanName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw ImportFailure("Enter a name of 1–100 characters.") }
        return name
    }
    static func fingerprint(date: Date, label: String, signedAmount: Decimal, currency: String) -> String {
        let parts = [ImportDateFormat.today(date), label.trimmingCharacters(in: .whitespacesAndNewlines), NSDecimalNumber(decimal: signedAmount).stringValue, currency]
        let encoded = (try? JSONEncoder().encode(parts)) ?? Data()
        return VaultCrypto.sha256(encoded).map { String(format: "%02x", $0) }.joined()
    }
    /// A statement row's signed amount and direction. Amount wins over Money in/out, and Money out may be written
    /// negative. An explicit type needs a positive amount, except a transfer, whose sign (`-` out, `+` in) is its direction;
    /// an unsigned transfer has no known direction, so balance history leaves it out. `positiveOut` reads an untyped
    /// amount as card exports write it: purchases positive, payments and refunds negative.
    static func movement(_ input: StatementInput, format: ImportNumberFormat, positiveOut: Bool = false) throws -> (signed: Decimal, outflow: Bool?) {
        if input.amount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !input.debit.isEmpty || !input.credit.isEmpty {
            let debit = try input.debit.isEmpty ? 0 : abs(format.decimal(input.debit))
            let credit = try input.credit.isEmpty ? 0 : format.decimal(input.credit)
            guard credit >= 0, debit == 0 || credit == 0 else { throw ImportFailure("Enter an amount in only one of Money in or Money out.") }
            let signed = try MoneyInput.add(credit, -debit)
            return (signed, signed < 0)
        }
        let amount = try format.decimal(input.amount)
        guard !input.originalType.isEmpty else { let signed = positiveOut ? -amount : amount; return (signed, signed < 0) }
        guard let type = EntryKind(rawValue: input.originalType), amount >= 0 || type == .transfer else {
            throw ImportFailure("Use income, expense, refund or transfer as the type, with a positive amount. Only a transfer can be negative, for money out.")
        }
        switch type {
        case .expense: return (-amount, true)
        case .transfer: return (amount, amount < 0 ? true : input.amount.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("+") ? false : nil)
        case .income, .refund: return (amount, false)
        }
    }
    /// `timeZone` says which date is today (the Mac's); tests pin one.
    static func evaluate(_ batch: ImportBatchDraft, document: VaultDocument, now: Date = Date(), timeZone: TimeZone = .current, catalog: [CatalogCoin] = []) -> ImportEvaluation {
        var result = ImportEvaluation()
        do { try batch.checkLimits(); try Task.checkCancellation() }
        catch { result.globalError = error.localizedDescription; return result }
        guard !batch.rows.isEmpty else { result.globalError = "Add at least one row."; return result }
        var pass = Pass(batch: batch, document: document, now: now, timeZone: timeZone, coins: ImportCoins.available(document: document, catalog: catalog))
        pass.checkFormats()
        for row in batch.rows {
            if Task.isCancelled { pass.result.globalError = "Import cancelled."; return pass.result }
            guard row.included else { pass.result.states[row.id] = .excluded; continue }
            guard let source = batch.sources.first(where: { $0.id == row.sourceID }) else { pass.result.states[row.id] = .error("The source file is missing."); continue }
            do {
                if let error = row.parseError { throw ImportFailure(error) }
                switch row.content {
                case .statement(let input): try pass.statement(row, input, from: source)
                case .bankBalance(let input): try pass.bankBalance(row, input, from: source)
                case .holding(let input): try pass.holding(row, input, from: source)
                }
            } catch { pass.result.states[row.id] = .error((error as? LocalizedError)?.errorDescription ?? "Check the name, currency, date and exact amount.") }
        }
        if batch.mode == .statements { pass.finishStatements() }
        return pass.finish()
    }
    /// One evaluation's working state: the document as it would be saved, and what the batch has created and seen so far.
    private struct Pass {
        /// Rows sharing an account and fingerprint: saved before, and met or added per file of this batch.
        struct Copies {
            var saved = 0, savedWithoutID = 0
            var seen: [UUID: Int] = [:], seenWithID: [UUID: Int] = [:], added: [UUID: Int] = [:], addedWithoutID: [UUID: Int] = [:]
        }
        let batch: ImportBatchDraft, document: VaultDocument, now: Date, timeZone: TimeZone, coins: [CatalogCoin]
        var result = ImportEvaluation(), next: VaultDocument
        var touchedAccounts = Set<UUID>()
        var createdAccounts: [String: UUID] = [:], createdPortfolios: [String: UUID] = [:]
        var sourceAccounts: [UUID: UUID] = [:], importedSources = Set<UUID>(), duplicateSources = Set<UUID>()
        var seenReferences: [String: Entry]
        /// Saved entries by reference, so re-imported rows find theirs without a scan.
        let savedIndex: [String: Int]
        /// By `<account>:<fingerprint>`.
        var copies: [String: Copies]
        var balanceKeys = Set<String>(), holdingKeys = Set<String>()
        /// Hashing a file is costly; do it once per file, not once per row.
        let digests: [UUID: Data]
        init(batch: ImportBatchDraft, document: VaultDocument, now: Date, timeZone: TimeZone, coins: [CatalogCoin]) {
            self.batch = batch; self.document = document; self.now = now; self.timeZone = timeZone; self.coins = coins; next = document
            seenReferences = Dictionary(document.entries.compactMap { entry in entry.sourceRef.map { ($0, entry) } }, uniquingKeysWith: { first, _ in first })
            savedIndex = Dictionary(document.entries.indices.compactMap { index in document.entries[index].sourceRef.map { ($0, index) } }, uniquingKeysWith: { first, _ in first })
            var copies: [String: Copies] = [:]
            for entry in document.entries {
                guard let fingerprint = entry.importFingerprint, let ref = entry.sourceRef else { continue }
                let parts = ref.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                let key = String(parts[0]) + ":" + fingerprint
                copies[key, default: Copies()].saved += 1
                if parts.count > 1, parts[1].hasPrefix("import-row/") { copies[key, default: Copies()].savedWithoutID += 1 }
            }
            self.copies = copies
            digests = batch.mode == .statements ? Dictionary(batch.sources.map { ($0.id, $0.digest) }, uniquingKeysWith: { first, _ in first }) : [:]
        }
        func digest(_ source: ImportSourceDraft) -> Data { digests[source.id] ?? source.digest }
        /// A date or number format that two readings fit waits for the user's choice, before anything is saved.
        mutating func checkFormats() {
            for source in batch.sources where source.unconfirmedDate != nil || source.unconfirmedNumber != nil {
                guard batch.rows.contains(where: { $0.sourceID == source.id && $0.included }) else { continue }
                let what = [source.unconfirmedDate.map { _ in "dates" }, source.unconfirmedNumber.map { _ in "amounts" }].compactMap { $0 }.joined(separator: " and ")
                result.needsFormat.insert(source.id)
                result.sourceErrors[source.id] = "Choose how " + source.filename + " writes " + what + "."
            }
        }
        mutating func resolveAccount(_ input: ImportAccount) throws -> UUID {
            let currency = try MoneyInput.normalizeCurrency(input.currency)
            if let id = input.existingID {
                guard let account = next.accounts.first(where: { $0.id == id }), account.currency == currency else { throw ImportFailure("Choose an existing account with this currency.") }
                return id
            }
            let name = try ImportBatchProcessor.cleanName(input.name), key = name.lowercased() + ":" + currency
            if let id = createdAccounts[key] {
                guard next.accounts.first(where: { $0.id == id })?.ownerBusinessID == input.ownerBusinessID else { throw ImportFailure("Rows in one account must have the same owner.") }
                return id
            }
            guard !document.accounts.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame && $0.currency == currency }) else { throw ImportFailure("You already have an account with this name and currency. Choose it instead.") }
            if let owner = input.ownerBusinessID, !(next.businessAccounting ?? []).contains(where: { $0.id == owner }) { throw ImportFailure("Choose a company with ownership history.") }
            let account = Account(name: name, currency: currency, ownerBusinessID: input.ownerBusinessID); next.accounts.append(account)
            next.track(.banks); createdAccounts[key] = account.id
            return account.id
        }
        mutating func recordBalance(accountID: UUID, amount: Decimal, date inputDate: Date) throws -> Bool {
            // Today on this Mac is observed now (within the day), and so is a later day that's already today further
            // east; earlier days keep their date.
            let today = UTCDay.today(now: now, timeZone: timeZone), isToday = UTCDay.start(of: inputDate) == today
            let date = isToday ? UTCDay.moment(for: today, now: now, timeZone: timeZone)
                : inputDate > today && inputDate < ImportDateFormat.endOfToday(now) ? now : inputDate
            guard date <= now.addingTimeInterval(300) else { throw ImportFailure("The observation date cannot be in the future.") }
            let key = accountID.uuidString + ":" + String(date.timeIntervalSince1970)
            let existing = next.bankBalances.filter { $0.accountID == accountID && $0.observedAt == date }
            if existing.contains(where: { $0.amount.value != amount }) {
                // Late in the evening west of UTC, today's balances all fall on the day's last second: a newer one
                // replaces the one there, as it would have come after it.
                guard isToday, date < now else { throw ImportFailure("A different balance exists at this time. Correct the date or amount.") }
                next.bankBalances.removeAll { $0.accountID == accountID && $0.observedAt == date }
            } else if !existing.isEmpty || balanceKeys.contains(key) { return false }
            guard let account = next.accounts.first(where: { $0.id == accountID }) else { throw ImportFailure("Choose an account.") }
            if !next.bankTracking.contains(where: { $0.accountID == accountID }) && !next.trackedBankAccountIDs.contains(accountID) { next.setBankTracked(accountID, tracked: true, at: date) }
            next.bankBalances.append(BankBalanceObservation(id: UUID(), accountID: accountID, amount: PreciseDecimal(amount), currency: account.currency, observedAt: date, source: "Import", sourceIdentity: accountID.uuidString))
            // A balance older than the account's first tracked day moves that start back.
            next.backdateBankTracking(accountID, to: date)
            balanceKeys.insert(key); next.track(.banks)
            touchedAccounts.insert(accountID)
            return true
        }
        /// The statement's account, asked about once for the file rather than on every row; nil while it can't be imported.
        mutating func account(for source: ImportSourceDraft, digest fileDigest: Data) -> UUID? {
            if let id = sourceAccounts[source.id] { return id }
            guard source.account.existingID != nil || !source.account.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                result.sourceErrors[source.id] = "Choose an account for " + source.filename + "."; result.needsAccount.insert(source.id); return nil
            }
            // One currency's part of a split file belongs in an account of that currency.
            if let code = source.splitCurrency, source.account.currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() != code {
                result.sourceErrors[source.id] = "Choose an account in " + code + " for " + source.filename + "."; return nil
            }
            let accountID: UUID
            do { accountID = try resolveAccount(source.account) }
            catch { result.sourceErrors[source.id] = error.localizedDescription; return nil }
            sourceAccounts[source.id] = accountID
            let imported = importedSources, accounts = sourceAccounts, hashes = self.digests
            let duplicate = document.importedStatements.contains { $0.digest == fileDigest && ($0.accountID == nil || $0.accountID == accountID) }
                || batch.sources.contains { other in imported.contains(other.id) && accounts[other.id] == accountID && (hashes[other.id] ?? other.digest) == fileDigest }
            if duplicate { duplicateSources.insert(source.id) }
            return accountID
        }
        mutating func statement(_ row: ImportDraftRow, _ input: StatementInput, from source: ImportSourceDraft) throws {
            let fileDigest = digest(source)
            if document.importedStatements.contains(where: { $0.digest == fileDigest && $0.accountID == nil }) { result.states[row.id] = .duplicate; return }
            guard batch.mode == .statements else { throw ImportFailure("The row does not match this import type.") }
            guard let accountID = account(for: source, digest: fileDigest) else { return }
            let date = try source.dateFormat.date(input.date)
            let format = source.numberFormat, positiveOut = source.positiveIsOutflow
            if duplicateSources.contains(source.id) {
                // The file was imported before its rows kept a day. Teach the saved rows now and move on.
                let external = input.transactionID.trimmingCharacters(in: .whitespacesAndNewlines)
                let outflow = (try? ImportBatchProcessor.movement(input, format: format, positiveOut: positiveOut))?.outflow
                if !external.isEmpty, let index = savedIndex[accountID.uuidString + ":" + external],
                   next.entries[index].day == nil || (next.entries[index].outflow == nil && outflow != nil) {
                    next.entries[index].day = ImportDateFormat.today(date)
                    if next.entries[index].outflow == nil { next.entries[index].outflow = outflow }
                    touchedAccounts.insert(accountID); result.learnedDays += 1
                }
                result.states[row.id] = .duplicate; return
            }
            guard date < ImportDateFormat.endOfToday(now) else { throw ImportFailure("The transaction date cannot be in the future.") }
            let currency = try MoneyInput.normalizeCurrency(input.currency)
            let label = input.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, label.count <= 500 else { throw ImportFailure("Enter a description of 1–500 characters.") }
            let (signed, fileOutflow) = try ImportBatchProcessor.movement(input, format: format, positiveOut: positiveOut)
            guard signed != 0 else { throw ImportFailure("This transaction has no amount. Correct it or exclude the row.") }
            let components = UTCDay.calendar.dateComponents([.year, .month], from: date)
            guard let month = MonthKey(String(format: "%04d-%02d", components.year!, components.month!)), month.year >= 1900 else { throw ImportFailure("Use a transaction date from 1900 onwards.") }
            // The fingerprint follows the file as written, so reading its signs the other way still finds saved rows.
            let written = try positiveOut ? ImportBatchProcessor.movement(input, format: format).signed : signed
            let fingerprint = ImportBatchProcessor.fingerprint(date: date, label: label, signedAmount: written, currency: currency)
            let external = input.transactionID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard external.count <= 200, !external.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw ImportFailure("Check the transaction ID.") }
            let reference = accountID.uuidString + ":" + (external.isEmpty ? "import-row/" + row.id.uuidString : external)
            if let existing = seenReferences[reference] {
                let same = existing.importFingerprint.map { $0 == fingerprint } ?? (existing.month == month.description && existing.amount == abs(signed) && existing.currency == currency && existing.label == label)
                guard same else { throw ImportFailure("This transaction ID has different saved details. Correct it or exclude the row.") }
                // Re-importing an older statement teaches existing rows their day and direction.
                if let index = savedIndex[reference], next.entries[index].day == nil || (next.entries[index].outflow == nil && fileOutflow != nil) {
                    next.entries[index].day = ImportDateFormat.today(date)
                    if next.entries[index].outflow == nil { next.entries[index].outflow = fileOutflow }
                    touchedAccounts.insert(accountID)
                }
                result.states[row.id] = .duplicate; return
            }
            let key = accountID.uuidString + ":" + fingerprint
            if isRepeat(row, key: key, withID: !external.isEmpty, source: source.id) { return }
            // The sign decides income or expense now, so a corrected amount or number format is never stale.
            // A type from the file or the user, or a Monzo refund or transfer, stays.
            var kind = input.kind
            if !input.kindIsUserEdited && input.originalType.isEmpty && (kind == .income || kind == .expense) { kind = signed < 0 ? .expense : .income }
            var entry = Entry(month: month, kind: kind, amount: abs(signed), currency: currency, label: label, source: .csv, sourceRef: reference)
            // An account set to Personal ("") keeps its rows personal.
            if let account = next.accounts.first(where: { $0.id == accountID }), AssetOwnership.businessID(for: account, in: next) != nil { entry.bucket = .otherBusiness }
            if !input.kindIsUserEdited && input.originalType.isEmpty { entry.kind = OwnerPayments.classify(entry.kind, label: label, month: month.description, document: next) }
            entry.kindIsUserEdited = input.kindIsUserEdited || !input.originalType.isEmpty
            entry.importFingerprint = fingerprint
            entry.day = ImportDateFormat.today(date)
            // A type chosen in review also says which way the money went; a transfer keeps the file's direction.
            entry.outflow = input.kindIsUserEdited && kind != .transfer ? (kind == .expense) : fileOutflow
            touchedAccounts.insert(accountID)
            next.entries.append(entry); next.track(.cashFlow)
            seenReferences[reference] = entry
            copies[key, default: Copies()].added[source.id, default: 0] += 1
            if external.isEmpty { copies[key, default: Copies()].addedWithoutID[source.id, default: 0] += 1 }
            importedSources.insert(source.id); result.states[row.id] = .ready("New transaction"); result.added += 1
        }
        /// Whether a row repeats one already saved or added, marking it if so. As many identical rows as are saved, or
        /// were added from another file in this batch, are those same payments and are skipped; a further copy in the
        /// file may be a second payment, so it's asked about. A row with an ID only repeats rows saved without one.
        mutating func isRepeat(_ row: ImportDraftRow, key: String, withID: Bool, source: UUID) -> Bool {
            var tally = copies[key] ?? Copies()
            defer { copies[key] = tally }
            func others(_ counts: [UUID: Int]) -> Int { counts.reduce(0) { $1.key == source ? $0 : $0 + $1.value } }
            if withID {
                let copy = tally.seenWithID[source, default: 0]; tally.seenWithID[source] = copy + 1
                // Saved from an export without IDs: the same payment, now with one.
                guard copy < tally.savedWithoutID + others(tally.addedWithoutID) else { return false }
                result.states[row.id] = .duplicate; return true
            }
            let copy = tally.seen[source, default: 0]; tally.seen[source] = copy + 1
            if row.duplicateApproved { return false }
            if copy < tally.saved + others(tally.added) { result.states[row.id] = .duplicate; return true }
            if copy > 0 { result.states[row.id] = .possibleDuplicate; return true }
            return false
        }
        mutating func bankBalance(_ row: ImportDraftRow, _ input: BankBalanceInput, from source: ImportSourceDraft) throws {
            guard batch.mode == .bankBalances else { throw ImportFailure("The row does not match this import type.") }
            // Typed-in values read a lone comma or point as a decimal where it can't separate thousands.
            let typed = source.isManual
            let accountID = try resolveAccount(input.account)
            let amount = try source.numberFormat.decimal(input.balance, typed: typed), date = try source.dateFormat.date(input.date)
            // "Update all balances" fills in every account; one left as it was is not a new observation.
            if typed, batch.rows.count > 1, UTCDay.start(of: date) == UTCDay.today(now: now, timeZone: timeZone),
               next.bankBalances.filter({ $0.accountID == accountID }).max(by: { $0.observedAt < $1.observedAt })?.amount.value == amount {
                result.states[row.id] = .duplicate; return
            }
            let added = try recordBalance(accountID: accountID, amount: amount, date: date)
            result.states[row.id] = added ? .ready("Record dated balance") : .duplicate
            if added { result.added += 1 }
        }
        mutating func holding(_ row: ImportDraftRow, _ input: HoldingInput, from source: ImportSourceDraft) throws {
            guard batch.mode.isHolding else { throw ImportFailure("The row does not match this import type.") }
            let typed = source.isManual
            let coin: CatalogCoin
            let quantity: Decimal
            if batch.mode == .metals {
                let metal = try PreciousMetal.resolve(input.coin)
                coin = CatalogCoin(id: metal.assetID.rawValue, symbol: metal.rawValue, name: metal.name)
                quantity = try MetalWeightUnit.resolve(input.unit).grams(source.numberFormat.decimal(input.quantity, typed: typed))
            } else {
                coin = try ImportCoins.resolve(input, coins: coins)
                guard !coin.id.hasPrefix("metal-") else { throw ImportFailure("Add gold and other metals under Metals.") }
                quantity = try source.numberFormat.decimal(input.quantity, typed: typed)
            }
            guard MoneyInput.isFinite(quantity), quantity >= 0 else { throw ImportFailure("Enter zero or a positive quantity.") }
            // The app writes this date itself, so it is always ISO. Today (the Mac's) means now, as for balances,
            // so an edit made earlier today can't outrank this one.
            let day = try ImportDateFormat.iso.date(input.date)
            guard day <= UTCDay.today(now: now, timeZone: timeZone) else { throw ImportFailure("Choose today or an earlier date.") }
            let date = UTCDay.moment(for: day, now: now, timeZone: timeZone)
            var cost: (paid: Decimal, currency: String)?
            let paidText = input.paid.trimmingCharacters(in: .whitespacesAndNewlines)
            if !paidText.isEmpty {
                let paid = try source.numberFormat.decimal(paidText, typed: typed)
                guard MoneyInput.isFinite(paid), paid >= 0 else { throw ImportFailure("Enter zero or a positive amount paid.") }
                let currency = try MoneyInput.normalizeCurrency(input.paidCurrency)
                cost = (paid, currency)
            }
            let portfolioID: UUID
            if let id = input.portfolioID {
                guard let portfolio = next.portfolio(id: id), portfolio.isActive(at: now), portfolio.kind == batch.mode.kind else { throw ImportFailure("Choose an active portfolio for this asset type.") }
                portfolioID = id
            } else {
                let name = try ImportBatchProcessor.cleanName(input.portfolioName), key = name.lowercased()
                if let owner = input.ownerBusinessID, !(next.businessAccounting ?? []).contains(where: { $0.id == owner }) {
                    throw ImportFailure("Choose a company with ownership history.")
                }
                if let id = createdPortfolios[key] {
                    guard next.portfolio(id: id)?.ownerBusinessID == input.ownerBusinessID else { throw ImportFailure("Rows in one portfolio must have the same owner.") }
                    portfolioID = id
                }
                else {
                    // Unique within an owner: a personal "Crypto" and a company's "Crypto" are different portfolios.
                    let owner = input.ownerBusinessID.flatMap { $0.isEmpty ? nil : $0 }
                    guard !document.portfolios.contains(where: { !$0.isArchived && ($0.ownerBusinessID.flatMap { $0.isEmpty ? nil : $0 }) == owner && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { throw ImportFailure("This portfolio exists. Choose it from your portfolios.") }
                    let portfolio = Portfolio(name: name, createdAt: now, kind: batch.mode.kind, ownerBusinessID: input.ownerBusinessID); next.portfolios.append(portfolio)
                    portfolioID = portfolio.id; createdPortfolios[key] = portfolio.id
                }
            }
            let key = portfolioID.uuidString + ":" + coin.id
            guard holdingKeys.insert(key).inserted else { throw ImportFailure("This coin appears twice in the same portfolio. Keep one total quantity.") }
            let before = next
            let existing = before.holdings.first { $0.portfolioID == portfolioID && $0.assetID.rawValue == coin.id && $0.archivedAt == nil }
            let previous = existing.flatMap { before.effectiveQuantity(holdingID: $0.id, at: now) }
            // The same total on the chosen date is nothing new, unless a cost is being recorded for the first time that day.
            let onDate = existing.flatMap { before.effectiveQuantity(holdingID: $0.id, at: date) }
            let sameDayLot = existing.flatMap { holding in before.purchases?.firstIndex { $0.holdingID == holding.id && UTCDay.isSameDay($0.at, date) } }
            if onDate == quantity, cost == nil || sameDayLot.map({ before.purchases?[$0].paid.value == cost?.paid && before.purchases?[$0].currency == cost?.currency }) == true {
                result.states[row.id] = .duplicate; return
            }
            next = try HoldingMutations.addHolding(portfolioID: portfolioID, assetID: CanonicalAssetID(coin.id), assetName: coin.name, quantity: quantity, at: date, document: next)
            next.track(batch.mode.kind)
            let after = next
            if let cost, let holdingID = (existing ?? after.holdings.last { $0.portfolioID == portfolioID && $0.assetID.rawValue == coin.id })?.id {
                // The lot covers the increase on that date. Restating a total without an increase records the cost of the
                // whole position, replacing a cost already recorded that day rather than counting it twice.
                let held = onDate ?? 0
                var lot = PurchaseLot(holdingID: holdingID, quantity: PreciseDecimal(quantity > held ? quantity - held : quantity), paid: PreciseDecimal(cost.paid), currency: cost.currency, at: date)
                var purchases = next.purchases ?? []
                if quantity <= held, let index = sameDayLot, purchases.indices.contains(index) { lot.id = purchases[index].id; purchases[index] = lot }
                else { purchases.append(lot) }
                next.purchases = purchases
            }
            result.states[row.id] = .ready("\(previous.map { NSDecimalNumber(decimal: $0).stringValue } ?? "New") → \(NSDecimalNumber(decimal: quantity).stringValue) \(coin.name)\(batch.mode == .metals ? " · fine grams" : "")")
            result.added += 1
        }
        /// Once every row is read: each statement's typed balance, and its original file, archived once. A file kept for
        /// one account (a Wise history split by currency) is only noted for the others, and past the budget by its hash.
        mutating func finishStatements() {
            compactArchive()
            var archived = next.importedStatements.reduce(0) { $0 + $1.originalBytes.count }
            for source in batch.sources where !duplicateSources.contains(source.id) {
                guard let accountID = sourceAccounts[source.id], batch.rows.contains(where: { $0.sourceID == source.id && $0.included }) else { continue }
                if !source.balance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    do {
                        let amount = try source.numberFormat.decimal(source.balance, typed: true), date = try ImportDateFormat.iso.date(source.balanceDate)
                        if try recordBalance(accountID: accountID, amount: amount, date: date) { result.added += 1 }
                    } catch { result.sourceErrors[source.id] = error.localizedDescription }
                }
                // Archive reviewed files even when their transactions were all already present.
                let fileDigest = digest(source)
                guard !source.bytes.isEmpty, !result.hasErrors,
                      !next.importedStatements.contains(where: { $0.digest == fileDigest && ($0.accountID == nil || $0.accountID == accountID) }) else { continue }
                let kept = next.importedStatements.contains { $0.digest == fileDigest && !$0.originalBytes.isEmpty }
                let fits = archived + source.bytes.count <= ImportBatchProcessor.archiveBudget
                if !kept && !fits { result.unarchivedFiles += 1 }
                let bytes = kept || !fits ? Data() : source.bytes
                next.importedStatements.append(ImportedStatement(digest: fileDigest, originalBytes: bytes, importedAt: now, accountID: accountID))
                archived += bytes.count; result.added += 1
            }
        }
        /// Older versions kept a split file's bytes once per account; the first copy is enough.
        mutating func compactArchive() {
            var holders: [Data: Int] = [:]
            for index in next.importedStatements.indices where !next.importedStatements[index].originalBytes.isEmpty {
                let hash = next.importedStatements[index].digest
                guard let first = holders[hash] else { holders[hash] = index; continue }
                if next.importedStatements[first].originalBytes == next.importedStatements[index].originalBytes { next.importedStatements[index].originalBytes = Data() }
            }
        }
        mutating func finish() -> ImportEvaluation {
            if !result.hasErrors {
                // Statements move the balance history of the accounts they touch.
                let accounts = touchedAccounts, moment = now
                if !accounts.isEmpty { result.historyStart = BalanceReconstruction.apply(accountIDs: accounts, to: &next, now: moment) }
                // Learned dates and a rebuilt history are worth saving even when no row is new.
                if result.learnedDays > 0 || result.historyStart != nil { result.added += max(result.learnedDays, 1) }
                result.document = next
            }
            return result
        }
    }
}
