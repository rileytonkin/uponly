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
        // A month confirmed with "Nothing to record this month" stays done even with no transactions.
        doc.entries = []
        #expect(DataAttention.evaluate(doc, months: [month]).spendingMonths.isEmpty)
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
        #expect(model.attention(in: doc).spendingMonths.isEmpty)
        #expect(model.attention(in: doc, includePerformance: false).count == 0)
        model.selectPeriod(.annual)
        #expect(model.attention(in: doc).spendingMonths.isEmpty)
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
        // With no accounting, business rows are simply left out.
        let all = MonthlyLedger.evaluate(month, document: doc)
        #expect(all.unavailable == nil && all.totals?.net == 60)
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
    private func statementReview(_ csv: String) throws -> ImportEvaluation {
        var source = try ImportParser.source(bytes: Data(csv.utf8), filename: "sample.csv", mode: .statements)
        source.account = ImportAccount(name: "Checking")
        return ImportBatchProcessor.evaluate(ImportBatchDraft(mode: .statements, sources: [source], rows: try ImportParser.rows(source: source, mode: .statements)), document: empty())
    }
    @Test("Statement import rejects bad rows rather than silently skipping them")
    func statementValidation() throws {
        let header = "TransactionID,Date,Description,Amount,Currency,Type\n"
        let good = "sample-1,2025-01-02,Sample expense,12.50,USD,expense\n"
        let valid = try statementReview(header + good)
        let doc = try #require(valid.document)
        #expect(doc.entries.count == 1 && doc.entries[0].amount == Decimal(string: "12.50"))
        let badDate = try statementReview(header + good + "sample-2,2025-02-30,Bad date,10,USD,income\n")
        #expect(badDate.hasErrors && badDate.document == nil)
        let conflicting = try statementReview(header + good + "sample-1,2025-01-02,Sample expense,13,USD,expense\n")
        #expect(conflicting.hasErrors && conflicting.document == nil)
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
        let review = try statementReview("TransactionID,Date,Description,Amount,Currency,Type\nfirst,2025-01-01,Sample,10,USD,income\n")
        let doc = try #require(review.document)
        #expect(doc.entries[0].month == "2025-01" && doc.entries[0].day == "2025-01-01")
    }
    @Test("Personal income details exclude business income")
    @MainActor func consistentBreakdown() {
        var doc = empty(); let month = MonthKey.current()
        doc.entries = [Entry(month: month, kind: .income, amount: 100, currency: "USD", label: "Personal"), Entry(month: month, bucket: .otherBusiness, kind: .income, amount: 200, currency: "USD", label: "Business")]
        let model = PopoverModel(); model.replace(with: doc)
        #expect(model.state.totals?.personalIncome == 100)
        #expect(model.personalEntries.filter { $0.kind == .income }.map(\.amount) == [100])
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
        var source = try ImportParser.source(bytes: Data(csv.utf8), filename: "sample.csv", mode: mode)
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
        // Monzo's Transfers count by their sign until review says they're your own.
        #expect(saved.entries[1].kind == .income && !draft.rows[2].included)
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
        let paid = Entry(month: MonthKey("2026-05")!, kind: .expense, amount: 1200, currency: "GBP", label: "Sample Ltd", source: .csv, sourceRef: bank.id.uuidString + ":a")
        var edited = Entry(month: MonthKey("2026-05")!, kind: .expense, amount: 10, currency: "GBP", label: "sample ltd", source: .csv, sourceRef: bank.id.uuidString + ":b"); edited.kindIsUserEdited = true
        let manual = Entry(month: MonthKey("2026-05")!, kind: .expense, amount: 5, currency: "GBP", label: "Sample Ltd")
        doc.entries = [paid, edited, manual]
        OwnerPayments.setTransferCounterparty(" Sample Ltd ", enabled: true, in: &doc)
        #expect(doc.transferCounterparties == ["Sample Ltd"])
        #expect(doc.entries.map(\.kind) == [.transfer, .expense, .expense])
        #expect(OwnerPayments.isPersonalTransferCounterparty("SAMPLE LTD", document: doc))
        #expect(try MonthlyLedger.nativeTotals(MonthKey("2026-05")!, document: doc).first?.totals.moneyOut == 15)
        let draft = try batch("Date,Description,Amount,Currency\n2026-06-01,Sample Ltd,-300,GBP\n2026-06-02,Sample Cafe,-3,GBP", mode: .statements)
        let saved = try #require(ImportBatchProcessor.evaluate(draft, document: doc).document)
        #expect(saved.entries.suffix(2).map(\.kind) == [.transfer, .expense])
        doc.entries[0].kind = .expense
        OwnerPayments.reconcile(in: &doc)
        #expect(doc.entries[0].kind == .transfer)
        OwnerPayments.setTransferCounterparty("Sample Ltd", enabled: false, in: &doc)
        #expect(doc.transferCounterparties == nil && doc.entries[0].kind == .transfer)
    }
    @Test("Monzo refunds and cashback reduce spending instead of counting as income")
    func monzoRefunds() throws {
        let doc = empty()
        let csv = "id,created,title,subtitle,amount,currency,categories\ntx1,\"15/07/26, 10:00\",Airbnb,,-1000,GBP,Holidays\ntx2,\"29/07/26, 10:00\",Festival,,150.00,GBP,Entertainment\ntx3,\"23/07/26, 10:00\",Monzo Premium cashback,,0.05,GBP,Income\ntx4,\"30/07/26, 10:00\",ACME INC,,500.00,GBP,Income\ntx5,\"11/07/26, 10:00\",agoda.com,Declined,,,Holidays"
        let draft = try batch(csv, mode: .statements)
        #expect(draft.rows.map(\.included) == [true, true, true, true, false])
        let saved = try #require(ImportBatchProcessor.evaluate(draft, document: doc).document)
        #expect(saved.entries.map(\.kind) == [.expense, .refund, .refund, .income])
        let totals = try #require(MonthlyLedger.nativeTotals(MonthKey("2026-07")!, document: saved).first?.totals)
        #expect(totals.moneyIn == 500 && totals.moneyOut == Decimal(string: "849.95"))
        let typed = try batch("Date,Description,Amount,Currency,Type\n2026-07-01,Shop,20,USD,refund", mode: .statements)
        #expect(try #require(ImportBatchProcessor.evaluate(typed, document: doc).document).entries.first?.kind == .refund)
    }
    @Test("Month evidence gives one USD line per source, the biggest movements of any kind, and accounts that went quiet")
    func monthEvidence() {
        var doc = empty()
        let monzo = Account(name: "Monzo", currency: "GBP"), cardCo = Account(name: "Card Co", currency: "USD")
        var wise = Account(name: "Alex · GBP", currency: "GBP"); wise.externalProfileID = "7"
        doc.accounts = [monzo, cardCo, wise]
        let july = MonthKey("2026-07")!, august = MonthKey("2026-08")!
        doc.fx = [FXObservation(sourceCurrency: "GBP", targetCurrency: "USD", rate: PreciseDecimal(2), providerTime: Date(timeIntervalSince1970: 1_787_000_000), fetchedAt: Date(timeIntervalSince1970: 1_787_000_000), provider: "test")]
        doc.entries = [
            Entry(month: august, kind: .income, amount: 3000, currency: "GBP", label: "Example Studio Ltd", source: .csv, sourceRef: monzo.id.uuidString + ":1"),
            Entry(month: august, kind: .expense, amount: 1000, currency: "GBP", label: "Airbnb", source: .csv, sourceRef: monzo.id.uuidString + ":2"),
            Entry(month: august, kind: .refund, amount: 10, currency: "GBP", label: "Airbnb refund", source: .csv, sourceRef: monzo.id.uuidString + ":3"),
            Entry(month: august, kind: .transfer, amount: 2000, currency: "GBP", label: "Sample Co", source: .csv, sourceRef: monzo.id.uuidString + ":4"),
            Entry(month: august, kind: .expense, amount: 40, currency: "GBP", label: "Cafe", source: .wise, sourceRef: "wise:7:a"),
            Entry(month: august, kind: .expense, amount: 5, currency: "USD", label: "Cash"),
            Entry(month: july, kind: .expense, amount: 9, currency: "USD", label: "Old", source: .csv, sourceRef: cardCo.id.uuidString + ":9")
        ]
        let evidence = MonthEvidence.build(august, document: doc, now: Date(timeIntervalSince1970: 1_787_000_000))
        #expect(evidence.sources.map(\.name) == ["Monzo", "Wise · Alex", "Added by hand"])
        #expect(MonthEvidence.sourceName(for: doc.entries[4], accounts: [Account(name: "Personal · GBP", currency: "GBP", externalProfileID: "7")]).name == "Wise")
        #expect(evidence.sources[0].count == 3 && evidence.sources[0].moneyIn == 6000 && evidence.sources[0].moneyOut == 1980)
        #expect(evidence.sources[2].moneyIn == 0 && evidence.sources[2].moneyOut == 5)
        #expect(evidence.largest.map(\.entry.label) == ["Example Studio Ltd", "Sample Co", "Airbnb", "Cafe", "Airbnb refund", "Cash"])
        #expect(evidence.largest[1].usd == 4000)
        #expect(evidence.silent == ["Card Co"])
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
            let draft = try batch("\(idHeader),Date,\(descriptionHeader),Amount,Currency,Type\nexample,13/01/2026,Sample,-12.50,USD,CARD_PAYMENT", mode: .statements)
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
    @Test("A full Monzo export imports its signed amounts and categories, ignores Money in/out and skips zero rows")
    func monzoFullExport() throws {
        let header = "Transaction ID,Date,Time,Type,Name,Emoji,Category,Amount,Currency,Local amount,Local currency,Notes and #tags,Address,Receipt,Description,Category split,Money Out,Money In"
        func line(_ id: String, _ date: String, _ type: String, _ name: String, _ category: String, _ amount: String, out: String = "", in money: String = "") -> String {
            [id, date, "10:00:00", type, name, "", category, amount, "GBP", amount, "GBP", "", "", "", name.uppercased(), "", out, money].joined(separator: ",")
        }
        let csv = [header,
                   line("tx_1", "14/08/2026", "Card payment", "Pret", "eating_out", "-4.50", out: "-4.50"),
                   line("tx_2", "15/08/2026", "Faster payment", "Acme Ltd", "income", "2500.00", in: "2500.00"),
                   line("tx_3", "16/08/2026", "Pot transfer", "Savings", "savings", "-100.00", out: "-100.00"),
                   line("tx_4", "17/08/2026", "Card payment", "Tesco", "groceries", "12.00", in: "12.00"),
                   line("tx_5", "18/08/2026", "Card payment", "Active card check", "general", "0.00")].joined(separator: "\n")
        let source = try ImportParser.source(bytes: Data(csv.utf8), filename: "monzo.csv", mode: .statements)
        #expect(source.account.name == "Monzo" && source.account.currency == "GBP" && source.dateFormat == .dayFirst)
        #expect(source.mapping[.amount] == 7 && source.mapping[.debit] == nil && source.mapping[.credit] == nil && source.mapping[.type] == nil)
        let draft = ImportBatchDraft(mode: .statements, sources: [source], rows: try ImportParser.rows(source: source, mode: .statements))
        #expect(draft.rows.map(\.included) == [true, true, true, true, false])
        let saved = try #require(ImportBatchProcessor.evaluate(draft, document: empty()).document)
        #expect(saved.accounts.map(\.currency) == ["GBP"])
        #expect(saved.entries.map(\.kind) == [.expense, .income, .transfer, .refund])
        #expect(saved.entries.map(\.amount) == [Decimal(string: "4.50")!, 2500, 100, 12])
        #expect(saved.entries.map(\.outflow) == [true, false, true, false])
        // Money out written negative, as Monzo does, is still money out.
        var split = source; split.mapping[.amount] = nil; split.mapping[.debit] = 16; split.mapping[.credit] = 17
        let rows = Array(try ImportParser.rows(source: split, mode: .statements).prefix(4))
        let splitSaved = try #require(ImportBatchProcessor.evaluate(ImportBatchDraft(mode: .statements, sources: [split], rows: rows), document: empty()).document)
        #expect(splitSaved.entries.map(\.amount) == saved.entries.map(\.amount))
        // A lone "Transaction ID" column is not a Monzo export.
        #expect(!ImportParser.isMonzoExport(["Transaction ID", "Date", "Description", "Amount"]))
    }
    @Test("A Wise statement reads dd-MM-yyyy dates, and common date styles are detected")
    func wiseAndDateFormats() throws {
        let header = "TransferWise ID,Date,Amount,Currency,Description,Payment Reference,Running Balance,Exchange From,Exchange To,Exchange Rate,Payer Name,Payee Name,Payee Account Number,Merchant,Card Last Four Digits,Card Holder Full Name,Attachment,Note,Total fees"
        let rows = [["CARD-1", "05-08-2026", "-20.00", "EUR", "Card transaction of 20.00 EUR issued by Cafe", "", "480.00", "", "", "", "", "", "", "Cafe", "1234", "Alex", "", "", "0.00"],
                    ["TRANSFER-2", "31-07-2026", "500.00", "EUR", "Received money from Alex", "", "500.00", "", "", "", "Alex", "", "", "", "", "", "", "", "0.00"]]
        let csv = ([header] + rows.map { $0.joined(separator: ",") }).joined(separator: "\n")
        let source = try ImportParser.source(bytes: Data(csv.utf8), filename: "wise.csv", mode: .statements)
        #expect(source.dateFormat == .dayFirstDash && source.account.currency == "EUR" && source.account.name == "Wise")
        var draft = ImportBatchDraft(mode: .statements, sources: [source], rows: try ImportParser.rows(source: source, mode: .statements))
        // Without an account, the file is asked about once and its rows wait.
        draft.sources[0].account.name = ""
        let unassigned = ImportBatchProcessor.evaluate(draft, document: empty())
        #expect(unassigned.needsAccount == [source.id] && unassigned.sourceErrors[source.id] == "Choose an account for wise.csv." && unassigned.states.isEmpty && unassigned.document == nil)
        draft.sources[0].account.name = "Wise EUR"
        let saved = try #require(ImportBatchProcessor.evaluate(draft, document: empty()).document)
        #expect(saved.entries.map(\.month) == ["2026-08", "2026-07"] && saved.entries.map(\.kind) == [.expense, .income])
        #expect(saved.accounts.first?.currency == "EUR")
        let day = try ImportDateFormat.iso.date("2026-01-31")
        let styles: [(String, ImportDateFormat)] = [("31-01-2026", .dayFirstDash), ("31.01.2026", .dayFirstDot), ("31/1/2026", .dayFirst), ("1/31/2026", .monthFirst),
                                                    ("2026-01-31 13:45:00", .iso), ("2026-01-31T13:45:00Z", .iso), ("31/01/2026, 09:30", .dayFirst)]
        for (text, format) in styles { #expect(try format.date(text) == day) }
        #expect(throws: Error.self) { _ = try ImportDateFormat.dayFirst.date("30/02/2026") }
        #expect(throws: Error.self) { _ = try ImportDateFormat.iso.date("2026-01-31 later") }
        #expect(ImportDateFormat.detect(["31.01.2026", "1.2.2026"]) == .dayFirstDot)
        #expect(ImportDateFormat.detect(["2026-01-31", "13/01/2026"]) == nil)
        let generic = try ImportParser.source(bytes: Data("Date,Description,Amount\n31/01/2026,Rent,-500\n1/2/2026,Pay,900".utf8), filename: "bank.csv", mode: .statements)
        #expect(generic.dateFormat == .dayFirst)
    }
    @Test("Wise's transaction history imports completed rows only, adds fees to money out and splits by currency")
    func wiseTransactionHistory() throws {
        let header = "ID,Status,Direction,Created on,Finished on,Source fee amount,Source fee currency,Target fee amount,Target fee currency,Source name,Source amount (after fees),Source currency,Target name,Target amount (after fees),Target currency,Exchange rate,Reference,Batch,Created by,Category,Note"
        let lines = ["TRANSFER-1001,COMPLETED,OUT,2026-08-03 14:20:05,2026-08-03 14:23:11,0.45,EUR,,,Alex Example,120.00,EUR,Landlord GmbH,120.00,EUR,1,August rent,,Alex Example,Housing,",
                     "TRANSFER-1002,COMPLETED,IN,2026-07-31 09:00:00,2026-07-31 09:01:30,,,5.00,GBP,Acme Ltd,2505.00,GBP,Alex Example,2500.00,GBP,1,Invoice 42,,,,",
                     "BALANCE-1003,COMPLETED,NEUTRAL,2026-08-01 10:00:00,2026-08-01 10:00:02,1.20,EUR,,,Alex Example,498.80,EUR,Alex Example,430.00,GBP,0.862,,,Alex Example,,",
                     "TRANSFER-1004,CANCELLED,OUT,2026-08-02 08:00:00,,0.45,EUR,,,Alex Example,50.00,EUR,Someone,50.00,EUR,1,,,Alex Example,,",
                     "CARD_TRANSACTION-1005,REFUNDED,OUT,2026-08-04 12:00:00,2026-08-04 12:00:01,,,,,Alex Example,15.00,EUR,Cafe Blau,15.00,EUR,1,,,Alex Example,Eating out,",
                     "CARD_TRANSACTION-1006,COMPLETED,OUT,2026-06-30 23:59:59,,0.30,USD,,,Alex Example,9.50,GBP,,11.99,USD,1.262,Netflix,,Alex Example,Entertainment,"]
        let bytes = Data(([header] + lines).joined(separator: "\n").utf8)
        let sources = try ImportParser.sources(bytes: bytes, filename: "wise.csv", mode: .statements)
        #expect(sources.map(\.filename) == ["wise.csv · EUR", "wise.csv · GBP"] && sources.map(\.splitCurrency) == ["EUR", "GBP"])
        #expect(sources.map(\.account) == [ImportAccount(name: "Wise · EUR", currency: "EUR"), ImportAccount(name: "Wise · GBP", currency: "GBP")])
        #expect(sources.allSatisfy { $0.bytes == bytes && $0.dateFormat == .iso })
        let rows = try sources.flatMap { try ImportParser.rows(source: $0, mode: .statements) }
        // Cancelled and refunded rows are left out; a conversion leaves one balance and arrives in another.
        #expect(rows.map(\.statement.transactionID) == ["TRANSFER-1001", "BALANCE-1003:out", "TRANSFER-1002", "BALANCE-1003:in", "CARD_TRANSACTION-1006"])
        let saved = try #require(ImportBatchProcessor.evaluate(ImportBatchDraft(mode: .statements, sources: sources, rows: rows), document: empty()).document)
        #expect(saved.accounts.map(\.name) == ["Wise · EUR", "Wise · GBP"] && saved.accounts.map(\.currency) == ["EUR", "GBP"])
        // Money out includes a fee charged in its own currency (0.45 EUR, 1.20 EUR) but not one in another (0.30 USD).
        #expect(saved.entries.map(\.amount) == [Decimal(string: "120.45")!, 500, 2500, 430, Decimal(string: "9.5")!])
        #expect(saved.entries.map(\.currency) == ["EUR", "EUR", "GBP", "GBP", "GBP"])
        #expect(saved.entries.map(\.kind) == [.expense, .transfer, .income, .transfer, .expense])
        #expect(saved.entries.map(\.outflow) == [true, true, false, false, true])
        #expect(saved.entries.map(\.label) == ["Landlord GmbH", "Alex Example", "Acme Ltd", "Alex Example", "Netflix"])
        #expect(saved.entries.map(\.day) == ["2026-08-03", "2026-08-01", "2026-07-31", "2026-08-01", "2026-06-30"])
        #expect(saved.entries.map(\.month) == ["2026-08", "2026-08", "2026-07", "2026-08", "2026-06"])
        #expect(saved.entries.map(\.accountID) == [saved.accounts[0].id, saved.accounts[0].id, saved.accounts[1].id, saved.accounts[1].id, saved.accounts[1].id])
        // The file is archived once, and noted for the other account it covered.
        #expect(saved.importedStatements.map(\.originalBytes) == [bytes, Data()] && saved.importedStatements.compactMap(\.accountID) == saved.accounts.map(\.id))
        // An account chosen before picking the file applies only to the part in its currency.
        let joint = Account(name: "Joint", currency: "EUR")
        let chosen = ImportAccount(existingID: joint.id, name: joint.name, currency: joint.currency)
        #expect(sources.map { ImportParser.account(for: $0, preferred: chosen, saved: [joint] + saved.accounts).existingID } == [joint.id, saved.accounts[1].id])
        var mismatched = ImportBatchDraft(mode: .statements, sources: sources, rows: rows)
        mismatched.sources[1].account.currency = "EUR"
        let blocked = ImportBatchProcessor.evaluate(mismatched, document: empty())
        #expect(blocked.sourceErrors[sources[1].id] == "Choose an account in GBP for wise.csv · GBP." && blocked.document == nil)
        // The same export again adds nothing.
        var again = try ImportParser.sources(bytes: bytes, filename: "wise.csv", mode: .statements)
        for index in again.indices { again[index].account = ImportParser.account(for: again[index], preferred: ImportAccount(), saved: saved.accounts) }
        #expect(again.compactMap(\.account.existingID) == saved.accounts.map(\.id))
        let repeated = ImportBatchProcessor.evaluate(ImportBatchDraft(mode: .statements, sources: again, rows: try again.flatMap { try ImportParser.rows(source: $0, mode: .statements) }), document: saved)
        #expect(repeated.duplicates == 5 && repeated.added == 0 && !repeated.hasErrors)
        // A later export, in another column order and without Category and Note, overlaps the first: only its new row is added.
        let later = ["Status,ID,Direction,Finished on,Created on,Source currency,Source amount (after fees),Source fee amount,Source fee currency,Target fee amount,Target fee currency,Source name,Target name,Target currency,Target amount (after fees),Exchange rate,Reference,Batch,Created by",
                     "COMPLETED,TRANSFER-1001,OUT,2026-08-03 14:23:11,2026-08-03 14:20:05,EUR,120.00,0.45,EUR,,,Alex Example,Landlord GmbH,EUR,120.00,1,August rent,,Alex Example",
                     "COMPLETED,BALANCE-1003,NEUTRAL,2026-08-01 10:00:02,2026-08-01 10:00:00,EUR,498.80,1.20,EUR,,,Alex Example,Alex Example,GBP,430.00,0.862,,,Alex Example",
                     "COMPLETED,TRANSFER-1007,OUT,2026-08-20 08:00:00,2026-08-20 07:59:00,EUR,40.00,0,EUR,,,Alex Example,Bike shop,EUR,40.00,1,,,Alex Example"].joined(separator: "\n")
        var overlap = try ImportParser.sources(bytes: Data(later.utf8), filename: "wise-2.csv", mode: .statements)
        for index in overlap.indices { overlap[index].account = ImportParser.account(for: overlap[index], preferred: ImportAccount(), saved: saved.accounts) }
        let review = ImportBatchProcessor.evaluate(ImportBatchDraft(mode: .statements, sources: overlap, rows: try overlap.flatMap { try ImportParser.rows(source: $0, mode: .statements) }), document: saved)
        #expect(review.duplicates == 3 && review.readyRows == 1 && !review.hasErrors)
        #expect(review.document?.entries.count == 6 && review.document?.entries.last?.label == "Bike shop" && review.document?.entries.last?.amount == 40)
    }
    @Test("Other statements, including Wise's classic statement and Monzo's export, stay one source each")
    func singleSourceStatements() throws {
        let classic = "TransferWise ID,Date,Amount,Currency,Description,Payment Reference,Running Balance\nCARD-1,05-08-2026,-20.00,EUR,Card transaction of 20.00 EUR issued by Cafe,,480.00"
        let wise = try ImportParser.sources(bytes: Data(classic.utf8), filename: "statement.csv", mode: .statements)
        #expect(wise.count == 1 && wise[0].filename == "statement.csv" && wise[0].splitCurrency == nil)
        #expect(wise[0].account.name == "Wise" && wise[0].account.currency == "EUR" && wise[0].dateFormat == .dayFirstDash)
        let monzo = "id,created,title,subtitle,amount,currency,categories\na,\"02/01/26, 12:03\",Coffee,,-5,GBP,General"
        let search = try ImportParser.sources(bytes: Data(monzo.utf8), filename: "monzo.csv", mode: .statements)
        #expect(search.count == 1 && search[0].account.name == "Monzo" && search[0].dateFormat == .monzoSearch)
        let both = wise + search
        let saved = try #require(ImportBatchProcessor.evaluate(ImportBatchDraft(mode: .statements, sources: both, rows: try both.flatMap { try ImportParser.rows(source: $0, mode: .statements) }), document: empty()).document)
        #expect(saved.accounts.map(\.name) == ["Wise", "Monzo"] && saved.entries.map(\.amount) == [20, 5] && saved.entries.map(\.kind) == [.expense, .expense])
    }
    @Test("Semicolon and tab files, Windows-1252 and UTF-16 text are read")
    func delimitersAndEncodings() throws {
        var source = try ImportParser.source(bytes: Data("Datum;Beschreibung;Amount;Currency\n31.01.2026;Miete;-1.250,00;EUR\n01.02.2026;Gehalt;2.500,50;EUR".utf8), filename: "bank.csv", mode: .statements)
        #expect(source.grid[1] == ["31.01.2026", "Miete", "-1.250,00", "EUR"])
        source.mapping = [.date: 0, .description: 1, .amount: 2, .currency: 3]; source.dateFormat = .dayFirstDot
        source.numberFormat = .comma; source.account = ImportAccount(name: "Girokonto", currency: "EUR")
        let saved = try #require(ImportBatchProcessor.evaluate(ImportBatchDraft(mode: .statements, sources: [source], rows: try ImportParser.rows(source: source, mode: .statements)), document: empty()).document)
        #expect(saved.entries.map(\.amount) == [1250, Decimal(string: "2500.5")!] && saved.entries.map(\.kind) == [.expense, .income])
        let tabbed = try ImportParser.source(bytes: Data("Account\tCurrency\tBalance\nChecking\tUSD\t1,250.00".utf8), filename: "balances.txt", mode: .bankBalances)
        #expect(tabbed.grid[1] == ["Checking", "USD", "1,250.00"] && tabbed.hasHeader)
        let latin = try ImportParser.source(bytes: try #require("Date,Description,Amount\n2026-01-02,£5 voucher,-5".data(using: .windowsCP1252)), filename: "uk.csv", mode: .statements)
        #expect(latin.grid[1][1] == "£5 voucher")
        let unicode = try ImportParser.source(bytes: try #require("Date\tDescription\tAmount\n2026-01-02\tCafé\t-5".data(using: .utf16)), filename: "excel.txt", mode: .statements)
        #expect(unicode.grid[0] == ["Date", "Description", "Amount"] && unicode.grid[1] == ["2026-01-02", "Café", "-5"])
    }
    @Test("Numbers accept signs, brackets and spaced thousands, and 0,125 is never 125")
    func numberVariants() throws {
        let cases: [(String, ImportNumberFormat, String)] = [
            ("+12.34", .point, "12.34"), ("(12.34)", .point, "-12.34"), ("12.34-", .point, "-12.34"), ("\u{2212}12.34", .point, "-12.34"),
            ("1 234,56", .comma, "1234.56"), ("1\u{00A0}234,56", .comma, "1234.56"), ("1'234.56", .point, "1234.56"), ("1 234 567", .point, "1234567")
        ]
        for (text, format, value) in cases { #expect(try format.decimal(text) == Decimal(string: value)!) }
        for invalid in ["0,125", "00,125", "-0,125", "1,2,3", "--5", "(5", "12,5.0"] {
            #expect(throws: Error.self) { _ = try ImportNumberFormat.point.decimal(invalid) }
        }
        #expect(throws: Error.self) { _ = try ImportNumberFormat.comma.decimal("0.125") }
        // Typed by hand, a lone separator that can't group thousands is the decimal mark; only 1,250 follows the format.
        #expect(try ImportNumberFormat.point.decimal("0,125", typed: true) == Decimal(string: "0.125")!)
        #expect(try ImportNumberFormat.point.decimal("12,50", typed: true) == Decimal(string: "12.5")!)
        #expect(try ImportNumberFormat.point.decimal("1,2345", typed: true) == Decimal(string: "1.2345")!)
        #expect(try ImportNumberFormat.point.decimal("1,250", typed: true) == 1250)
        #expect(try ImportNumberFormat.comma.decimal("1.250", typed: true) == 1250)
        #expect(try ImportNumberFormat.comma.decimal("0.5", typed: true) == Decimal(string: "0.5")!)
        // The guided form saves what it reads: 0,125 BTC is 0.125.
        let manual = ImportSourceDraft(filename: "Manual entry", bytes: Data(), grid: [])
        let row = ImportDraftRow(sourceID: manual.id, line: 1, content: .holding(HoldingInput(portfolioName: "Ledger", coin: "bitcoin", resolvedCoinID: "bitcoin", assetName: "Bitcoin", quantity: "0,125")))
        let saved = try #require(ImportBatchProcessor.evaluate(ImportBatchDraft(mode: .holdings, sources: [manual], rows: [row]), document: empty()).document)
        let holding = try #require(saved.holdings.first)
        #expect(saved.effectiveQuantity(holdingID: holding.id, at: Date()) == Decimal(string: "0.125")!)
    }
    @Test("Income or expense follows the amount as finally read, after the number format changes")
    func kindFollowsNumberFormat() throws {
        var draft = try batch("Date,Description,Amount,Currency\n2026-01-02,Salary,\"2500,00\",EUR\n2026-01-03,Coffee,\"-12,50\",EUR", mode: .statements)
        // Decimal commas are detected; read with decimal points instead, the amounts are wrong.
        #expect(draft.sources[0].numberFormat == .comma)
        draft.sources[0].numberFormat = .point
        #expect(ImportBatchProcessor.evaluate(draft, document: empty()).hasErrors)
        draft.sources[0].numberFormat = .comma
        let saved = try #require(ImportBatchProcessor.evaluate(draft, document: empty()).document)
        #expect(saved.entries.map(\.kind) == [.income, .expense] && saved.entries.map(\.amount) == [2500, Decimal(string: "12.5")!])
    }
    @Test("Typed transfers take their direction from the sign; unsigned ones stay out of balance history")
    func transferDirection() throws {
        let draft = try batch("TransactionID,Date,Description,Amount,Currency,Type\nt1,2026-03-01,To savings,-500,USD,transfer\nt2,2026-03-02,From savings,200,USD,transfer\nt3,2026-03-03,Rent,900,USD,expense\nt4,2026-03-04,Refund,-5,USD,refund", mode: .statements)
        let failed = ImportBatchProcessor.evaluate(draft, document: empty())
        #expect(failed.hasErrors && failed.states[draft.rows[3].id]?.blocksSave == true)
        var fixed = draft; fixed.rows.removeLast()
        let saved = try #require(ImportBatchProcessor.evaluate(fixed, document: empty()).document)
        #expect(saved.entries.map(\.kind) == [.transfer, .transfer, .expense] && saved.entries.map(\.amount) == [500, 200, 900])
        #expect(saved.entries.map(\.outflow) == [true, nil, true])
        #expect(saved.entries.map(BalanceReconstruction.signed) == [-500, nil, -900])
    }
    @Test("A holding total dated today is saved as now, so an edit earlier the same day can't override it")
    func sameDayHolding() throws {
        let now = Date()
        var doc = empty()
        let portfolio = Portfolio(name: "Ledger", createdAt: now.addingTimeInterval(-86400 * 30)); doc.portfolios = [portfolio]
        doc = try HoldingMutations.addHolding(portfolioID: portfolio.id, assetID: CanonicalAssetID("bitcoin"), assetName: "Bitcoin", quantity: 1, at: now.addingTimeInterval(-86400 * 10), document: doc)
        let holding = try #require(doc.holdings.first)
        // An edit earlier today, as Manage makes it (late in the evening west of UTC, at the day's last second, like this one).
        doc = try HoldingMutations.setQuantity(holdingID: holding.id, quantity: 2, at: UTCDay.moment(for: UTCDay.today(now: now), now: now.addingTimeInterval(-60)), document: doc)
        var draft = try batch("Portfolio\tCoin\tQuantity\nLedger\tbitcoin\t3", mode: .holdings)
        draft.rows[0].holding.portfolioID = portfolio.id
        let saved = try #require(ImportBatchProcessor.evaluate(draft, document: doc, now: now).document)
        #expect(saved.effectiveQuantity(holdingID: holding.id, at: now) == 3)
        // Going back to the start-of-day total is a change, not "already saved".
        draft.rows[0].holding.quantity = "1"
        let restored = ImportBatchProcessor.evaluate(draft, document: doc, now: now)
        #expect(restored.duplicates == 0 && restored.document?.effectiveQuantity(holdingID: holding.id, at: now) == 1)
    }
    @Test("At 11:30 pm in Buenos Aires, already tomorrow in UTC, today's holding and balance are saved under today and tomorrow is refused")
    func localEvening() throws {
        let buenosAires = TimeZone(identifier: "America/Argentina/Buenos_Aires")!
        let sep24 = try ImportDateFormat.iso.date("2026-09-24"), now = sep24.addingTimeInterval(26.5 * 3600)
        var draft = try batch("Portfolio\tCoin\tQuantity\nLedger\tbitcoin\t1", mode: .holdings)
        draft.rows[0].holding.date = "2026-09-24"; draft.rows[0].holding.paid = "60000"
        let saved = try #require(ImportBatchProcessor.evaluate(draft, document: empty(), now: now, timeZone: buenosAires, catalog: []).document)
        let observed = try #require(saved.quantities.first?.effectiveAt)
        #expect(UTCDay.start(of: observed) == sep24 && observed <= now)
        #expect(saved.purchases?.first.map { ImportDateFormat.today($0.at) } == "2026-09-24")
        let holding = try #require(saved.holdings.first)
        #expect(saved.effectiveQuantity(holdingID: holding.id, at: now) == 1)
        // Sep 25 is tomorrow there, though it's today in UTC.
        draft.rows[0].holding.date = "2026-09-25"
        #expect(ImportBatchProcessor.evaluate(draft, document: empty(), now: now, timeZone: buenosAires, catalog: []).hasErrors)
        // A balance saved twice that evening: both fall on the day's last second, and the newer replaces the older.
        let first = try batch("Account,Currency,Balance,ObservedOn\nChecking,USD,100,2026-09-24", mode: .bankBalances)
        let one = try #require(ImportBatchProcessor.evaluate(first, document: empty(), now: now, timeZone: buenosAires).document)
        #expect(one.bankBalances.map { UTCDay.start(of: $0.observedAt) } == [sep24])
        var second = try batch("Account,Currency,Balance,ObservedOn\nChecking,USD,120,2026-09-24", mode: .bankBalances)
        let checking = try #require(one.accounts.first)
        second.rows[0].bank.account = ImportAccount(existingID: checking.id, name: checking.name, currency: "USD")
        let two = try #require(ImportBatchProcessor.evaluate(second, document: one, now: now.addingTimeInterval(600), timeZone: buenosAires).document)
        #expect(two.bankBalances.map(\.amount.value) == [120])
    }
    @Test("Restating a total and its cost on the same day replaces that day's purchase lot")
    func restatedLot() throws {
        var draft = try batch("Portfolio\tCoin\tQuantity\nLedger\tbitcoin\t1", mode: .holdings)
        draft.rows[0].holding.date = "2026-03-10"; draft.rows[0].holding.paid = "30000"
        let saved = try #require(ImportBatchProcessor.evaluate(draft, document: empty()).document)
        draft.rows[0].holding.portfolioID = saved.portfolios[0].id
        #expect(ImportBatchProcessor.evaluate(draft, document: saved).duplicates == 1)
        draft.rows[0].holding.paid = "32000"
        let corrected = try #require(ImportBatchProcessor.evaluate(draft, document: saved).document)
        #expect(corrected.purchases?.count == 1 && corrected.purchases?[0].paid.value == 32000 && corrected.purchases?[0].id == saved.purchases?[0].id)
    }
    @Test("An account set to Personal keeps its imported rows personal and still matches by name")
    func personalOwnerSentinel() throws {
        var doc = empty()
        let account = Account(name: "Monzo", currency: "GBP", ownerBusinessID: ""); doc.accounts = [account]
        var draft = try batch("Date,Description,Amount,Currency\n2026-03-02,Coffee,-4,GBP", mode: .statements)
        draft.sources[0].account = ImportAccount(existingID: account.id, name: account.name, currency: account.currency)
        let saved = try #require(ImportBatchProcessor.evaluate(draft, document: doc).document)
        #expect(saved.entries.first?.bucket == .personal)
        let search = try ImportParser.source(bytes: Data("id,created,title,subtitle,amount,currency,categories\na,\"02/01/26, 12:03\",Coffee,,-5,GBP,General".utf8), filename: "monzo.csv", mode: .statements)
        #expect(ImportParser.account(for: search, preferred: ImportAccount(), saved: [account]).existingID == account.id)
    }
    @Test("A bank's own Type column is ignored unless every value is an Up Only type, and a reference is not an ID")
    func typeColumnGating() throws {
        let chase = try batch("Date,Description,Amount,Type\n2026-03-02,Coffee,-4,DEBIT_CARD\n2026-03-03,Payroll,1200,ACH_CREDIT", mode: .statements)
        #expect(chase.sources[0].mapping[.type] == nil)
        let saved = try #require(ImportBatchProcessor.evaluate(chase, document: empty()).document)
        #expect(saved.entries.map(\.kind) == [.expense, .income])
        let typed = try batch("Date,Description,Amount,Type\n2026-03-02,Coffee,4,expense\n2026-03-03,Payroll,1200,", mode: .statements)
        #expect(typed.sources[0].mapping[.type] == 3)
        #expect(try #require(ImportBatchProcessor.evaluate(typed, document: empty()).document).entries.map(\.kind) == [.expense, .income])
        let rent = try batch("Date,Description,Amount,Reference\n2026-02-01,Rent,-900,RENT\n2026-03-01,Rent,-900,RENT", mode: .statements)
        #expect(rent.sources[0].mapping[.transactionID] == nil && !ImportBatchProcessor.evaluate(rent, document: empty()).hasErrors)
        // One familiar word in a row of data doesn't make it a header.
        let headerless = try batch("2026-01-02,Deposit,100.00,USD", mode: .statements)
        #expect(!headerless.sources[0].hasHeader && headerless.sources[0].mapping[.amount] == 2)
    }
    @Test("Blank rows are dropped, a trailing delimiter is harmless, and zero amounts are left out")
    func blankAndRaggedRows() throws {
        #expect(try CSVReader.parse("A,B\n1,2\n,\n , \n\n3,4\n") == [["A", "B"], ["1", "2"], ["3", "4"]])
        let draft = try batch("Date,Description,Amount,Currency\n2026-01-02,Coffee,-4,USD,\n2026-01-03,Lunch,-9,USD,\n,,,,\n", mode: .statements)
        #expect(draft.rows.count == 2 && draft.rows.allSatisfy { $0.parseError == nil })
        #expect(!ImportBatchProcessor.evaluate(draft, document: empty()).hasErrors)
        #expect(try batch("Date,Description,Amount,Currency\n2026-01-02,Coffee", mode: .statements).rows.first?.parseError != nil)
        #expect(try batch("Date,Description,Amount,Currency\n2026-01-02,Coffee, large,-4,USD", mode: .statements).rows.first?.parseError != nil)
        var zero = try batch("Date,Description,Amount,Currency\n2026-01-02,Card check,0.00,USD", mode: .statements)
        #expect(zero.rows.first?.included == false)
        zero.rows[0].included = true
        #expect(ImportBatchProcessor.evaluate(zero, document: empty()).hasErrors)
        // The row limit counts data rows, not the header.
        #expect(try CSVReader.parse("A\n" + Array(repeating: "1", count: 20000).joined(separator: "\n") + "\n").count == 20001)
    }
    @Test("Updating all balances records only the accounts that changed")
    func updateAllBalances() throws {
        var doc = empty()
        let checking = Account(name: "Checking", currency: "USD"), savings = Account(name: "Savings", currency: "USD"); doc.accounts = [checking, savings]
        let then = Date().addingTimeInterval(-86400 * 40)
        doc.bankBalances = [checking, savings].map { BankBalanceObservation(id: UUID(), accountID: $0.id, amount: PreciseDecimal(100), currency: "USD", observedAt: then, source: "Import", sourceIdentity: $0.id.uuidString) }
        let manual = ImportSourceDraft(filename: "Current balances", bytes: Data(), grid: [])
        let rows = [(checking, "100"), (savings, "250")].enumerated().map { index, item in
            ImportDraftRow(sourceID: manual.id, line: index + 1, content: .bankBalance(BankBalanceInput(account: ImportAccount(existingID: item.0.id, name: item.0.name, currency: "USD"), balance: item.1)))
        }
        let review = ImportBatchProcessor.evaluate(ImportBatchDraft(mode: .bankBalances, sources: [manual], rows: rows), document: doc)
        #expect(review.duplicates == 1 && review.readyRows == 1)
        #expect(review.document?.bankBalances.filter { $0.accountID == checking.id }.count == 1)
    }
    @Test("Day-first or month-first dates are decided by the only reading that's in order, and review asks when both are")
    func ambiguousDates() throws {
        // 1–12 September reads in order either way (as 9 January–9 December too), so the shorter span is only a guess.
        let september = (1...12).map { String(format: "%02d/09/2025", $0) }
        #expect(ImportDateFormat.detection(september).map { $0.format == .dayFirst && $0.unconfirmed == "01/09/2025" } == true)
        #expect(ImportDateFormat.detection(Array(september.reversed())).map { $0.format == .dayFirst && $0.unconfirmed == "12/09/2025" } == true)
        var uk = try batch("Date,Description,Amount,Currency\n" + september.map { $0 + ",Coffee,-3,USD" }.joined(separator: "\n"), mode: .statements)
        #expect(uk.sources[0].dateFormat == .dayFirst && uk.sources[0].unconfirmedDate == "01/09/2025")
        #expect(ImportBatchProcessor.evaluate(uk, document: empty()).needsFormat == [uk.sources[0].id])
        uk.sources[0].unconfirmedDate = nil
        let saved = try #require(ImportBatchProcessor.evaluate(uk, document: empty()).document)
        #expect(saved.entries.compactMap(\.day) == (1...12).map { String(format: "2025-09-%02d", $0) })
        // A day past the 12th has only one reading.
        #expect(ImportDateFormat.detection(september + ["13/09/2025"]).map { $0.format == .dayFirst && $0.unconfirmed == nil } == true)
        // Interest on the 12th of each month is in order either way too; in order one way only is enough.
        #expect(ImportDateFormat.detection(["12/01/2025", "12/02/2025", "12/03/2025"]).map { $0.format == .monthFirst && $0.unconfirmed == "12/01/2025" } == true)
        #expect(ImportDateFormat.detection(["02/01/2025", "01/02/2025", "03/02/2025"]).map { $0.format == .dayFirst && $0.unconfirmed == nil } == true)
        // Dates that read the same either way need no question.
        #expect(ImportDateFormat.detection(["05/05/2025", "07/07/2025"]).map { $0.unconfirmed == nil } == true)
        // One row reads either way, so its file's card asks before anything is saved.
        var single = try batch("Date,Description,Amount,Currency\n03/04/2025,Coffee,-3,USD", mode: .statements)
        #expect(single.sources[0].unconfirmedDate == "03/04/2025")
        let waiting = ImportBatchProcessor.evaluate(single, document: empty())
        #expect(waiting.needsFormat == [single.sources[0].id] && waiting.document == nil)
        single.sources[0].dateFormat = .monthFirst; single.sources[0].unconfirmedDate = nil
        #expect(try #require(ImportBatchProcessor.evaluate(single, document: empty()).document).entries.first?.day == "2025-03-04")
    }
    @Test("The number format is read from the amounts, then a semicolon or other columns, and review asks when nothing tells")
    func numberDetection() throws {
        let comma = try batch("Date,Description,Amount\n2026-01-02,Rent,\"-1.250,00\"\n2026-01-03,Coffee,\"-3,50\"", mode: .statements)
        #expect(comma.sources[0].numberFormat == .comma && comma.sources[0].unconfirmedNumber == nil)
        let point = try batch("Date,Description,Amount\n2026-01-02,Rent,\"-1,250.00\"\n2026-01-03,Coffee,-3.50", mode: .statements)
        #expect(point.sources[0].numberFormat == .point && point.sources[0].unconfirmedNumber == nil)
        // 1.250 reads both ways: a semicolon file means decimal commas, and so does a balance written 8.750,50.
        let semicolon = try batch("Date;Description;Amount\n2026-01-02;Rent;-1.250\n2026-01-03;Coffee;-3", mode: .statements)
        #expect(semicolon.sources[0].numberFormat == .comma && semicolon.sources[0].unconfirmedNumber == nil)
        #expect(try #require(ImportBatchProcessor.evaluate(semicolon, document: empty()).document).entries.map(\.amount) == [1250, 3])
        let balance = try batch("Date,Description,Amount,Balance\n2026-01-02,Rent,-1.250,\"8.750,50\"", mode: .statements)
        #expect(balance.sources[0].numberFormat == .comma && balance.sources[0].unconfirmedNumber == nil)
        // With nothing to go on, review asks.
        var unclear = try batch("Date,Description,Amount\n2026-01-02,Rent,-1.250\n2026-01-03,Coffee,-3", mode: .statements)
        #expect(unclear.sources[0].numberFormat == .point && unclear.sources[0].unconfirmedNumber == "-1.250")
        #expect(ImportBatchProcessor.evaluate(unclear, document: empty()).needsFormat == [unclear.sources[0].id])
        unclear.sources[0].numberFormat = .comma; unclear.sources[0].unconfirmedNumber = nil
        #expect(try #require(ImportBatchProcessor.evaluate(unclear, document: empty()).document).entries.map(\.amount) == [1250, 3])
        // Whole numbers read the same either way.
        #expect(try batch("Date,Description,Amount\n2026-01-02,Rent,-900", mode: .statements).sources[0].unconfirmedNumber == nil)
    }
    @Test("Card exports whose purchases are positive read as money out, and a type chosen in review sets the direction")
    func positiveMoneyOut() throws {
        // American Express's Card Member column, or a column headed Charges, marks a card export.
        let amex = try batch("Date,Description,Card Member,Account #,Amount\n2026-01-02,Coffee,A EXAMPLE,-11001,4.50\n2026-01-05,Payment received,A EXAMPLE,-11001,-200.00", mode: .statements)
        #expect(amex.sources[0].positiveIsOutflow)
        let saved = try #require(ImportBatchProcessor.evaluate(amex, document: empty()).document)
        #expect(saved.entries.map(\.kind) == [.expense, .income] && saved.entries.map(\.outflow) == [true, false] && saved.entries.map(\.amount) == [Decimal(string: "4.5")!, 200])
        let charges = try batch("Date,Description,Charges\n2026-01-02,Coffee,4.50", mode: .statements)
        #expect(charges.sources[0].mapping[.amount] == 2 && charges.sources[0].positiveIsOutflow)
        // Beside a Credits column, Charges are money out.
        let split = try batch("Date,Description,Charges,Credits\n2026-01-02,Coffee,4.50,\n2026-01-03,Payment,,200", mode: .statements)
        #expect(split.sources[0].mapping[.debit] == 2 && split.sources[0].mapping[.credit] == 3 && split.sources[0].mapping[.amount] == nil)
        #expect(try #require(ImportBatchProcessor.evaluate(split, document: empty()).document).entries.map(\.outflow) == [true, false])
        // Any other file can be switched, which doesn't change which rows count as already saved.
        var generic = try batch("Date,Description,Amount\n2026-01-02,Coffee,4.50\n2026-01-03,Payment,-200", mode: .statements)
        #expect(!generic.sources[0].positiveIsOutflow && !ImportParser.signsKnown(generic.sources[0].grid))
        // A negative payment doesn't say which way its purchases go, so review shows what the new rows add up to.
        let asRead = ImportBatchProcessor.evaluate(generic, document: empty())
        #expect(asRead.flows == ["USD": ImportEvaluation.MoneyFlow(moneyIn: Decimal(string: "4.5")!, moneyOut: 200)])
        let asWritten = try #require(asRead.document)
        generic.sources[0].positiveIsOutflow = true
        let flippedReview = ImportBatchProcessor.evaluate(generic, document: empty())
        #expect(flippedReview.flows == ["USD": ImportEvaluation.MoneyFlow(moneyIn: 200, moneyOut: Decimal(string: "4.5")!)])
        let flipped = try #require(flippedReview.document)
        #expect(flipped.entries.map(\.kind) == [.expense, .income] && flipped.entries.map(\.importFingerprint) == asWritten.entries.map(\.importFingerprint))
        // A type chosen in review sets the direction: an expense is money out whatever its sign.
        var edited = try batch("Date,Description,Amount\n2026-01-02,Coffee,4.50", mode: .statements)
        edited.rows[0].statement.kind = .expense; edited.rows[0].statement.kindIsUserEdited = true
        let entry = try #require(ImportBatchProcessor.evaluate(edited, document: empty()).document?.entries.first)
        #expect(entry.kind == .expense && entry.outflow == true && BalanceReconstruction.signed(entry) == Decimal(string: "-4.5")!)
    }
    @Test("Rows without IDs skip as many identical rows as are saved and ask only about extra copies, which can be settled at once")
    func countedDuplicates() throws {
        let first = try batch("Date,Description,Amount,Currency\n2026-01-02,Coffee,-5,USD", mode: .statements)
        let saved = try #require(ImportBatchProcessor.evaluate(first, document: empty()).document)
        let account = ImportAccount(existingID: saved.accounts[0].id, name: saved.accounts[0].name, currency: "USD")
        // A later export repeats the saved coffee, has a second one that day, and a new lunch.
        var overlap = try batch("Date,Description,Amount,Currency\n2026-01-02,Coffee,-5,USD\n2026-01-02,Coffee,-5,USD\n2026-01-03,Lunch,-9,USD", mode: .statements)
        overlap.sources[0].account = account
        let review = ImportBatchProcessor.evaluate(overlap, document: saved)
        #expect(review.states[overlap.rows[0].id] == .duplicate && review.states[overlap.rows[1].id] == .possibleDuplicate && review.states[overlap.rows[2].id] == .ready("New transaction"))
        #expect(review.possibleDuplicates == 1 && review.document == nil)
        var kept = overlap; kept.settleDuplicates(review, keep: true)
        let both = try #require(ImportBatchProcessor.evaluate(kept, document: saved).document)
        #expect(both.entries.map(\.label) == ["Coffee", "Coffee", "Lunch"])
        var skipped = overlap; skipped.settleDuplicates(review, keep: false)
        #expect(!skipped.rows[1].included && ImportBatchProcessor.evaluate(skipped, document: saved).document?.entries.count == 2)
        // With both coffees saved, the same rows again need no decision.
        var again = try batch("Date,Description,Amount,Currency\n2026-01-02,Coffee,-5,USD\n2026-01-02,Coffee,-5,USD", mode: .statements)
        again.sources[0].account = account
        let repeated = ImportBatchProcessor.evaluate(again, document: both)
        #expect(repeated.duplicates == 2 && !repeated.hasErrors)
        // An export format that adds IDs doesn't double up rows saved without them; its extra rows are new.
        var withIDs = try batch("TransactionID,Date,Description,Amount,Currency\na,2026-01-02,Coffee,-5,USD\nb,2026-01-02,Coffee,-5,USD\nc,2026-01-02,Coffee,-5,USD", mode: .statements)
        withIDs.sources[0].account = account
        let identified = ImportBatchProcessor.evaluate(withIDs, document: both)
        #expect(identified.duplicates == 2 && identified.readyRows == 1 && !identified.hasErrors)
        // Two overlapping files in one batch add each payment once.
        var pair = try batch("Date,Description,Amount,Currency\n2026-02-02,Tea,-3,USD", mode: .statements)
        let second = try batch("Date,Description,Amount,Currency\n2026-02-02,Tea,-3,USD\n2026-02-03,Cake,-4,USD", mode: .statements)
        pair.sources += second.sources; pair.rows += second.rows
        let merged = try #require(ImportBatchProcessor.evaluate(pair, document: empty()).document)
        #expect(merged.entries.map(\.label) == ["Tea", "Cake"])
    }
    @Test("An original file is archived once, older duplicate copies are dropped, and past the budget only its hash is kept")
    func archiveOnce() throws {
        var doc = empty()
        let bytes = Data("Date,Description,Amount,Currency\n2026-01-02,Old,-1,USD".utf8), digest = VaultCrypto.sha256(bytes)
        let one = Account(name: "One", currency: "USD"), two = Account(name: "Two", currency: "USD"); doc.accounts = [one, two]
        doc.importedStatements = [one, two].map { ImportedStatement(digest: digest, originalBytes: bytes, importedAt: Date(), accountID: $0.id) }
        var draft = try batch("Date,Description,Amount,Currency\n2026-01-03,Coffee,-4,USD", mode: .statements)
        draft.sources[0].account = ImportAccount(existingID: one.id, name: one.name, currency: "USD")
        let saved = try #require(ImportBatchProcessor.evaluate(draft, document: doc).document)
        #expect(saved.importedStatements.filter { $0.digest == digest }.map(\.originalBytes) == [bytes, Data()])
        #expect(saved.importedStatements.last?.originalBytes == draft.sources[0].bytes && saved.importedStatements.last?.accountID == one.id)
        // The same file for another account is noted there without storing it again.
        var other = draft; other.sources[0].account = ImportAccount(existingID: two.id, name: two.name, currency: "USD")
        let noted = try #require(ImportBatchProcessor.evaluate(other, document: saved).document)
        #expect(noted.importedStatements.filter { $0.digest == draft.sources[0].digest }.map(\.originalBytes) == [draft.sources[0].bytes, Data()])
        // Past the budget, a new file's transactions still import and only its hash is kept.
        var full = empty()
        full.importedStatements = [ImportedStatement(digest: Data([1]), originalBytes: Data(count: ImportBatchProcessor.archiveBudget), importedAt: Date())]
        let review = ImportBatchProcessor.evaluate(try batch("Date,Description,Amount,Currency\n2026-01-03,Coffee,-4,USD", mode: .statements), document: full)
        #expect(review.unarchivedFiles == 1 && review.document?.entries.count == 1 && review.document?.importedStatements.last?.originalBytes.isEmpty == true)
    }
    @Test("A statement row or balance dated today anywhere on Earth is accepted, even when it's already tomorrow in UTC")
    func todayEastOfUTC() throws {
        let day = try ImportDateFormat.iso.date("2026-03-10"), evening = day.addingTimeInterval(22 * 3600)
        var draft = try batch("Date,Description,Amount,Currency\n2026-03-11,Coffee,-4,USD", mode: .statements)
        #expect(ImportBatchProcessor.evaluate(draft, document: empty(), now: evening).document?.entries.first?.day == "2026-03-11")
        // The limit is the end of today in UTC+14, where 11 March begins at 10:00 UTC on the 10th.
        #expect(ImportBatchProcessor.evaluate(draft, document: empty(), now: day.addingTimeInterval(10 * 3600 - 60)).hasErrors)
        #expect(!ImportBatchProcessor.evaluate(draft, document: empty(), now: day.addingTimeInterval(10 * 3600)).hasErrors)
        draft.rows[0].statement.date = "2026-03-12"
        #expect(ImportBatchProcessor.evaluate(draft, document: empty(), now: evening).hasErrors)
        // A balance dated today there is observed now.
        let balances = try batch("Account,Currency,Balance,ObservedOn\nChecking,USD,100,2026-03-11", mode: .bankBalances)
        let doc = try #require(ImportBatchProcessor.evaluate(balances, document: empty(), now: evening).document)
        #expect(doc.bankBalances.first?.observedAt == evening)
    }
    @Test("Spaces around quoted fields and quotes inside unquoted ones are read rather than rejecting the file")
    func lenientQuotes() throws {
        #expect(try CSVReader.parse("A,B,C\n \"x,y\" , 5\" screen ,\"z\"\n") == [["A", "B", "C"], ["x,y", " 5\" screen ", "z"]])
        #expect(try CSVReader.parse("a,b\"c\"d,\"Best\" coffee") == [["a", "b\"c\"d", "Best coffee"]])
        #expect(throws: StatementError.self) { _ = try CSVReader.parse("A,B\n\"unfinished") }
        // A stray quote in the first line doesn't hide its delimiters.
        #expect(ImportParser.delimiter("12\" pizza;9;x\nb;c;d") == ";")
        let draft = try batch("Date, Description, Amount, Currency\n2026-01-02, \"Coffee, large\" , -4.50, USD\n2026-01-03,12\" pizza,-9,USD", mode: .statements)
        let saved = try #require(ImportBatchProcessor.evaluate(draft, document: empty()).document)
        #expect(saved.entries.map(\.label) == ["Coffee, large", "12\" pizza"] && saved.entries.map(\.amount) == [Decimal(string: "4.5")!, 9])
    }
}

@Suite("Import audit fixes")
struct ImportAuditTests {
    private func empty() -> VaultDocument {
        let pair = VaultCrypto.makeInboxKeyPair()
        return VaultDocument.empty(inboxPrivateKeyX963: pair.privateX963, inboxPublicKeyX963: pair.publicX963)
    }
    private func batch(_ csv: String, mode: ImportMode = .statements, name: String = "Example") throws -> ImportBatchDraft {
        var source = try ImportParser.source(bytes: Data(csv.utf8), filename: "sample.csv", mode: mode)
        source.account = ImportAccount(name: name)
        return ImportBatchDraft(mode: mode, sources: [source], rows: try ImportParser.rows(source: source, mode: mode))
    }
    private func day(_ date: Date) -> String { ImportDateFormat.today(date) }
    private func choose(_ account: Account, in draft: inout ImportBatchDraft) {
        for index in draft.sources.indices { draft.sources[index].account = ImportAccount(existingID: account.id, name: account.name, currency: account.currency) }
    }
    @Test("Interest on the 1st of each month reads in order either way, so review asks rather than picking the shorter span")
    func firstOfTheMonth() throws {
        var interest = try batch("Date,Description,Amount,Currency\n01/01/2026,Interest,1,GBP\n01/02/2026,Interest,1,GBP\n01/03/2026,Interest,1,GBP")
        #expect(interest.sources[0].unconfirmedDate == "01/02/2026")
        let waiting = ImportBatchProcessor.evaluate(interest, document: empty())
        #expect(waiting.needsFormat == [interest.sources[0].id] && waiting.document == nil)
        interest.sources[0].dateFormat = .dayFirst; interest.sources[0].unconfirmedDate = nil
        let saved = try #require(ImportBatchProcessor.evaluate(interest, document: empty()).document)
        #expect(saved.entries.map(\.month) == ["2026-01", "2026-02", "2026-03"])
    }
    @Test("Re-importing a statement brings back rows removed since and skips the rest, keeping its one record")
    func reimportAfterRemoving() throws {
        for csv in ["TransactionID,Date,Description,Amount,Currency\na,2026-01-02,Coffee,-4,USD\nb,2026-01-03,Lunch,-9,USD",
                    "Date,Description,Amount,Currency\n2026-01-02,Coffee,-4,USD\n2026-01-03,Lunch,-9,USD"] {
            var draft = try batch(csv)
            var saved = try #require(ImportBatchProcessor.evaluate(draft, document: empty()).document)
            #expect(saved.entries.count == 2 && saved.importedStatements.count == 1)
            saved.entries.removeAll { $0.label == "Lunch" }
            // Read afresh, as choosing the file again does.
            draft = try batch(csv)
            choose(saved.accounts[0], in: &draft)
            let review = ImportBatchProcessor.evaluate(draft, document: saved)
            #expect(review.duplicates == 1 && review.readyRows == 1 && review.states[draft.rows[1].id] == .ready("New transaction"))
            let restored = try #require(review.document)
            #expect(restored.entries.map(\.label) == ["Coffee", "Lunch"] && restored.importedStatements == saved.importedStatements)
            // Once it's back, the same file again adds nothing.
            draft = try batch(csv)
            choose(saved.accounts[0], in: &draft)
            let again = ImportBatchProcessor.evaluate(draft, document: restored)
            #expect(again.duplicates == 2 && again.added == 0 && !again.hasErrors)
        }
    }
    @Test("In a statement imported before, a saved ID is the same payment even if review changed it; another file's conflict still blocks")
    func reimportEditedRow() throws {
        let csv = "TransactionID,Date,Description,Amount,Currency\na,2026-01-02,Coffee,-4,USD"
        var edited = try batch(csv)
        edited.rows[0].statement.amount = "-5"
        let saved = try #require(ImportBatchProcessor.evaluate(edited, document: empty()).document)
        var original = try batch(csv)
        choose(saved.accounts[0], in: &original)
        let review = ImportBatchProcessor.evaluate(original, document: saved)
        #expect(review.duplicates == 1 && !review.hasErrors)
        var other = try batch(csv + "\nb,2026-01-03,Tea,-2,USD")
        choose(saved.accounts[0], in: &other)
        #expect(ImportBatchProcessor.evaluate(other, document: saved).states[other.rows[0].id] == .error("This transaction ID has different saved details. Correct it or exclude the row."))
    }
    @Test("A time with a zone is filed under its day on this Mac; the fingerprint keeps the date as written, so re-imports still match")
    func zonedTimes() throws {
        let iso = ImportDateFormat.iso, utc = TimeZone(secondsFromGMT: 0)!, athens = TimeZone(secondsFromGMT: 2 * 3600)!, newYork = TimeZone(secondsFromGMT: -5 * 3600)!
        #expect(day(try iso.date("2026-01-31T23:30:00Z", in: athens)) == "2026-02-01")
        #expect(day(try iso.date("2026-01-31T23:30:00Z", in: newYork)) == "2026-01-31")
        #expect(day(try iso.date("2026-01-31T23:30:00.250-05:00", in: utc)) == "2026-02-01")
        #expect(day(try iso.date("2026-02-01 00:30:00 +0100", in: utc)) == "2026-01-31")
        #expect(day(try ImportDateFormat.dayFirst.date("31/01/2026 23:30 +01", in: athens)) == "2026-02-01")
        // Without a zone, or without a Mac's zone to convert to, the date is as written.
        #expect(day(try iso.date("2026-01-31 23:30:00", in: athens)) == "2026-01-31")
        #expect(day(try iso.date("2026-01-31T23:30:00Z")) == "2026-01-31")
        let now = try iso.date("2026-03-01")
        let csv = "Date,Description,Amount,Currency\n2026-01-31T23:30:00Z,Late coffee,-4,USD"
        // Saved on a Mac in UTC (as every version so far filed it), then read again in Athens and New York.
        let saved = try #require(ImportBatchProcessor.evaluate(try batch(csv), document: empty(), now: now, timeZone: utc).document)
        #expect(saved.entries[0].day == "2026-01-31" && saved.entries[0].month == "2026-01")
        var draft = try batch(csv)
        choose(saved.accounts[0], in: &draft)
        for zone in [athens, newYork] { #expect(ImportBatchProcessor.evaluate(draft, document: saved, now: now, timeZone: zone).duplicates == 1) }
        // Read first in Athens, it's February's; the fingerprint is still the written date's.
        let east = try #require(ImportBatchProcessor.evaluate(try batch(csv), document: empty(), now: now, timeZone: athens).document)
        #expect(east.entries[0].day == "2026-02-01" && east.entries[0].month == "2026-02")
        #expect(east.entries[0].importFingerprint == saved.entries[0].importFingerprint)
        #expect(east.entries[0].importFingerprint == ImportBatchProcessor.fingerprint(date: try iso.date("2026-01-31"), label: "Late coffee", signedAmount: -4, currency: "USD"))
    }
    @Test("Signed card exports show their money in and out per currency before saving")
    func reviewFlows() throws {
        let csv = "Date,Description,Amount,Currency\n2026-01-02,Shoes,120,GBP\n2026-01-03,Payment,-500,GBP\n2026-01-04,Hotel,80,EUR"
        var card = try batch(csv)
        let asRead = ImportBatchProcessor.evaluate(card, document: empty())
        #expect(asRead.flows == ["GBP": ImportEvaluation.MoneyFlow(moneyIn: 120, moneyOut: 500), "EUR": ImportEvaluation.MoneyFlow(moneyIn: 80, moneyOut: 0)])
        card.sources[0].positiveIsOutflow = true
        let flipped = ImportBatchProcessor.evaluate(card, document: empty())
        #expect(flipped.flows == ["GBP": ImportEvaluation.MoneyFlow(moneyIn: 500, moneyOut: 120), "EUR": ImportEvaluation.MoneyFlow(moneyIn: 0, moneyOut: 80)])
        // Rows already saved aren't new money.
        let saved = try #require(flipped.document)
        choose(saved.accounts[0], in: &card)
        #expect(ImportBatchProcessor.evaluate(card, document: saved).flows.isEmpty)
    }
    @Test("A row in another currency than the chosen account's needs fixing or excluding")
    func accountCurrency() throws {
        var doc = empty()
        let checking = Account(name: "Checking", currency: "USD"); doc.accounts = [checking]
        var draft = try batch("Date,Description,Amount,Currency\n2026-01-02,Croissant,-4,EUR\n2026-01-03,Tea,-3,USD")
        choose(checking, in: &draft)
        let review = ImportBatchProcessor.evaluate(draft, document: doc)
        #expect(review.states[draft.rows[0].id] == .error("This row is in EUR but the account is in USD. Choose an account in EUR, or exclude the row."))
        #expect(review.states[draft.rows[1].id] == .ready("New transaction") && review.document == nil)
        draft.rows[0].included = false
        #expect(try #require(ImportBatchProcessor.evaluate(draft, document: doc).document).entries.map(\.currency) == ["USD"])
    }
    @Test("A Wise history split by currency counts as one file of its size against the batch limits")
    func splitFileLimits() throws {
        let part = ImportSourceDraft(filename: "wise.csv", bytes: Data(count: 7 * 1024 * 1024), grid: [["TransactionID"]])
        let parts = ["CHF", "EUR", "GBP", "JPY", "USD"].map { code -> ImportSourceDraft in var piece = part; piece.id = UUID(); piece.splitCurrency = code; return piece }
        var draft = ImportBatchDraft(mode: .statements, sources: parts)
        #expect(draft.files.count == 1)
        try draft.checkLimits()
        // Five separate files of that size are over 32 MiB.
        draft.sources = parts.map { var separate = $0; separate.splitCurrency = nil; return separate }
        #expect(throws: ImportFailure.self) { try draft.checkLimits() }
        // 49 files and a split one are 50 files.
        let small = (1...49).map { ImportSourceDraft(filename: "\($0).csv", bytes: Data("file \($0)".utf8), grid: [["Date"]]) }
        let wise = ["EUR", "GBP"].map { code -> ImportSourceDraft in var piece = ImportSourceDraft(filename: "wise.csv", bytes: Data("wise".utf8), grid: [["Date"]]); piece.splitCurrency = code; return piece }
        draft.sources = small + wise
        #expect(draft.files.count == 50)
        try draft.checkLimits()
    }
    @Test("Balances need a date from 1900 onwards, as statement rows do")
    func balanceDates() throws {
        let old = try batch("Account,Currency,Balance,ObservedOn\nChecking,USD,100,1899-12-31", mode: .bankBalances)
        #expect(ImportBatchProcessor.evaluate(old, document: empty()).states[old.rows[0].id] == .error("Use a balance date from 1900 onwards."))
        var statement = try batch("Date,Description,Amount,Currency\n2026-01-02,Coffee,-4,USD")
        statement.sources[0].balance = "100"; statement.sources[0].balanceDate = "0001-01-01"
        #expect(ImportBatchProcessor.evaluate(statement, document: empty()).sourceErrors[statement.sources[0].id] == "Use a balance date from 1900 onwards.")
    }
    @Test("One batch adds at most 100 new accounts and 100 new portfolios")
    func newAccountCap() throws {
        let accounts = try batch("Account,Currency,Balance,ObservedOn\n" + (1...101).map { "Account \($0),USD,1,2026-01-02" }.joined(separator: "\n"), mode: .bankBalances)
        let review = ImportBatchProcessor.evaluate(accounts, document: empty())
        #expect(review.states[accounts.rows[99].id] == .ready("Record dated balance"))
        #expect(review.states[accounts.rows[100].id] == .error("One import can add at most 100 new accounts. Choose existing accounts, or import the rest separately."))
        let portfolios = try batch("Portfolio,Coin,Quantity\n" + (1...101).map { "Wallet \($0),bitcoin,1" }.joined(separator: "\n"), mode: .holdings)
        let held = ImportBatchProcessor.evaluate(portfolios, document: empty())
        #expect(held.states[portfolios.rows[99].id].map { state -> Bool in if case .ready = state { return true }; return false } == true)
        #expect(held.states[portfolios.rows[100].id] == .error("One import can add at most 100 new portfolios. Choose existing portfolios, or import the rest separately."))
    }
    @Test("Files are read only when regular and within the limit, never through a symlink or from a pipe")
    func boundedRead() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("UpOnlyBounded-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func code(_ url: URL, limit: Int) -> CocoaError.Code? {
            do { _ = try BoundedFile.read(url, limit: limit); return nil } catch { return (error as? CocoaError)?.code }
        }
        let file = directory.appendingPathComponent("statement.csv")
        try Data("Date,Amount\n".utf8).write(to: file)
        #expect(try BoundedFile.read(file, limit: 12) == Data("Date,Amount\n".utf8))
        #expect(code(file, limit: 11) == .fileReadTooLarge)
        let link = directory.appendingPathComponent("link.csv")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(code(link, limit: 100) == .fileReadNoPermission)
        #expect(code(directory.appendingPathComponent("missing.csv"), limit: 100) == .fileReadNoSuchFile)
        let pipe = directory.appendingPathComponent("pipe.csv")
        try #require(mkfifo(pipe.path, 0o600) == 0)
        #expect(code(pipe, limit: 100) == .fileReadUnknown)
        #expect(code(directory, limit: 100) == .fileReadUnknown)
    }
    @Test("Dropped web links aren't read, and a chosen symlink reads the file it points to")
    @MainActor func importURLs() async throws {
        let io = MemoryFileIO(), layout = VaultLayout(root: URL(fileURLWithPath: "/tmp/uponly-import-test-" + UUID().uuidString))
        let session = UpOnlySession(testing: VaultStore(layout: layout, io: io, keys: MemoryKeyStore(), authenticator: FixtureAuthenticator()), layout: layout)
        await session.create(recovery: .random())
        session.startImport(.statements)
        await session.readImportFiles([try #require(URL(string: "https://example.com/statement.csv"))])
        #expect(session.importMessage == "Choose files on this Mac." && session.importDraft?.rows.isEmpty == true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let csv = directory.appendingPathComponent("statement.csv"), link = directory.appendingPathComponent("link.csv")
        try Data("Date,Description,Amount,Currency\n2026-01-02,Coffee,-4,USD\n".utf8).write(to: csv)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: csv)
        await session.readImportFiles([link])
        #expect(session.importMessage == nil && session.importDraft?.rows.count == 1)
    }
    @Test("A UTF-8 file with a stray bad byte stays UTF-8, and a byte order mark is dropped whatever the encoding")
    func lenientEncoding() throws {
        var bytes = Data("Date,Description,Amount\n".utf8)
        for index in 1...60 { bytes += Data("2026-01-02,Café \(index),-1\n".utf8) }
        bytes += Data("2026-01-03,X".utf8) + Data([0xFF]) + Data("Y,-2\n".utf8)
        let text = try ImportParser.decode(bytes)
        #expect(text.contains("Café 60") && text.contains("X\u{FFFD}Y"))
        // Windows-1252 text stays Windows-1252, with or without a stray UTF-8 byte order mark.
        let latin = try #require("Date,Description,Amount\n2026-01-02,£5 voucher,-5".data(using: .windowsCP1252))
        for input in [latin, Data([0xEF, 0xBB, 0xBF]) + latin] {
            let source = try ImportParser.source(bytes: input, filename: "uk.csv", mode: .statements)
            #expect(source.grid[0][0] == "Date" && source.grid[1][1] == "£5 voucher")
        }
        let marked = try ImportParser.source(bytes: Data([0xEF, 0xBB, 0xBF]) + Data("Date,Description,Amount\n2026-01-02,Café,-5".utf8), filename: "bom.csv", mode: .statements)
        #expect(marked.grid[0][0] == "Date" && marked.mapping[.date] == 0)
    }
    @Test("Monzo transfers count as spending and income until review says they're your own; pots and marked payees stay transfers")
    func monzoTransfers() throws {
        let header = "Transaction ID,Date,Time,Type,Name,Emoji,Category,Amount,Currency,Local amount,Local currency,Notes and #tags,Address,Receipt,Description,Category split,Money Out,Money In"
        func line(_ id: String, _ date: String, _ type: String, _ name: String, _ category: String, _ amount: String) -> String {
            [id, date, "10:00:00", type, name, "", category, amount, "GBP", amount, "GBP", "", "", "", name.uppercased(), "", "", ""].joined(separator: ",")
        }
        let csv = [header, line("tx_1", "14/08/2026", "Faster payment", "Alex Example", "transfers", "-50.00"),
                   line("tx_2", "15/08/2026", "Faster payment", "Other Bank", "transfers", "500.00"),
                   line("tx_3", "16/08/2026", "Pot transfer", "Savings", "savings", "-100.00"),
                   line("tx_4", "17/08/2026", "Faster payment", "Example Ltd", "transfers", "-300.00")].joined(separator: "\n")
        var doc = empty()
        OwnerPayments.setTransferCounterparty("Example Ltd", enabled: true, in: &doc)
        var draft = try batch(csv, name: "Monzo")
        let source = draft.sources[0].id
        #expect(draft.transferCategoryRows(source).count == 3 && !draft.transfersAreOwn(source))
        let review = ImportBatchProcessor.evaluate(draft, document: doc)
        let saved = try #require(review.document)
        #expect(saved.entries.map(\.kind) == [.expense, .income, .transfer, .transfer] && review.transfersCounted == 2)
        let totals = try #require(MonthlyLedger.nativeTotals(MonthKey("2026-08")!, document: saved).first?.totals)
        #expect(totals.moneyOut == 50 && totals.moneyIn == 500)
        draft.setTransfersAreOwn(true, source: source)
        #expect(draft.transfersAreOwn(source))
        let own = ImportBatchProcessor.evaluate(draft, document: doc)
        #expect(try #require(own.document).entries.allSatisfy { $0.kind == .transfer } && own.transfersCounted == 0)
        draft.setTransfersAreOwn(false, source: source)
        #expect(try #require(ImportBatchProcessor.evaluate(draft, document: doc).document).entries.map(\.kind) == [.expense, .income, .transfer, .transfer])
    }
    @Test("A rate typed in counts for its whole month; a fetched one only from the month's last week; the latest wins")
    func manualRates() throws {
        var doc = empty()
        let july = MonthKey("2026-07")!, now = try ImportDateFormat.iso.date("2026-09-01")
        func rate(_ value: String, _ day: String, _ provider: String) throws -> FXObservation {
            FXObservation(sourceCurrency: "GBP", targetCurrency: "USD", rate: PreciseDecimal(Decimal(string: value)!), providerTime: try ImportDateFormat.iso.date(day), fetchedAt: now, provider: provider)
        }
        doc.fx = [try rate("1.20", "2026-07-05", "Frankfurter")]
        #expect(MonthlyLedger.rate(currency: "GBP", month: july, document: doc, now: now) == nil)
        doc.fx.append(try rate("1.25", "2026-07-05", "Manual"))
        #expect(MonthlyLedger.rate(currency: "GBP", month: july, document: doc, now: now) == Decimal(string: "1.25"))
        doc.fx.append(try rate("1.30", "2026-07-28", "Frankfurter"))
        #expect(MonthlyLedger.rate(currency: "GBP", month: july, document: doc, now: now) == Decimal(string: "1.30"))
        // A manual rate from another month doesn't price this one.
        doc.fx = [try rate("1.25", "2026-06-10", "Manual")]
        #expect(MonthlyLedger.rate(currency: "GBP", month: july, document: doc, now: now) == nil)
    }
    @Test("Descriptions are saved without control or bidi characters, and still match rows saved with them")
    func cleanDescriptions() throws {
        #expect(ImportBatchProcessor.cleanLabel(" Coffee\u{202E}eeffoc\u{2066}x\u{2069}\u{200F}\nshop\t\u{0007}") == "Coffeeeeffocx shop")
        #expect(ImportBatchProcessor.cleanLabel("Family 👨‍👩‍👧 dinner") == "Family 👨‍👩‍👧 dinner")
        let csv = "Date,Description,Amount,Currency\n2026-01-02,\"Pay\u{202E}ment\",-4,USD"
        let saved = try #require(ImportBatchProcessor.evaluate(try batch(csv), document: empty()).document)
        #expect(saved.entries[0].label == "Payment")
        #expect(saved.entries[0].importFingerprint == ImportBatchProcessor.fingerprint(date: try ImportDateFormat.iso.date("2026-01-02"), label: "Pay\u{202E}ment", signedAmount: -4, currency: "USD"))
        var again = try batch(csv)
        choose(saved.accounts[0], in: &again)
        #expect(ImportBatchProcessor.evaluate(again, document: saved).duplicates == 1)
    }
    @Test("The biggest movements rank dollars against dollars, with rows that have no rate after them")
    func evidenceOrder() {
        var doc = empty()
        let august = MonthKey("2026-08")!, now = Date(timeIntervalSince1970: 1_787_000_000)
        doc.fx = [FXObservation(sourceCurrency: "GBP", targetCurrency: "USD", rate: PreciseDecimal(2), providerTime: now, fetchedAt: now, provider: "test")]
        doc.entries = [Entry(month: august, kind: .expense, amount: 1_000_000, currency: "JPY", label: "Yen"),
                       Entry(month: august, kind: .expense, amount: 150, currency: "USD", label: "Dollars"),
                       Entry(month: august, kind: .expense, amount: 5000, currency: "EUR", label: "Euros"),
                       Entry(month: august, kind: .expense, amount: 100, currency: "GBP", label: "Pounds")]
        let evidence = MonthEvidence.build(august, document: doc, now: now)
        #expect(evidence.largest.map(\.entry.label) == ["Pounds", "Dollars", "Euros", "Yen"])
    }
    @Test("Merging accounting tolerates a company saved twice")
    func duplicateCompanies() {
        let old = BusinessBook(id: "studio", name: "Studio", ownership: [], firstMonth: "2026-01", sourceURL: "", basis: "Test", fetchedAt: Date(timeIntervalSince1970: 1), transferCounterparties: nil)
        var new = old; new.fetchedAt = Date(timeIntervalSince1970: 2)
        let merged = AccountingHistory.merging([], into: [old, new])
        #expect(merged.count == 1 && merged[0].fetchedAt == new.fetchedAt)
    }
    @Test("A number with two decimal marks is flagged without repeating the amount")
    func numberMessage() {
        do { _ = try ImportNumberFormat.point.decimal("1.234.56"); Issue.record("Two decimal points were read.") }
        catch { #expect(error.localizedDescription == "Check the number format: this amount has more than one decimal point.") }
    }
    @Test("Deleting saved statement files keeps their transactions and still skips them when imported again")
    func deleteOriginals() throws {
        var draft = try batch("TransactionID,Date,Description,Amount,Currency\na,2026-01-02,Coffee,-4,USD")
        var saved = try #require(ImportBatchProcessor.evaluate(draft, document: empty()).document)
        #expect(saved.statementOriginals.files == 1 && saved.statementOriginals.bytes == draft.sources[0].bytes.count)
        let before = saved.importedStatements
        saved.deleteStatementOriginals()
        #expect(saved.statementOriginals.files == 0 && saved.entries.count == 1)
        #expect(saved.importedStatements.map(\.digest) == before.map(\.digest) && saved.importedStatements.map(\.accountID) == before.map(\.accountID))
        choose(saved.accounts[0], in: &draft)
        let again = ImportBatchProcessor.evaluate(draft, document: saved)
        #expect(again.duplicates == 1 && again.added == 0 && again.document?.importedStatements == saved.importedStatements)
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
    @Test("A Wise transaction history with two currencies is read as one statement per currency")
    func wiseHistorySplits() async throws {
        let (session, _, _) = harness()
        await session.create(recovery: .random())
        session.startImport(.statements)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let csv = directory.appendingPathComponent("wise.csv")
        try Data(("ID,Status,Direction,Created on,Finished on,Source fee amount,Source fee currency,Source name,Source amount (after fees),Source currency,Target name,Target amount (after fees),Target currency,Reference\n"
                  + "BALANCE-1,COMPLETED,NEUTRAL,2026-08-01 10:00:00,2026-08-01 10:00:02,1.20,EUR,Alex,498.80,EUR,Alex,430.00,GBP,\n"
                  + "TRANSFER-2,COMPLETED,OUT,2026-08-03 14:20:05,2026-08-03 14:23:11,0,EUR,Alex,20.00,EUR,Cafe,20.00,EUR,\n").utf8).write(to: csv)
        await session.readImportFiles([csv])
        let draft = try #require(session.importDraft)
        #expect(session.importMessage == nil && draft.sources.map(\.filename) == ["wise.csv · EUR", "wise.csv · GBP"])
        #expect(draft.sources.map(\.account.name) == ["Wise · EUR", "Wise · GBP"] && draft.rows.count == 3)
        #expect(Set(draft.rows.map(\.sourceID)) == Set(draft.sources.map(\.id)))
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
    @Test("The idle check runs by itself while unlocked: an idle vault locks without a click or the menu opening")
    func idleTimerLocks() async throws {
        let (session, _, _) = harness()
        await session.create(recovery: .random())
        session.recordActivity(at: Date().addingTimeInterval(-UpOnlySession.inactivityInterval))
        for _ in 0..<50 where session.state == .unlocked { try await Task.sleep(for: .milliseconds(100)) }
        #expect(session.state == .locked && session.document == nil)
    }
    @Test("Diagnostics are created readable by this user only, without profile IDs or ownership shares, and can be deleted")
    func diagnosticsFile() async throws {
        let (session, _, _) = harness()
        await session.create(recovery: .random())
        try await session.mutate { doc in
            doc.accounts.append(Account(name: "Synthetic Wise", currency: "EUR", externalProfileID: "90210"))
            doc.businessAccounting = [BusinessBook(id: "studio", name: "Studio", ownership: [OwnershipPeriod(fromMonth: "2026-01", numerator: 1, denominator: 3)],
                                                   firstMonth: "2026-01", sourceURL: "", basis: "", fetchedAt: Date())]
        }
        try FileManager.default.createDirectory(at: Config.supportDirectory, withIntermediateDirectories: true)
        defer { _ = session.deleteDiagnostics() }
        #expect(!session.hasDiagnosticsFile)
        #expect(session.writeDiagnostics().hasPrefix("Written to "))
        let text = try String(contentsOf: session.diagnosticsURL, encoding: .utf8)
        #expect(text.contains("Synthetic Wise [EUR]") && text.contains("Studio first=2026-01 ownership from=2026-01"))
        #expect(!text.contains("90210") && !text.contains("profile=") && !text.contains("⅓"))
        let mode = try FileManager.default.attributesOfItem(atPath: session.diagnosticsURL.path)[.posixPermissions] as? Int
        #expect(mode == 0o600 && session.hasDiagnosticsFile)
        #expect(session.deleteDiagnostics() == "Diagnostics file deleted." && !session.hasDiagnosticsFile)
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
    @Test("A privacy choice that can't be saved leaves values hidden, says so, and leaves the vault unchanged")
    func privacyWriteFailure() async throws {
        let (session, io, _) = harness()
        await session.create(recovery: .random())
        // Hiding that can't be saved still holds for this unlock; the next unlock is as saved.
        let unsaved = try io.data(at: session.layout.current)
        io.failWrite = true
        await #expect(throws: Error.self) { try await session.togglePrivacyMode() }
        let unchanged = try io.data(at: session.layout.current)
        #expect(session.privacyMode && session.message != nil && unchanged == unsaved)
        io.failWrite = false
        session.lock(); await session.unlock()
        #expect(!session.privacyMode)
        // Showing values that can't be saved leaves them hidden.
        try await session.togglePrivacyMode()
        let saved = try io.data(at: session.layout.current)
        io.failWrite = true
        await #expect(throws: Error.self) { try await session.togglePrivacyMode() }
        let after = try io.data(at: session.layout.current)
        #expect(session.privacyMode && session.message != nil && after == saved)
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
        // The archive of originals is already past its budget, so this file isn't kept; its transactions cross the limit.
        let label = String(repeating: "x", count: 480)
        let csv = "TransactionID,Date,Description,Amount,Currency\n" + (0..<8000).map { "\($0),2026-01-02,\(label),1,USD" }.joined(separator: "\n")
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
    @Test("Lock replaces everything that belonged to the unlocked vault: drafts, editors, navigation and remembered values start afresh")
    func lockStartsAfresh() async throws {
        let (session, _, vault) = harness()
        await session.create(recovery: .random())
        let before = session.unlocked
        // What lock once had to clear field by field: a half-made draft and its editors, a page and its trail, a
        // request, a note, and values remembered for the document.
        session.startImport(.holdings); session.importTableMode = true; session.importRequest = .paste; session.importMessage = "Half done"
        session.addingInMenu = true; session.addOpenedForUpdate = true; session.managementInMenu = true; session.entryEditorInMenu = true
        #expect(session.handleEscape())
        #expect(session.backRequests == 1)
        session.showDashboard(.cashFlow); session.showDashboard(.all, .drill); session.showingSwitcher = true; session.dashboardDetailOpen = true
        session.dropZoneVisible = true; session.sourceMessage = "Updated"; session.hourlyCache["probe"] = []
        #expect(session.chartEstimates() != nil && session.latestRate("EUR") == nil && session.dashboardTrail == [.cashFlow])
        // How you like the dashboard is about this Mac, not the vault, so it stays.
        session.worthRange = .month; session.holdingSortIndex = 2; session.dashboardHeight = 480
        session.lock()
        #expect(session.unlocked !== before && session.document == nil && session.importDraft == nil && session.chartEstimates() == nil)
        // The vault gains a EUR rate while locked, so a remembered "no EUR rate" would show if the cache survived.
        let opened = try await vault.unlock()
        var changed = opened.document
        changed.fx.append(FXObservation(sourceCurrency: "EUR", targetCurrency: "USD", rate: PreciseDecimal(Decimal(string: "1.25")!), providerTime: Date(), fetchedAt: Date(), provider: "Synthetic"))
        changed.generation += 1
        try await vault.commit(changed, expectedGeneration: opened.document.generation, sessionID: opened.sessionID)
        vault.lock()
        await session.unlock()
        #expect(session.state == .unlocked && session.latestRate("EUR") == Decimal(string: "1.25"))
        #expect(session.importDraft == nil && session.importMode == .statements && !session.importTableMode && session.importRequest == nil && session.importMessage == nil)
        #expect(!session.addingInMenu && !session.addOpenedForUpdate && !session.managementInMenu && !session.entryEditorInMenu && session.backRequests == 0)
        #expect(session.dashboardSelection == .all && session.dashboardTrail.isEmpty && !session.showingSwitcher && !session.dashboardDetailOpen)
        #expect(!session.dropZoneVisible && session.sourceMessage == nil && session.hourlyCache.isEmpty)
        #expect(session.worthRange == .month && session.holdingSortIndex == 2 && session.dashboardHeight == 480)
    }
    @Test("Quick saves wait their turn: each lands in the order made, one generation apart, with a background update among them")
    func savesWaitTheirTurn() async throws {
        let (session, _, vault) = harness()
        await session.create(recovery: .random())
        let start = try #require(session.document?.generation)
        let quote = QuoteObservation(assetID: PreciousMetal.gold.assetID, priceUSD: PreciseDecimal(100), providerTime: Date(), fetchedAt: Date(), provider: "Synthetic")
        let names = (0..<8).map { "Account \($0)" }
        // Started together, as quick taps are: none is refused, and each waits for the one before it.
        let background = Task { var update = PriceUpdate(); update.quotes = [quote]; try await session.commitPriceUpdate(update) }
        let edits = names.map { name in Task { try await session.mutate { $0.accounts.append(Account(name: name, currency: "USD")) } } }
        for edit in edits { try await edit.value }
        try await background.value
        #expect(session.document?.accounts.map(\.name) == names && session.document?.generation == start + 9 && !session.isBusy)
        let saved = try await vault.currentSession().document
        #expect(saved.accounts.map(\.name) == names && saved.generation == start + 9 && saved.quotes.contains { $0.provider == "Synthetic" })
        // And they're what the next unlock reads from disk.
        session.lock(); await session.unlock()
        #expect(session.document?.accounts.map(\.name) == names && session.document?.generation == start + 9)
    }
    @Test("A lock during a save refuses it and the saves waiting their turn; nothing is published and the next unlock reads the last save")
    func lockDuringSave() async throws {
        let (session, io, _) = harness()
        await session.create(recovery: .random())
        try await session.mutate { $0.accounts.append(Account(name: "Kept", currency: "USD")) }
        let kept = try #require(session.document?.generation)
        // The vault actor stops partway through writing the next save until the lock has happened.
        let writing = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0)
        io.onWrite = { writing.signal(); proceed.wait() }
        let saving = Task { try await session.mutate { $0.accounts.append(Account(name: "Lost", currency: "USD")) } }
        await withCheckedContinuation { (reached: CheckedContinuation<Void, Never>) in DispatchQueue.global().async { writing.wait(); reached.resume() } }
        let queued = Task { try await session.mutate { $0.accounts.append(Account(name: "Also lost", currency: "USD")) } }
        for _ in 0..<5 { await Task.yield() }
        session.lock()
        io.onWrite = nil
        proceed.signal()
        await #expect(throws: VaultError.locked) { try await saving.value }
        await #expect(throws: VaultError.locked) { try await queued.value }
        #expect(session.state == .locked && session.document == nil && !session.isBusy)
        await session.unlock()
        #expect(session.document?.accounts.map(\.name) == ["Kept"] && session.document?.generation == kept)
    }
    @Test("The writer is handed on, not polled for: user edits in order and ahead of background work; cancelling or locking turns a waiter away")
    func writerHandover() async throws {
        let writers = WriterQueue(), log = TurnLog()
        try await writers.acquire(background: true)
        let background = Task { try await writers.acquire(background: true); log.turns.append("background"); writers.release() }
        let first = Task { try await writers.acquire(background: false); log.turns.append("first"); writers.release() }
        let second = Task { try await writers.acquire(background: false); log.turns.append("second"); writers.release() }
        for _ in 0..<5 { await Task.yield() }
        #expect(log.turns.isEmpty)
        writers.release()
        try await background.value; try await first.value; try await second.value
        #expect(log.turns == ["first", "second", "background"])
        // A cancelled waiter leaves the line, as a restarted refresh's does.
        try await writers.acquire(background: true)
        let cancelled = Task { try await writers.acquire(background: true) }
        for _ in 0..<5 { await Task.yield() }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        // A lock turns away whoever is waiting, and nothing is handed on afterwards.
        let waiting = Task { try await writers.acquire(background: false) }
        for _ in 0..<5 { await Task.yield() }
        writers.close()
        await #expect(throws: VaultError.locked) { try await waiting.value }
        await #expect(throws: VaultError.locked) { try await writers.acquire(background: true) }
    }
}
/// Who held the writer, in turn.
@MainActor private final class TurnLog { var turns: [String] = [] }
#endif

struct MetalHistoryTests {
    private func empty() -> VaultDocument {
        let pair = VaultCrypto.makeInboxKeyPair()
        return VaultDocument.empty(inboxPrivateKeyX963: pair.privateX963, inboxPublicKeyX963: pair.publicX963)
    }
    private func batch(_ text: String) throws -> ImportBatchDraft {
        let source = try ImportParser.source(bytes: Data(text.utf8), filename: "metals.csv", mode: .metals)
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
        // The explanation's ✗ and ~ legend isn't a result: only the verdict row, or a ✗ in the status column, is.
        let legend = #"["Three records are cross-checked. ✗ = that number may be wrong. ~ = estimated while reports settle."],[""]"#
        let passing = try range(#"{"range":"Data Health","values":["# + legend + #",["VERDICT","✓ ALL CHECKS PASSING"],["~","Store revenue","2026-09","accrued"],["CHECKS RUN"],["✓","Payouts","","ties"]]}"#)
        #expect(AccountingSheets.healthWarning(passing) == nil)
        let failing = try range(#"{"range":"Data Health","values":["# + legend + #",["VERDICT","✗ 1 CHECK(S) FAILING"],["✗","Payouts","2026-08","off by $12.00"]]}"#)
        #expect(AccountingSheets.healthWarning(failing) != nil)
        #expect(AccountingSheets.healthWarning(try range(#"{"range":"Data Health","values":[["✗","Payouts","2026-08","off"]]}"#)) != nil)
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
        let vault = UUID(), now = Date(timeIntervalSince1970: 1_800_000_000), files = BackgroundFiles(root: root, key: BackgroundFiles.newKey())
        let schedule = BackgroundRefreshSchedule()
        #expect(try await schedule.claim(vaultID: vault, files: files, now: now))
        for source in ["crypto", "metals"] {
            #expect(try await schedule.claim(vaultID: vault, files: files, source: source, now: now))
            #expect(try await !BackgroundRefreshSchedule().claim(vaultID: vault, files: files, source: source, now: now.addingTimeInterval(3599)))
            #expect(try await BackgroundRefreshSchedule().claim(vaultID: vault, files: files, source: source, now: now.addingTimeInterval(3600)))
        }
        #expect(try await !schedule.claim(vaultID: vault, files: files, now: now.addingTimeInterval(3600)))
        #expect(try await schedule.claim(vaultID: vault, files: files, now: now.addingTimeInterval(43200)))
    }
    @Test("Automatic bank attempts survive relaunch and become due after twelve hours")
    func bankCadence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = UUID(), now = Date(timeIntervalSince1970: 1_800_000_000), files = BackgroundFiles(root: root, key: BackgroundFiles.newKey())
        #expect(try await BackgroundRefreshSchedule().claim(vaultID: vault, files: files, now: now))
        #expect(try await !BackgroundRefreshSchedule().claim(vaultID: vault, files: files, now: now.addingTimeInterval(60)))
        #expect(try await !BackgroundRefreshSchedule().claim(vaultID: vault, files: files, now: now.addingTimeInterval(43199)))
        #expect(try await BackgroundRefreshSchedule().claim(vaultID: vault, files: files, now: now.addingTimeInterval(43200)))
        #expect(try await BackgroundRefreshSchedule().claim(vaultID: UUID(), files: files, now: now.addingTimeInterval(43201)))
    }
    @Test("Failed bank attempts stay visible without causing repeated automatic requests")
    func failedBankCadence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = UUID(), now = Date(timeIntervalSince1970: 1_800_000_000), schedule = BackgroundRefreshSchedule(), files = BackgroundFiles(root: root, key: BackgroundFiles.newKey())
        try await schedule.finish(vaultID: vault, files: files, failed: true, now: now)
        #expect(await BackgroundRefreshSchedule().failed(vaultID: vault, files: files))
        #expect(try await !schedule.claim(vaultID: vault, files: files, now: now.addingTimeInterval(900)))
        try await schedule.finish(vaultID: vault, files: files, failed: false, now: now.addingTimeInterval(1000))
        #expect(await !schedule.failed(vaultID: vault, files: files))
        #expect(try await !schedule.claim(vaultID: vault, files: files, now: now.addingTimeInterval(43200)))
        #expect(try await schedule.claim(vaultID: vault, files: files, now: now.addingTimeInterval(-60)))
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
        return (doc, BackgroundConfiguration(vaultID: doc.vaultID, inboxPublicKey: inbox.publicX963, signingPrivateKey: signing.privateX963, signingPublicKey: signing.publicX963, crypto: [], currencies: [], metals: [], pricesEnabled: true, fxEnabled: true, metalsEnabled: true, coinGeckoKey: "", fileKey: BackgroundFiles.newKey()))
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
        let files = try #require(config.files(root: root))
        // Replay comparison uses the same millisecond precision as persisted dates.
        let now = try VaultJSON.decode(Date.self, from: VaultJSON.encode(Date()))
        try BackgroundRefresh.save(BackgroundPacket(source: "fx", fetchedAt: now, prices: PriceUpdate()), configuration: config, root: root)
        try BackgroundRefresh.save(BackgroundPacket(source: "crypto", fetchedAt: now, prices: PriceUpdate()), configuration: config, root: root)
        doc.backgroundAppliedAt = ["crypto": now]
        var bad = try BackgroundEnvelope.seal(BackgroundPacket(source: "metals", fetchedAt: now, prices: PriceUpdate()), configuration: config)
        bad.signature[bad.signature.startIndex] ^= 1
        try VaultJSON.encode(bad).write(to: files.sealed("metals"))
        let snapshot = doc
        let result = await Task.detached { BackgroundRefresh.cachedPackets(document: snapshot, files: files) }.value
        #expect(result.packets.map(\.source) == ["fx"])
        #expect(result.issues == ["Metals cached data"])
        let cancelled = Task.detached {
            try? await Task.sleep(for: .milliseconds(30))
            return BackgroundRefresh.cachedPackets(document: snapshot, files: files)
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
        let files = config.files(root: root)
        for source in BackgroundRefresh.sources {
            try BackgroundRefresh.save(BackgroundPacket(source: source, fetchedAt: Date(), prices: PriceUpdate(messages: [String(repeating: "Synthetic cache content ", count: 25000)])), configuration: config, root: root)
        }
        let start = ContinuousClock.now
        // This is the previous main-executor path, measured with synthetic data.
        let baseline = BackgroundRefresh.cachedPackets(document: doc, files: files)
        let before = start.duration(to: .now)
        #expect(baseline.packets.count == 5)
        var beats = 0
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled { beats += 1; try? await Task.sleep(for: .milliseconds(2)) }
        }
        let request = Task.detached(priority: .utility) {
            let onMainThread = Thread.isMainThread
            let result = BackgroundRefresh.cachedPackets(document: doc, files: files)
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
    #if UPONLY_PERSONAL
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
    #else
    @Test("The public build ignores an accounting packet: it has no accounting connection")
    func publicBuildIgnoresAccounting() throws {
        let (doc, _) = pair()
        let book = BusinessBook(id: "company", name: "Company", ownership: [OwnershipPeriod(fromMonth: "2025-01", numerator: 1, denominator: 1)], firstMonth: "2025-01", sourceURL: "", basis: "", months: [BusinessMonth(month: "2025-01", profitUSD: 100, sourceRange: "Synthetic")], fetchedAt: Date())
        #expect(try BackgroundRefresh.applying(BackgroundPacket(source: "accounting", fetchedAt: Date(), books: [book]), to: doc) == doc)
    }
    #endif
    @Test("Prefetched prices never require access to the vault key")
    func noVaultKeyInConfiguration() throws {
        let (_, config) = pair()
        let data = try JSONEncoder().encode(config)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String:Any])
        #expect(object["inboxPrivateKey"] == nil && object["vaultKey"] == nil)
        #expect(BackgroundRefresh.interval == 900)
    }
}

/// The support folder shows only how many background sources are on: sealed and schedule files are named by a keyed
/// hash, schedules are sealed, and the source-named files earlier builds left are removed.
@Suite("Background file names and schedules")
struct BackgroundFileTests {
    private func temporaryRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("uponly-files-" + UUID().uuidString) }
    private func configuration(vaultID: UUID = UUID(), fileKey: Data? = BackgroundFiles.newKey()) -> BackgroundConfiguration {
        let inbox = VaultCrypto.makeInboxKeyPair(), signing = VaultCrypto.makeSigningKeyPair()
        return BackgroundConfiguration(vaultID: vaultID, inboxPublicKey: inbox.publicX963, signingPrivateKey: signing.privateX963, signingPublicKey: signing.publicX963, crypto: ["bitcoin"], currencies: ["EUR"], metals: [.gold], pricesEnabled: true, fxEnabled: true, metalsEnabled: true, coinGeckoKey: "", wiseEnabled: true, accountingEnabled: true, fileKey: fileKey)
    }
    private let kinds = BackgroundRefresh.sources + ["history"]
    @Test("File names don't name the source, are the same each time for a key, and differ for another key")
    func opaqueNames() {
        let root = temporaryRoot(), key = BackgroundFiles.newKey()
        let files = BackgroundFiles(root: root, key: key), other = BackgroundFiles(root: root, key: BackgroundFiles.newKey())
        let urls = kinds.flatMap { [files.sealed($0), files.schedule($0)] }
        #expect(Set(urls).count == urls.count && urls.allSatisfy { $0.path == root.path + "/" + $0.lastPathComponent })
        for name in urls.map(\.lastPathComponent) {
            let hash = name.dropFirst("Background-".count).prefix { $0 != "." }
            #expect(name.hasPrefix("Background-") && (name.hasSuffix(".sealed") || name.hasSuffix(".schedule")))
            #expect(hash.count == 32 && hash.allSatisfy(\.isHexDigit))
            #expect(!kinds.contains { name.lowercased().contains($0) })
        }
        #expect(BackgroundFiles(root: root, key: key).sealed("banks") == files.sealed("banks"))
        #expect(kinds.allSatisfy { other.sealed($0) != files.sealed($0) && other.schedule($0) != files.schedule($0) })
        #expect(files.sealed("banks").lastPathComponent.dropLast(".sealed".count) != files.schedule("banks").lastPathComponent.dropLast(".schedule".count))
    }
    @Test("A schedule record is sealed: its file holds neither the vault ID nor the source, and it opens only under its key and source")
    func sealedSchedules() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let vaultID = UUID(), now = Date(timeIntervalSince1970: 1_800_000_000), schedule = BackgroundRefreshSchedule()
        let files = BackgroundFiles(root: root, key: BackgroundFiles.newKey())
        try await schedule.finish(vaultID: vaultID, files: files, failed: true, source: "banks", now: now)
        let bytes = try Data(contentsOf: files.schedule("banks"))
        for plain in [vaultID.uuidString, vaultID.uuidString.lowercased(), "banks", "vaultID", "failed", "attemptedAt"] {
            #expect(bytes.range(of: Data(plain.utf8)) == nil)
        }
        // Round trip: the record reads back, through a new schedule as after a relaunch.
        let opened = try files.openSchedule(bytes, source: "banks")
        #expect(String(decoding: opened, as: UTF8.self).contains(vaultID.uuidString))
        #expect(await BackgroundRefreshSchedule().failed(vaultID: vaultID, files: files, source: "banks"))
        #expect(try await !BackgroundRefreshSchedule().claim(vaultID: vaultID, files: files, source: "banks", now: now.addingTimeInterval(60)))
        // Another key, or another source's file, opens nothing: no record, so that slot is free.
        #expect(throws: (any Error).self) { try BackgroundFiles(root: root, key: BackgroundFiles.newKey()).openSchedule(bytes, source: "banks") }
        #expect(throws: (any Error).self) { try files.openSchedule(bytes, source: "crypto") }
        try bytes.write(to: files.schedule("crypto"))
        #expect(await !schedule.failed(vaultID: vaultID, files: files, source: "crypto"))
        #expect(try await schedule.claim(vaultID: vaultID, files: files, source: "crypto", now: now.addingTimeInterval(60)))
    }
    @Test("A sealed packet saves under its opaque name and reads back at unlock")
    func sealedPacketRoundTrip() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let inbox = VaultCrypto.makeInboxKeyPair()
        var doc = VaultDocument.empty(inboxPrivateKeyX963: inbox.privateX963, inboxPublicKeyX963: inbox.publicX963)
        var config = configuration(vaultID: doc.vaultID); config.inboxPublicKey = inbox.publicX963
        doc.backgroundSignerPublicKey = config.signingPublicKey
        let files = try #require(config.files(root: root))
        try BackgroundRefresh.save(BackgroundPacket(source: "metals", fetchedAt: Date(), prices: PriceUpdate()), configuration: config, root: root)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [files.sealed("metals").lastPathComponent])
        #expect(BackgroundRefresh.cachedPackets(document: doc, files: files).packets.map(\.source) == ["metals"])
        // Under another key the same folder holds nothing to read.
        #expect(BackgroundRefresh.cachedPackets(document: doc, files: BackgroundFiles(root: root, key: BackgroundFiles.newKey())).packets.isEmpty)
    }
    @Test("A configuration saved before file keys still loads, with none: nothing is read, fetched or written under it")
    func configurationWithoutFileKey() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let config = configuration()
        #expect(try JSONDecoder().decode(BackgroundConfiguration.self, from: JSONEncoder().encode(config)) == config)
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        object.removeValue(forKey: "fileKey")
        var old = try JSONDecoder().decode(BackgroundConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.fileKey == nil && old.files(root: root) == nil)
        // Saved in the Keychain, it gives the unlocked app no files; with a key, only for its own vault.
        let keychain = MemoryBackgroundStore()
        try old.save(to: keychain)
        #expect(BackgroundConfiguration.files(for: old.vaultID, root: root, keychain: keychain) == nil)
        #expect(BackgroundRefresh.cachedPackets(document: VaultDocument.empty(inboxPrivateKeyX963: Data(), inboxPublicKeyX963: Data()), files: nil).packets.isEmpty)
        #expect(await BackgroundRefresh.fetch(configuration: old, root: root).isEmpty)
        #expect(throws: (any Error).self) { try BackgroundRefresh.save(BackgroundPacket(source: "fx", fetchedAt: Date()), configuration: old, root: root) }
        #expect(!FileManager.default.fileExists(atPath: root.path))
        old.fileKey = config.fileKey
        #expect(old == config)
        try old.save(to: keychain)
        #expect(BackgroundConfiguration.files(for: old.vaultID, root: root, keychain: keychain)?.sealed("fx") == config.files(root: root)?.sealed("fx"))
        #expect(BackgroundConfiguration.files(for: UUID(), root: root, keychain: keychain) == nil)
    }
    @Test("The source-named files earlier builds left, and files under an earlier key, are removed; nothing else is")
    func legacyFilesRemoved() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacy = BackgroundRefresh.sources.flatMap { ["Background-\($0).sealed", "Background-\($0).schedule"] } + ["Background-history.schedule"]
        let earlier = BackgroundFiles(root: root, key: BackgroundFiles.newKey())
        let background = legacy.map { root.appendingPathComponent($0) } + [earlier.sealed("fx"), earlier.schedule("history")]
        let kept = ["diagnostics.txt", "refresh.request", "Background notes.txt"].map { root.appendingPathComponent($0) }
        for url in background + kept { try Data("x".utf8).write(to: url) }
        BackgroundRefresh.deleteFiles(root: root)
        #expect(!background.contains { FileManager.default.fileExists(atPath: $0.path) })
        #expect(kept.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }
}

/// Networking stays opt-in: nothing is asked during setup or of a source that's off, the background configuration
/// fetches only for the vault on disk, credentials leave the login keychain, and what's sealed is checked again as applied.
struct NetworkOptInTests {
    private func temporaryRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("uponly-network-" + UUID().uuidString) }
    private func configuration(vaultID: UUID) -> BackgroundConfiguration {
        let inbox = VaultCrypto.makeInboxKeyPair(), signing = VaultCrypto.makeSigningKeyPair()
        return BackgroundConfiguration(vaultID: vaultID, inboxPublicKey: inbox.publicX963, signingPrivateKey: signing.privateX963, signingPublicKey: signing.publicX963, crypto: ["bitcoin"], currencies: ["EUR"], metals: [], pricesEnabled: true, fxEnabled: true, metalsEnabled: false, coinGeckoKey: "", fileKey: BackgroundFiles.newKey())
    }
    private func empty() -> VaultDocument {
        let inbox = VaultCrypto.makeInboxKeyPair()
        return VaultDocument.empty(inboxPrivateKeyX963: inbox.privateX963, inboxPublicKeyX963: inbox.publicX963)
    }
    @Test("Nothing is looked up before setup completes, and each source only with its own switch on")
    func lookupsFollowSwitches() async throws {
        var settings = AppSettings()
        settings.automaticPrices = true; settings.automaticFX = true; settings.automaticMetals = true
        let sources: [PriceHistoryRequest.Source] = [.crypto, .metal, .fx]
        let duringSetup = sources.map { settings.allowsLookups($0) }
        #expect(duringSetup == [false, false, false])
        settings.setupComplete = true
        let afterSetup = sources.map { settings.allowsLookups($0) }
        #expect(afterSetup == [true, true, true])
        settings.automaticPrices = false; settings.automaticMetals = false
        let fxOnly = sources.map { settings.allowsLookups($0) }
        #expect(fxOnly == [false, false, true])
        // A refresh while setup runs returns before any request, whatever its switches say.
        var doc = empty()
        doc.settings.automaticPrices = true; doc.settings.automaticFX = true; doc.settings.automaticMetals = true
        let portfolio = Portfolio(name: "Ledger", createdAt: Date().addingTimeInterval(-30 * 86400)); doc.portfolios = [portfolio]
        doc.holdings = [Holding(portfolioID: portfolio.id, assetID: try CanonicalAssetID("bitcoin"), assetName: "Bitcoin", createdAt: portfolio.createdAt)]
        doc.accounts = [Account(name: "Sample", currency: "EUR")]
        let update = try await PublicPrices.update(document: doc)
        #expect(update.quotes.isEmpty && update.rates.isEmpty && update.coverage.isEmpty && update.messages.isEmpty)
    }
    @Test("Background sources fetch only for the vault in the folder, named by its file's plain-text header")
    func configurationBelongsToVaultOnDisk() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let layout = VaultLayout(root: root.appendingPathComponent("Vault", isDirectory: true))
        let vaultID = UUID(), keychain = MemoryBackgroundStore(), config = configuration(vaultID: vaultID)
        try config.save(to: keychain)
        func header(_ id: UUID) throws -> Data { try JSONSerialization.data(withJSONObject: ["format": 1, "vaultID": id.uuidString, "generation": 3, "nonce": "", "ciphertext": "", "tag": ""]) }
        // No vault (deleted, or setup stopped after its recovery file): nothing is fetched.
        #expect(try BackgroundConfiguration.load(for: layout, keychain: keychain) == nil)
        try FileManager.default.createDirectory(at: layout.root, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: layout.recovery)
        #expect(try BackgroundConfiguration.load(for: layout, keychain: keychain) == nil)
        try header(vaultID).write(to: layout.current)
        #expect(try BackgroundConfiguration.load(for: layout, keychain: keychain) == config)
        // Another vault in its place (a restore, or setup after Start over): this configuration fetches nothing.
        try header(UUID()).write(to: layout.current)
        #expect(try BackgroundConfiguration.load(for: layout, keychain: keychain) == nil)
        // A current file that can't be read falls back to the previous copy's header; a link is never followed.
        try FileManager.default.removeItem(at: layout.current)
        let elsewhere = root.appendingPathComponent("elsewhere.uponly")
        try header(UUID()).write(to: elsewhere); try header(vaultID).write(to: layout.previous)
        try FileManager.default.createSymbolicLink(at: layout.current, withDestinationURL: elsewhere)
        #expect(layout.storedVaultID() == vaultID)
        #expect(try BackgroundConfiguration.load(for: layout, keychain: keychain) == config)
    }
    @Test("Start over, a new vault or another vault's restore deletes the configuration and what it left; the same vault keeps them")
    func forgetOtherVaults() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let vaultID = UUID(), keychain = MemoryBackgroundStore(), config = configuration(vaultID: vaultID), files = try #require(config.files(root: root))
        try config.save(to: keychain)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Named under its file key, and one an earlier build named by source: both go.
        let left = [files.sealed("crypto"), files.schedule("crypto"), files.schedule("history"), root.appendingPathComponent("Background-banks.sealed")]
        for url in left { try Data("x".utf8).write(to: url) }
        #expect(!BackgroundRefresh.forget(unless: vaultID, root: root, keychain: keychain))
        #expect(keychain.current != nil && left.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(BackgroundRefresh.forget(unless: UUID(), root: root, keychain: keychain))
        #expect(keychain.current == nil && !left.contains { FileManager.default.fileExists(atPath: $0.path) })
        // With no vault left, whatever is saved goes.
        try configuration(vaultID: vaultID).save(to: keychain)
        #expect(BackgroundRefresh.forget(unless: nil, root: root, keychain: keychain) && keychain.current == nil)
    }
    @Test("A credential provisioned into the login keychain moves to the data-protection Keychain, the login item going only once it's saved")
    func provisionedCredentialsMove() throws {
        let store = MemoryBackgroundStore(), first = Data("first".utf8), second = Data("second".utf8)
        #expect(try KeychainItem.provisioned(from: store) == nil)
        store.legacy = first
        // A move that fails leaves the login item where it is, still used.
        store.saveFails = true
        #expect(try KeychainItem.provisioned(from: store) == first)
        #expect(store.legacy == first && store.current == nil && !store.changes.contains("delete old"))
        store.saveFails = false
        #expect(try KeychainItem.provisioned(from: store) == first)
        #expect(store.current == first && store.legacy == nil && store.changes == ["save", "save", "delete old"])
        // Once moved, it's read from its new place.
        #expect(try KeychainItem.provisioned(from: store) == first && store.changes.count == 3)
        // Provisioned again, say with a new token: the login item wins and is moved.
        store.legacy = second
        #expect(try KeychainItem.provisioned(from: store) == second && store.current == second && store.legacy == nil)
        // A login item that can't be read now doesn't hide the moved one; with none moved, loading fails.
        store.legacy = first; store.unreadable = [true]
        #expect(try KeychainItem.provisioned(from: store) == second)
        store.current = nil
        #expect(throws: VaultError.unavailable) { _ = try KeychainItem.provisioned(from: store) }
        #expect(store.legacy == first)
    }
    @Test("A sealed packet is checked again as it's applied, and refused whole if anything in it is out of bounds")
    func sealedPacketsRevalidated() throws {
        var enabled = empty(); enabled.settings.automaticPrices = true; enabled.settings.automaticFX = true
        let doc = enabled, now = Date()
        func quote(_ id: String = "bitcoin", price: Decimal = 100, at time: Date? = nil) -> QuoteObservation {
            QuoteObservation(assetID: CanonicalAssetID(rawValue: id), priceUSD: PreciseDecimal(price), providerTime: time ?? now.addingTimeInterval(-60), fetchedAt: now, provider: "Synthetic")
        }
        func rate(_ currency: String = "EUR", _ value: Decimal = 2, at time: Date? = nil) -> FXObservation {
            FXObservation(sourceCurrency: currency, targetCurrency: "USD", rate: PreciseDecimal(value), providerTime: time ?? now.addingTimeInterval(-60), fetchedAt: now, provider: "Synthetic")
        }
        func crypto(_ quotes: [QuoteObservation]) throws -> VaultDocument { try BackgroundRefresh.applying(BackgroundPacket(source: "crypto", fetchedAt: now, prices: PriceUpdate(quotes: quotes)), to: doc, now: now) }
        func fx(_ update: PriceUpdate, fetchedAt: Date? = nil) throws -> VaultDocument { try BackgroundRefresh.applying(BackgroundPacket(source: "fx", fetchedAt: fetchedAt ?? now, prices: update), to: doc, now: now) }
        #expect(try crypto([quote()]).quotes.count == 1)
        for bad in [quote(price: 0), quote(price: -5), quote("Bit/coin"), quote(at: now.addingTimeInterval(600)), quote(at: Date(timeIntervalSince1970: 1_000_000_000))] {
            #expect(throws: (any Error).self) { try crypto([quote(), bad]) }
        }
        #expect(try fx(PriceUpdate(rates: [rate()])).fx.count == 1)
        for bad in [rate("eu"), rate("ZZZ"), rate("USD"), rate("EUR", 0), rate(at: now.addingTimeInterval(3600))] {
            #expect(throws: (any Error).self) { try fx(PriceUpdate(rates: [bad])) }
        }
        let backwards = PriceHistoryCoverage(key: "fx:EUR", start: now, end: now.addingTimeInterval(-86400), checkedAt: now, complete: true)
        #expect(throws: (any Error).self) { try fx(PriceUpdate(rates: [rate()], coverage: [backwards])) }
        // A packet dated ahead of this Mac's clock is refused too.
        #expect(throws: (any Error).self) { try fx(PriceUpdate(rates: [rate()]), fetchedAt: now.addingTimeInterval(3600)) }
    }
    @Test("Schedule and cache files are read only as plain files within their size, never through a link")
    func boundedCacheReads() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var doc = empty(); let config = configuration(vaultID: doc.vaultID), files = try #require(config.files(root: root))
        let vaultID = doc.vaultID, now = Date(timeIntervalSince1970: 1_800_000_000), schedule = BackgroundRefreshSchedule()
        #expect(try await schedule.claim(vaultID: vaultID, files: files, source: "crypto", now: now))
        #expect(try await !schedule.claim(vaultID: vaultID, files: files, source: "crypto", now: now.addingTimeInterval(60)))
        // Padded past 4 KiB, the record is no record, so the slot is free.
        let record = files.schedule("crypto")
        var padded = try Data(contentsOf: record); padded.append(Data(repeating: 0x20, count: 5000))
        try padded.write(to: record)
        #expect(try await schedule.claim(vaultID: vaultID, files: files, source: "crypto", now: now.addingTimeInterval(120)))
        // A cache file that's a link, or too big, is reported and never read.
        doc.backgroundSignerPublicKey = config.signingPublicKey
        let elsewhere = root.appendingPathComponent("elsewhere"), away = try #require(config.files(root: elsewhere))
        try BackgroundRefresh.save(BackgroundPacket(source: "fx", fetchedAt: Date(), prices: PriceUpdate()), configuration: config, root: elsewhere)
        try FileManager.default.createSymbolicLink(at: files.sealed("fx"), withDestinationURL: away.sealed("fx"))
        try Data(repeating: 0x20, count: 8 * 1024 * 1024 + 1).write(to: files.sealed("crypto"))
        let result = BackgroundRefresh.cachedPackets(document: doc, files: files)
        #expect(result.packets.isEmpty && Set(result.issues) == ["Fx cached data", "Crypto cached data"])
    }
    @Test("Accounting refreshes hourly, and a company left out counts as a failed attempt")
    func accountingSchedule() async throws {
        #expect(BackgroundRefreshSchedule.interval(for: "accounting") == 3600)
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let config = configuration(vaultID: UUID()), schedule = BackgroundRefreshSchedule()
        let missing = BusinessBook(id: "company", name: "Company", ownership: [], firstMonth: "2025-01", sourceURL: "", basis: "", fetchedAt: .distantPast)
        let ok = await BackgroundRefresh.scheduled("accounting", configuration: config, root: root, schedule: schedule, incomplete: { $0.books?.contains { $0.fetchedAt == .distantPast } == true }) {
            BackgroundPacket(source: "accounting", fetchedAt: Date(), books: [missing])
        }
        let files = try #require(config.files(root: root))
        #expect(!ok && FileManager.default.fileExists(atPath: files.sealed("accounting").path))
        #expect(await schedule.failed(vaultID: config.vaultID, files: files, source: "accounting"))
    }
    @Test("History is asked for only while a coin or metal was held, never after it was sold, nor for an invalid coin ID")
    func historyOnlyWhileHeld() throws {
        let now = try ImportDateFormat.iso.date("2026-09-20"), start = now.addingTimeInterval(-200 * 86400), sold = now.addingTimeInterval(-100 * 86400 + 3600)
        var doc = empty(); doc.settings.automaticPrices = true; doc.settings.automaticMetals = true
        let ledger = Portfolio(name: "Ledger", createdAt: start), safe = Portfolio(name: "Safe", createdAt: start, kind: .metals)
        doc.portfolios = [ledger, safe]
        let bitcoin = try CanonicalAssetID("bitcoin")
        doc.holdings = [Holding(portfolioID: ledger.id, assetID: bitcoin, assetName: "Bitcoin", createdAt: start), Holding(portfolioID: safe.id, assetID: PreciousMetal.gold.assetID, assetName: "Gold", createdAt: start)]
        func requests(_ source: PriceHistoryRequest.Source) -> [PriceHistoryRequest] { PriceHistory.requests(document: doc, now: now).filter { $0.source == source } }
        #expect(requests(.crypto).map(\.end).max() == now && requests(.metal).map(\.end).max() == now)
        // Sold: the coin's holding archived, and the gold's whole portfolio. Each is asked for through its last day.
        let lastDay = UTCDay.start(of: sold).addingTimeInterval(86400)
        doc.holdings[0].archivedAt = sold; doc.portfolios[1].archivedAt = sold
        #expect(requests(.crypto).map(\.start).min() == start && requests(.crypto).map(\.end).max() == lastDay)
        #expect(requests(.metal).map(\.end).max() == lastDay)
        // Bought again later: only that stretch is added, not the days in between.
        let again = now.addingTimeInterval(-10 * 86400)
        doc.holdings.append(Holding(portfolioID: ledger.id, assetID: bitcoin, assetName: "Bitcoin", createdAt: again))
        #expect(requests(.crypto).map(\.end).max() == now && !requests(.crypto).contains { $0.start < again && $0.end > lastDay })
        // An ID that isn't a valid coin ID is never asked for.
        doc.holdings.append(Holding(portfolioID: ledger.id, assetID: CanonicalAssetID(rawValue: "../markets"), assetName: "Bad", createdAt: start))
        #expect(!PriceHistory.requests(document: doc, now: now).contains { $0.identifier == "../markets" })
    }
    @Test("Coin IDs reach request paths only valid and percent-encoded, and a bad one can't cost the others their prices")
    func coinIDsInRequests() async throws {
        #expect(try PublicPrices.pathSegment("usd-coin") == "usd-coin")
        for bad in ["../markets", "bit/coin", "coin?x=1", "Bitcoin", "", "a%2Fb"] {
            #expect(throws: (any Error).self) { try PublicPrices.pathSegment(bad) }
        }
        // Refused before anything is sent.
        await #expect(throws: PriceError.invalidResponse) { try await PublicPrices.request(host: "api.coingecko.com", path: "/api/v3/coins/a b/market_chart/range", query: []) }
        await #expect(throws: PriceError.invalidResponse) { try await PublicPrices.request(host: "api.coingecko.com", path: "/api/v3/coins/%zz", query: []) }
        // Only invalid IDs: nothing to ask for, and no error.
        #expect(try await PublicPrices.marketQuotes(ids: ["bad id", "../x"], key: "").quotes.isEmpty)
    }
    @Test("Several buys are saved only under a valid coin ID")
    @MainActor func buysNeedValidCoinID() async throws {
        let layout = VaultLayout(root: URL(fileURLWithPath: "/tmp/uponly-network-test-" + UUID().uuidString))
        let session = UpOnlySession(testing: VaultStore(layout: layout, io: MemoryFileIO(), keys: MemoryKeyStore(), authenticator: FixtureAuthenticator()), layout: layout)
        await session.create(recovery: .random())
        let buy = UpOnlySession.Buy(quantity: 1, date: Date().addingTimeInterval(-86400), cost: 100)
        await #expect(throws: ImportFailure.self) {
            try await session.commitBuys(portfolioID: nil, portfolioName: "Ledger", owner: nil, assetID: "../markets", assetName: "Bad", kind: .crypto, buys: [buy])
        }
        #expect(session.document?.holdings.isEmpty == true)
        try await session.commitBuys(portfolioID: nil, portfolioName: "Ledger", owner: nil, assetID: "bitcoin", assetName: "Bitcoin", kind: .crypto, buys: [buy])
        #expect(session.document?.holdings.map(\.assetID.rawValue) == ["bitcoin"])
    }
}

#if UPONLY_FIXTURE
/// A socket the test feeds by hand: `send` delivers a message as Binance would, and `close` ends the connection, as
/// the server or the app would.
private final class FakeLiveSocket: LivePriceSocket, @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var queued: [Data] = []
    private var waiter: CheckedContinuation<Data, Error>?
    private var ended = false
    init(url: URL) { self.url = url }
    var closed: Bool { lock.withLock { ended } }
    func send(_ message: Data) {
        let waiting: CheckedContinuation<Data, Error>? = lock.withLock {
            guard !ended else { return nil }
            guard let next = waiter else { queued.append(message); return nil }
            waiter = nil
            return next
        }
        waiting?.resume(returning: message)
    }
    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let ready: Result<Data, Error>? = lock.withLock {
                if ended { return .failure(URLError(.networkConnectionLost)) }
                if !queued.isEmpty { return .success(queued.removeFirst()) }
                waiter = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }
    func close() {
        let waiting: CheckedContinuation<Data, Error>? = lock.withLock {
            ended = true
            defer { waiter = nil }
            return waiter
        }
        waiting?.resume(throwing: URLError(.cancelled))
    }
}
/// Every socket the session opened, in order, behind sources that list BTC and ETH on Binance and price nothing else.
private final class FakeLiveSockets: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [FakeLiveSocket] = []
    var opened: [FakeLiveSocket] { lock.withLock { all } }
    func open(_ url: URL) -> any LivePriceSocket {
        let socket = FakeLiveSocket(url: url)
        lock.withLock { all.append(socket) }
        return socket
    }
    var sources: LivePriceSources {
        LivePriceSources(book: { ["BTCUSDT": 61000, "ETHUSDT": 2500] }, open: { [self] in self.open($0) }, gecko: { _, _ in [] })
    }
}
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func add() { lock.withLock { value += 1 } }
}

/// Live prices while the menu is open: the stream's URL and messages are checked, live prices only ever stand in for
/// older saved ones in today's figures, and the stream runs only while the menu is open, unlocked and priced.
@Suite("Live prices while the menu is open")
@MainActor struct LivePriceTests {
    private let now = Date(timeIntervalSince1970: 1_790_256_000)
    private let bitcoin = CanonicalAssetID(rawValue: "bitcoin")
    /// A combined-stream mini-ticker message, as Binance sends it.
    private func tick(_ pair: String = "BTCUSDT", event: String = "24hrMiniTicker", stream: String? = nil, price: String = "61000.50", at time: Date) -> Data {
        let millis = Int64((time.timeIntervalSince1970 * 1000).rounded()), name = stream ?? pair.lowercased() + "@miniTicker"
        return Data(#"{"stream":"\#(name)","data":{"e":"\#(event)","E":\#(millis),"s":"\#(pair)","c":"\#(price)","o":"60000","h":"61500","l":"59000","v":"10","q":"600000"}}"#.utf8)
    }
    /// An unlocked vault, set up with crypto prices on, holding 2 BTC last saved at $60,000 ten minutes ago.
    private func unlockedSession() async throws -> UpOnlySession {
        let layout = VaultLayout(root: URL(fileURLWithPath: "/tmp/uponly-live-test-" + UUID().uuidString))
        let session = UpOnlySession(testing: VaultStore(layout: layout, io: MemoryFileIO(), keys: MemoryKeyStore(), authenticator: FixtureAuthenticator()), layout: layout)
        await session.create(recovery: .random())
        try await session.completeSetup(tracked: [.crypto], prices: true, fx: false, key: "")
        let held = Date().addingTimeInterval(-2 * 86400), saved = Date().addingTimeInterval(-600)
        try await session.mutate { doc in
            let portfolio = Portfolio(name: "Ledger", createdAt: held.addingTimeInterval(-60))
            doc.portfolios.append(portfolio)
            doc = try HoldingMutations.addHolding(portfolioID: portfolio.id, assetID: CanonicalAssetID("bitcoin"), assetName: "Bitcoin", quantity: 2, at: held, document: doc)
            doc.quotes.append(QuoteObservation(assetID: CanonicalAssetID(rawValue: "bitcoin"), priceUSD: PreciseDecimal(60000), providerTime: saved, fetchedAt: saved, provider: "Binance"))
        }
        return session
    }
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition(), "The live prices did not get there in time")
    }

    @Test("The stream's URL names only valid pairs, lowercased and once each, at most 100, and only it opens")
    func streamURL() throws {
        let stream = try #require(PublicPrices.liveStream(["BTCUSDT", "ethusdt", "BTCUSDT", "BTC/USDT", "x", "ÉTHUSDT", "../stream", "btc@miniticker", "BTC USDT", String(repeating: "A", count: 21)]))
        #expect(stream.url.absoluteString == "wss://stream.binance.com:443/stream?streams=btcusdt@miniTicker/ethusdt@miniTicker")
        #expect(stream.pairs == ["BTCUSDT", "ETHUSDT"])
        let many = try #require(PublicPrices.liveStream((0..<150).map { "COIN\($0)USDT" }))
        #expect(many.pairs.count == 100 && many.url.absoluteString.components(separatedBy: "@miniTicker").count == 101)
        #expect(PublicPrices.liveStream(["", "a", "BTC-USDT"]) == nil && PublicPrices.liveStream([]) == nil)
        // Nothing else is opened: another host, port or path is refused before any connection.
        for text in ["wss://example.com:443/stream?streams=btcusdt@miniTicker", "wss://stream.binance.com:9443/stream?streams=btcusdt@miniTicker",
                     "ws://stream.binance.com:443/stream?streams=btcusdt@miniTicker", "wss://stream.binance.com:443/ws/btcusdt@miniTicker"] {
            #expect(throws: (any Error).self) { try PublicPrices.openLiveStream(URL(string: text)!) }
        }
    }
    @Test("Only a fresh mini-ticker for a subscribed pair, with a sane exact price, becomes a live price")
    func parsing() {
        let subscribed = ["BTCUSDT": LiveSubscription(asset: bitcoin, reference: 60000)]
        func decode(_ data: Data) -> (asset: CanonicalAssetID, price: LivePrice)? { PublicPrices.decodeLiveTick(data, subscribed: subscribed, now: now) }
        let good = decode(tick(at: now.addingTimeInterval(-1)))
        #expect(good?.asset == bitcoin && good?.price == LivePrice(price: Decimal(string: "61000.5")!, time: now.addingTimeInterval(-1), streamed: true))
        // Another event, a pair not asked for, or a stream named for another pair.
        #expect(decode(tick(event: "24hrTicker", at: now)) == nil)
        #expect(decode(tick("ETHUSDT", price: "2500", at: now)) == nil)
        #expect(decode(tick(stream: "ethusdt@miniTicker", at: now)) == nil)
        // Prices that aren't exact positive decimals, or aren't near the saved price.
        for price in ["abc", "-61000", "0", "6.1e4", "NaN", "", "1000000000000000000000000000", "999999", "20000"] {
            #expect(decode(tick(price: price, at: now)) == nil, "\(price)")
        }
        #expect(decode(tick(price: "89000", at: now)) != nil)
        // Older than five minutes, or ahead of the Mac's clock by more than a few seconds; a second ahead counts as now.
        #expect(decode(tick(at: now.addingTimeInterval(-301))) == nil && decode(tick(at: now.addingTimeInterval(-299))) != nil)
        #expect(decode(tick(at: now.addingTimeInterval(60))) == nil)
        #expect(decode(tick(at: now.addingTimeInterval(1)))?.price.time == now)
        // Anything else Binance might send, or not JSON at all, or too large.
        #expect(decode(Data(#"{"result":null,"id":1}"#.utf8)) == nil && decode(Data("not json".utf8)) == nil)
        #expect(decode(Data(#"{"stream":"btcusdt@miniTicker","data":{"e":"24hrMiniTicker","E":1790256000000,"s":"BTCUSDT"}}"#.utf8)) == nil)
        var padded = tick(at: now); padded.insert(contentsOf: Data(repeating: 0x20, count: 70_000), at: padded.count - 1)
        #expect(decode(padded) == nil)
    }
    @Test("A live price newer than the saved one values today's figures and moves; an older one doesn't")
    func overlay() throws {
        let inbox = VaultCrypto.makeInboxKeyPair()
        var doc = VaultDocument.empty(inboxPrivateKeyX963: inbox.privateX963, inboxPublicKeyX963: inbox.publicX963)
        let portfolio = Portfolio(name: "Ledger", createdAt: now.addingTimeInterval(-3 * 86400)); doc.portfolios = [portfolio]
        doc = try HoldingMutations.addHolding(portfolioID: portfolio.id, assetID: bitcoin, assetName: "Bitcoin", quantity: 2, at: now.addingTimeInterval(-2 * 86400), document: doc)
        doc.quotes = [QuoteObservation(assetID: bitcoin, priceUSD: PreciseDecimal(50000), providerTime: now.addingTimeInterval(-86400), fetchedAt: now, provider: "Binance"),
                      QuoteObservation(assetID: bitcoin, priceUSD: PreciseDecimal(60000), providerTime: now.addingTimeInterval(-600), fetchedAt: now, provider: "Binance")]
        let newer = LivePrice(price: 61000, time: now.addingTimeInterval(-5), streamed: true), older = LivePrice(price: 59000, time: now.addingTimeInterval(-900), streamed: true)
        let live = PublicPrices.overlaying([bitcoin: newer], on: doc), stale = PublicPrices.overlaying([bitcoin: older], on: doc)
        #expect(NetWorthCalculator.value(at: now, scope: .allTracked, document: live, now: now).total == 122000)
        #expect(NetWorthCalculator.value(at: now, scope: .allTracked, document: stale, now: now).total == 120000)
        #expect(stale.quotes == doc.quotes && live.quotes.count == doc.quotes.count + 1 && live.quotes.last?.provider == "Binance · live")
        // The holding's move over the day follows the newer live price, and not an older one.
        let estimates = ChartEstimates(document: doc), dayAgo = now.addingTimeInterval(-86400)
        #expect(estimates.priceChange(bitcoin, since: dayAgo, now: now) == Decimal(string: "0.2"))
        #expect(estimates.priceChange(bitcoin, since: dayAgo, now: now, live: newer) == Decimal(string: "0.22"))
        #expect(estimates.priceChange(bitcoin, since: dayAgo, now: now, live: older) == Decimal(string: "0.2"))
    }
    @Test("Reconnects wait a second after a working connection, doubling to a minute while they fail")
    func backoff() {
        var delay: TimeInterval?, waits: [TimeInterval] = []
        for _ in 0..<8 { let next = PublicPrices.liveRetryDelay(after: delay); waits.append(next); delay = next }
        #expect(waits == [1, 2, 4, 8, 16, 32, 60, 60])
    }
    @Test("The stream runs while the menu is open, shows in today's figures without saving, reconnects, and stops at close and lock")
    func lifecycle() async throws {
        let session = try await unlockedSession()
        // The fixture build never streams by itself.
        #expect(session.liveSources == nil)
        let sockets = FakeLiveSockets()
        session.liveSources = sockets.sources
        let generation = try #require(session.document?.generation)
        session.menuOpened()
        try await waitFor { sockets.opened.count == 1 }
        #expect(sockets.opened.first?.url.absoluteString == "wss://stream.binance.com:443/stream?streams=btcusdt@miniTicker")
        sockets.opened[0].send(tick(at: Date().addingTimeInterval(-1)))
        try await waitFor { session.livePrices[bitcoin]?.price == Decimal(string: "61000.5") }
        #expect(session.liveStreaming)
        let priced = try #require(session.pricedDocument())
        let valuation = NetWorthCalculator.value(at: Date(), scope: .allTracked, document: priced)
        #expect(valuation.total == Decimal(string: "122001") && session.isLive(valuation.components))
        // Nothing is saved for it: the vault keeps its one saved price and generation.
        #expect(session.document?.generation == generation && session.document?.quotes.count == 1)
        // A dropped connection (Binance ends each after a day) reconnects after a second.
        sockets.opened[0].close()
        try await waitFor { sockets.opened.count == 2 }
        // Closing the menu closes the socket, and nothing reconnects.
        session.surfaceClosed()
        try await waitFor { sockets.opened[1].closed }
        #expect(!session.liveStreaming)
        try await Task.sleep(for: .milliseconds(1500))
        #expect(sockets.opened.count == 2)
        // Opening it again streams again; locking closes the socket and discards what streamed.
        session.menuOpened()
        try await waitFor { sockets.opened.count == 3 }
        session.lock()
        try await waitFor { sockets.opened[2].closed }
        #expect(session.livePrices.isEmpty && !session.liveStreaming && session.pricedDocument() == nil)
    }
    @Test("Switching crypto prices off stops the stream and drops what streamed")
    func pricesOff() async throws {
        let session = try await unlockedSession()
        let sockets = FakeLiveSockets()
        session.liveSources = sockets.sources
        session.menuOpened()
        try await waitFor { sockets.opened.count == 1 }
        sockets.opened[0].send(tick(at: Date()))
        try await waitFor { session.livePrices[bitcoin] != nil }
        try await session.saveSources(prices: false, fx: false, key: "")
        try await waitFor { sockets.opened[0].closed }
        #expect(session.livePrices.isEmpty && !session.liveStreaming)
    }
    @Test("A coin Binance doesn't list is priced from CoinGecko at most once a minute, and isn't marked live")
    func unlisted() async throws {
        let session = try await unlockedSession()
        let calls = CallCounter()
        session.liveSources = LivePriceSources(book: { [:] }, open: { _ in throw PriceError.unavailable }, gecko: { ids, _ in
            calls.add()
            return ids.map { QuoteObservation(assetID: CanonicalAssetID(rawValue: $0), priceUSD: PreciseDecimal(60500), providerTime: Date(), fetchedAt: Date(), provider: "CoinGecko") }
        })
        session.menuOpened()
        try await waitFor { session.livePrices[bitcoin]?.price == 60500 }
        #expect(session.livePrices[bitcoin]?.streamed == false && !session.liveStreaming)
        let priced = try #require(session.pricedDocument())
        #expect(!session.isLive(NetWorthCalculator.value(at: Date(), scope: .allTracked, document: priced).components))
        try await Task.sleep(for: .seconds(2))
        #expect(calls.count == 1)
        // Reopening within the minute doesn't ask again.
        session.surfaceClosed(); session.menuOpened()
        try await Task.sleep(for: .milliseconds(1500))
        #expect(calls.count == 1)
    }
    @Test("A second's prices from an earlier unlock never reach a later one, and an older price never replaces a newer")
    func fenced() async throws {
        let session = try await unlockedSession()
        let token = session.sessionToken, price = LivePrice(price: 61000, time: Date(), streamed: true)
        session.lock()
        await session.unlock()
        #expect(session.state == .unlocked)
        session.publishLive([bitcoin: price], streaming: true, token: token)
        #expect(session.livePrices.isEmpty && !session.liveStreaming)
        session.publishLive([bitcoin: price], streaming: true, token: session.sessionToken)
        #expect(session.livePrices[bitcoin] == price && session.liveStreaming)
        session.publishLive([bitcoin: LivePrice(price: 1, time: price.time.addingTimeInterval(-10), streamed: true)], streaming: true, token: session.sessionToken)
        #expect(session.livePrices[bitcoin] == price)
    }
}
#endif

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

struct DataSourceTests {
    private let now = Date(timeIntervalSince1970: 1_790_256_000)
    @Test("The market list gives prices only for coins asked about, and every listed coin's ticker")
    func markets() throws {
        let data = Data(#"[{"id":"bitcoin","symbol":"btc","current_price":60000.5,"last_updated":"2026-09-24T10:00:00.000Z"},{"id":"ethereum","symbol":"eth","current_price":2500,"last_updated":"2026-09-24T10:00:00Z"},{"id":"quiet","symbol":"q","current_price":null,"last_updated":null}]"#.utf8)
        let listed = try PublicPrices.decodeMarkets(data, wanted: ["bitcoin", "quiet"], fetchedAt: now)
        #expect(listed.quotes.map(\.assetID.rawValue) == ["bitcoin"] && listed.quotes.first?.priceUSD.value == Decimal(string: "60000.5"))
        #expect(listed.symbols == ["bitcoin": "btc", "ethereum": "eth", "quiet": "q"])
    }
    @Test("Binance daily candles become each closed day's closing price")
    func klines() throws {
        let data = Data(#"[[1577836800000,"7195.24","7255.00","7175.15","7200.85","16792.3",1577923199999,"x",1,"x","x","0"],[1577923200000,"7200.77","7212.5","6924.74","6965.71","1",1578009599999,"x",1,"x","x","0"]]"#.utf8)
        let start = Date(timeIntervalSince1970: 1_577_836_800), end = start.addingTimeInterval(86400)
        let quotes = try PublicPrices.decodeKlines(data, asset: try CanonicalAssetID("bitcoin"), start: start, end: end, fetchedAt: now)
        #expect(quotes.count == 1 && quotes[0].priceUSD.value == Decimal(string: "7200.85") && quotes[0].provider == "Binance · daily close")
        #expect(PublicPrices.binancePair("btc") == "BTCUSDT" && PublicPrices.binancePair("usdt") == nil && PublicPrices.binancePair("a-b") == nil)
        #expect(PublicPrices.knownSymbols["bitcoin"] == "btc" && PublicPrices.knownSymbols.count >= 200)
    }
    @Test("Wise rates are USD per unit, one a day for a range and dated to the UTC day")
    func wiseRates() throws {
        let daily = Data(#"[{"rate":1.1,"source":"EUR","target":"USD","time":"2026-09-01T00:00:00+0000"},{"rate":1.12,"source":"EUR","target":"USD","time":"2026-09-02T00:00:00+0000"}]"#.utf8)
        let rates = try PublicPrices.decodeWiseRates(daily, currency: "EUR", fetchedAt: now, daily: true)
        #expect(rates.map(\.rate.value) == [Decimal(string: "1.1"), Decimal(string: "1.12")] && rates.allSatisfy { $0.provider == "Wise" && UTCDay.start(of: $0.providerTime) == $0.providerTime })
        let latest = Data(#"[{"rate":4125.5,"source":"COP","target":"USD","time":"2026-09-24T10:43:31+0000"}]"#.utf8)
        #expect(throws: (any Error).self) { try PublicPrices.decodeWiseRates(latest, currency: "EUR", fetchedAt: now, daily: false) }
        let cop = try PublicPrices.decodeWiseRates(latest, currency: "COP", fetchedAt: now, daily: false)
        #expect(cop.count == 1 && cop[0].providerTime == Date(timeIntervalSince1970: 1_790_246_611))
    }
    @Test("Swissquote's gold quote is the tightest spread's mid-price, per gram")
    func swissquote() throws {
        let data = Data(#"[{"topo":{"platform":"AT","server":"AT"},"spreadProfilePrices":[{"spreadProfile":"standard","bidSpread":27.0,"askSpread":27.0,"bid":4276.345,"ask":4277.035},{"spreadProfile":"prime","bidSpread":24.25,"askSpread":24.25,"bid":4276.373,"ask":4277.008}],"ts":1790256132290}]"#.utf8)
        let quote = try PublicPrices.decodeSwissquote(data, metal: .gold, fetchedAt: now.addingTimeInterval(200))
        #expect(quote.assetID == PreciousMetal.gold.assetID && quote.provider == "Swissquote · spot")
        #expect(quote.priceUSD.value == (try PriceHistory.pricePerGram(Decimal(string: "4276.6905")!)))
    }
    @Test("Crypto history is asked for from when a coin was first held, not only the past year")
    func fullHistory() throws {
        var doc = VaultDocument.empty(inboxPrivateKeyX963: VaultCrypto.makeInboxKeyPair().privateX963, inboxPublicKeyX963: VaultCrypto.makeInboxKeyPair().publicX963)
        doc.settings.automaticPrices = true
        let held = now.addingTimeInterval(-700 * 86400)
        let portfolio = Portfolio(name: "Ledger", createdAt: held.addingTimeInterval(-86400)); doc.portfolios = [portfolio]
        doc = try HoldingMutations.addHolding(portfolioID: portfolio.id, assetID: CanonicalAssetID("bitcoin"), assetName: "Bitcoin", quantity: 1, at: held, document: doc)
        let requests = PriceHistory.requests(document: doc, now: now).filter { $0.source == .crypto }
        #expect(requests.map(\.start).min() == UTCDay.start(of: held))
    }
}

struct IntradayTests {
    private let now = Date(timeIntervalSince1970: 1_790_256_000)
    @Test("Binance candles give each candle's open at its start and the latest close now")
    func candles() throws {
        let data = Data(#"[[1790254200000,"100.0","101","99","100.5","1",1790255099999,"x",1,"x","x","0"],[1790255100000,"100.5","102","100","101.5","1",1790255999999,"x",1,"x","x","0"]]"#.utf8)
        let series = try PublicPrices.decodeCandles(data, now: now)
        #expect(series.map(\.value) == [100, Decimal(string: "100.5")!, Decimal(string: "101.5")!])
        #expect(series.last?.time == now && series.first?.time == Date(timeIntervalSince1970: 1_790_254_200))
    }
    @Test("CoinGecko's chart points come back oldest first, bad points skipped")
    func chartPrices() throws {
        let data = Data(#"{"prices":[[1790255000000,61000.5],[1790254000000,60900],[1790254500000,null]]}"#.utf8)
        let series = try PublicPrices.decodeChartPrices(data, now: now)
        #expect(series.map(\.value) == [60900, Decimal(string: "61000.5")!])
    }
    @Test("A step takes the latest price at or before it, or the first before them all")
    func latest() {
        let series: ChartEstimates.Series = [(now.addingTimeInterval(-900), 1), (now, 2)]
        #expect(ChartEstimates.latest(series, at: now.addingTimeInterval(-60)) == 1)
        #expect(ChartEstimates.latest(series, at: now.addingTimeInterval(-3600)) == 1)
        #expect(ChartEstimates.latest(series, at: now.addingTimeInterval(60)) == 2)
        #expect(ChartEstimates.latest([], at: now) == nil)
    }
    @Test("Finer charts mark midnights over 7 days and Mondays over 30, on the Mac's clock")
    func marks() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = Date(timeIntervalSince1970: 1_789_603_200) // Thu Sep 17, 2026, 00:00 UTC
        let hourly = (0..<(7 * 24)).map { start.addingTimeInterval(TimeInterval($0) * 3600) }
        #expect(DashboardChart.localMarks(hourly, range: .week, calendar: calendar).compactMap { $0 } == ["Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed"])
        let fourHourly = (0..<(30 * 6)).map { start.addingTimeInterval(TimeInterval($0) * 4 * 3600) }
        #expect(DashboardChart.localMarks(fourHourly, range: .month, calendar: calendar).compactMap { $0 } == ["Sep 21", "Sep 28", "Oct 5", "Oct 12"])
        #expect(WorthRange.day.intradayStep == 900 && WorthRange.week.candleInterval == "1h" && WorthRange.year.intradayStep == nil)
    }

    @Test("An account's bank is found from its name, and typing suggests banks")
    func bankCatalog() {
        // The bundled catalog is there, each bank with its logo.
        #expect(BankCatalog.all.count > 40 && BankCatalog.all.allSatisfy(\.logo))
        #expect(BankCatalog.bank(named: "Monzo Joint")?.id == "monzo")
        #expect(BankCatalog.bank(named: "credit agricole")?.name == "Crédit Agricole")
        #expect(BankLogos.logo(for: "Personal · USD", synced: true) == "wise")
        // Everyday words on their own don't name a bank.
        #expect(BankCatalog.bank(named: "Joint savings") == nil)
        #expect(BankCatalog.suggestions("cha").contains { $0.id == "chase" })
        #expect(BankCatalog.suggestions("bank of am").first?.id == "bank-of-america")
        #expect(BankCatalog.suggestions("").isEmpty)
    }

    @Test("The currency field keeps three capital letters and suggests real currencies until one is typed")
    func currencyField() {
        #expect(CurrencyCodes.cleaned("gbp") == "GBP")
        #expect(CurrencyCodes.cleaned("e1u-rx") == "EUR")
        #expect(CurrencyCodes.cleaned("£é") == "")
        #expect(Array(CurrencyCodes.all.prefix(3)) == ["USD", "EUR", "GBP"])
        // The same check saving uses.
        #expect(CurrencyCodes.isValid("CHF") && !CurrencyCodes.isValid("XQZ") && !CurrencyCodes.isValid(""))
        let english = Locale(identifier: "en_US")
        #expect(CurrencyCodes.suggestions(for: "", locale: english).isEmpty)
        #expect(CurrencyCodes.suggestions(for: "GBP", locale: english).isEmpty)
        #expect(CurrencyCodes.suggestions(for: "G", locale: english).first == "GBP")
        // By name too, at most five.
        #expect(CurrencyCodes.suggestions(for: "YEN", locale: english).contains("JPY"))
        #expect(CurrencyCodes.suggestions(for: "DOL", locale: english).count == 5)
    }
}
