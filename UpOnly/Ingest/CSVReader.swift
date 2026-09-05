import Foundation

nonisolated enum CSVReader {
    static func parse(_ text: String) throws -> [[String]] {
        var rows: [[String]] = [], row: [String] = []
        var field = "", quoted = false, afterQuote = false
        var iterator = text.makeIterator(), pending: Character?
        while let c = pending ?? iterator.next() {
            pending = nil
            if quoted {
                if c == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") }
                        else { quoted = false; afterQuote = true; pending = next }
                    } else { quoted = false; afterQuote = true }
                } else { field.append(c) }
            } else {
                if afterQuote && c != "," && c != "\n" && c != "\r" && c != "\r\n" { throw StatementError.invalidCSV }
                switch c {
                case "\"": guard field.isEmpty else { throw StatementError.invalidCSV }; quoted = true
                case ",": row.append(field); field = ""; afterQuote = false
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
        case .invalidCSV: "This CSV is not valid UTF-8 with correctly quoted fields."
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
