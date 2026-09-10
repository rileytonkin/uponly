import Foundation
import LocalAuthentication
import Testing
@testable import UpOnly

struct PublicAppTests {
    private func empty() -> VaultDocument {
        let pair = VaultCrypto.makeInboxKeyPair()
        return VaultDocument.empty(inboxPrivateKeyX963: pair.privateX963, inboxPublicKeyX963: pair.publicX963)
    }
    @Test("Balances, archives and partial imports never assert complete personal spending")
    func attentionDoesNotInventCoverage() {
        var doc = empty(); let month = MonthKey.current().previous
        let account = Account(name: "Personal bank", currency: "USD")
        doc.accounts = [account]; doc.setBankTracked(account.id, tracked: true, at: .distantPast)
        doc.bankBalances = [BankBalanceObservation(id: UUID(), accountID: account.id, amount: PreciseDecimal(0), currency: "USD", observedAt: Date(), source: "Test", sourceIdentity: "test")]
        doc.importedStatements = [ImportedStatement(digest: Data(), originalBytes: Data(), importedAt: Date(), accountID: account.id)]
        doc.entries = [Entry(month: month, kind: .expense, amount: 10, currency: "USD", label: "Partial import", source: .csv, sourceRef: account.id.uuidString + ":1")]
        var result = DataAttention.evaluate(doc, months: [month])
        #expect(result.spendingMonths == [month] && result.balances.isEmpty)
        doc.reviewedMonths = [month.description]
        result = DataAttention.evaluate(doc, months: [month])
        #expect(result.count == 0)
        doc.entries = []
        #expect(DataAttention.evaluate(doc, months: [month]).spendingMonths == [month])
    }
    @Test("Attention catches missing first observations and ignores explicit zero holdings")
    func attentionFirstObservations() throws {
        var doc = empty(); doc.settings.tracked = [.banks, .crypto]
        let account = Account(name: "New bank", currency: "USD")
        doc.accounts = [account]; doc.setBankTracked(account.id, tracked: true, at: .distantPast)
        let portfolio = Portfolio(name: "Wallet", createdAt: .distantPast)
        doc.portfolios = [portfolio]
        let holding = Holding(portfolioID: portfolio.id, assetID: try CanonicalAssetID("bitcoin"), assetName: "Bitcoin", createdAt: .distantPast)
        doc.holdings = [holding]
        let result = DataAttention.evaluate(doc, months: [])
        #expect(result.balances.map(\.id) == [account.id] && result.quantities.map(\.id) == [holding.id])
        doc = try HoldingMutations.setQuantity(holdingID: holding.id, quantity: 0, at: Date(), document: doc)
        #expect(DataAttention.evaluate(doc, months: []).quantities.isEmpty)
        #expect(!DataAttention.evaluate(doc, months: []).pricesNeeded)
        doc.setBankTracked(account.id, tracked: false, at: Date())
        #expect(DataAttention.evaluate(doc, months: []).count == 0)
    }
    @Test("Review attention follows the selected period and does not flag personal gaps in a company view")
    @MainActor func attentionSelection() {
        var doc = empty(); let previous = MonthKey.current().previous
        doc.settings.tracked = [.cashFlow]
        doc.entries = [Entry(month: previous, kind: .expense, amount: 0, currency: "USD", label: "No spending")]
        doc.reviewedMonths = [previous.description]
        let model = PopoverModel(); model.replace(with: doc); model.select(previous)
        #expect(model.attention(in: doc).count == 0)
        model.step(by: 1)
        #expect(model.attention(in: doc).spendingMonths == [.current()])
        #expect(model.attention(in: doc, includePerformance: false).count == 0)
        model.selectPeriod(.annual)
        #expect(model.attention(in: doc).spendingMonths.count == MonthKey.current().month - (previous.year == MonthKey.current().year ? 1 : 0))
        #expect(DataAttention.evaluate(doc, months: [.current()], includePersonal: false).spendingMonths.isEmpty)
        doc.settings.tracked = [] ; doc.entries = []
        #expect(DataAttention.evaluate(doc, months: [.current()]).count == 0)
    }

    @Test("A new vault contains no accounts, holdings, entries or enabled sources")
    func blankSetup() throws {
        let doc = empty()
        #expect(doc.accounts.isEmpty && doc.portfolios.isEmpty && doc.holdings.isEmpty && doc.entries.isEmpty)
        #expect(doc.bankBalances.isEmpty && doc.quotes.isEmpty && doc.dailyValuations.isEmpty)
        #expect(!doc.settings.setupComplete && !doc.settings.automaticPrices && !doc.settings.automaticFX)
        #expect(doc.settings.tracked == TrackedKind.allCases)
        #expect(doc.settings.coinGeckoKey.isEmpty && doc.importedStatements.isEmpty)
    }
    @Test("Amounts which would silently round are refused")
    func excessivePrecision() throws {
        #expect(throws: VaultError.invalidAmount) { _ = try MoneyInput.parseExact("1.1234567890123456789012345678901234567890123456789") }
        #expect(try MoneyInput.parseExact("0.00000001") == Decimal(string: "0.00000001"))
        #expect(try MoneyInput.parseExact(".12") == Decimal(string: "0.12"))
        #expect(try MoneyInput.parseExact("-.5") == Decimal(string: "-0.5"))
        #expect(throws: VaultError.invalidAmount) { _ = try MoneyInput.parseExact(".") }
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
        #expect(result.unavailable == .exchangeRates(["EUR"]))
    }
    @Test("Empty months and missing exchange rates have different next steps")
    func monthlyAvailability() {
        var doc = empty(); let month = MonthKey.current()
        #expect(MonthlyLedger.evaluate(month, document: doc).unavailable == .noEntries)
        doc.entries = [Entry(month: month, kind: .income, amount: 100, currency: "CHF", label: "Income"), Entry(month: month, kind: .expense, amount: 20, currency: "EUR", label: "Expense"), Entry(month: month, kind: .transfer, amount: 50, currency: "JPY", label: "Transfer")]
        #expect(MonthlyLedger.evaluate(month, document: doc).unavailable == .exchangeRates(["CHF", "EUR"]))
        let now = Date()
        doc.fx = ["CHF", "EUR"].map { FXObservation(sourceCurrency: $0, targetCurrency: "USD", rate: PreciseDecimal(1), providerTime: now, fetchedAt: now, provider: "Test") }
        let ready = MonthlyLedger.evaluate(month, document: doc)
        #expect(ready.unavailable == nil)
        #expect(ready.totals?.net == 80)
    }
    @Test("Native monthly results preserve personal currencies and exclude company payments")
    func nativeMonthlyResults() throws {
        var doc = empty(); let month = MonthKey.current()
        doc.entries = [
            Entry(month: month, kind: .income, amount: 100, currency: "USD", label: "Income"),
            Entry(month: month, bucket: .otherBusiness, kind: .income, amount: 60, currency: "GBP", label: "Business income"),
            Entry(month: month, kind: .expense, amount: 20, currency: "GBP", label: "Spending"),
            Entry(month: month, kind: .transfer, amount: 999, currency: "EUR", label: "Transfer"),
            Entry(month: month, bucket: .reserve, kind: .expense, amount: 999, currency: "GBP", label: "Reserve")
        ]
        let rows = try MonthlyLedger.nativeTotals(month, document: doc)
        #expect(rows.map(\.currency) == ["GBP", "USD"])
        #expect(rows[0].totals.moneyIn == 0 && rows[0].totals.moneyOut == 20 && rows[0].totals.net == -20)
        #expect(rows[1].totals.net == 100)
        #expect(MonthlyLedger.evaluate(month, document: doc).totals == nil)
        doc.fx = [FXObservation(sourceCurrency: "GBP", targetCurrency: "USD", rate: PreciseDecimal(2), providerTime: Date(), fetchedAt: Date(), provider: "Synthetic")]
        let total = try #require(MonthlyLedger.personal(month, document: doc).totals)
        #expect(total.moneyIn == 100 && total.moneyOut == 40 && total.net == 60)
        #expect(MonthlyLedger.evaluate(month, document: doc).unavailable == .accounting(["Business profit"]))
    }
    @Test("Zero foreign amounts do not require a rate or hide real results")
    func zeroCurrencyDoesNotBlock() throws {
        var doc = empty(); let month = MonthKey.current(), now = Date()
        doc.entries = [Entry(month: month, kind: .income, amount: 10, currency: "USD", label: "Income"), Entry(month: month, kind: .expense, amount: 0, currency: "XYZ", label: "Zero")]
        #expect(MonthlyLedger.evaluate(month, document: doc).totals?.net == 10)
        let account = Account(name: "Empty balance", currency: "XYZ")
        doc.accounts = [account]; doc.setBankTracked(account.id, tracked: true, at: now)
        doc.bankBalances = [BankBalanceObservation(id: UUID(), accountID: account.id, amount: PreciseDecimal(0), currency: "XYZ", observedAt: now, source: "manual", sourceIdentity: "Synthetic")]
        let result = NetWorthCalculator.value(at: now, scope: .banks, document: doc)
        #expect(result.total == 0 && result.missing.isEmpty)
    }
    @Test("Frankfurter v2 rates preserve exact decimals and reject wrong pairs or dates")
    func fxV2Validation() throws {
        let now = try ImportDateFormat.iso.date("2026-09-05")
        let data = Data(#"[{"date":"2026-09-04","base":"AED","quote":"USD","rate":0.27229411123456789}]"#.utf8)
        let rates = try PublicPrices.decodeFX(data, currency: "AED", fetchedAt: now)
        #expect(rates.count == 1 && rates[0].rate.value == Decimal(string: "0.27229411123456789"))
        #expect(throws: Error.self) { try PublicPrices.decodeFX(data, currency: "GBP", fetchedAt: now) }
        for json in [#"[{"date":"2026-09-06","base":"AED","quote":"USD","rate":1}]"#, #"[{"date":"2026-09-04","base":"AED","quote":"EUR","rate":1}]"#, #"[{"date":"2026-09-04","base":"AED","quote":"USD","rate":0}]"#, "[]"] {
            #expect(throws: Error.self) { try PublicPrices.decodeFX(Data(json.utf8), currency: "AED", fetchedAt: now) }
        }
    }
    @Test("One unsupported currency cannot discard valid exchange rates")
    func partialFXSuccess() async throws {
        let update = try await PublicPrices.fx(currencies: ["AED", "EUR", "USD"]) { code in
            if code != "EUR" { throw PriceError.unavailable }
            return [FXObservation(sourceCurrency: code, targetCurrency: "USD", rate: PreciseDecimal(Decimal(string: "1.123456789")!), providerTime: Date(), fetchedAt: Date(), provider: "Synthetic")]
        }
        #expect(update.rates.count == 1 && update.rates[0].sourceCurrency == "EUR")
        #expect(update.fxIssues["AED"] != nil && update.fxIssues["EUR"] == nil && update.fxIssues["USD"] == nil)
        #expect(update.messages.count == 1)
        let saved = try PriceHistory.applying(update, to: empty(), now: Date())
        #expect(saved.fx.count == 1 && saved.fx[0].rate.value == Decimal(string: "1.123456789"))
    }
    @Test("Cancelling currency refresh does not return a partial batch for saving")
    func cancelledFX() async {
        await #expect(throws: CancellationError.self) {
            try await PublicPrices.fx(currencies: ["EUR", "GBP"]) { code in
                if code == "GBP" { throw CancellationError() }
                return [FXObservation(sourceCurrency: code, targetCurrency: "USD", rate: PreciseDecimal(1), providerTime: Date(), fetchedAt: Date(), provider: "Synthetic")]
            }
        }
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
        next.settings.setupComplete = true; next.settings.tracked = [.crypto]; next.generation += 1
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
        #expect(restored.document.settings.tracked == [.crypto])
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
        #expect(model.state.partialTotals?.personalIncome == 100)
        #expect(model.breakdown(.income).count == 1)
        #expect(model.breakdown(.income)[0].amount == 100)
    }
    @Test("Combined personal activity reconciles both entry types across monthly, annual and all-time periods")
    @MainActor func combinedPersonalActivity() {
        var doc = empty()
        let january = MonthKey("2025-01")!, february = MonthKey("2025-02")!, prior = MonthKey("2024-12")!
        doc.entries = [
            Entry(month: january, kind: .income, amount: 100, currency: "USD", label: "Income"),
            Entry(month: january, kind: .expense, amount: 30, currency: "USD", label: "Spending"),
            Entry(month: january, kind: .transfer, amount: 900, currency: "USD", label: "Transfer"),
            Entry(month: january, bucket: .otherBusiness, kind: .income, amount: 800, currency: "USD", label: "Company income"),
            Entry(month: february, kind: .income, amount: 200, currency: "USD", label: "Income"),
            Entry(month: february, kind: .expense, amount: 250, currency: "USD", label: "Spending"),
            Entry(month: prior, kind: .income, amount: 40, currency: "USD", label: "Previous year")
        ]
        let model = PopoverModel(); model.replace(with: doc); model.select(january)
        #expect(model.personalState.totals?.net == 70)
        #expect(model.personalEntries.count == 2)
        #expect(model.personalChartHistory.first { $0.month == february }?.net == -50)
        model.selectPeriod(.annual)
        #expect(model.personalState.totals?.personalIncome == 300)
        #expect(model.personalState.totals?.personalSpend == 280)
        #expect(model.personalState.totals?.net == 20 && model.personalEntries.count == 4)
        model.selectPeriod(.allTime)
        #expect(model.personalState.totals?.net == 60 && model.personalEntries.count == 5)
        #expect(model.personalEntries.allSatisfy { $0.bucket == .personal && $0.kind != .transfer })
    }
    @Test("Unpriced personal entries remain visible and missing months never become zero")
    @MainActor func incompletePersonalActivity() {
        var doc = empty(); let month = MonthKey("2025-01")!
        doc.entries = [Entry(month: month, kind: .income, amount: 100, currency: "USD", label: "Income"), Entry(month: month, kind: .expense, amount: 40, currency: "CHF", label: "Needs FX")]
        let model = PopoverModel(); model.replace(with: doc); model.select(month)
        #expect(model.personalState.totals == nil && model.personalEntries.count == 2)
        #expect(model.personalState.unavailable == .exchangeRates(["CHF"]))
        #expect(model.personalChartHistory.first { $0.month == month }?.net == nil)
        model.select(month.next)
        #expect(model.personalState.totals == nil && model.personalEntries.isEmpty)
        model.selectPeriod(.annual)
        #expect(model.personalState.totals == nil && model.personalState.missingMonths > 0)
        #expect(model.personalEntries.count == 2)
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

struct BulkInputTests {
    private func empty() -> VaultDocument {
        let pair = VaultCrypto.makeInboxKeyPair()
        return VaultDocument.empty(inboxPrivateKeyX963: pair.privateX963, inboxPublicKeyX963: pair.publicX963)
    }
    private func batch(_ csv: String, mode: ImportMode, name: String = "Example") throws -> ImportBatchDraft {
        var source = try ImportParser.source(bytes: Data(csv.utf8), filename: "sample.csv", mode: mode, pasted: true)
        source.account = ImportAccount(name: name)
        return ImportBatchDraft(mode: mode, sources: [source], rows: try ImportParser.rows(source: source, mode: mode))
    }
    @Test("A holding entered with a past date and a cost records a lot; the same total on that date is a duplicate")
    func backdatedHoldingImport() throws {
        var draft = try batch("Portfolio\tCoin\tQuantity\nLedger\tbitcoin\t1", mode: .holdings)
        draft.rows[0].holding.date = "2026-03-10"; draft.rows[0].holding.paid = "40000"; draft.rows[0].holding.paidCurrency = "usd"
        let saved = try #require(ImportBatchProcessor.evaluate(draft, document: empty(), catalog: []).document)
        let holding = try #require(saved.holdings.first)
        #expect(saved.portfolios[0].createdAt == holding.createdAt)
        #expect(saved.effectiveQuantity(holdingID: holding.id, at: try ImportDateFormat.iso.date("2026-04-01")) == 1)
        #expect(saved.purchases?.count == 1 && saved.purchases?[0].paid.value == 40000 && saved.purchases?[0].currency == "USD" && saved.purchases?[0].quantity.value == 1)
        var again = try batch("Portfolio\tCoin\tQuantity\nLedger\tbitcoin\t1", mode: .holdings)
        again.rows[0].holding.portfolioID = saved.portfolios[0].id; again.rows[0].holding.date = "2026-03-10"
        #expect(ImportBatchProcessor.evaluate(again, document: saved, catalog: []).duplicates == 1)
        var more = try batch("Portfolio\tCoin\tQuantity\nLedger\tbitcoin\t1.5", mode: .holdings)
        more.rows[0].holding.portfolioID = saved.portfolios[0].id; more.rows[0].holding.date = "2026-06-01"; more.rows[0].holding.paid = "30000"
        let next = try #require(ImportBatchProcessor.evaluate(more, document: saved, catalog: []).document)
        #expect(next.purchases?.count == 2 && next.purchases?[1].quantity.value == 0.5)
        var future = try batch("Portfolio\tCoin\tQuantity\nLedger\tbitcoin\t2", mode: .holdings)
        future.rows[0].holding.date = "2999-01-01"
        #expect(ImportBatchProcessor.evaluate(future, document: next, catalog: []).hasErrors)
    }
    @Test("Monzo search exports span months, exclude declines and merge overlaps")
    func monzoSearchMonths() throws {
        let csv = "id,created,title,subtitle,amount,currency,categories\na,\"02/01/26, 12:03\",Coffee,,-5,GBP,General\nb,\"03/08/26, 01:47\",Deposit,,20,GBP,Transfers\nc,\"04/08/26, 01:47\",Card,Declined,,,General"
        let source = try ImportParser.source(bytes: Data(csv.utf8), filename: "sample.csv", mode: .statements)
        #expect(source.dateFormat == .monzoSearch && source.account.name == "Monzo" && source.account.currency == "GBP")
        var draft = ImportBatchDraft(mode: .statements, sources: [source], rows: try ImportParser.rows(source: source, mode: .statements))
        let saved = try #require(ImportBatchProcessor.evaluate(draft, document: empty()).document)
        #expect(saved.entries.map(\.month) == ["2026-01", "2026-08"])
        #expect(saved.entries[1].kind == .transfer && !draft.rows[2].included)
        draft.sources[0].account = ImportParser.account(for: source, preferred: ImportAccount(), saved: saved.accounts)
        #expect(draft.sources[0].account.existingID == saved.accounts[0].id)
        #expect(ImportBatchProcessor.evaluate(draft, document: saved).duplicates == 2)
        var overlap = try ImportParser.source(bytes: Data((csv + "\nd,\"05/08/26, 12:00\",New,,-3,GBP,General").utf8), filename: "overlap.csv", mode: .statements)
        overlap.account = draft.sources[0].account
        let next = ImportBatchDraft(mode: .statements, sources: [overlap], rows: try ImportParser.rows(source: overlap, mode: .statements))
        let review = ImportBatchProcessor.evaluate(next, document: saved)
        #expect(review.duplicates == 2 && review.document?.entries.count == 3 && !review.hasErrors)
        let explicit = ImportAccount(name: "My card", currency: "GBP")
        #expect(ImportParser.account(for: source, preferred: explicit, saved: saved.accounts) == explicit)
    }
    @Test("Company payments to you are income; money sent to your company is a transfer; unrelated costs and edits remain")
    func ownerPayments() throws {
        var doc = empty()
        doc.businessAccounting = [BusinessBook(id: "studio", name: "Studio", ownership: [OwnershipPeriod(fromMonth: "2026-02", numerator: 1, denominator: 2)], firstMonth: "2026-02", sourceURL: "", basis: "Profit before draws", fetchedAt: Date(), transferCounterparties: ["Studio Holdings", "Studio App"])]
        var draft = try batch("Date,Description,Amount,Currency\n2026-02-01,Studio Holdings,500,USD\n2026-02-02,Studio App,-100,USD\n2026-02-03,Studio Holdings Store,-20,USD\n2026-01-01,Studio Holdings,30,USD", mode: .statements)
        var saved = try #require(ImportBatchProcessor.evaluate(draft, document: doc).document)
        #expect(saved.entries.map(\.kind) == [.income, .transfer, .expense, .income])
        let february = try #require(MonthlyLedger.nativeTotals(MonthKey("2026-02")!, document: saved).first?.totals)
        #expect(february.moneyIn == 500 && february.moneyOut == 20)
        // Personal shows the payment as income. All replaces it with the profit share.
        let personal = MonthlyLedger.personal(MonthKey("2026-02")!, document: saved)
        #expect(personal.totals?.personalIncome == 500 && personal.totals?.ownerPayments == 500 && personal.totals?.net == 480)
        saved.businessAccounting?[0].months = [BusinessMonth(month: "2026-02", profitUSD: 1200, sourceRange: "test")]
        let all = MonthlyLedger.evaluate(MonthKey("2026-02")!, document: saved)
        #expect(all.totals?.personalIncome == 0 && all.totals?.otherBusiness == 600 && all.totals?.net == 580)
        draft.rows[1].statement.kindIsUserEdited = true; draft.rows[1].statement.kind = .expense
        saved = try #require(ImportBatchProcessor.evaluate(draft, document: doc).document)
        #expect(saved.entries[1].kind == .expense && saved.entries[1].kindIsUserEdited == true)
        saved.entries[0].kind = .transfer; saved.entries[2].kind = .transfer
        OwnerPayments.reconcile(in: &saved)
        #expect(saved.entries[0].kind == .income && saved.entries[1].kind == .expense && saved.entries[2].kind == .transfer)
        draft.sources[0].account.ownerBusinessID = "studio"
        saved = try #require(ImportBatchProcessor.evaluate(draft, document: doc).document)
        #expect(saved.entries.allSatisfy { $0.bucket == .otherBusiness })
    }
    @Test("A payee marked as always a transfer reclassifies imports, syncs and future statements")
    func personalTransferCounterparties() throws {
        var doc = empty()
        let bank = Account(name: "Monzo", currency: "GBP"); doc.accounts = [bank]
        let paid = Entry(month: MonthKey("2026-05")!, kind: .expense, amount: 2500, currency: "GBP", label: "Amora Ltd", source: .csv, sourceRef: bank.id.uuidString + ":a")
        var edited = Entry(month: MonthKey("2026-05")!, kind: .expense, amount: 10, currency: "GBP", label: "amora ltd", source: .csv, sourceRef: bank.id.uuidString + ":b"); edited.kindIsUserEdited = true
        let manual = Entry(month: MonthKey("2026-05")!, kind: .expense, amount: 5, currency: "GBP", label: "Amora Ltd")
        doc.entries = [paid, edited, manual]
        OwnerPayments.setTransferCounterparty(" Amora Ltd ", enabled: true, in: &doc)
        #expect(doc.transferCounterparties == ["Amora Ltd"])
        #expect(doc.entries.map(\.kind) == [.transfer, .expense, .expense])
        #expect(OwnerPayments.isPersonalTransferCounterparty("AMORA LTD", document: doc))
        #expect(try MonthlyLedger.nativeTotals(MonthKey("2026-05")!, document: doc).first?.totals.moneyOut == 15)
        let draft = try batch("Date,Description,Amount,Currency\n2026-06-01,Amora Ltd,-300,GBP\n2026-06-02,Amora Cafe,-3,GBP", mode: .statements)
        let saved = try #require(ImportBatchProcessor.evaluate(draft, document: doc).document)
        #expect(saved.entries.suffix(2).map(\.kind) == [.transfer, .expense])
        doc.entries[0].kind = .expense
        OwnerPayments.reconcile(in: &doc)
        #expect(doc.entries[0].kind == .transfer)
        OwnerPayments.setTransferCounterparty("Amora Ltd", enabled: false, in: &doc)
        #expect(doc.transferCounterparties == nil && doc.entries[0].kind == .transfer)
    }
    @Test("Monzo refunds and cashback reduce spending instead of counting as income")
    func monzoRefunds() throws {
        let doc = empty()
        let csv = "id,created,title,subtitle,amount,currency,categories\ntx1,\"15/07/26, 10:00\",Airbnb,,-1000,GBP,Holidays\ntx2,\"29/07/26, 10:00\",Tomorrowland,,159.06,GBP,Entertainment\ntx3,\"23/07/26, 10:00\",Monzo Premium cashback,,0.05,GBP,Income\ntx4,\"30/07/26, 10:00\",APPLE INC,,516.05,GBP,Income\ntx5,\"11/07/26, 10:00\",agoda.com,Declined,,,Holidays"
        let draft = try batch(csv, mode: .statements)
        #expect(draft.rows.map(\.included) == [true, true, true, true, false])
        let saved = try #require(ImportBatchProcessor.evaluate(draft, document: doc).document)
        #expect(saved.entries.map(\.kind) == [.expense, .refund, .refund, .income])
        let totals = try #require(MonthlyLedger.nativeTotals(MonthKey("2026-07")!, document: saved).first?.totals)
        #expect(totals.moneyIn == 516.05 && totals.moneyOut == Decimal(string: "840.89"))
        let typed = try batch("Date,Description,Amount,Currency,Type\n2026-07-01,Shop,20,USD,refund", mode: .statements)
        #expect(try #require(ImportBatchProcessor.evaluate(typed, document: doc).document).entries.first?.kind == .refund)
    }
    @Test("Month evidence gives one USD line per source, the biggest movements of any kind, and accounts that went quiet")
    func monthEvidence() {
        var doc = empty()
        let monzo = Account(name: "Monzo", currency: "GBP"), kast = Account(name: "Kast", currency: "USD")
        var wise = Account(name: "Riley · GBP", currency: "GBP"); wise.externalProfileID = "7"
        doc.accounts = [monzo, kast, wise]
        let july = MonthKey("2026-07")!, august = MonthKey("2026-08")!
        doc.fx = [FXObservation(sourceCurrency: "GBP", targetCurrency: "USD", rate: PreciseDecimal(2), providerTime: Date(timeIntervalSince1970: 1_787_000_000), fetchedAt: Date(timeIntervalSince1970: 1_787_000_000), provider: "test")]
        doc.entries = [
            Entry(month: august, kind: .income, amount: 4000, currency: "GBP", label: "Equinox", source: .csv, sourceRef: monzo.id.uuidString + ":1"),
            Entry(month: august, kind: .expense, amount: 1000, currency: "GBP", label: "Airbnb", source: .csv, sourceRef: monzo.id.uuidString + ":2"),
            Entry(month: august, kind: .refund, amount: 10, currency: "GBP", label: "Airbnb refund", source: .csv, sourceRef: monzo.id.uuidString + ":3"),
            Entry(month: august, kind: .transfer, amount: 2500, currency: "GBP", label: "Tonkin Apps", source: .csv, sourceRef: monzo.id.uuidString + ":4"),
            Entry(month: august, kind: .expense, amount: 40, currency: "GBP", label: "Cafe", source: .wise, sourceRef: "wise:7:a"),
            Entry(month: august, kind: .expense, amount: 5, currency: "USD", label: "Cash"),
            Entry(month: july, kind: .expense, amount: 9, currency: "USD", label: "Old", source: .csv, sourceRef: kast.id.uuidString + ":9")
        ]
        let evidence = MonthEvidence.build(august, document: doc, now: Date(timeIntervalSince1970: 1_787_000_000))
        #expect(evidence.sources.map(\.name) == ["Monzo", "Wise · Riley", "Added by hand"])
        #expect(MonthEvidence.sourceName(for: doc.entries[4], accounts: [Account(name: "Personal · GBP", currency: "GBP", externalProfileID: "7")]).name == "Wise")
        #expect(evidence.sources[0].count == 3 && evidence.sources[0].moneyIn == 8000 && evidence.sources[0].moneyOut == 1980)
        #expect(evidence.sources[2].moneyIn == 0 && evidence.sources[2].moneyOut == 5)
        #expect(evidence.largest.map(\.entry.label) == ["Equinox", "Tonkin Apps", "Airbnb", "Cafe", "Airbnb refund", "Cash"])
        #expect(evidence.largest[1].usd == 5000)
        #expect(evidence.silent == ["Kast"])
    }
    @Test("A business cost paid personally leaves personal spending and month evidence")
    func businessCostPaidPersonally() {
        var doc = empty()
        let bank = Account(name: "Monzo", currency: "USD"); doc.accounts = [bank]
        let month = MonthKey("2026-08")!
        var cost = Entry(month: month, kind: .expense, amount: 300, currency: "USD", label: "Laptop", source: .csv, sourceRef: bank.id.uuidString + ":1")
        doc.entries = [cost, Entry(month: month, kind: .expense, amount: 20, currency: "USD", label: "Lunch")]
        #expect(MonthlyLedger.personal(month, document: doc).totals?.personalSpend == 320)
        cost.bucket = .businessCost; doc.entries[0] = cost
        #expect(MonthlyLedger.personal(month, document: doc).totals?.personalSpend == 20)
        #expect(MonthEvidence.build(month, document: doc).largest.map(\.entry.label) == ["Lunch"])
    }
    @Test("Imported entries expose their bank account; manual and Wise entries do not")
    func entryAccountID() {
        let bank = Account(name: "Monzo", currency: "GBP")
        #expect(Entry(month: .current(), kind: .expense, amount: 1, currency: "GBP", label: "a", source: .csv, sourceRef: bank.id.uuidString + ":tx:1").accountID == bank.id)
        #expect(Entry(month: .current(), kind: .expense, amount: 1, currency: "GBP", label: "a").accountID == nil)
        #expect(Entry(month: .current(), kind: .expense, amount: 1, currency: "GBP", label: "a", source: .wise, sourceRef: "wise:1:x").accountID == nil)
    }
    @Test("Legacy settings and empty settings preserve defaults")
    func legacySettings() throws {
        for json in ["{}", "{\"setupComplete\":true,\"automaticFX\":true}"] {
            let settings = try VaultJSON.decode(AppSettings.self, from: Data(json.utf8))
            #expect(settings.tracked == TrackedKind.allCases)
            #expect(!settings.automaticPrices && settings.coinGeckoKey.isEmpty)
        }
        var settings = AppSettings(); settings.tracked = [.cashFlow, .banks, .banks]
        let restored = try VaultJSON.decode(AppSettings.self, from: VaultJSON.encode(settings))
        #expect(restored.tracked == [.banks, .cashFlow])
    }
    @Test("Choice or data controls visibility and navigation")
    func visibility() {
        var doc = empty(); doc.settings.tracked = [.crypto]
        #expect(!doc.shows(.banks) && !doc.shows(.cashFlow) && doc.showsNetWorth)
        #expect(doc.defaultDestination == 1 && doc.defaultManagementSection == "Portfolios")
        #expect(!doc.showsSection("Accounts") && doc.showsSection("Sources"))
        #expect(!doc.showsDestination(7))
        doc.accounts = [Account(name: "Existing", currency: "USD")]
        #expect(doc.shows(.banks)); doc.setTracked(.banks, false); #expect(doc.shows(.banks))
        doc.accounts = []; doc.settings.tracked = [.cashFlow]
        #expect(doc.defaultDestination == 0 && doc.defaultManagementSection == "Entries" && !doc.showsNetWorth)
        doc.settings.tracked = []
        doc.portfolios = [Portfolio(name: "Archived", archivedAt: Date())]
        #expect(!doc.shows(.crypto) && doc.defaultManagementSection == "Manage")
        doc.track(.cashFlow); doc.track(.banks); doc.track(.banks)
        #expect(doc.settings.tracked == [.banks, .cashFlow])
    }
    @Test("Spreadsheet paste supports headers and headerless rows")
    func cellPaste() throws {
        let headed = try batch("Account\tCurrency\tBalance\tObservedOn\nChecking\tUSD\t-25.50\t2026-01-02", mode: .bankBalances)
        let plain = try batch("Checking\tUSD\t-25.50\t2026-01-02", mode: .bankBalances)
        #expect(headed.sources[0].hasHeader && !plain.sources[0].hasHeader)
        for draft in [headed, plain] {
            let review = ImportBatchProcessor.evaluate(draft, document: empty())
            #expect(!review.hasErrors && review.document?.bankBalances.first?.amount.value == Decimal(string: "-25.50"))
        }
    }
    @Test("Number formats preserve exact decimals and reject ambiguous grouping")
    func numbers() throws {
        #expect(try ImportNumberFormat.point.decimal("1,234.5601") == Decimal(string: "1234.5601"))
        #expect(try ImportNumberFormat.comma.decimal("1.234,5601") == Decimal(string: "1234.5601"))
        for invalid in ["1,23", "$12", "=SUM(A1)", "1.1234567890123456789012345678901234567890123456789"] {
            #expect(throws: Error.self) { _ = try ImportNumberFormat.point.decimal(invalid) }
        }
        #expect(try ImportDateFormat.dayFirst.date("02/03/2026") != ImportDateFormat.monthFirst.date("02/03/2026"))
        #expect(throws: Error.self) { _ = try ImportDateFormat.iso.date("02/03/2026") }
    }
    @Test("Bank observations include zero, preserve history, and do not sum transactions")
    func bankObservations() throws {
        let draft = try batch("Account,Currency,Balance,ObservedOn\nChecking,USD,100,2026-01-01\nChecking,USD,0,2026-02-01", mode: .bankBalances)
        let review = ImportBatchProcessor.evaluate(draft, document: empty())
        let doc = try #require(review.document)
        #expect(doc.accounts.count == 1 && doc.bankBalances.count == 2 && doc.entries.isEmpty)
        #expect(doc.isBankTracked(doc.accounts[0].id, at: Date()))
        var conflict = draft
        conflict.rows[1].bank.date = "2026-01-01"
        #expect(ImportBatchProcessor.evaluate(conflict, document: empty()).hasErrors)
        #expect(ImportBatchProcessor.evaluate(conflict, document: empty()).document == nil)
    }
    @Test("Statements can create accounts before a balance is known")
    func statementAccount() throws {
        let draft = try batch("Date,Description,Amount,Currency\n2026-01-02,Sample,-12.50,USD", mode: .statements)
        let review = ImportBatchProcessor.evaluate(draft, document: empty())
        var doc = try #require(review.document)
        #expect(doc.accounts.count == 1 && doc.bankBalances.isEmpty && doc.entries.count == 1)
        #expect(NetWorthCalculator.value(at: Date(), scope: .banks, document: doc).isUnavailable)
        var balances = try batch("Account,Currency,Balance,ObservedOn\nExample,USD,100,2026-02-01", mode: .bankBalances)
        balances.rows[0].bank.account.existingID = doc.accounts[0].id
        doc = try #require(ImportBatchProcessor.evaluate(balances, document: doc).document)
        #expect(doc.isBankTracked(doc.accounts[0].id, at: Date()))
    }
    @Test("Known bank exports keep their signed amounts despite provider type columns")
    func knownBankExports() throws {
        for idHeader in ["Transaction ID", "TransferWise ID"] {
            let descriptionHeader = idHeader == "Transaction ID" ? "Name" : "Description"
            let draft = try batch("\(idHeader),Date,\(descriptionHeader),Amount,Currency,Type\nexample,02/01/2026,Sample,-12.50,USD,CARD_PAYMENT", mode: .statements)
            let doc = try #require(ImportBatchProcessor.evaluate(draft, document: empty()).document)
            #expect(doc.entries.count == 1 && doc.entries[0].kind == .expense && doc.entries[0].amount == Decimal(string: "12.50"))
        }
    }
    @Test("A multi-account batch uses separate transaction namespaces")
    func multiAccount() throws {
        let csv = "TransactionID,Date,Description,Amount,Currency,Type\nsame-id,2026-01-02,Sample,10,USD,expense"
        var draft = try batch(csv, mode: .statements, name: "One")
        let second = try batch(csv, mode: .statements, name: "Two")
        draft.sources += second.sources; draft.rows += second.rows
        let review = ImportBatchProcessor.evaluate(draft, document: empty())
        #expect(review.readyRows == 2 && review.added == 4) // Archived files are changes, not transaction rows.
        let doc = try #require(review.document)
        #expect(doc.accounts.count == 2 && doc.entries.count == 2 && doc.importedStatements.count == 2)
        #expect(Set(doc.entries.compactMap(\.sourceRef)).count == 2)
    }
    @Test("Reclassifying a saved statement preserves duplicate detection and the user's choice")
    func reclassifiedStatement() throws {
        var draft = try batch("TransactionID,Date,Description,Amount,Currency,Type\none,2026-01-02,Own transfer,10,USD,expense", mode: .statements)
        var saved = try #require(ImportBatchProcessor.evaluate(draft, document: empty()).document)
        saved.entries[0].kind = .transfer; saved.entries[0].kindIsUserEdited = true
        let restored = try VaultJSON.decode(VaultDocument.self, from: VaultJSON.encode(saved))
        draft.sources[0].account.existingID = restored.accounts[0].id
        let repeated = try #require(ImportBatchProcessor.evaluate(draft, document: restored).document)
        #expect(repeated.entries.count == 1 && repeated.entries[0].kind == .transfer && repeated.entries[0].kindIsUserEdited == true)
        #expect(try MonthlyLedger.nativeTotals(MonthKey("2026-01")!, document: repeated).isEmpty)
    }
    @Test("Overlapping IDs skip identical transactions and block conflicting data")
    func duplicateIDs() throws {
        var original = try batch("TransactionID,Date,Description,Amount,Currency,Type\none,2026-01-02,Sample,10,USD,expense", mode: .statements)
        let saved = try #require(ImportBatchProcessor.evaluate(original, document: empty()).document)
        original.sources[0].account.existingID = saved.accounts[0].id
        #expect(ImportBatchProcessor.evaluate(original, document: saved).duplicates == 1)
        var overlap = try batch("TransactionID,Date,Description,Amount,Currency,Type\none,2026-01-02,Sample,10,USD,expense\ntwo,2026-01-03,New,20,USD,income", mode: .statements)
        overlap.sources[0].account.existingID = saved.accounts[0].id
        let review = ImportBatchProcessor.evaluate(overlap, document: saved)
        #expect(!review.hasErrors && review.duplicates == 1 && review.document?.entries.count == 2)
        overlap.rows[0].statement.amount = "11"
        let conflict = ImportBatchProcessor.evaluate(overlap, document: saved)
        #expect(conflict.hasErrors && conflict.document == nil && saved.entries.count == 1)
    }
    @Test("Legitimate repeated payments without IDs require explicit review")
    func repeatedPayments() throws {
        var draft = try batch("Date,Description,Amount,Currency\n2026-01-02,Coffee,-5,USD\n2026-01-02,Coffee,-5,USD", mode: .statements)
        let initial = ImportBatchProcessor.evaluate(draft, document: empty())
        #expect(initial.hasErrors && initial.states[draft.rows[1].id]?.blocksSave == true)
        draft.rows[1].duplicateApproved = true
        let saved = try #require(ImportBatchProcessor.evaluate(draft, document: empty()).document)
        #expect(saved.entries.count == 2 && saved.entries.allSatisfy { $0.importFingerprint != nil })
    }
    @Test("Separate credit/debit columns and transfer review preserve cash flow")
    func debitCredit() throws {
        var draft = try batch("Date,Description,Debit,Credit,Currency\n2026-01-02,Payment,12,,USD\n2026-01-03,Deposit,,20,USD", mode: .statements)
        draft.rows[1].statement.kind = .transfer
        let saved = try #require(ImportBatchProcessor.evaluate(draft, document: empty()).document)
        #expect(saved.entries[0].kind == .expense && saved.entries[0].amount == 12)
        #expect(saved.entries[1].kind == .transfer)
        draft.rows[0].statement.credit = "1"
        #expect(ImportBatchProcessor.evaluate(draft, document: empty()).hasErrors)
    }
    @Test("Coin tickers need resolution and quantities replace rather than add")
    func cryptoTotals() throws {
        var draft = try batch("Portfolio,Coin,Quantity\nMain,BTC,0.1\nMain,ethereum,2", mode: .holdings)
        #expect(ImportBatchProcessor.evaluate(draft, document: empty()).hasErrors)
        draft.rows[0].holding.resolvedCoinID = "bitcoin"
        let saved = try #require(ImportBatchProcessor.evaluate(draft, document: empty()).document)
        let bitcoin = try #require(saved.holdings.first { $0.assetID.rawValue == "bitcoin" })
        var update = try batch("Portfolio,Coin,Quantity\nMain,bitcoin,0", mode: .holdings)
        update.rows[0].holding.portfolioID = saved.portfolios[0].id
        let changed = try #require(ImportBatchProcessor.evaluate(update, document: saved).document)
        #expect(changed.effectiveQuantity(holdingID: bitcoin.id, at: Date()) == 0)
        let ether = try #require(changed.holdings.first { $0.assetID.rawValue == "ethereum" })
        #expect(changed.effectiveQuantity(holdingID: ether.id, at: Date()) == 2)
        update.rows.append(update.rows[0]); update.rows[1].id = UUID()
        #expect(ImportBatchProcessor.evaluate(update, document: saved).hasErrors)
    }
    @Test("Invalid and excluded rows never produce partially applied documents")
    func excludedErrors() throws {
        var draft = try batch("Account,Currency,Balance,ObservedOn\nValid,USD,100,2026-01-02\nInvalid,USD,wrong,2026-01-02", mode: .bankBalances)
        let before = empty(), failed = ImportBatchProcessor.evaluate(draft, document: empty())
        #expect(failed.hasErrors && failed.document == nil && before.accounts.isEmpty)
        draft.rows[1].included = false
        let saved = try #require(ImportBatchProcessor.evaluate(draft, document: before).document)
        #expect(saved.accounts.count == 1 && saved.accounts[0].name == "Valid")
    }
    @Test("Batch bounds and cancellation refuse work")
    func boundsAndCancellation() async throws {
        var draft = try batch("Main,bitcoin,1", mode: .holdings)
        draft.sources = Array(repeating: draft.sources[0], count: 51)
        #expect(ImportBatchProcessor.evaluate(draft, document: empty()).hasErrors)
        let normal = try batch("Main,bitcoin,1", mode: .holdings), doc = empty()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return ImportBatchProcessor.evaluate(normal, document: doc)
        }
        #expect(await task.value.document == nil)
    }
    @Test("Imported metadata is compatible with older documents and persists")
    func importMetadata() throws {
        var draft = try batch("Date,Description,Amount,Currency\n2026-01-02,Sample,1,USD", mode: .statements)
        draft.sources[0].balance = "100"
        let saved = try #require(ImportBatchProcessor.evaluate(draft, document: empty()).document)
        let decoded = try VaultJSON.decode(VaultDocument.self, from: VaultJSON.encode(saved))
        #expect(decoded.entries[0].importFingerprint == saved.entries[0].importFingerprint)
        #expect(decoded.importedStatements[0].accountID == saved.accounts[0].id)
        let legacy = try VaultJSON.decode(ImportedStatement.self, from: Data("{\"digest\":\"\",\"originalBytes\":\"\",\"importedAt\":\"2026-01-01T00:00:00.000Z\"}".utf8))
        #expect(legacy.accountID == nil)
    }
}

#if UPONLY_PERSONAL
struct WiseInputTests {
    private func empty() -> VaultDocument {
        let pair = VaultCrypto.makeInboxKeyPair()
        return VaultDocument.empty(inboxPrivateKeyX963: pair.privateX963, inboxPublicKeyX963: pair.publicX963)
    }
    @Test("Wise amount parsing preserves exact values and direction")
    func amounts() throws {
        let value = try #require(try WiseAPI.amount("<b>+ 1,234.56 USD</b>"))
        #expect(value.value == Decimal(string: "1234.56") && value.currency == "USD" && value.incoming)
        #expect(try WiseAPI.amount("0.00 USD")?.value == 0)
        #expect(throws: Error.self) { _ = try WiseAPI.amount("1,23 USD") }
    }
    @Test("Wise sync is idempotent, retracts cancelled records and excludes own transfers")
    func sync() throws {
        let date = Date(), first = WiseConfiguredProfile(id: 1, name: "Personal", bucket: .personal, image: Data([1, 2, 3]))
        let second = WiseConfiguredProfile(id: 2, name: "Business", bucket: .otherBusiness)
        let payment = WiseActivity(id: "payment", type: "CARD_PAYMENT", title: "Sample", primaryAmount: "10 USD", secondaryAmount: "10.05 USD", status: "COMPLETED", createdOn: "2026-01-02T12:00:00.000Z")
        let outgoing = WiseActivity(id: "out", type: "TRANSFER", resource: .init(type: "TRANSFER", id: "shared"), title: "Own transfer", primaryAmount: "50 USD", status: "COMPLETED", createdOn: "2026-01-03T12:00:00Z")
        let incoming = WiseActivity(id: "in", type: "TRANSFER", resource: .init(type: "TRANSFER", id: "shared"), title: "Own transfer", primaryAmount: "+ 50 USD", status: "COMPLETED", createdOn: "2026-01-03T12:00:00Z")
        var snapshot = WiseSnapshot(profiles: [
            WiseProfileSnapshot(profile: first, balances: [WiseBalance(id: 11, currency: "USD", amount: WiseAmount(value: 100, currency: "USD")), WiseBalance(id: 12, currency: "USD", amount: WiseAmount(value: 40, currency: "USD"), type: "SAVINGS", name: "Tax")], activities: [payment, outgoing]),
            WiseProfileSnapshot(profile: second, balances: [WiseBalance(id: 22, currency: "USD", amount: WiseAmount(value: 50, currency: "USD"))], activities: [incoming])
        ], fetchedAt: date)
        let saved = try WiseAPI.apply(snapshot, to: empty())
        let repeated = try WiseAPI.apply(snapshot, to: saved)
        #expect(saved.entries.count == 3 && repeated.entries.count == 3)
        // The synced balance anchors a rebuilt history: 100 today, so 100 at the end of Jan 3 and 150 at the end of Jan 2, before the 50 went out.
        let personalUSD = try #require(saved.accounts.first { $0.externalProfileID == "1" && $0.currency == "USD" })
        let derived = saved.bankBalances.filter { $0.accountID == personalUSD.id && $0.source == BalanceReconstruction.source }.sorted { $0.observedAt < $1.observedAt }
        #expect(derived.map(\.amount.value) == [150, 100])
        #expect(saved.isBankTracked(personalUSD.id, at: BalanceReconstruction.dayFormatter().date(from: "2026-01-02")!))
        #expect(saved.entries.allSatisfy { $0.day != nil && $0.outflow != nil })
        // A jar is its own account, named after the jar, valued from the sync alone: no activity is attributed to it.
        let jar = try #require(saved.accounts.first { $0.externalBalanceID == "12" })
        #expect(jar.name == "Personal · USD · Tax" && AssetOwnership.jarName(jar) == "Tax" && AssetOwnership.profileName(jar) == "Personal")
        #expect(saved.bankBalances.filter { $0.accountID == jar.id }.count == 1)
        #expect(saved.entries.filter { $0.kind == .transfer }.count == 2)
        #expect(saved.entries.first { $0.kind == .expense }?.amount == Decimal(string: "10.05"))
        #expect(saved.accounts[0].profileImage == first.image)
        var classified = saved
        let paymentIndex = try #require(classified.entries.firstIndex { $0.sourceRef == "wise:1:payment" })
        classified.entries[paymentIndex].kind = .income
        classified.entries[paymentIndex].kindIsUserEdited = true
        let restored = try VaultJSON.decode(VaultDocument.self, from: VaultJSON.encode(classified))
        let refreshed = try WiseAPI.apply(snapshot, to: restored)
        #expect(refreshed.entries[paymentIndex].kind == .income)
        snapshot.profiles[0].activities[0].status = "CANCELLED"
        let cancelled = try WiseAPI.apply(snapshot, to: saved)
        #expect(cancelled.entries.count == 2 && cancelled.accounts.count == 2)
    }
}
#endif

#if UPONLY_FIXTURE
@MainActor struct ImportSessionTests {
    private func harness(keys: VaultKeyStoring = MemoryKeyStore(), authenticator: any VaultAuthenticating = FixtureAuthenticator()) -> (UpOnlySession, MemoryFileIO, VaultStore) {
        let io = MemoryFileIO(), layout = VaultLayout(root: URL(fileURLWithPath: "/tmp/uponly-import-test-" + UUID().uuidString))
        let vault = VaultStore(layout: layout, io: io, keys: keys, authenticator: authenticator)
        return (UpOnlySession(testing: vault, layout: layout), io, vault)
    }
    private func bankDraft() throws -> ImportBatchDraft {
        let source = try ImportParser.source(bytes: Data("Account,Currency,Balance,ObservedOn\nSample,USD,42,2026-01-02".utf8), filename: "example.csv", mode: .bankBalances)
        return ImportBatchDraft(mode: .bankBalances, sources: [source], rows: try ImportParser.rows(source: source, mode: .bankBalances))
    }
    @Test("Statements accept CSV uploads and reject other files without changing the draft")
    func statementsCSVOnly() async throws {
        let (session, _, _) = harness()
        await session.create(recovery: .random())
        session.startImport(.statements)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let csv = directory.appendingPathComponent("statement.CSV")
        try Data("TransactionID,Date,Description,Amount,Currency,Type\nsample,2026-01-02,Sample expense,12.50,USD,expense\n".utf8).write(to: csv)
        let reference = try #require((csv as NSURL).fileReferenceURL())
        await session.readImportFiles([reference])
        #expect(session.importMessage == nil)
        #expect(session.importDraft?.rows.count == 1)
        let draft = try #require(session.importDraft)
        #expect(draft.sources.count == 1 && draft.sources[0].filename == "statement.CSV")
        #expect(!draft.sources[0].grid.isEmpty)
        await session.readImportFiles([csv, directory.appendingPathComponent("statement.tsv")])
        #expect(session.importMessage == "Choose CSV files for statements.")
        #expect(session.importDraft?.rows.map(\.id) == draft.rows.map(\.id))
        #expect(session.importDraft?.sources.map(\.id) == draft.sources.map(\.id))
        #expect(session.importDraft?.rows.first?.statement.amount == "12.50" && !session.importLoading)
        #expect(session.document?.entries.isEmpty == true)
    }
    @Test("Setup completes with one generation and correct navigation")
    func setup() async throws {
        let (session, _, _) = harness()
        await session.create(recovery: .random())
        let before = try #require(session.document?.generation)
        try await session.completeSetup(tracked: [.crypto], prices: false, fx: false, key: "")
        #expect(session.document?.generation == before + 1)
        #expect(session.destination == 1 && session.managementSection == "Portfolios")
        #expect(session.document?.settings.setupComplete == true)
    }

    @Test("Interrupted onboarding resumes after a normal unlock")
    func resumeSetup() async throws {
        let (session, _, _) = harness()
        await session.create(recovery: .random())
        let id = try #require(session.document?.vaultID)
        session.lock()
        #expect(session.state == .locked)
        await session.unlock()
        #expect(session.state == .unlocked && session.document?.vaultID == id)
        #expect(session.document?.settings.setupComplete == false)
        try await session.completeSetup(tracked: [.banks], prices: false, fx: false, key: "")
        #expect(session.document?.settings.setupComplete == true)
    }

    @Test("Failed key storage leaves setup on the creation screen")
    func failedSetupStaysNew() async throws {
        let keys = SetupTestKeyStore(); keys.storeError = .keychainUnavailable(-34018)
        let (session, io, _) = harness(keys: keys)
        await session.create(recovery: .random())
        #expect(session.state == .newVault && session.document == nil && !session.isBusy)
        #expect(!io.fileExists(at: session.layout.current))
        keys.storeError = nil
        await session.create(recovery: .random())
        #expect(session.state == .unlocked)
    }

    @Test("Keychain access errors do not send users to recovery")
    func unavailableKeychainIsNotMissingKey() async throws {
        let keys = SetupTestKeyStore()
        let (session, _, _) = harness(keys: keys)
        await session.create(recovery: .random())
        keys.loadError = .keychainUnavailable(-34018)
        session.lock(); await session.unlock()
        #expect(session.state == .locked && session.message != nil && !session.isBusy)
    }

    @Test("Back exits a required recovery screen without replacing its vault")
    func recoveryCanReturnToUnlock() async throws {
        let keys = SetupTestKeyStore()
        let (session, io, _) = harness(keys: keys)
        await session.create(recovery: .random())
        let id = try #require(session.document?.vaultID)
        let original = try io.data(at: session.layout.current)
        try keys.delete(vaultID: id)
        session.lock(); await session.unlock()
        #expect(session.state == .recovery)
        session.returnToUnlock()
        #expect(session.state == .locked)
        #expect(try io.data(at: session.layout.current) == original)
    }
    @Test("Write failure leaves every imported account and balance unsaved")
    func atomicFailure() async throws {
        let (session, io, vault) = harness()
        await session.create(recovery: .random())
        let before = try #require(session.document)
        io.failWrite = true
        let draft = try bankDraft()
        await #expect(throws: Error.self) { try await session.commitImportBatch(draft) }
        #expect(session.document == before)
        let persisted = try await vault.currentSession()
        #expect(persisted.document.accounts.isEmpty && persisted.document.bankBalances.isEmpty)
    }
    @Test("Successful batches commit together and locking clears drafts")
    func successAndLock() async throws {
        let (session, _, _) = harness()
        await session.create(recovery: .random())
        let draft = try bankDraft()
        session.importDraft = draft
        try await session.commitImportBatch(draft)
        #expect(session.document?.accounts.count == 1 && session.document?.bankBalances.count == 1)
        #expect(session.importDraft == nil)
        session.startImport(.holdings)
        session.addingInMenu = true
        session.lock()
        #expect(session.importDraft == nil && session.document == nil && !session.importLoading && !session.addingInMenu)
        await #expect(throws: VaultError.locked) { try await session.commitImportBatch(draft) }
    }
    @Test("Starting another entry flow preserves an unfinished draft and its return page")
    func importNavigation() async throws {
        let (session, _, _) = harness()
        await session.create(recovery: .random())
        session.managementSection = "Accounts"
        #expect(session.startImport(.bankBalances))
        session.importDraft = try bankDraft()
        let id = try #require(session.importDraft?.rows.first?.id)
        session.managementSection = "Portfolios"
        #expect(!session.startImport(.holdings))
        #expect(session.importDraft?.rows.first?.id == id)
        #expect(session.managementSection == "Add your info" && session.importReturnSection == "Accounts")
        session.discardImport()
        #expect(session.importDraft == nil && session.managementSection == "Accounts")
        #expect(session.document?.accounts.isEmpty == true)
    }
    @Test("Onboarding resumes its encrypted step, choices and keys after locking")
    func setupProgressSurvivesLock() async throws {
        let (session, io, _) = harness()
        await session.create(recovery: .random())
        var progress = SetupProgress(step: 0, tracked: [.crypto, .banks, .crypto])
        session.checkpointSetup(progress)
        progress.step = 1; progress.prices = true; progress.fx = true; progress.coinGeckoKey = "synthetic-setup-key"
        session.checkpointSetup(progress)
        try await session.flushSetupProgress()
        #expect(session.document?.settings.setupProgress == progress.normalized)
        #expect(session.document?.settings.automaticPrices == false && session.document?.settings.automaticFX == false)
        #expect(!(try io.data(at: session.layout.current)).contains(Data(progress.coinGeckoKey.utf8)))
        session.lock(); await session.unlock()
        #expect(session.document?.settings.setupProgress == progress.normalized)
        #expect(session.document?.settings.setupComplete == false)
        try await session.completeSetup(tracked: progress.tracked, prices: true, fx: true, key: progress.coinGeckoKey)
        #expect(session.document?.settings.setupProgress == nil && session.document?.settings.setupComplete == true)
    }
    @Test("Lock clears pending rate editors and transaction drill-through context")
    func lockClearsManagementRequests() async throws {
        let (session, _, _) = harness()
        await session.create(recovery: .random())
        session.entryMonthForManagement = "2026-01"; session.requestedRateCurrency = "GBP"
        session.lock()
        #expect(session.entryMonthForManagement.isEmpty && session.requestedRateCurrency == nil)
    }
    @Test("A detached embedded authentication callback cannot start another unlock")
    func detachedAuthentication() async throws {
        let (session, _, _) = harness()
        await session.create(recovery: .random())
        session.lock()
        await session.unlockEmbedded(LAContext())
        #expect(session.state == .locked && session.document == nil && !session.isBusy)
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition(), "The asynchronous unlock did not finish")
    }
    @Test("Opening the menu authenticates a locked vault and respects the five-minute deadline")
    func menuOpenAuthenticates() async throws {
        let auth = FixtureAuthenticator()
        let (session, _, _) = harness(authenticator: auth)
        session.menuOpened()
        await Task.yield()
        #expect(session.state == .newVault && auth.evaluateCount == 0)
        session.surfaceClosed()
        await session.create(recovery: .random())
        let id = try #require(session.document?.vaultID), count = auth.evaluateCount
        session.lock()
        session.menuOpened()
        try await waitUntil { session.state == .unlocked }
        #expect(auth.evaluateCount == count + 1 && session.document?.vaultID == id)
        session.surfaceClosed(); session.menuOpened()
        await Task.yield()
        #expect(auth.evaluateCount == count + 1)
        session.surfaceClosed()
        session.recordActivity(at: Date().addingTimeInterval(-301))
        session.menuOpened()
        #expect(session.state == .locked && session.document == nil)
        try await waitUntil { session.state == .unlocked }
        #expect(auth.evaluateCount == count + 2 && session.document?.vaultID == id)
    }
    @Test("Cancelling automatic authentication waits for a new opening or the password fallback")
    func menuUnlockCancellation() async throws {
        let auth = FixtureAuthenticator()
        let (session, _, _) = harness(authenticator: auth)
        await session.create(recovery: .random())
        session.lock(); auth.shouldCancel = true
        let count = auth.evaluateCount
        session.menuOpened()
        try await waitUntil { auth.evaluateCount == count + 1 && !session.isBusy }
        #expect(session.state == .locked && session.document == nil)
        // A cancellation must not schedule another attempt by itself.
        try await Task.sleep(for: .milliseconds(50))
        #expect(auth.evaluateCount == count + 1)
        auth.shouldCancel = false
        session.surfaceClosed(); session.menuOpened()
        try await waitUntil { session.state == .unlocked }
        #expect(auth.evaluateCount == count + 2)
        session.lock(); auth.shouldCancel = true
        session.surfaceClosed(); session.menuOpened()
        try await waitUntil { auth.evaluateCount == count + 3 && !session.isBusy }
        auth.shouldCancel = false
        session.beginUnlock(usePassword: true)
        try await waitUntil { session.state == .unlocked }
        #expect(auth.evaluateCount == count + 4)
    }
    @Test("A failed fingerprint offers password without closing the menu")
    func fingerprintPasswordWithoutReopening() async throws {
        let auth = FixtureAuthenticator()
        let (session, _, _) = harness(authenticator: auth)
        await session.create(recovery: .random())
        session.lock(); auth.shouldCancel = true
        let count = auth.evaluateCount
        session.menuOpened()
        try await waitUntil { session.authenticationFailed && !session.isBusy }
        #expect(auth.evaluateCount == count + 1 && session.document == nil)
        auth.shouldCancel = false
        session.beginUnlock(usePassword: true)
        try await waitUntil { session.state == .unlocked }
        #expect(auth.evaluateCount == count + 2 && !session.authenticationFailed)
    }
    @Test("Password click replaces a pending unlock and ignores its late success")
    func passwordReplacesPendingAuthentication() async throws {
        let auth = DeferredUnlockAuthenticator()
        let (session, _, _) = harness(authenticator: auth)
        await session.create(recovery: .random())
        session.lock(); auth.deferReplies = true
        session.menuOpened()
        try await waitUntil { auth.pendingCount == 1 && session.isBusy }
        let oldToken = session.sessionToken
        session.beginUnlock(usePassword: true)
        #expect(session.sessionToken != oldToken && session.passwordUnlockRequested)
        try await waitUntil { auth.pendingCount == 2 && session.isBusy }
        let passwordToken = session.sessionToken
        session.beginUnlock(usePassword: true)
        session.menuOpened()
        session.surfaceClosed(); session.surfaceClosed()
        #expect(session.sessionToken == passwordToken && session.passwordUnlockRequested)
        auth.completeFirst(success: true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(session.state == .locked && session.document == nil && session.isBusy && session.passwordUnlockRequested)
        auth.completeFirst(success: false)
        try await waitUntil { session.authenticationFailed && !session.isBusy }
        #expect(session.state == .locked && !session.passwordUnlockRequested)
        // A new opening returns to automatic authentication after password cancellation.
        auth.deferReplies = false
        session.menuOpened()
        try await waitUntil { session.state == .unlocked }
    }
    @Test("Password unlock succeeds while a cancelled biometric reply arrives afterwards")
    func passwordSuccessSurvivesLateBiometricCancellation() async throws {
        let auth = DeferredUnlockAuthenticator()
        let (session, _, _) = harness(authenticator: auth)
        await session.create(recovery: .random())
        let id = try #require(session.document?.vaultID)
        session.lock(); auth.deferReplies = true
        session.menuOpened()
        try await waitUntil { auth.pendingCount == 1 }
        session.beginUnlock(usePassword: true)
        try await waitUntil { auth.pendingCount == 2 }
        auth.completeLast(success: true)
        try await waitUntil { session.state == .unlocked }
        auth.completeFirst(success: false)
        try await Task.sleep(for: .milliseconds(50))
        #expect(session.document?.vaultID == id && !session.authenticationFailed && !session.isBusy)
    }
    @Test("Locking before a queued password attempt starts cancels it")
    func queuedPasswordUnlockIsFenced() async throws {
        let auth = FixtureAuthenticator()
        let (session, _, _) = harness(authenticator: auth)
        await session.create(recovery: .random())
        session.lock()
        let count = auth.evaluateCount
        session.beginUnlock(usePassword: true); session.lock()
        try await Task.sleep(for: .milliseconds(50))
        #expect(session.state == .locked && session.document == nil && auth.evaluateCount == count && !session.passwordUnlockRequested)
    }
    @Test("Locking before a queued automatic unlock starts cancels that attempt")
    func queuedMenuUnlockIsFenced() async throws {
        let auth = FixtureAuthenticator()
        let (session, _, _) = harness(authenticator: auth)
        await session.create(recovery: .random())
        session.lock()
        let count = auth.evaluateCount
        session.menuOpened(); session.lock()
        try await Task.sleep(for: .milliseconds(50))
        #expect(session.state == .locked && session.document == nil && auth.evaluateCount == count)
    }
    @Test("Manual locking clears finances immediately and starts authentication without reopening")
    func manualLockAuthenticates() async throws {
        let auth = FixtureAuthenticator()
        let (session, _, _) = harness(authenticator: auth)
        await session.create(recovery: .random())
        let id = try #require(session.document?.vaultID), count = auth.evaluateCount
        session.lockAndAuthenticate()
        #expect(session.state == .locked && session.document == nil && !session.authenticationFailed)
        try await waitUntil { session.state == .unlocked }
        #expect(auth.evaluateCount == count + 1 && session.document?.vaultID == id)
        auth.shouldCancel = true
        session.lockAndAuthenticate()
        try await waitUntil { session.authenticationFailed && !session.isBusy }
        #expect(auth.evaluateCount == count + 2 && session.state == .locked && session.document == nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(auth.evaluateCount == count + 2)
        auth.shouldCancel = false
        session.menuOpened()
        #expect(!session.authenticationFailed)
        try await waitUntil { session.state == .unlocked }
        // System/idle locking does not start authentication in the background.
        session.lock()
        try await Task.sleep(for: .milliseconds(50))
        #expect(session.state == .locked && !session.authenticationFailed && auth.evaluateCount == count + 3)
    }
    @Test("Popover dismissal retains the session until five idle minutes; background saves do not extend it")
    func idleLockDeadline() async throws {
        let (session, _, _) = harness()
        await session.create(recovery: .random())
        let start = Date()
        session.surfaceOpened()
        session.recordActivity(at: start)
        session.surfaceClosed()
        session.checkInactivity(at: start.addingTimeInterval(299.9))
        #expect(session.state == .unlocked)
        try await session.mutate { $0.reviewedMonths.append("2026-01") }
        session.checkInactivity(at: start.addingTimeInterval(300))
        #expect(session.state == .locked && session.document == nil)
    }
    @Test("User activity and a fresh unlock each start a full five-minute idle period")
    func idleLockActivity() async throws {
        let (session, _, _) = harness()
        await session.create(recovery: .random())
        let start = Date()
        session.recordActivity(at: start)
        session.recordActivity(at: start.addingTimeInterval(250))
        session.checkInactivity(at: start.addingTimeInterval(300))
        #expect(session.state == .unlocked)
        session.checkInactivity(at: start.addingTimeInterval(550))
        #expect(session.state == .locked)
        await session.unlock()
        session.checkInactivity(at: Date().addingTimeInterval(299))
        #expect(session.state == .unlocked)
        session.lock()
        #expect(session.state == .locked)
    }
    @Test("A late timer cannot let a new click extend an already expired session")
    func expiredSessionOnResume() async throws {
        let (session, _, _) = harness()
        await session.create(recovery: .random())
        let start = Date()
        session.recordActivity(at: start)
        session.handleActivity(at: start.addingTimeInterval(301))
        #expect(session.state == .locked && session.document == nil)
        await session.unlock()
        session.recordActivity(at: Date().addingTimeInterval(-301))
        session.surfaceOpened()
        #expect(session.state == .locked && session.document == nil)
    }
    @Test("Privacy defaults safely and survives an encrypted save and unlock without changing financial data")
    func privacyPersistence() async throws {
        #expect(try VaultJSON.decode(AppSettings.self, from: Data("{}".utf8)).privacyMode == false)
        let (session, _, _) = harness()
        await session.create(recovery: .random())
        try await session.commitImportBatch(bankDraft())
        let accounts = session.document?.accounts, balances = session.document?.bankBalances
        try await session.togglePrivacyMode()
        #expect(session.privacyMode)
        #expect(session.document?.accounts == accounts && session.document?.bankBalances == balances)
        session.lock(); await session.unlock()
        #expect(session.privacyMode)
        try await session.togglePrivacyMode()
        #expect(!session.privacyMode)
    }
    @Test("A failed privacy preference save leaves the current visibility and vault unchanged")
    func privacyWriteFailure() async throws {
        let (session, io, _) = harness()
        await session.create(recovery: .random())
        try await session.togglePrivacyMode()
        let saved = try io.data(at: session.layout.current)
        io.failWrite = true
        await #expect(throws: Error.self) { try await session.togglePrivacyMode() }
        let after = try io.data(at: session.layout.current)
        #expect(session.privacyMode && after == saved)
        #expect(ImportRowState.ready("1 → 2 Bitcoin").displayText(privacy: true) == "Replace current total · Values hidden")
        #expect(ImportRowState.error("Choose a coin").displayText(privacy: true) == "Choose a coin")
    }
    @Test("Enabling FX directly preserves all other source choices")
    func enableFXOnly() async throws {
        let (session, _, _) = harness()
        await session.create(recovery: .random())
        try await session.mutate { $0.settings.coinGeckoKey = "synthetic-key"; $0.settings.automaticMetals = true }
        await session.enableExchangeRates()
        #expect(session.document?.settings.automaticFX == true)
        #expect(session.document?.settings.coinGeckoKey == "synthetic-key" && session.document?.settings.automaticMetals == true)
        #expect(session.document?.settings.automaticPrices == false)
    }
    @Test("Failed onboarding autosave is visible and can be retried")
    func setupProgressWriteFailure() async throws {
        let (session, io, _) = harness()
        await session.create(recovery: .random())
        let progress = SetupProgress(step: 1, tracked: [.banks], fx: true)
        io.failWrite = true; session.checkpointSetup(progress)
        await #expect(throws: Error.self) { try await session.flushSetupProgress() }
        #expect(session.setupProgressMessage != nil && session.document?.settings.setupProgress == nil)
        io.failWrite = false; session.checkpointSetup(progress)
        try await session.flushSetupProgress()
        #expect(session.setupProgressMessage == nil && session.document?.settings.setupProgress == progress)
    }
    @Test("An account update prefills only that account and returns after saving")
    func focusedBalanceUpdate() async throws {
        let (session, _, _) = harness()
        await session.create(recovery: .random())
        try await session.commitImportBatch(bankDraft())
        let target = try #require(session.document?.accounts.first)
        try await session.mutate { $0.accounts.append(Account(name: "Untouched", currency: "EUR")) }
        session.managementSection = "Accounts"
        session.startImport(.bankBalances, prefill: true, accountID: target.id)
        #expect(session.importDraft?.rows.count == 1)
        #expect(session.importDraft?.rows.first?.bank.account.existingID == target.id)
        session.importDraft?.rows[0].bank.balance = "0"
        session.importDraft?.rows[0].bank.date = "2026-09-04"
        try await session.commitImportBatch(#require(session.importDraft))
        #expect(session.managementSection == "Accounts" && session.importDraft == nil)
        #expect(session.document?.accounts.count == 2)
        #expect(session.document?.bankBalances.contains { $0.accountID != target.id } == false)
    }
    @Test("A batch crossing the vault size limit saves no accounts or entries")
    func vaultSizeFailure() async throws {
        let (session, _, vault) = harness()
        await session.create(recovery: .random())
        try await session.mutate { doc in
            doc.importedStatements = [ImportedStatement(digest: Data([1]), originalBytes: Data(repeating: 0, count: 70 * 1024 * 1024), importedAt: Date())]
        }
        let generation = try #require(session.document?.generation)
        let notes = String(repeating: "x", count: 2048)
        let csv = "TransactionID,Date,Description,Amount,Currency,Notes\n" + (0..<1600).map { "\($0),2026-01-02,Sample,1,USD,\(notes)" }.joined(separator: "\n")
        var source = try ImportParser.source(bytes: Data(csv.utf8), filename: "large.csv", mode: .statements)
        source.account = ImportAccount(name: "Must not remain")
        let draft = ImportBatchDraft(mode: .statements, sources: [source], rows: try ImportParser.rows(source: source, mode: .statements))
        await #expect(throws: VaultError.oversizedVault) { try await session.commitImportBatch(draft) }
        let persisted = try await vault.currentSession()
        #expect(persisted.document.generation == generation)
        #expect(persisted.document.accounts.isEmpty && persisted.document.entries.isEmpty)
        #expect(persisted.document.importedStatements.count == 1)
        #expect(session.document?.generation == generation && session.document?.accounts.isEmpty == true)
    }
    @Test("Failed history saves preserve quotes, coverage, quantities and charts together")
    func historyWriteFailure() async throws {
        let (session, io, vault) = harness()
        await session.create(recovery: .random())
        let before = try #require(session.document)
        let date = try ImportDateFormat.iso.date("2026-08-01")
        var update = PriceUpdate()
        update.quotes = [QuoteObservation(assetID: PreciousMetal.gold.assetID, priceUSD: PreciseDecimal(100), providerTime: date, fetchedAt: Date(), provider: "Synthetic")]
        update.coverage = [PriceHistoryCoverage(key: "asset:metal-gold-gram", start: date, end: date.addingTimeInterval(86400), checkedAt: Date(), complete: true)]
        io.failWrite = true
        await #expect(throws: Error.self) { try await session.commitPriceUpdate(update) }
        #expect(session.document == before)
        #expect(try await vault.currentSession().document == before)
        session.lock()
        await #expect(throws: VaultError.locked) { try await session.commitPriceUpdate(update) }
    }
    @Test("Lock fences a pending prepared import")
    func lockDuringCommit() async throws {
        let (session, _, vault) = harness()
        await session.create(recovery: .random())
        var draft = try bankDraft()
        // Keep parsing busy long enough to exercise cancellation after the commit task starts.
        let first = draft.rows[0]
        draft.rows = (0..<5000).map { index in
            var row = first; row.id = UUID(); row.bank.account.name = "Account " + String(index); return row
        }
        let task = Task { try await session.commitImportBatch(draft) }
        await Task.yield()
        session.lock()
        await #expect(throws: Error.self) { try await task.value }
        let reopened = try await vault.unlock()
        #expect(reopened.document.accounts.isEmpty && reopened.document.bankBalances.isEmpty)
    }
}
#endif

struct MetalHistoryTests {
    private func empty() -> VaultDocument {
        let pair = VaultCrypto.makeInboxKeyPair()
        return VaultDocument.empty(inboxPrivateKeyX963: pair.privateX963, inboxPublicKeyX963: pair.publicX963)
    }
    private func batch(_ text: String) throws -> ImportBatchDraft {
        let source = try ImportParser.source(bytes: Data(text.utf8), filename: "metals.csv", mode: .metals, pasted: true)
        return ImportBatchDraft(mode: .metals, sources: [source], rows: try ImportParser.rows(source: source, mode: .metals))
    }
    @Test("Metals have independent visibility and legacy portfolios remain crypto")
    func visibilityAndDecoding() throws {
        var doc = empty(); doc.createdAt = Date(timeIntervalSince1970: 0); doc.settings.tracked = [.metals]
        #expect(doc.showsNetWorth && !doc.shows(.crypto) && !doc.shows(.banks))
        #expect(doc.defaultManagementSection == "Precious metals" && doc.defaultDestination == 1)
        let portfolio = Portfolio(name: "Safe", createdAt: Date(timeIntervalSince1970: 1), kind: .metals)
        doc.portfolios = [portfolio]; doc.settings.tracked = []
        #expect(doc.shows(.metals) && !doc.shows(.crypto))
        doc.portfolios[0].archivedAt = Date(timeIntervalSince1970: 2)
        #expect(!doc.shows(.metals))
        let legacy = Portfolio(name: "Legacy")
        #expect(try VaultJSON.decode(Portfolio.self, from: VaultJSON.encode(legacy)).kind == .crypto)
        doc.settings.automaticMetals = true; doc.settings.metalHistoryKey = "synthetic-key"
        doc.priceHistoryCoverage = [PriceHistoryCoverage(key: "asset:metal-gold-gram", start: Date(timeIntervalSince1970: 100), end: Date(timeIntervalSince1970: 200), checkedAt: Date(timeIntervalSince1970: 300), complete: true)]
        #expect(try VaultJSON.decode(VaultDocument.self, from: VaultJSON.encode(doc)) == doc)
    }
    @Test("Fine weights convert exactly and reject ambiguous ounces and unknown metals")
    func units() throws {
        #expect(try MetalWeightUnit.troyOunces.grams(1) == PreciousMetal.gramsPerTroyOunce)
        #expect(try MetalWeightUnit.kilograms.grams(Decimal(string: "0.123456789")!) == Decimal(string: "123.456789")!)
        #expect(throws: Error.self) { try MetalWeightUnit.resolve("oz") }
        #expect(throws: Error.self) { try MetalWeightUnit.grams.grams(-1) }
        #expect(throws: Error.self) { try PreciousMetal.resolve("PAXG") }
        for metal in PreciousMetal.allCases { #expect(try PreciousMetal.resolve(metal.rawValue) == metal) }
    }
    @Test("Metal CSV and headerless paste replace totals and preserve omitted holdings")
    func replacement() throws {
        let draft = try batch("Portfolio,Metal,Weight,Unit\nSafe,Gold,1,ozt\nSafe,Silver,500,g")
        let saved = try #require(ImportBatchProcessor.evaluate(draft, document: empty()).document)
        #expect(saved.portfolios[0].kind == .metals && saved.hasData(.metals) && !saved.hasData(.crypto))
        let gold = try #require(saved.holdings.first { $0.assetID == PreciousMetal.gold.assetID })
        #expect(saved.effectiveQuantity(holdingID: gold.id, at: Date()) == PreciousMetal.gramsPerTroyOunce)
        var change = try batch("Safe\tGold\t0\tg")
        change.rows[0].holding.portfolioID = saved.portfolios[0].id
        let updated = try #require(ImportBatchProcessor.evaluate(change, document: saved).document)
        #expect(updated.effectiveQuantity(holdingID: gold.id, at: Date()) == 0)
        let silver = try #require(updated.holdings.first { $0.assetID == PreciousMetal.silver.assetID })
        #expect(updated.effectiveQuantity(holdingID: silver.id, at: Date()) == 500)
        change.rows[0].holding.unit = "oz"
        #expect(ImportBatchProcessor.evaluate(change, document: saved).document == nil)
    }
    @Test("Metals cannot leak into a crypto portfolio through import or holding mutations")
    func classification() throws {
        var doc = empty(); let crypto = Portfolio(name: "Crypto"); doc.portfolios = [crypto]
        var draft = try batch("Portfolio,Metal,Weight,Unit\nSafe,Gold,1,g")
        draft.rows[0].holding.portfolioID = crypto.id
        #expect(ImportBatchProcessor.evaluate(draft, document: doc).hasErrors)
        #expect(throws: VaultError.invalidAssetID) { try HoldingMutations.addHolding(portfolioID: crypto.id, assetID: PreciousMetal.gold.assetID, assetName: "Gold", quantity: 1, at: Date(), document: doc) }
    }
    @Test("Metal quotes validate symbol currency timestamp and exact source decimal")
    func metalQuotes() throws {
        let now = try ImportDateFormat.iso.date("2026-08-10")
        let json = Data(#"{"symbol":"XAU","currency":"USD","price":3110.34768,"updatedAt":"2026-08-10T00:00:00Z"}"#.utf8)
        let quote = try PriceHistory.decodeMetal(json, metal: .gold, fetchedAt: now)
        #expect(quote.assetID == PreciousMetal.gold.assetID && quote.priceUSD.value == 100)
        #expect(throws: Error.self) { try PriceHistory.decodeMetal(json, metal: .silver, fetchedAt: now) }
        #expect(throws: Error.self) { try PriceHistory.decodeMetal(json, metal: .gold, fetchedAt: now.addingTimeInterval(-600)) }
    }
    @Test("Historical parsers preserve timestamps, select daily observations and reject bad rows")
    func decoders() throws {
        let start = try ImportDateFormat.iso.date("2026-08-01"), end = try ImportDateFormat.iso.date("2026-08-03")
        let request = PriceHistoryRequest(source: .crypto, key: "asset:bitcoin", identifier: "bitcoin", start: start, end: end)
        let ms = Int(start.timeIntervalSince1970 * 1000)
        let json = Data("{\"prices\":[[\(ms),1.123456789123456789],[\(ms + 3600000),2.123456789123456789],[\(ms + 86400000),3]]}".utf8)
        let quotes = try PriceHistory.decodeCrypto(json, request: request, fetchedAt: end)
        #expect(quotes.count == 2 && quotes[0].priceUSD.value == Decimal(string: "2.123456789123456789")!)
        #expect(quotes[0].providerTime == start.addingTimeInterval(3600))
        #expect(throws: Error.self) { try PriceHistory.decodeCrypto(Data("{\"prices\":[[0,-1]]}".utf8), request: request, fetchedAt: end) }
        let metalRequest = PriceHistoryRequest(source: .metal, key: "asset:metal-gold-gram", identifier: PreciousMetal.gold.assetID.rawValue, start: start, end: end)
        let metals = try PriceHistory.decodeMetals(Data(#"[{"day":"2026-08-01","avg_price":3110.34768}]"#.utf8), request: metalRequest, fetchedAt: end)
        #expect(metals[0].priceUSD.value == 100 && metals[0].providerTime == start.addingTimeInterval(86399))
        let fxRequest = PriceHistoryRequest(source: .fx, key: "fx:GBP", identifier: "GBP", start: start, end: end)
        let fx = try PriceHistory.decodeFX(Data(#"{"base":"GBP","rates":{"2026-07-31":{"USD":1.23456789123456789}}}"#.utf8), request: fxRequest, fetchedAt: end)
        #expect(fx.count == 1 && fx[0].providerTime < start)
    }
    @Test("Catch-up fills offline dates using past quantities and is idempotent")
    func backfillValuations() throws {
        let start = try ImportDateFormat.iso.date("2026-08-01"), now = try ImportDateFormat.iso.date("2026-08-05")
        var doc = empty(); let portfolio = Portfolio(name: "Safe", createdAt: start, kind: .metals); doc.portfolios = [portfolio]
        doc = try HoldingMutations.addHolding(portfolioID: portfolio.id, assetID: PreciousMetal.gold.assetID, assetName: "Gold", quantity: 10, at: start, document: doc)
        let holding = doc.holdings[0]
        doc = try HoldingMutations.setQuantity(holdingID: holding.id, quantity: 20, at: start.addingTimeInterval(2 * 86400), document: doc)
        var update = PriceUpdate()
        for day in 0..<4 { update.quotes.append(QuoteObservation(assetID: PreciousMetal.gold.assetID, priceUSD: PreciseDecimal(Decimal(100 + day)), providerTime: start.addingTimeInterval(Double(day) * 86400 + 86399), fetchedAt: now, provider: "Synthetic history")) }
        update.coverage = [PriceHistoryCoverage(key: "asset:metal-gold-gram", start: start, end: now, checkedAt: now, complete: true)]
        let saved = try PriceHistory.applying(update, to: doc, now: now)
        #expect(saved.storedValuation(day: start, scope: .allTracked)?.total?.value == 1000)
        #expect(saved.storedValuation(day: start.addingTimeInterval(86400), scope: .allTracked)?.total?.value == 1010)
        #expect(saved.storedValuation(day: start.addingTimeInterval(2 * 86400), scope: .allTracked)?.total?.value == 2040)
        #expect(try PriceHistory.applying(update, to: saved, now: now) == saved)
        #expect(saved.quantities == doc.quantities)
    }
    @Test("History gaps remain unavailable, completed coverage resumes at the next day")
    func gapsAndResumption() throws {
        let start = try ImportDateFormat.iso.date("2026-08-01"), now = try ImportDateFormat.iso.date("2026-08-05")
        var doc = empty(); doc.settings.automaticPrices = true
        let portfolio = Portfolio(name: "Crypto", createdAt: start); doc.portfolios = [portfolio]
        doc = try HoldingMutations.addHolding(portfolioID: portfolio.id, assetID: CanonicalAssetID("bitcoin"), assetName: "Bitcoin", quantity: 1, at: start, document: doc)
        var update = PriceUpdate()
        update.quotes = [QuoteObservation(assetID: try CanonicalAssetID("bitcoin"), priceUSD: PreciseDecimal(100), providerTime: start, fetchedAt: now, provider: "Synthetic")]
        update.coverage = [PriceHistoryCoverage(key: "asset:bitcoin", start: start, end: now, checkedAt: now, complete: false)]
        let saved = try PriceHistory.applying(update, to: doc, now: now)
        #expect(saved.storedValuation(day: start.addingTimeInterval(86400), scope: .allTracked)?.total == nil)
        #expect(PriceHistory.requests(document: saved, now: now).isEmpty)
        #expect(!PriceHistory.requests(document: saved, now: now, reconnected: true).isEmpty)
        doc.priceHistoryCoverage = [PriceHistoryCoverage(key: "asset:bitcoin", start: start, end: now.addingTimeInterval(-86400), checkedAt: now, complete: true)]
        #expect(PriceHistory.requests(document: doc, now: now).first?.start == now.addingTimeInterval(-86400))
    }
    @Test("Historical FX keeps the last published weekend rate without changing its timestamp")
    func weekendFX() throws {
        let friday = try ImportDateFormat.iso.date("2026-07-31"), sunday = friday.addingTimeInterval(2 * 86400 + 86399)
        var doc = empty(); let account = Account(name: "Bank", currency: "GBP"); doc.accounts = [account]
        doc.setBankTracked(account.id, tracked: true, at: friday)
        doc.bankBalances = [BankBalanceObservation(id: UUID(), accountID: account.id, amount: PreciseDecimal(100), currency: "GBP", observedAt: friday, source: "Synthetic", sourceIdentity: "one")]
        doc.fx = [FXObservation(sourceCurrency: "GBP", targetCurrency: "USD", rate: PreciseDecimal(Decimal(string: "1.25")!), providerTime: friday, fetchedAt: friday, provider: "Synthetic")]
        let result = NetWorthCalculator.value(at: sunday, scope: .banks, document: doc, now: sunday.addingTimeInterval(86400))
        #expect(result.total == 125 && result.components[0].fxTime == friday)
        #expect(NetWorthCalculator.value(at: sunday.addingTimeInterval(8 * 86400), scope: .banks, document: doc, now: sunday.addingTimeInterval(9 * 86400)).total == nil)
    }
}

struct AccountingPerformanceTests {
    private func empty() -> VaultDocument {
        let pair = VaultCrypto.makeInboxKeyPair()
        return .empty(inboxPrivateKeyX963: pair.privateX963, inboxPublicKeyX963: pair.publicX963)
    }
    private func book(_ rows: [(String, Decimal)], id: String = "company", first: String = "2024-01", ownership: [OwnershipPeriod]? = nil) -> BusinessBook {
        BusinessBook(id: id, name: id.capitalized, ownership: ownership ?? [.init(fromMonth: "2024-01", numerator: 1, denominator: 3), .init(fromMonth: "2025-01", numerator: 1, denominator: 2)], firstMonth: first, sourceURL: "https://docs.google.com/spreadsheets/d/synthetic/edit", basis: "Revenue less operating costs before owner payouts", months: rows.map { BusinessMonth(month: $0.0, profitUSD: $0.1, sourceRange: "Synthetic") }, fetchedAt: Date())
    }
    private func range(_ json: String) throws -> AccountingSheets.Range { try JSONDecoder().decode(AccountingSheets.Range.self, from: Data(json.utf8)) }
    @Test("Company profit remains independent of changing owner payouts")
    func ownerDraws() throws {
        for (profit, pay) in [(1000, 500), (-500, 2000)] {
            let data = #"{"range":"Synthetic","values":[["","Actual Distr. (%)","Actual Distr. ($)"],["",1,4000],["Profit",0,\#(profit)],["Owner's Dividends",0,\#(pay)],["Directors Salary",0,500],["Operating Expenses",0,2000]]}"#
            let parsed = try AccountingSheets.profitFirst(range(data), title: "Aug26:PF")
            #expect(parsed.profitUSD == 2000)
            #expect(parsed.revenueUSD == 4000 && parsed.expensesUSD == 2000)
        }
    }
    @Test("Legacy months use the encoded year and actual column, ignoring forecasts")
    func legacyDates() throws {
        let data = #"{"range":"Synthetic","values":[[44927],["","PF %","January Actual","Forecast"],["Real Revenue",1,900,99999],["Profit",0,100,99999],["Owner's Pay",0,500,99999],["Operating Expenses",0,300,99999]]}"#
        let row = try AccountingSheets.profitFirst(range(data), title: "Jan:PF")
        #expect(row.month == "2023-01" && row.profitUSD == 600)
        #expect(AccountingSheets.profitFirstMonth("June24:PF")?.description == "2024-06")
        #expect(AccountingSheets.profitFirstMonth("Dec2:PF", rows: [[.number(45261)]])?.description == "2023-12")
    }
    @Test("Incorrect client totals are disclosed while using reconciled actual revenue and costs")
    func inconsistentClientTotal() throws {
        let data = #"{"range":"Synthetic","values":[["Clients","Profit/Loss"],["TOTAL",999],["","Actual Distr. (%)","Actual Distr. ($)"],["",1,900],["Profit",0,100],["Owner's Pay",0,500],["Operating Expenses",0,300]]}"#
        let row = try AccountingSheets.profitFirst(range(data), title: "May24:PF")
        #expect(row.profitUSD == 600 && row.estimated && row.warning != nil)
    }
    @Test("Missing or unreconciled accounting values never become a zero profit")
    func invalidSheets() throws {
        for amount in ["null", "\"#REF!\""] {
            let data = #"{"range":"Synthetic","values":[["","Actual Distr. (%)","Actual Distr. ($)"],["",1,\#(amount)],["Profit",0,100],["Owner's Pay",0,500],["Operating Expenses",0,300]]}"#
            #expect(throws: Error.self) { try AccountingSheets.profitFirst(range(data), title: "May24:PF") }
        }
    }
    @Test("Incorrect payout allocations cannot prevent calculating the company's pre-payout result")
    func unreconciledAllocations() throws {
        let r = try range(#"{"range":"Synthetic","values":[["","Actual Distr. (%)","Actual Distr. ($)"],["",1,800],["Profit",0,100],["Owner's Pay",0,500],["Operating Expenses",0,300]]}"#)
        let row = try AccountingSheets.profitFirst(r, title: "Feb23:PF")
        #expect(row.profitUSD == 500 && row.estimated && row.warning?.contains("allocations") == true)
    }
    @Test("P&L selects net profit rather than Profit First allocations")
    func pnlSource() throws {
        let r = try range(#"{"range":"P&L","values":[["Month","2026-01","2026-02 (so far)"],["Profit (set aside)",999,999],["NET PROFIT",-80,120]]}"#)
        let rows = try AccountingSheets.pnl(r)
        #expect(rows.map(\.profitUSD) == [-80,120] && rows[1].estimated)
        let health = try range(#"{"range":"Data Health","values":[["✗ 1 CHECK(S) FAILING"]]}"#)
        #expect(AccountingSheets.healthWarning(health) != nil)
    }
    @Test("One-third ownership changes to one-half at the documented month, including losses")
    func historicalOwnership() throws {
        let b = book([])
        #expect(try b.ownership(at: "2024-12")?.portion(100) == Decimal(string: "33.33"))
        #expect(try b.ownership(at: "2025-01")?.portion(100) == 50)
        #expect(try b.ownership(at: "2024-12")?.portion(-100) == Decimal(string: "-33.33"))
        #expect(try b.ownership(at: "2025-01")?.portion(-100) == -50)
    }
    @Test("Personal result includes ownership profit and excludes all company bank costs and transfers")
    func isolatedPersonalResult() {
        var doc = empty(); let m = MonthKey("2025-01")!
        doc.businessAccounting = [book([("2025-01",1000)])]
        doc.entries = [Entry(month:m,kind:.income,amount:200,currency:"USD",label:"Outside income"),Entry(month:m,kind:.expense,amount:50,currency:"USD",label:"Personal spending"),Entry(month:m,bucket:.otherBusiness,kind:.income,amount:9000,currency:"EUR",label:"Company revenue"),Entry(month:m,bucket:.otherBusiness,kind:.expense,amount:8000,currency:"CHF",label:"Company payouts"),Entry(month:m,kind:.transfer,amount:8000,currency:"USD",label:"Owner draw")]
        let r = MonthlyLedger.evaluate(m,document:doc)
        #expect(r.totals?.net == 650 && r.totals?.personalSpend == 50 && r.totals?.personalIncome == 200)
        #expect(r.businesses.first?.share == 500)
    }
    @Test("Missing business month leaves the combined headline unavailable and personal amounts visible")
    func missingMonth() {
        var doc = empty(); let m = MonthKey("2025-02")!
        doc.businessAccounting = [book([("2025-01",1000)])]
        doc.entries = [Entry(month:m,kind:.expense,amount:25,currency:"USD",label:"Spending")]
        let r = MonthlyLedger.evaluate(m,document:doc)
        #expect(r.totals == nil && r.partialTotals?.personalSpend == 25 && r.missingMonths == 1)
        #expect(r.businesses.first?.share == nil)
    }
    @Test("Performance selection isolates each company's total and uses historical ownership for the personal contribution")
    @MainActor func isolatedScopes() {
        var doc = empty(); doc.businessAccounting = [book([("2024-12",900),("2025-01",1000)])]
        let model = PopoverModel(); model.replace(with:doc); model.select(MonthKey("2024-12")!)
        #expect(model.state.totals == nil && model.state.partialTotals?.net == 300 && model.state.missingMonths == 1)
        model.selectScope(.business("company"))
        #expect(model.state.totals?.net == 900 && model.state.businesses.first?.share == 300)
        model.selectScope(.personal)
        #expect(model.state.totals == nil)
        model.selectScope(.business("company")); model.select(MonthKey("2025-01")!)
        #expect(model.state.totals?.net == 1000 && model.state.businesses.first?.share == 500)
    }
    @Test("Annual and all-time sums use monthly shares and visibly flag missing months")
    @MainActor func timeframes() {
        var doc = empty(); doc.businessAccounting = [book([("2024-12",900),("2025-01",1000)])]
        let model = PopoverModel(); model.replace(with:doc); model.selectScope(.business("company")); model.select(MonthKey("2025-01")!)
        model.selectPeriod(.annual)
        #expect(model.state.totals?.net == 1000 && model.state.businesses.first?.share == 500)
        #expect(model.state.missingMonths == 11)
        #expect(model.chartHistory.count == 12 && model.chartHistory.allSatisfy { $0.month.year == 2025 })
        model.selectPeriod(.allTime)
        #expect(model.state.totals?.net == 1900 && model.state.businesses.first?.share == 800)
        #expect(model.state.businesses.first?.ownershipLabel == "Historical ownership")
        #expect(model.chartHistory.count > 12)
        model.drillInto(MonthKey("2024-12")!)
        #expect(model.period == .monthly && model.chartHistory.last?.month.description == "2024-12")
    }
    @Test("Missing personal FX preserves known company shares without inventing a complete result")
    @MainActor func missingPersonalFX() {
        var doc = empty(); let m = MonthKey("2025-01")!
        doc.businessAccounting = [book([("2025-01", 1000)])]
        doc.entries = [Entry(month: m, kind: .expense, amount: 20, currency: "EUR", label: "Spending")]
        let result = MonthlyLedger.evaluate(m, document: doc)
        #expect(result.totals == nil && result.partialTotals?.otherBusiness == 500)
        #expect(result.unavailable == .exchangeRates(["EUR"]) && result.missingMonths == 1)
        #expect(result.businesses.first?.share == 500)
        let model = PopoverModel(); model.replace(with: doc); model.select(m)
        #expect(model.availableTotals == nil, "Known company shares must not hide the exchange-rate repair controls")
    }
    @Test("Monthly headline uses one month with its annual chart; first load uses the latest accounting month")
    @MainActor func exactMonthlyRange() {
        var doc = empty(); doc.businessAccounting = [book([("2024-12",900),("2025-01",1000)])]
        let model = PopoverModel(); model.replace(with: doc)
        #expect(model.month.description == "2025-01")
        model.selectScope(.business("company")); model.select(MonthKey("2024-12")!)
        #expect(model.chartHistory.count == 12 && model.chartHistory.allSatisfy { $0.month.year == 2024 })
        #expect(model.chartHistory.last?.net == 900)
        #expect(model.state.totals?.net == 900)
        #expect(model.attentionMonths == [MonthKey("2024-12")!])
        model.replace(with: doc)
        #expect(model.month.description == "2024-12", "Refresh must not change an explicit month selection")
        model.select(MonthKey("2025-02")!)
        #expect(model.chartHistory.count == 12 && model.chartHistory[0].net == 1000)
        #expect(model.chartHistory[1].net == nil && model.state.totals == nil)
        model.step(by: -1)
        #expect(model.month.description == "2025-01" && model.state.totals?.net == 1000)
        model.step(by: 1)
        #expect(model.pendingAccounting == [doc.businessAccounting![0].name])
    }
    @Test("A partial company refresh keeps the other business and marks retained missing months")
    func safeAccountingMerge() {
        let old = book([("2024-12",900),("2025-01",1000)])
        var other = book([("2025-01",200)]); other.id = "other"; other.name = "Other"
        var updated = old; updated.fetchedAt = old.fetchedAt.addingTimeInterval(10); updated.months.removeFirst(); updated.months[0].profitUSD = 1100
        let merged = AccountingHistory.merging([updated], into: [old, other])
        #expect(merged.count == 2 && merged.contains { $0.id == "other" && $0.months == other.months })
        let company = merged.first { $0.id == old.id }!
        #expect(company.months.count == 2 && company.months.last?.profitUSD == 1100)
        #expect(company.months.first?.estimated == true && company.months.first?.warning?.contains("saved result") == true)
        #expect(AccountingHistory.merging([old], into: merged) == merged, "An older background response cannot undo newer accounting")
    }
    #if UPONLY_PERSONAL
    @Test("A failed company does not prevent a successful company refresh")
    func isolatedAccountingFetch() async throws {
        let sources = ["good", "broken"].map { AccountingConnection.Source(id: $0, name: $0, sheetID: $0, layout: "pnl", firstMonth: "2025-01", ownership: [OwnershipPeriod(fromMonth: "2025-01", numerator: 1, denominator: 1)]) }
        let result = try await AccountingAPI.collect(sources) { source in
            if source.id == "broken" { throw AccountingAPI.HTTPFailure.status(403) }
            return book([("2025-01",123)])
        }
        #expect(result.books.filter { !$0.months.isEmpty }.count == 1 && result.failedSources == ["broken"])
        #expect(result.books.contains { $0.id == "broken" && $0.months.isEmpty })
        var doc = empty(); doc.businessAccounting = result.books
        let month = MonthKey("2025-01")!
        doc.entries = [Entry(month: month, kind: .income, amount: 100, currency: "USD", label: "Personal")]
        #expect(MonthlyLedger.evaluate(month, document: doc).totals == nil, "A missing company cannot produce a falsely complete headline")
        await #expect(throws: CancellationError.self) { try await AccountingAPI.collect(sources) { _ in throw CancellationError() } }
    }
    @Test("Transient accounting failures retry within a bound; denied access does not retry")
    func accountingRetries() async throws {
        var calls = 0
        let result = try await AccountingAPI.retrying({
            calls += 1
            if calls < 3 { throw AccountingAPI.HTTPFailure.status(503) }
            return Data("ok".utf8)
        }, pause: { _ in })
        #expect(calls == 3 && result == Data("ok".utf8))
        calls = 0
        do { _ = try await AccountingAPI.retrying({ calls += 1; throw AccountingAPI.HTTPFailure.status(403) }, pause: { _ in }); Issue.record("Expected denied access") }
        catch { #expect(calls == 1) }
        #expect(!AccountingAPI.isRetryable(CancellationError()))
    }
    #endif
    @Test("Older vaults decode without the optional accounting field")
    func olderVault() throws {
        let doc = empty(); let encoded = try JSONEncoder().encode(doc)
        var json = try #require(JSONSerialization.jsonObject(with:encoded) as? [String:Any]); json.removeValue(forKey:"businessAccounting")
        let restored = try JSONDecoder().decode(VaultDocument.self,from:JSONSerialization.data(withJSONObject:json))
        #expect(restored.businessAccounting == nil && restored.vaultID == doc.vaultID)
    }
}

struct BackgroundRefreshTests {
    @Test("Crypto and metals refresh hourly without advancing the bank schedule")
    func independentSourceCadences() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = UUID(), now = Date(timeIntervalSince1970: 1_800_000_000)
        let schedule = BackgroundRefreshSchedule()
        #expect(try await schedule.claim(vaultID: vault, root: root, now: now))
        for source in ["crypto", "metals"] {
            #expect(try await schedule.claim(vaultID: vault, root: root, source: source, now: now))
            #expect(try await !BackgroundRefreshSchedule().claim(vaultID: vault, root: root, source: source, now: now.addingTimeInterval(3599)))
            #expect(try await BackgroundRefreshSchedule().claim(vaultID: vault, root: root, source: source, now: now.addingTimeInterval(3600)))
        }
        #expect(try await !schedule.claim(vaultID: vault, root: root, now: now.addingTimeInterval(3600)))
        #expect(try await schedule.claim(vaultID: vault, root: root, now: now.addingTimeInterval(43200)))
    }
    @Test("Automatic bank attempts survive relaunch and become due after twelve hours")
    func bankCadence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = UUID(), now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(try await BackgroundRefreshSchedule().claim(vaultID: vault, root: root, now: now))
        #expect(try await !BackgroundRefreshSchedule().claim(vaultID: vault, root: root, now: now.addingTimeInterval(60)))
        #expect(try await !BackgroundRefreshSchedule().claim(vaultID: vault, root: root, now: now.addingTimeInterval(43199)))
        #expect(try await BackgroundRefreshSchedule().claim(vaultID: vault, root: root, now: now.addingTimeInterval(43200)))
        #expect(try await BackgroundRefreshSchedule().claim(vaultID: UUID(), root: root, now: now.addingTimeInterval(43201)))
    }
    @Test("Failed bank attempts stay visible without causing repeated automatic requests")
    func failedBankCadence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = UUID(), now = Date(timeIntervalSince1970: 1_800_000_000), schedule = BackgroundRefreshSchedule()
        try await schedule.finish(vaultID: vault, root: root, failed: true, now: now)
        #expect(await BackgroundRefreshSchedule().failed(vaultID: vault, root: root))
        #expect(try await !schedule.claim(vaultID: vault, root: root, now: now.addingTimeInterval(900)))
        try await schedule.finish(vaultID: vault, root: root, failed: false, now: now.addingTimeInterval(1000))
        #expect(await !schedule.failed(vaultID: vault, root: root))
        #expect(try await !schedule.claim(vaultID: vault, root: root, now: now.addingTimeInterval(43200)))
        #expect(try await schedule.claim(vaultID: vault, root: root, now: now.addingTimeInterval(-60)))
    }
    #if UPONLY_PERSONAL
    @Test("Encrypted bank prefetch retains transactions and accepts older balance-only packets")
    func bankActivities() throws {
        var (doc, config) = pair(); doc.settings.automaticWise = true
        let profile = WiseConfiguredProfile(id: 1, name: "Personal", bucket: .personal)
        let activity = WiseActivity(id: "payment", type: "CARD_PAYMENT", title: "Sample payment", primaryAmount: "10 USD", status: "COMPLETED", createdOn: "2026-01-02T12:00:00Z")
        let bank = BackgroundBankProfile(profile: profile, balances: [], activities: [activity])
        let packet = BackgroundPacket(source: "banks", fetchedAt: Date(), banks: [bank])
        let decoded = try BackgroundEnvelope.seal(packet, configuration: config).open(document: doc)
        let updated = try BackgroundRefresh.applying(decoded, to: doc)
        #expect(updated.entries.first?.sourceRef == "wise:1:payment")
        #expect(updated.entries.first?.amount == 10)
        #expect(try BackgroundRefresh.applying(decoded, to: updated) == updated)
        let legacy = try JSONEncoder().encode(BackgroundBankProfile(profile: profile, balances: []))
        #expect(try JSONDecoder().decode(BackgroundBankProfile.self, from: legacy).activities == nil)
    }
    #endif
    private func pair() -> (VaultDocument, BackgroundConfiguration) {
        let inbox = VaultCrypto.makeInboxKeyPair(), signing = VaultCrypto.makeSigningKeyPair()
        var doc = VaultDocument.empty(inboxPrivateKeyX963: inbox.privateX963, inboxPublicKeyX963: inbox.publicX963)
        doc.backgroundSignerPublicKey = signing.publicX963
        return (doc, BackgroundConfiguration(vaultID: doc.vaultID, inboxPublicKey: inbox.publicX963, signingPrivateKey: signing.privateX963, signingPublicKey: signing.publicX963, crypto: [], currencies: [], metals: [], pricesEnabled: true, fxEnabled: true, metalsEnabled: true, coinGeckoKey: ""))
    }
    @Test("Background packets can be sealed with only the public inbox key and require the unlocked vault to decrypt")
    func encryptedPrefetch() throws {
        let (doc, config) = pair()
        let packet = BackgroundPacket(source: "fx", fetchedAt: Date(), prices: PriceUpdate(messages: ["PRIVATE BALANCE MARKER"]))
        let envelope = try BackgroundEnvelope.seal(packet, configuration: config)
        let encoded = try VaultJSON.encode(envelope)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("PRIVATE BALANCE MARKER"))
        #expect(try envelope.open(document: doc).prices?.messages == ["PRIVATE BALANCE MARKER"])
        var wrong = doc; wrong.inboxPrivateKeyX963 = VaultCrypto.makeInboxKeyPair().privateX963
        #expect(throws: Error.self) { try envelope.open(document: wrong) }
    }
    @Test("Unsigned, modified and wrong-vault cache entries are rejected")
    func tampering() throws {
        let (doc, config) = pair()
        var envelope = try BackgroundEnvelope.seal(BackgroundPacket(source: "fx", fetchedAt: Date(), prices: PriceUpdate()), configuration: config)
        envelope.ciphertext[envelope.ciphertext.startIndex] ^= 1
        #expect(throws: Error.self) { try envelope.open(document: doc) }
        let other = pair().0
        #expect(throws: Error.self) { try envelope.open(document: other) }
    }
    @Test("Cached reads preserve signature, source and replay checks off the main thread")
    func cachedFileValidation() async throws {
        var (doc, config) = pair()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("uponly-cache-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        // Replay comparison uses the same millisecond precision as persisted dates.
        let now = try VaultJSON.decode(Date.self, from: VaultJSON.encode(Date()))
        try BackgroundRefresh.save(BackgroundPacket(source: "fx", fetchedAt: now, prices: PriceUpdate()), configuration: config, root: root)
        try BackgroundRefresh.save(BackgroundPacket(source: "crypto", fetchedAt: now, prices: PriceUpdate()), configuration: config, root: root)
        doc.backgroundAppliedAt = ["crypto": now]
        var bad = try BackgroundEnvelope.seal(BackgroundPacket(source: "metals", fetchedAt: now, prices: PriceUpdate()), configuration: config)
        bad.signature[bad.signature.startIndex] ^= 1
        try VaultJSON.encode(bad).write(to: BackgroundRefresh.path("metals", root: root))
        let snapshot = doc
        let result = await Task.detached { BackgroundRefresh.cachedPackets(document: snapshot, root: root) }.value
        #expect(result.packets.map(\.source) == ["fx"])
        #expect(result.issues == ["Metals cached data"])
        let cancelled = Task.detached {
            try? await Task.sleep(for: .milliseconds(30))
            return BackgroundRefresh.cachedPackets(document: snapshot, root: root)
        }
        cancelled.cancel()
        let stopped = await cancelled.value
        #expect(stopped.packets.isEmpty && stopped.issues.isEmpty)
    }
    @Test("Large cached unlock updates leave the UI executor responsive")
    @MainActor func cachedUnlockResponsiveness() async throws {
        let (doc, config) = pair()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("uponly-cache-load-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for source in BackgroundRefresh.sources {
            try BackgroundRefresh.save(BackgroundPacket(source: source, fetchedAt: Date(), prices: PriceUpdate(messages: [String(repeating: "Synthetic cache content ", count: 25000)])), configuration: config, root: root)
        }
        let start = ContinuousClock.now
        // This is the previous main-executor path, measured with synthetic data.
        let baseline = BackgroundRefresh.cachedPackets(document: doc, root: root)
        let before = start.duration(to: .now)
        #expect(baseline.packets.count == 5)
        var beats = 0
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled { beats += 1; try? await Task.sleep(for: .milliseconds(2)) }
        }
        let request = Task.detached(priority: .utility) {
            let onMainThread = Thread.isMainThread
            let result = BackgroundRefresh.cachedPackets(document: doc, root: root)
            return (onMainThread, result.packets.count)
        }
        let after = await request.value
        heartbeat.cancel()
        #expect(!after.0 && after.1 == 5 && beats > 0)
        print("UPONLY_CACHE_BENCHMARK main_blocked_before=\(before) background_ui_heartbeats=\(beats)")
    }
    @Test("Disabled sources and already-applied packets cannot overwrite vault observations")
    func disabledAndReplayed() throws {
        var (doc, _) = pair()
        let now = Date(), rate = FXObservation(sourceCurrency: "EUR", targetCurrency: "USD", rate: PreciseDecimal(2), providerTime: Date(), fetchedAt: Date(), provider: "Synthetic")
        let packet = BackgroundPacket(source: "fx", fetchedAt: now, prices: PriceUpdate(rates: [rate]))
        #expect(try BackgroundRefresh.applying(packet, to: doc).fx.isEmpty)
        doc.settings.automaticFX = true
        let applied = try BackgroundRefresh.applying(packet, to: doc)
        #expect(applied.fx.count == 1 && applied.backgroundAppliedAt?["fx"] == now)
        #expect(try BackgroundRefresh.applying(packet, to: applied) == applied)
    }
    @Test("Older accounting prefetch cannot replace a newer foreground snapshot")
    func newerAccountingPreserved() throws {
        var (doc, _) = pair()
        let now = Date()
        let old = BusinessBook(id: "company", name: "Company", ownership: [], firstMonth: "2025-01", sourceURL: "", basis: "", months: [], fetchedAt: now.addingTimeInterval(-100))
        var newer = old; newer.fetchedAt = now; newer.warning = "Latest snapshot"
        doc.businessAccounting = [newer]
        let updated = try BackgroundRefresh.applying(BackgroundPacket(source: "accounting", fetchedAt: old.fetchedAt, books: [old]), to: doc)
        #expect(updated.businessAccounting?.first?.warning == "Latest snapshot")
    }
    @Test("Prefetched prices never require access to the vault key")
    func noVaultKeyInConfiguration() throws {
        let (_, config) = pair()
        let data = try JSONEncoder().encode(config)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String:Any])
        #expect(object["inboxPrivateKey"] == nil && object["vaultKey"] == nil)
        #expect(BackgroundRefresh.interval == 900)
    }
}

struct PerformanceFXTests {
    @Test("Personal historical FX is fetched without waiting behind company currencies or asset history")
    func personalFXBackfill() throws {
        let pair = VaultCrypto.makeInboxKeyPair()
        var doc = VaultDocument.empty(inboxPrivateKeyX963: pair.privateX963, inboxPublicKeyX963: pair.publicX963)
        let now = try ImportDateFormat.iso.date("2026-09-06"), month = MonthKey("2024-03")!
        doc.settings.automaticFX = true
        doc.entries = [Entry(month:month,kind:.expense,amount:10,currency:"EUR",label:"Personal"),Entry(month:month,bucket:.otherBusiness,kind:.expense,amount:10,currency:"CHF",label:"Company"),Entry(month:month,kind:.transfer,amount:10,currency:"AUD",label:"Draw")]
        let requests = PublicPrices.monthlyFXRequests(document:doc,now:now)
        #expect(requests.count == 1 && requests[0].identifier == "EUR")
        doc.fx = [FXObservation(sourceCurrency:"EUR",targetCurrency:"USD",rate:PreciseDecimal(1),providerTime:try ImportDateFormat.iso.date("2024-03-29"),fetchedAt:now,provider:"Synthetic")]
        #expect(PublicPrices.monthlyFXRequests(document:doc,now:now).isEmpty)
        doc.fx = []; doc.settings.automaticFX = false
        #expect(PublicPrices.monthlyFXRequests(document:doc,now:now).isEmpty)
    }
    @Test("Multi-year FX history uses recent-first bounded windows and explicit retry bypasses cooldown")
    func boundedWindows() throws {
        let pair = VaultCrypto.makeInboxKeyPair()
        var doc = VaultDocument.empty(inboxPrivateKeyX963: pair.privateX963, inboxPublicKeyX963: pair.publicX963)
        let now = try ImportDateFormat.iso.date("2026-09-06")
        doc.settings.automaticFX = true
        doc.entries = (2020...2026).flatMap { year in (1...8).map { month in Entry(month: MonthKey(String(format: "%04d-%02d", year, month))!, kind: .expense, amount: 10, currency: "EUR", label: "Synthetic") } }
        let requests = PublicPrices.monthlyFXRequests(document: doc, now: now)
        #expect(requests.count == 12)
        #expect(requests.first?.key == "monthly-fx:2026-08:EUR")
        #expect(requests.allSatisfy { $0.end.timeIntervalSince($0.start) == 7 * 86400 && $0.end <= now })
        let first = try #require(requests.first)
        doc.priceHistoryCoverage = [PriceHistoryCoverage(key: first.key, start: first.start, end: first.end, checkedAt: now, complete: false)]
        #expect(!PublicPrices.monthlyFXRequests(document: doc, now: now).contains { $0.key == first.key })
        #expect(PublicPrices.monthlyFXRequests(document: doc, now: now, month: MonthKey("2026-08")!, retry: true).count == 1)
    }
    @Test("Monthly windows cover weekends and year boundaries without oversized responses")
    func boundaries() throws {
        let pair = VaultCrypto.makeInboxKeyPair()
        var doc = VaultDocument.empty(inboxPrivateKeyX963: pair.privateX963, inboxPublicKeyX963: pair.publicX963)
        doc.settings.automaticFX = true
        let now = try ImportDateFormat.iso.date("2026-09-06")
        for text in ["2024-02", "2024-03", "2025-12", "2026-08"] {
            let month = MonthKey(text)!
            let request = try #require(PublicPrices.monthlyFXRequests(document: doc, now: now, month: month, currencies: ["EUR", "USD"]).first)
            #expect(AssetOwnership.month(at: request.start) == month)
            #expect(AssetOwnership.month(at: request.end.addingTimeInterval(-1)) == month)
            #expect(request.end.timeIntervalSince(request.start) == 7 * 86400)
        }
    }
    @Test("One failed currency does not discard successful dated rates")
    func partialRepair() async throws {
        let pair = VaultCrypto.makeInboxKeyPair()
        var doc = VaultDocument.empty(inboxPrivateKeyX963: pair.privateX963, inboxPublicKeyX963: pair.publicX963)
        doc.settings.automaticFX = true
        let now = try ImportDateFormat.iso.date("2026-09-06"), month = MonthKey("2026-08")!
        doc.entries = [Entry(month: month, kind: .expense, amount: 10, currency: "EUR", label: "Synthetic")]
        let update = try await PublicPrices.performanceFX(document: doc, now: now, month: month, currencies: ["EUR", "GBP"], retry: true) { request in
            if request.identifier == "GBP" { throw PriceError.invalidResponse }
            return [FXObservation(sourceCurrency: "EUR", targetCurrency: "USD", rate: PreciseDecimal(Decimal(string: "1.25")!), providerTime: request.end.addingTimeInterval(-3 * 86400), fetchedAt: now, provider: "Synthetic")]
        }
        #expect(update.rates.count == 1 && update.fxIssues["GBP"] != nil && update.fxIssues["EUR"] == nil)
        #expect(update.coverage.filter(\.complete).count == 1)
        doc = try PriceHistory.applying(update, to: doc, now: now)
        #expect(MonthlyLedger.rate(currency: "EUR", month: month, document: doc, now: now) == Decimal(string: "1.25"))
    }

}

struct ChartScaleTests {
    @Test("Date labels keep measured bounds apart without losing timeline endpoints")
    func dateLabelSpacing() {
        for widths: [CGFloat] in [[35, 38, 35, 37, 36, 35, 37, 37, 35, 38, 35, 37], [18, 20, 19, 20, 18, 18, 20, 21], Array(repeating: 42, count: 72), [40]] {
            for width: CGFloat in [30, 80, 250, 600] {
                let ticks = UpOnlyChartAxis.ticks(widths: widths, plotWidth: width)
                for tick in ticks { #expect(tick.center - tick.width / 2 >= 0 && tick.center + tick.width / 2 <= width) }
                for (left, right) in zip(ticks, ticks.dropFirst()) {
                    #expect(left.center + left.width / 2 + 10 <= right.center - right.width / 2)
                }
                if width >= 250 { #expect(ticks.first?.index == 0 && ticks.last?.index == widths.count - 1) }
            }
        }
        #expect(UpOnlyChartAxis.ticks(widths: [], plotWidth: 250).isEmpty)
    }
    @Test("Chart scales retain losses, flat values and large all-time totals without crowded ticks")
    func readableBounds() {
        for values: [Decimal] in [[0, 4000], [-180, 50, 200], [-90000, -12000], [42, 42], [0, 0], [Decimal(string: "0.03")!, Decimal(string: "0.08")!], [12000, 12001], [Decimal(string: "45496.812")!, Decimal(string: "45496.819")!], [999999, 1000001], [999, 1001], [Decimal(string: "0.000001")!, Decimal(string: "0.000002")!]] {
            for zero in [true, false] {
                let scale = UpOnlyChartScale(values: values, includesZero: zero)
                #expect(scale.lower < scale.upper && scale.ticks.count >= 2 && scale.ticks.count <= 6)
                #expect(Set(scale.ticks.map(UpOnlyChartScale.label)).count == scale.ticks.count)
                #expect(scale.ticks.allSatisfy { $0.isFinite && $0 >= scale.lower && $0 <= scale.upper * (scale.upper > 0 ? 1.00000001 : 1) + 0.000001 })
                for value in values { #expect(scale.fraction(value) >= -0.000001 && scale.fraction(value) <= 1.000001) }
                if zero { #expect(scale.lower <= 0 && scale.upper >= 0) }
            }
        }
    }
    @Test("Chart labels use compact readable currency and preserve the sign")
    func labels() {
        #expect(UpOnlyChartScale.label(1500) == "$1.5k")
        #expect(UpOnlyChartScale.label(-1000) == "−$1k")
        #expect(UpOnlyChartScale.label(2_000_000) == "$2M")
        #expect(UpOnlyChartScale.label(0) == "$0")
    }
}

struct CoinSuggestionTests {
    @Test("Coin selection stays empty until typing and ranks exact matches before suggestions")
    func search() {
        let coins = ImportCoins.common + [CatalogCoin(id: "wrapped-bitcoin", symbol: "btc", name: "Wrapped Bitcoin")]
        #expect(ImportCoins.suggestions("  ", coins: coins).isEmpty)
        #expect(ImportCoins.suggestions(" BItCoin ", coins: coins).first?.id == "bitcoin")
        #expect(ImportCoins.suggestions("BTC", coins: coins).prefix(2).map(\.id) == ["bitcoin", "wrapped-bitcoin"])
        let lookalikes = coins + [CatalogCoin(id: "batcat", symbol: "btc", name: "batcat"), CatalogCoin(id: "big-tom-coin", symbol: "btc", name: "Big Tom Coin")]
        #expect(ImportCoins.suggestions("btc", coins: lookalikes).first?.id == "bitcoin")
        #expect(ImportCoins.suggestions("eth", coins: lookalikes + [CatalogCoin(id: "ethena-usde", symbol: "usde", name: "Ethena USDe")]).first?.id == "ethereum")
        #expect(ImportCoins.suggestions("bsv", coins: coins).first?.id == "bitcoin-cash-sv")
        #expect(Set(ImportCoins.common.map(\.id)).count == ImportCoins.common.count)
        #expect(ImportCoins.suggestions("no-such-coin", coins: coins).isEmpty)
        #expect(ImportCoins.suggestions("a", coins: (0..<20).map { CatalogCoin(id: "asset-\($0)", symbol: "a", name: "Asset \($0)") }).count == 8)
    }
}

#if UPONLY_FIXTURE
// Replies intentionally survive invalidate(), modelling callbacks already queued
// by the OS when the user changes authentication method or locks the app.
private final class DeferredUnlockAuthenticator: VaultAuthenticating, @unchecked Sendable {
    private let lock = NSLock()
    private var deferred = false
    private var replies: [CheckedContinuation<Void, Error>] = []
    var deferReplies: Bool {
        get { lock.withLock { deferred } }
        set { lock.withLock { deferred = newValue } }
    }
    var pendingCount: Int { lock.withLock { replies.count } }
    func evaluate() async throws {
        try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, Error>) in
            let immediate = lock.withLock {
                if deferred { replies.append(reply); return false }
                return true
            }
            if immediate { reply.resume() }
        }
    }
    func completeFirst(success: Bool) { complete(last: false, success: success) }
    func completeLast(success: Bool) { complete(last: true, success: success) }
    private func complete(last: Bool, success: Bool) {
        let reply = lock.withLock { last ? replies.removeLast() : replies.removeFirst() }
        if success { reply.resume() } else { reply.resume(throwing: VaultError.cancelled) }
    }
    nonisolated func invalidate() {}
    nonisolated var keychainContext: AnyObject? { nil }
}
#endif
