import Foundation

nonisolated enum CSVReader {
    static func parse(_ text: String, delimiter: Character = ",") throws -> [[String]] {
        var rows: [[String]] = [], row: [String] = []
        var field = "", quoted = false, afterQuote = false
        var iterator = text.makeIterator(), pending: Character?
        var characterCount = 0
        while let c = pending ?? iterator.next() {
            pending = nil
            characterCount += 1
            if characterCount.isMultiple(of: 4096) { try Task.checkCancellation() }
            if quoted {
                if c == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") }
                        else { quoted = false; afterQuote = true; pending = next }
                    } else { quoted = false; afterQuote = true }
                } else { field.append(c) }
            } else {
                if afterQuote && c != delimiter && c != "\n" && c != "\r" && c != "\r\n" { throw StatementError.invalidCSV }
                switch c {
                case "\"": guard field.isEmpty else { throw StatementError.invalidCSV }; quoted = true
                case delimiter: row.append(field); field = ""; afterQuote = false
                case "\n", "\r", "\r\n": row.append(field); rows.append(row); row = []; field = ""; afterQuote = false
                default: field.append(c)
                }
            }
            if rows.count > 20000 || row.count > 100 || field.count > 100000 { throw StatementError.tooLarge }
        }
        guard !quoted else { throw StatementError.invalidCSV }
        if !field.isEmpty || !row.isEmpty || afterQuote { row.append(field); rows.append(row) }
        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    }
}

nonisolated enum StatementError: LocalizedError {
    case invalidCSV, columns, invalidRow(Int), tooLarge, duplicate
    var errorDescription: String? {
        switch self {
        case .invalidCSV: "This CSV couldn’t be read. Export a fresh CSV from your bank or spreadsheet and try again."
        case .columns: "Use the Up Only CSV template, or a Monzo or Wise statement with transaction IDs."
        case .invalidRow(let n): "Row \(n) has an invalid date, currency, amount or transaction ID. Nothing was imported."
        case .tooLarge: "Choose a statement smaller than 8 MB and 20,000 rows."
        case .duplicate: "This statement has already been imported."
        }
    }
}
nonisolated struct StatementDraft: Identifiable {
    var id = UUID()
    var bytes: Data
    var digest: Data
    var entries: [Entry]
    var filename: String
    var accountID: UUID
}
nonisolated enum StatementParser {
    static func read(_ bytes: Data, filename: String, accountID: UUID) throws -> StatementDraft {
        guard bytes.count <= VaultLimits.maxBatchBytes else { throw StatementError.tooLarge }
        guard let text = String(data: bytes, encoding: .utf8) else { throw StatementError.invalidCSV }
        let grid = try CSVReader.parse(text.replacingOccurrences(of: "\u{FEFF}", with: ""))
        guard let header = grid.first, grid.count > 1, Set(header).count == header.count else { throw StatementError.columns }
        let columns = Dictionary(uniqueKeysWithValues: header.enumerated().map { ($0.element, $0.offset) })
        let monzo = columns["Transaction ID"] != nil
        let wise = columns["TransferWise ID"] != nil
        let idColumn = monzo ? "Transaction ID" : wise ? "TransferWise ID" : "TransactionID"
        let descriptionColumn = monzo ? "Name" : "Description"
        for key in [idColumn, "Date", "Amount", "Currency", descriptionColumn] where columns[key] == nil { throw StatementError.columns }
        if !monzo && !wise && columns["Type"] == nil { throw StatementError.columns }
        var entries: [Entry] = [], seen = Set<String>()
        for (index, row) in grid.dropFirst().enumerated() {
            func field(_ name: String) -> String { columns[name].flatMap { $0 < row.count ? row[$0].trimmingCharacters(in: .whitespacesAndNewlines) : nil } ?? "" }
            do {
                guard row.count == header.count else { throw StatementError.invalidRow(index+2) }
                let external = field(idColumn)
                guard !external.isEmpty, external.count <= 200, seen.insert(external).inserted else { throw StatementError.invalidRow(index+2) }
                let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = UTCDay.timeZone
                formatter.dateFormat = monzo || wise ? "dd/MM/yyyy" : "yyyy-MM-dd"; formatter.isLenient = false
                let dateText = field("Date")
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = UTCDay.timeZone
                guard let date = formatter.date(from: dateText), formatter.string(from: date) == dateText, date <= Date(),
                      let month = MonthKey(String(format: "%04d-%02d", calendar.component(.year, from: date), calendar.component(.month, from: date))) else { throw StatementError.invalidRow(index+2) }
                let amount = try MoneyInput.parseExact(field("Amount")), currency = try MoneyInput.normalizeCurrency(field("Currency"))
                let label = field(descriptionColumn).isEmpty ? field("Description") : field(descriptionColumn)
                guard !label.isEmpty, label.count <= 500 else { throw StatementError.invalidRow(index+2) }
                let kind: EntryKind
                if monzo || wise { kind = amount < 0 ? .expense : .income }
                else { guard let supplied = EntryKind(rawValue: field("Type").lowercased()), amount >= 0 else { throw StatementError.invalidRow(index+2) }; kind = supplied }
                entries.append(Entry(month: month, kind: kind, amount: abs(amount), currency: currency, label: label, source: .csv, sourceRef: accountID.uuidString + ":" + external))
            } catch { throw StatementError.invalidRow(index+2) }
        }
        return StatementDraft(bytes: bytes, digest: VaultCrypto.sha256(bytes), entries: entries, filename: filename, accountID: accountID)
    }
}

// Drafts never leave memory. All three input paths use the same validation and atomic application.
nonisolated enum ImportMode: String, CaseIterable, Sendable {
    case statements, bankBalances, holdings, metals
    var title: String {
        switch self { case .statements: "Statements"; case .bankBalances: "Bank balances"; case .holdings: "Crypto holdings"; case .metals: "Precious metals" }
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
        case .statements: "TransactionID,Date,Description,Amount,Currency,Type\nsample-1,2026-01-02,Groceries,12.50,USD,expense\n"
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
    case iso = "yyyy-MM-dd", dayFirst = "dd/MM/yyyy", monthFirst = "MM/dd/yyyy"
    func date(_ raw: String) throws -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = UTCDay.timeZone
        formatter.dateFormat = rawValue; formatter.isLenient = false
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let date = formatter.date(from: clean), formatter.string(from: date) == clean else {
            throw ImportFailure("Use the selected date format: \(rawValue).")
        }
        return date
    }
    static func today(_ now: Date = Date()) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = UTCDay.timeZone; formatter.dateFormat = iso.rawValue
        return formatter.string(from: now)
    }
}
nonisolated enum ImportNumberFormat: String, CaseIterable, Sendable {
    case point = "1,234.56", comma = "1.234,56"
    func decimal(_ raw: String) throws -> Decimal {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let decimalMark: Character = self == .point ? "." : ","
        let grouping: Character = self == .point ? "," : "."
        let parts = clean.split(separator: decimalMark, omittingEmptySubsequences: false)
        guard parts.count <= 2, !parts.isEmpty else { throw ImportFailure("Check the number format (\(rawValue)).") }
        let whole = String(parts[0])
        if whole.contains(grouping) {
            let unsigned = whole.hasPrefix("-") ? String(whole.dropFirst()) : whole
            let groups = unsigned.split(separator: grouping, omittingEmptySubsequences: false)
            guard (1...3).contains(groups[0].count), groups.allSatisfy({ $0.allSatisfy(\.isNumber) }),
                  groups.dropFirst().allSatisfy({ $0.count == 3 }) else { throw ImportFailure("Check the thousands separators.") }
        }
        guard parts.count < 2 || !parts[1].contains(grouping) else { throw ImportFailure("Check the decimal separator.") }
        let normalized = whole.replacingOccurrences(of: String(grouping), with: "") + (parts.count == 2 ? "." + parts[1] : "")
        do { return try MoneyInput.parseExact(normalized) }
        catch { throw ImportFailure("Enter an exact number, without a currency symbol or formula.") }
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
    var account = ImportAccount()
    var balance = ""
    var balanceDate = ImportDateFormat.today()
    var digest: Data { VaultCrypto.sha256(bytes) }
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
}
nonisolated enum ImportParser {
    static func source(bytes: Data, filename: String, mode: ImportMode, pasted: Bool = false) throws -> ImportSourceDraft {
        guard bytes.count <= VaultLimits.maxBatchBytes else { throw StatementError.tooLarge }
        guard let text = String(data: bytes, encoding: .utf8) else { throw StatementError.invalidCSV }
        let clean = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        let delimiter: Character = pasted && clean.contains("\t") ? "\t" : ","
        let grid = try CSVReader.parse(clean, delimiter: delimiter)
        guard let first = grid.first, !first.isEmpty else { throw ImportFailure("This file has no rows.") }
        var source = ImportSourceDraft(filename: filename, bytes: bytes, grid: grid)
        source.mapping = guessMapping(first, mode: mode)
        source.hasHeader = !source.mapping.isEmpty
        if !source.hasHeader {
            let order: [ImportColumn] = switch mode {
            case .statements: [.date, .description, .amount, .currency, .type, .transactionID]
            case .bankBalances: [.account, .currency, .balance, .date]
            case .holdings: [.portfolio, .coin, .quantity]
            case .metals: [.portfolio, .coin, .quantity, .unit]
            }
            for (index, column) in order.enumerated() where index < first.count { source.mapping[column] = index }
        }
        if first.contains("Transaction ID") || first.contains("TransferWise ID") {
            source.dateFormat = .dayFirst
            // Bank transaction types (card payment, transfer, etc.) are not Up Only classifications.
            if mode == .statements { source.mapping.removeValue(forKey: .type) }
        }
        return source
    }
    static func guessMapping(_ header: [String], mode: ImportMode) -> [ImportColumn: Int] {
        let aliases: [ImportColumn: [String]] = [
            .date: ["date", "observedon", "observedat", "transactiondate"], .description: ["description", "name", "memo", "narrative"],
            .amount: ["amount", "transactionamount"], .debit: ["debit", "moneyout", "withdrawal", "withdrawals"],
            .credit: ["credit", "moneyin", "deposit", "deposits"], .currency: ["currency", "currencycode"],
            .transactionID: ["transactionid", "transferwiseid", "id", "reference"], .type: ["type", "kind"],
            .account: ["account", "accountname"], .balance: ["balance", "closingbalance", "currentbalance"],
            .portfolio: ["portfolio", "portfolioname"], .coin: ["coin", "coinid", "coingeckoid", "asset", "symbol", "ticker", "metal"],
            .quantity: ["quantity", "totalquantity", "balance", "amount", "weight"], .unit: ["unit", "weightunit"]
        ]
        var result: [ImportColumn: Int] = [:]
        for (index, name) in header.enumerated() {
            let normalized = name.lowercased().filter { $0.isLetter || $0.isNumber }
            for column in mode.columns where aliases[column]?.contains(normalized) == true && result[column] == nil { result[column] = index }
        }
        return result
    }
    static func rows(source: ImportSourceDraft, mode: ImportMode) throws -> [ImportDraftRow] {
        var result: [ImportDraftRow] = []
        for (offset, cells) in source.grid.dropFirst(source.hasHeader ? 1 : 0).enumerated() {
            if offset.isMultiple(of: 100) { try Task.checkCancellation() }
            func field(_ column: ImportColumn) -> String {
                guard let index = source.mapping[column], cells.indices.contains(index) else { return "" }
                return cells[index].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let content: ImportRowContent
            switch mode {
            case .statements:
                let rawType = field(.type).lowercased()
                let inferred: EntryKind = (try? source.numberFormat.decimal(field(.amount))) .map { $0 < 0 ? .expense : .income } ?? (!field(.credit).isEmpty && (try? source.numberFormat.decimal(field(.credit))) != 0 ? .income : .expense)
                let typed = EntryKind(rawValue: rawType)
                content = .statement(StatementInput(date: field(.date), label: field(.description), amount: field(.amount), debit: field(.debit), credit: field(.credit), currency: field(.currency).isEmpty ? source.account.currency : field(.currency), transactionID: field(.transactionID), kind: typed ?? inferred, originalType: rawType))
            case .bankBalances:
                content = .bankBalance(BankBalanceInput(account: ImportAccount(name: field(.account), currency: field(.currency).isEmpty ? "USD" : field(.currency)), balance: field(.balance), date: field(.date).isEmpty ? ImportDateFormat.today() : field(.date)))
            case .holdings, .metals:
                content = .holding(HoldingInput(portfolioName: field(.portfolio), coin: field(.coin), quantity: field(.quantity), unit: mode == .metals ? field(.unit) : "g"))
            }
            var row = ImportDraftRow(sourceID: source.id, line: offset + (source.hasHeader ? 2 : 1), content: content)
            if cells.count != source.grid.first?.count { row.parseError = "This row has a different number of cells. Correct the fields or exclude it." }
            result.append(row)
        }
        return result
    }
}
nonisolated enum ImportCoins {
    static let common: [CatalogCoin] = [
        CatalogCoin(id: "bitcoin", symbol: "btc", name: "Bitcoin"), CatalogCoin(id: "ethereum", symbol: "eth", name: "Ethereum"),
        CatalogCoin(id: "solana", symbol: "sol", name: "Solana"), CatalogCoin(id: "usd-coin", symbol: "usdc", name: "USDC"),
        CatalogCoin(id: "tether", symbol: "usdt", name: "Tether"), CatalogCoin(id: "ripple", symbol: "xrp", name: "XRP"),
        CatalogCoin(id: "dogecoin", symbol: "doge", name: "Dogecoin"), CatalogCoin(id: "cardano", symbol: "ada", name: "Cardano")
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
        func rank(_ coin: CatalogCoin) -> Int {
            let fields = [coin.id, coin.symbol, coin.name].map { $0.lowercased() }
            if fields.contains(query) { return 0 }
            if fields.contains(where: { $0.hasPrefix(query) }) { return 1 }
            return 2
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
    case ready(String), duplicate, needsReview(String), error(String), excluded
    var text: String {
        switch self { case .ready(let s), .needsReview(let s), .error(let s): s; case .duplicate: "Already imported · skipped"; case .excluded: "Excluded" }
    }
    func displayText(privacy: Bool) -> String {
        if privacy, case .ready(let description) = self, description.contains(" → ") {
            return "Replace current total · Values hidden"
        }
        return text
    }
    var blocksSave: Bool { switch self { case .error, .needsReview: true; default: false } }
}
nonisolated struct ImportEvaluation: Sendable {
    var states: [UUID: ImportRowState] = [:]
    var sourceErrors: [UUID: String] = [:]
    var globalError: String?
    var added = 0
    var document: VaultDocument?
    var hasErrors: Bool { globalError != nil || !sourceErrors.isEmpty || states.values.contains(where: \.blocksSave) }
    var duplicates: Int { states.values.filter { $0 == .duplicate }.count }
    var readyRows: Int { states.values.filter { if case .ready = $0 { return true }; return false }.count }
}
nonisolated enum ImportBatchProcessor {
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
    static func evaluate(_ batch: ImportBatchDraft, document: VaultDocument, now: Date = Date(), catalog: [CatalogCoin] = []) -> ImportEvaluation {
        var result = ImportEvaluation(), next = document
        do { try batch.checkLimits(); try Task.checkCancellation() }
        catch { result.globalError = error.localizedDescription; return result }
        guard !batch.rows.isEmpty else { result.globalError = "Add at least one row."; return result }
        var createdAccounts: [String: UUID] = [:], createdPortfolios: [String: UUID] = [:]
        var sourceAccounts: [UUID: UUID] = [:], importedSources = Set<UUID>(), duplicateSources = Set<UUID>()
        let coins = ImportCoins.available(document: document, catalog: catalog)
        var seenReferences = Dictionary(document.entries.compactMap { entry in entry.sourceRef.map { ($0, entry) } }, uniquingKeysWith: { first, _ in first })
        var fingerprints = Set(document.entries.compactMap { entry -> String? in
            guard let fingerprint = entry.importFingerprint, let ref = entry.sourceRef, let account = ref.split(separator: ":").first else { return nil }
            return String(account) + ":" + fingerprint
        })
        var balanceKeys = Set<String>(), holdingKeys = Set<String>()
        func resolveAccount(_ input: ImportAccount, in doc: inout VaultDocument) throws -> UUID {
            let currency = try MoneyInput.normalizeCurrency(input.currency)
            if let id = input.existingID {
                guard let account = doc.accounts.first(where: { $0.id == id }), account.currency == currency else { throw ImportFailure("Choose an existing account with this currency.") }
                return id
            }
            let name = try cleanName(input.name), key = name.lowercased() + ":" + currency
            if let id = createdAccounts[key] {
                guard doc.accounts.first(where: { $0.id == id })?.ownerBusinessID == input.ownerBusinessID else { throw ImportFailure("Rows in one account must have the same owner.") }
                return id
            }
            guard !document.accounts.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame && $0.currency == currency }) else { throw ImportFailure("This account exists. Select it from the account menu.") }
            if let owner = input.ownerBusinessID, !(doc.businessAccounting ?? []).contains(where: { $0.id == owner }) { throw ImportFailure("Choose a company with ownership history.") }
            let account = Account(name: name, currency: currency, ownerBusinessID: input.ownerBusinessID); doc.accounts.append(account)
            doc.track(.banks); createdAccounts[key] = account.id
            return account.id
        }
        func recordBalance(accountID: UUID, amount: Decimal, date inputDate: Date, in doc: inout VaultDocument) throws -> Bool {
            let date = UTCDay.isSameDay(inputDate, now) ? now : inputDate
            guard date <= now.addingTimeInterval(300) else { throw ImportFailure("The observation date cannot be in the future.") }
            let key = accountID.uuidString + ":" + String(date.timeIntervalSince1970)
            let existing = doc.bankBalances.filter { $0.accountID == accountID && $0.observedAt == date }
            if existing.contains(where: { $0.amount.value != amount }) { throw ImportFailure("A different balance exists at this time. Correct the date or amount.") }
            if !existing.isEmpty || balanceKeys.contains(key) { return false }
            guard let account = doc.accounts.first(where: { $0.id == accountID }) else { throw ImportFailure("Choose an account.") }
            if !doc.bankTracking.contains(where: { $0.accountID == accountID }) && !doc.trackedBankAccountIDs.contains(accountID) { doc.setBankTracked(accountID, tracked: true, at: date) }
            doc.bankBalances.append(BankBalanceObservation(id: UUID(), accountID: accountID, amount: PreciseDecimal(amount), currency: account.currency, observedAt: date, source: "Import", sourceIdentity: accountID.uuidString))
            balanceKeys.insert(key); doc.track(.banks)
            return true
        }
        for row in batch.rows {
            if Task.isCancelled { result.globalError = "Import cancelled."; return result }
            guard row.included else { result.states[row.id] = .excluded; continue }
            guard let source = batch.sources.first(where: { $0.id == row.sourceID }) else { result.states[row.id] = .error("The source file is missing."); continue }
            do {
                if let error = row.parseError { throw ImportFailure(error) }
                switch row.content {
                case .statement(let input):
                    if document.importedStatements.contains(where: { $0.digest == source.digest && $0.accountID == nil }) { result.states[row.id] = .duplicate; continue }
                    guard batch.mode == .statements else { throw ImportFailure("The row does not match this import type.") }
                    let accountID: UUID
                    if let id = sourceAccounts[source.id] { accountID = id }
                    else {
                        accountID = try resolveAccount(source.account, in: &next); sourceAccounts[source.id] = accountID
                        let duplicate = document.importedStatements.contains { $0.digest == source.digest && ($0.accountID == nil || $0.accountID == accountID) }
                            || batch.sources.contains { other in importedSources.contains(other.id) && other.digest == source.digest && sourceAccounts[other.id] == accountID }
                        if duplicate { duplicateSources.insert(source.id) }
                    }
                    if duplicateSources.contains(source.id) { result.states[row.id] = .duplicate; continue }
                    let date = try source.dateFormat.date(input.date)
                    guard date <= now else { throw ImportFailure("The transaction date cannot be in the future.") }
                    let currency = try MoneyInput.normalizeCurrency(input.currency)
                    let label = input.label.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !label.isEmpty, label.count <= 500 else { throw ImportFailure("Enter a description of 1–500 characters.") }
                    let signed: Decimal
                    if !input.debit.isEmpty || !input.credit.isEmpty {
                        guard input.amount.isEmpty else { throw ImportFailure("Use either Amount or Money in/out, not both.") }
                        let debit = try input.debit.isEmpty ? 0 : source.numberFormat.decimal(input.debit)
                        let credit = try input.credit.isEmpty ? 0 : source.numberFormat.decimal(input.credit)
                        guard debit >= 0, credit >= 0, debit == 0 || credit == 0 else { throw ImportFailure("Use a nonnegative amount in only one of Money in or Money out.") }
                        signed = try MoneyInput.add(credit, -debit)
                    } else {
                        let amount = try source.numberFormat.decimal(input.amount)
                        if !input.originalType.isEmpty {
                            guard let type = EntryKind(rawValue: input.originalType), amount >= 0 else { throw ImportFailure("Explicit types need income, expense or transfer and a nonnegative amount.") }
                            signed = type == .expense ? -amount : amount
                        } else { signed = amount }
                    }
                    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = UTCDay.timeZone
                    let components = calendar.dateComponents([.year, .month], from: date)
                    guard let month = MonthKey(String(format: "%04d-%02d", components.year!, components.month!)), month.year >= 1900 else { throw ImportFailure("Use a transaction date from 1900 onwards.") }
                    let fingerprint = fingerprint(date: date, label: label, signedAmount: signed, currency: currency)
                    let external = input.transactionID.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard external.count <= 200, !external.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw ImportFailure("Check the transaction ID.") }
                    let reference = accountID.uuidString + ":" + (external.isEmpty ? "import-row/" + row.id.uuidString : external)
                    if let existing = seenReferences[reference] {
                        let same = existing.importFingerprint.map { $0 == fingerprint } ?? (existing.month == month.description && existing.amount == abs(signed) && existing.currency == currency && existing.label == label)
                        guard same else { throw ImportFailure("This transaction ID has different saved details. Correct it or exclude the row.") }
                        result.states[row.id] = .duplicate; continue
                    }
                    let fingerprintKey = accountID.uuidString + ":" + fingerprint
                    if external.isEmpty && fingerprints.contains(fingerprintKey) && !row.duplicateApproved {
                        result.states[row.id] = .needsReview("Looks like another transaction. Confirm it is a separate payment or exclude it."); continue
                    }
                    var entry = Entry(month: month, kind: input.kind, amount: abs(signed), currency: currency, label: label, source: .csv, sourceRef: reference)
                    entry.importFingerprint = fingerprint
                    next.entries.append(entry); next.track(.cashFlow)
                    seenReferences[reference] = entry; fingerprints.insert(fingerprintKey)
                    importedSources.insert(source.id); result.states[row.id] = .ready("New transaction"); result.added += 1
                case .bankBalance(let input):
                    guard batch.mode == .bankBalances else { throw ImportFailure("The row does not match this import type.") }
                    let accountID = try resolveAccount(input.account, in: &next)
                    let amount = try source.numberFormat.decimal(input.balance), date = try source.dateFormat.date(input.date)
                    let added = try recordBalance(accountID: accountID, amount: amount, date: date, in: &next)
                    result.states[row.id] = added ? .ready("Record dated balance") : .duplicate
                    if added { result.added += 1 }
                case .holding(let input):
                    guard batch.mode.isHolding else { throw ImportFailure("The row does not match this import type.") }
                    let coin: CatalogCoin
                    let quantity: Decimal
                    if batch.mode == .metals {
                        let metal = try PreciousMetal.resolve(input.coin)
                        coin = CatalogCoin(id: metal.assetID.rawValue, symbol: metal.rawValue, name: metal.name)
                        quantity = try MetalWeightUnit.resolve(input.unit).grams(source.numberFormat.decimal(input.quantity))
                    } else {
                        coin = try ImportCoins.resolve(input, coins: coins)
                        guard !coin.id.hasPrefix("metal-") else { throw ImportFailure("Add physical metals using Precious metals.") }
                        quantity = try source.numberFormat.decimal(input.quantity)
                    }
                    guard MoneyInput.isFinite(quantity), quantity >= 0 else { throw ImportFailure("Enter zero or a positive quantity.") }
                    let portfolioID: UUID
                    if let id = input.portfolioID {
                        guard let portfolio = next.portfolio(id: id), portfolio.isActive(at: now), portfolio.kind == batch.mode.kind else { throw ImportFailure("Choose an active portfolio for this asset type.") }
                        portfolioID = id
                    } else {
                        let name = try cleanName(input.portfolioName), key = name.lowercased()
                        if let owner = input.ownerBusinessID, !(next.businessAccounting ?? []).contains(where: { $0.id == owner }) {
                            throw ImportFailure("Choose a company with ownership history.")
                        }
                        if let id = createdPortfolios[key] {
                            guard next.portfolio(id: id)?.ownerBusinessID == input.ownerBusinessID else { throw ImportFailure("Rows in one portfolio must have the same owner.") }
                            portfolioID = id
                        }
                        else {
                            guard !document.portfolios.contains(where: { !$0.isArchived && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { throw ImportFailure("This portfolio exists. Select it from the portfolio menu.") }
                            let portfolio = Portfolio(name: name, createdAt: now, kind: batch.mode.kind, ownerBusinessID: input.ownerBusinessID); next.portfolios.append(portfolio)
                            portfolioID = portfolio.id; createdPortfolios[key] = portfolio.id
                        }
                    }
                    let key = portfolioID.uuidString + ":" + coin.id
                    guard holdingKeys.insert(key).inserted else { throw ImportFailure("This coin appears twice in the same portfolio. Keep one total quantity.") }
                    let previous = next.holdings.first { $0.portfolioID == portfolioID && $0.assetID.rawValue == coin.id && $0.isActive(at: now) }
                        .flatMap { next.effectiveQuantity(holdingID: $0.id, at: now) }
                    if previous == quantity { result.states[row.id] = .duplicate; continue }
                    next = try HoldingMutations.addHolding(portfolioID: portfolioID, assetID: CanonicalAssetID(coin.id), assetName: coin.name, quantity: quantity, at: now, document: next)
                    next.track(batch.mode.kind)
                    result.states[row.id] = .ready("\(previous.map { NSDecimalNumber(decimal: $0).stringValue } ?? "New") → \(NSDecimalNumber(decimal: quantity).stringValue) \(coin.name)\(batch.mode == .metals ? " · fine grams" : "")")
                    result.added += 1
                }
            } catch { result.states[row.id] = .error((error as? ImportFailure)?.text ?? "Check the name, currency, date and exact amount.") }
        }
        if batch.mode == .statements {
            for source in batch.sources where !duplicateSources.contains(source.id) {
                guard let accountID = sourceAccounts[source.id], batch.rows.contains(where: { $0.sourceID == source.id && $0.included }) else { continue }
                if !source.balance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    do {
                        let amount = try source.numberFormat.decimal(source.balance), date = try ImportDateFormat.iso.date(source.balanceDate)
                        if try recordBalance(accountID: accountID, amount: amount, date: date, in: &next) { result.added += 1 }
                    } catch { result.sourceErrors[source.id] = error.localizedDescription }
                }
                // Archive reviewed files even when their transactions were all already present.
                if !source.bytes.isEmpty && !result.hasErrors && !next.importedStatements.contains(where: { $0.digest == source.digest && ($0.accountID == nil || $0.accountID == accountID) }) {
                    next.importedStatements.append(ImportedStatement(digest: source.digest, originalBytes: source.bytes, importedAt: now, accountID: accountID))
                    result.added += 1
                }
            }
        }
        if !result.hasErrors { result.document = next }
        return result
    }
}
