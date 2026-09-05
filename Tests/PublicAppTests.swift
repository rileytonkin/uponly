import Foundation
import Testing
@testable import UpOnly

struct PublicAppTests {
    private func empty() -> VaultDocument {
        let pair = VaultCrypto.makeInboxKeyPair()
        return VaultDocument.empty(inboxPrivateKeyX963: pair.privateX963, inboxPublicKeyX963: pair.publicX963)
    }
    @Test("A new vault contains no accounts, holdings, entries or enabled sources")
    func blankSetup() throws {
        let doc = empty()
        #expect(doc.accounts.isEmpty && doc.portfolios.isEmpty && doc.holdings.isEmpty && doc.entries.isEmpty)
        #expect(doc.bankBalances.isEmpty && doc.quotes.isEmpty && doc.dailyValuations.isEmpty)
        #expect(!doc.settings.setupComplete && !doc.settings.automaticPrices && !doc.settings.automaticFX)
        #expect(doc.settings.coinGeckoKey.isEmpty && doc.importedStatements.isEmpty)
    }
    @Test("Amounts which would silently round are refused")
    func excessivePrecision() throws {
        #expect(throws: VaultError.invalidAmount) { _ = try MoneyInput.parseExact("1.1234567890123456789012345678901234567890123456789") }
        #expect(try MoneyInput.parseExact("0.00000001") == Decimal(string: "0.00000001"))
        #expect(try MoneyInput.parseExact("-0.0100") == Decimal(string: "-0.01"))
        #expect(throws: VaultError.invalidAmount) { _ = try MoneyInput.parseExact("123oops") }
    }
    @Test("Transfers and reserve allocations are excluded from monthly results")
    func monthlyTransfers() {
        var doc = empty(); let month = MonthKey.current()
        doc.entries = [Entry(month: month, kind: .income, amount: 100, currency: "USD", label: "Income"), Entry(month: month, kind: .expense, amount: 25, currency: "USD", label: "Expense"), Entry(month: month, kind: .transfer, amount: 900, currency: "USD", label: "Transfer"), Entry(month: month, bucket: .reserve, kind: .expense, amount: 500, currency: "USD", label: "Reserve")]
        #expect(MonthlyLedger.evaluate(month, document: doc).totals?.net == 75)
        #expect(MonthlyLedger.evaluate(month, document: doc).isEstimated)
    }
    @Test("A missing currency rate cannot silently become one USD")
    func missingRate() {
        var doc = empty(); let month = MonthKey.current()
        doc.entries = [Entry(month: month, kind: .income, amount: 100, currency: "EUR", label: "Income")]
        let result = MonthlyLedger.evaluate(month, document: doc)
        #expect(result.totals == nil)
        #expect(result.waitingCaption?.contains("EUR") == true)
    }
    @Test("Tracking does not backfill ownership before its first observation")
    func trackedHistory() {
        var doc = empty(); let id = UUID(), now = Date()
        doc.setBankTracked(id, tracked: true, at: now)
        #expect(!doc.isBankTracked(id, at: now.addingTimeInterval(-1)))
        #expect(doc.isBankTracked(id, at: now))
    }
    @Test("CSV parsing preserves quoted commas, escaped quotes and CRLF")
    func csvQuoting() throws {
        let rows = try CSVReader.parse("A,B\r\n\"x,y\",\"say \"\"hello\"\"\"\r\n")
        #expect(rows == [["A", "B"], ["x,y", "say \"hello\""]])
        #expect(throws: StatementError.self) { _ = try CSVReader.parse("A,B\n\"unfinished") }
    }
    @Test("Statement import rejects bad rows rather than silently skipping them")
    func statementValidation() throws {
        let header = "TransactionID,Date,Description,Amount,Currency,Type\n"
        let good = "sample-1,2025-01-02,Sample expense,12.50,USD,expense\n"
        let doc = try StatementParser.read(Data((header + good).utf8), filename: "sample.csv", accountID: UUID())
        #expect(doc.entries.count == 1 && doc.entries[0].amount == Decimal(string: "12.50"))
        #expect(throws: StatementError.self) { _ = try StatementParser.read(Data((header + good + "sample-2,2025-02-30,Bad date,10,USD,income\n").utf8), filename: "sample.csv", accountID: UUID()) }
        #expect(throws: StatementError.self) { _ = try StatementParser.read(Data((header + good + good).utf8), filename: "sample.csv", accountID: UUID()) }
    }
    @Test("Price responses reject unrelated assets and future timestamps")
    func quotesBoundary() throws {
        let now = Date(timeIntervalSince1970: 1700000000)
        let valid = Data("{\"bitcoin\":{\"usd\":123.45,\"last_updated_at\":1699999999}}".utf8)
        #expect(try PublicPrices.decodeQuotes(valid, requested: ["bitcoin"], fetchedAt: now).count == 1)
        #expect(throws: PriceError.self) { _ = try PublicPrices.decodeQuotes(valid, requested: ["ethereum"], fetchedAt: now) }
        #expect(throws: PriceError.self) { _ = try PublicPrices.decodeQuotes(valid, requested: ["bitcoin"], fetchedAt: now.addingTimeInterval(-1000)) }
    }
    @Test("Real disk backup restores encrypted settings and statements")
    func diskRestore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UpOnlyTest-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let io = DiskFileIO(), keys = MemoryKeyStore(), code = RecoveryCode.random()
        let layout = VaultLayout(root: root.appendingPathComponent("original"))
        let store = VaultStore(layout: layout, io: io, keys: keys, authenticator: FixtureAuthenticator())
        let opened = try await store.create(recovery: code, confirmation: code.canonical)
        var next = opened.document
        let marker = Data("synthetic-secret-only-for-test".utf8)
        next.importedStatements = [ImportedStatement(digest: VaultCrypto.sha256(marker), originalBytes: marker, importedAt: Date())]
        next.settings.setupComplete = true; next.generation += 1
        try await store.commit(next, expectedGeneration: opened.document.generation, sessionID: opened.sessionID)
        #expect(!(try io.data(at: layout.current)).contains(marker))
        let package = try await BackupCoordinator.makePackage(store: store, producers: [])
        let backup = root.appendingPathComponent("sample.uponlybackup")
        try BackupCoordinator.publish(package, to: backup, io: io)
        let read = try BackupCoordinator.read(from: backup, io: io)
        let restored = try BackupCoordinator.restore(package: read, recovery: code, keys: MemoryKeyStore(), layout: VaultLayout(root: root.appendingPathComponent("restored")), io: io)
        #expect(restored.document.importedStatements.count == 1)
        #expect(restored.document.importedStatements[0].originalBytes == marker)
        #expect(restored.document.importedStatements[0].digest == VaultCrypto.sha256(marker))
        #expect(abs(restored.document.importedStatements[0].importedAt.timeIntervalSince(next.importedStatements[0].importedAt)) < 0.001)
        #expect(restored.document.settings.setupComplete)
    }
    @Test("CSV month follows its calendar date independent of device timezone")
    func utcStatementMonth() throws {
        let csv = "TransactionID,Date,Description,Amount,Currency,Type\nfirst,2025-01-01,Sample,10,USD,income\n"
        let parsed = try StatementParser.read(Data(csv.utf8), filename: "sample.csv", accountID: UUID())
        #expect(parsed.entries[0].month == "2025-01")
    }
    @Test("Personal income details exclude business income")
    @MainActor func consistentBreakdown() {
        var doc = empty(); let month = MonthKey.current()
        doc.entries = [Entry(month: month, kind: .income, amount: 100, currency: "USD", label: "Personal"), Entry(month: month, bucket: .otherBusiness, kind: .income, amount: 200, currency: "USD", label: "Business")]
        let model = PopoverModel(); model.replace(with: doc)
        #expect(model.state.totals?.personalIncome == 100)
        #expect(model.breakdown(.income).count == 1)
        #expect(model.breakdown(.income)[0].amount == 100)
    }
    @Test("Daily reference FX remains current through a normal weekend")
    func dailyFXFreshness() {
        var doc = empty(); let now = Date()
        let account = Account(name: "Sample", currency: "EUR")
        doc.accounts = [account]; doc.setBankTracked(account.id, tracked: true, at: now)
        doc.bankBalances = [BankBalanceObservation(id: UUID(), accountID: account.id, amount: PreciseDecimal(10), currency: "EUR", observedAt: now, source: "Manual", sourceIdentity: account.id.uuidString)]
        doc.fx = [FXObservation(sourceCurrency: "EUR", targetCurrency: "USD", rate: PreciseDecimal(Decimal(string: "1.10")!), providerTime: now.addingTimeInterval(-3 * 86400), fetchedAt: now, provider: "Reference")]
        let result = NetWorthCalculator.value(at: now, scope: .banks, document: doc, now: now)
        #expect(result.total == 11 && result.stale.isEmpty)
    }

}
