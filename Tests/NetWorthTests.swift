import Foundation
import Testing
@testable import UpOnly

struct NetWorthTests {
    private func utc(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12, minute: Int = 0) -> Date {
        var parts = DateComponents()
        parts.calendar = Calendar(identifier: .gregorian)
        parts.timeZone = TimeZone(secondsFromGMT: 0)
        parts.year = year
        parts.month = month
        parts.day = day
        parts.hour = hour
        parts.minute = minute
        return parts.date!
    }

    private func document() -> VaultDocument {
        let inbox = VaultCrypto.makeInboxKeyPair()
        return VaultDocument.empty(
            inboxPrivateKeyX963: inbox.privateX963,
            inboxPublicKeyX963: inbox.publicX963
        )
    }

    @Test("The same coin can live in two portfolios")
    func multiPortfolioSameCoin() throws {
        let day = utc(2026, 9, 4)
        var doc = document()
        let cold = Portfolio(name: "Cold", createdAt: utc(2026, 8, 1))
        let hot = Portfolio(name: "Hot", createdAt: utc(2026, 8, 1))
        doc.portfolios = [cold, hot]
        doc = try HoldingMutations.addHolding(
            portfolioID: cold.id, assetID: CanonicalAssetID("bitcoin"),
            assetName: "Bitcoin", quantity: 2, at: day, document: doc
        )
        doc = try HoldingMutations.addHolding(
            portfolioID: hot.id, assetID: CanonicalAssetID("bitcoin"),
            assetName: "Bitcoin", quantity: 0.5, at: day, document: doc
        )
        doc.quotes = [
            QuoteObservation(
                assetID: try CanonicalAssetID("bitcoin"),
                priceUSD: PreciseDecimal(10_000),
                providerTime: day,
                fetchedAt: day,
                provider: "coingecko"
            ),
        ]
        let all = NetWorthCalculator.value(at: day, scope: .allTracked, document: doc, now: day)
        #expect(all.total == Decimal(25_000))
        let coldValue = NetWorthCalculator.value(at: day, scope: .portfolio(cold.id), document: doc, now: day)
        let hotValue = NetWorthCalculator.value(at: day, scope: .portfolio(hot.id), document: doc, now: day)
        #expect(coldValue.total == 20_000)
        #expect(hotValue.total == 5_000)
    }

    @Test("Tiny quantities keep Decimal precision")
    func precision() throws {
        let day = utc(2026, 9, 4)
        var doc = document()
        let portfolio = Portfolio(name: "Dust", createdAt: utc(2026, 8, 1))
        doc.portfolios = [portfolio]
        let qty = Decimal(string: "0.00000001")!
        doc = try HoldingMutations.addHolding(
            portfolioID: portfolio.id, assetID: CanonicalAssetID("bitcoin"),
            assetName: "Bitcoin", quantity: qty, at: day, document: doc
        )
        doc.quotes = [
            QuoteObservation(
                assetID: try CanonicalAssetID("bitcoin"),
                priceUSD: PreciseDecimal(Decimal(string: "100000.00")!),
                providerTime: day, fetchedAt: day, provider: "coingecko"
            ),
        ]
        let result = NetWorthCalculator.value(at: day, scope: .allTracked, document: doc, now: day)
        #expect(result.total == Decimal(string: "0.001"))
    }

    @Test("Zero quantity closes a holding")
    func zeroCloses() throws {
        let open = utc(2026, 9, 1)
        let close = utc(2026, 9, 4)
        var doc = document()
        let portfolio = Portfolio(name: "Main", createdAt: utc(2026, 8, 1))
        doc.portfolios = [portfolio]
        doc = try HoldingMutations.addHolding(
            portfolioID: portfolio.id, assetID: CanonicalAssetID("bitcoin"),
            assetName: "Bitcoin", quantity: 1, at: open, document: doc
        )
        let holdingID = doc.holdings[0].id
        doc = try HoldingMutations.setQuantity(holdingID: holdingID, quantity: 0, at: close, document: doc)
        doc.quotes = [
            QuoteObservation(
                assetID: try CanonicalAssetID("bitcoin"),
                priceUSD: PreciseDecimal(10),
                providerTime: close, fetchedAt: close, provider: "coingecko"
            ),
        ]
        let result = NetWorthCalculator.value(at: close, scope: .allTracked, document: doc, now: close)
        #expect(result.components.isEmpty)
        #expect(result.total == 0)
    }

    @Test("A move is atomic and rolls back on failure")
    func moveInvariantAndRollback() throws {
        let day = utc(2026, 9, 4)
        var doc = document()
        let a = Portfolio(name: "A", createdAt: utc(2026, 8, 1))
        let b = Portfolio(name: "B", createdAt: utc(2026, 8, 1))
        doc.portfolios = [a, b]
        let btc = try CanonicalAssetID("bitcoin")
        doc = try HoldingMutations.addHolding(
            portfolioID: a.id, assetID: btc, assetName: "Bitcoin", quantity: 2, at: day, document: doc
        )
        doc = try HoldingMutations.addHolding(
            portfolioID: b.id, assetID: btc, assetName: "Bitcoin", quantity: 1, at: day, document: doc
        )
        let before = doc
        #expect(throws: VaultError.insufficientQuantity) {
            _ = try HoldingMutations.moveHolding(
                assetID: btc, quantity: 5, from: a.id, to: b.id, at: day, document: doc
            )
        }
        #expect(doc.quantities.map(\.quantity.value) == before.quantities.map(\.quantity.value))

        doc = try HoldingMutations.moveHolding(
            assetID: btc, quantity: Decimal(string: "0.5")!, from: a.id, to: b.id, at: day, document: doc
        )
        let sourceQty = doc.effectiveQuantity(holdingID: doc.holdings.first { $0.portfolioID == a.id }!.id, at: day)
        let destQty = doc.effectiveQuantity(holdingID: doc.holdings.first { $0.portfolioID == b.id }!.id, at: day)
        #expect(sourceQty == Decimal(string: "1.5"))
        #expect(destQty == Decimal(string: "1.5"))
        #expect((sourceQty ?? 0) + (destQty ?? 0) == 3)
        #expect(throws: VaultError.samePortfolio) {
            _ = try HoldingMutations.moveHolding(
                assetID: btc, quantity: 1, from: a.id, to: a.id, at: day, document: doc
            )
        }
    }

    @Test("Later quantity edits do not rewrite a stored prior sample")
    func historicalQuantityPreserved() throws {
        let day1 = utc(2026, 9, 1)
        let day4 = utc(2026, 9, 4)
        var doc = document()
        let portfolio = Portfolio(name: "Main", createdAt: utc(2026, 8, 1))
        doc.portfolios = [portfolio]
        doc = try HoldingMutations.addHolding(
            portfolioID: portfolio.id, assetID: CanonicalAssetID("bitcoin"),
            assetName: "Bitcoin", quantity: 1, at: day1, document: doc
        )
        doc.quotes = [
            QuoteObservation(
                assetID: try CanonicalAssetID("bitcoin"),
                priceUSD: PreciseDecimal(100),
                providerTime: day1, fetchedAt: day1, provider: "coingecko"
            ),
        ]
        let first = NetWorthCalculator.value(at: day1, scope: .allTracked, document: doc, now: day1)
        doc = NetWorthCalculator.recordingSample(first, in: doc)
        let holdingID = doc.holdings[0].id
        doc = try HoldingMutations.setQuantity(holdingID: holdingID, quantity: 5, at: day4, document: doc)
        doc.quotes.append(
            QuoteObservation(
                assetID: try CanonicalAssetID("bitcoin"),
                priceUSD: PreciseDecimal(200),
                providerTime: day4, fetchedAt: day4, provider: "coingecko"
            )
        )
        let historic = NetWorthCalculator.value(at: day1, scope: .allTracked, document: doc, now: day4)
        #expect(historic.total == 100)
        let current = NetWorthCalculator.value(at: day4, scope: .allTracked, document: doc, now: day4)
        #expect(current.total == 1_000)
    }

    @Test("Archive keeps history and drops the portfolio from current totals")
    func archivePreservesHistory() throws {
        let day1 = utc(2026, 9, 1)
        let day4 = utc(2026, 9, 4)
        var doc = document()
        let portfolio = Portfolio(name: "Old", createdAt: utc(2026, 8, 1))
        doc.portfolios = [portfolio]
        doc = try HoldingMutations.addHolding(
            portfolioID: portfolio.id, assetID: CanonicalAssetID("bitcoin"),
            assetName: "Bitcoin", quantity: 1, at: day1, document: doc
        )
        doc.quotes = [
            QuoteObservation(
                assetID: try CanonicalAssetID("bitcoin"),
                priceUSD: PreciseDecimal(100),
                providerTime: day1, fetchedAt: day1, provider: "coingecko"
            ),
        ]
        doc = NetWorthCalculator.recordingSample(
            NetWorthCalculator.value(at: day1, scope: .allTracked, document: doc, now: day1),
            in: doc
        )
        doc = try HoldingMutations.archivePortfolio(id: portfolio.id, at: day4, document: doc)
        let historic = NetWorthCalculator.value(at: day1, scope: .allTracked, document: doc, now: day4)
        let current = NetWorthCalculator.value(at: day4, scope: .allTracked, document: doc, now: day4)
        #expect(historic.total == 100)
        #expect(current.total == nil)
        #expect(current.isUnavailable)
        #expect(current.components.isEmpty)
    }

    @Test("USD is identity 1 and missing FX never becomes 1")
    func currenciesAndFX() throws {
        let day = utc(2026, 9, 4)
        var doc = document()
        let usd = Account(name: "Wise USD", currency: "USD")
        let eur = Account(name: "Wise EUR", currency: "EUR")
        doc.accounts = [usd, eur]
        doc.trackedBankAccountIDs = [usd.id, eur.id]
        doc.bankBalances = [
            BankBalanceObservation(
                id: UUID(), accountID: usd.id, amount: PreciseDecimal(100),
                currency: "USD", observedAt: day, source: "wise", sourceIdentity: "usd"
            ),
            BankBalanceObservation(
                id: UUID(), accountID: eur.id, amount: PreciseDecimal(100),
                currency: "EUR", observedAt: day, source: "wise", sourceIdentity: "eur"
            ),
        ]
        let missing = NetWorthCalculator.value(at: day, scope: .banks, document: doc, now: day)
        #expect(missing.total == nil)
        #expect(missing.missing.contains { $0.reason == "fx" })
        #expect(missing.components.first { $0.id == usd.id }?.usdValue?.value == 100)

        doc.fx = [
            FXObservation(
                sourceCurrency: "EUR", targetCurrency: "USD",
                rate: PreciseDecimal(Decimal(string: "1.10")!),
                providerTime: day, fetchedAt: day, provider: "wise"
            ),
        ]
        let valued = NetWorthCalculator.value(at: day, scope: .banks, document: doc, now: day)
        #expect(valued.total == Decimal(string: "210"))
    }

    @Test("Overdrafts subtract")
    func overdraft() throws {
        let day = utc(2026, 9, 4)
        var doc = document()
        let checking = Account(name: "Sample bank", currency: "USD")
        doc.accounts = [checking]
        doc.trackedBankAccountIDs = [checking.id]
        doc.bankBalances = [
            BankBalanceObservation(
                id: UUID(), accountID: checking.id, amount: PreciseDecimal(-20),
                currency: "USD", observedAt: day, source: "manual", sourceIdentity: "monzo"
            ),
        ]
        let result = NetWorthCalculator.value(at: day, scope: .banks, document: doc, now: day)
        #expect(result.total == -20)
    }

    @Test("Internal bank transfers do not create wealth")
    func internalTransfer() throws {
        let day = utc(2026, 9, 4)
        var doc = document()
        let a = Account(name: "Sample bank", currency: "USD")
        let b = Account(name: "Wise USD", currency: "USD")
        doc.accounts = [a, b]
        doc.trackedBankAccountIDs = [a.id, b.id]
        doc.bankBalances = [
            BankBalanceObservation(
                id: UUID(), accountID: a.id, amount: PreciseDecimal(80),
                currency: "USD", observedAt: day, source: "wise", sourceIdentity: "a"
            ),
            BankBalanceObservation(
                id: UUID(), accountID: b.id, amount: PreciseDecimal(70),
                currency: "USD", observedAt: day, source: "wise", sourceIdentity: "b"
            ),
        ]
        let result = NetWorthCalculator.value(at: day, scope: .banks, document: doc, now: day)
        #expect(result.total == 150)
        doc.entries = [
            Entry(
                month: MonthKey(year: 2026, month: 9),
                bucket: .personal, kind: .transfer,
                amount: 20, currency: "USD", label: "to Wise", source: .csv
            ),
        ]
        let again = NetWorthCalculator.value(at: day, scope: .banks, document: doc, now: day)
        #expect(again.total == 150)
    }

    @Test("Business profit is not added to net worth")
    func businessProfitExcluded() throws {
        let day = utc(2026, 9, 4)
        var doc = document()
        doc.entries = [
            Entry(
                month: MonthKey(year: 2026, month: 9),
                bucket: .otherBusiness, kind: .income,
                amount: 5_000, currency: "USD", label: "Sample business", source: .manual
            ),
        ]
        let result = NetWorthCalculator.value(at: day, scope: .allTracked, document: doc, now: day)
        #expect(result.total == nil)
        #expect(result.isUnavailable)
    }

    @Test("Unknown quote blocks a complete total and keeps the last complete sample")
    func missingQuoteShowsLastComplete() throws {
        let day1 = utc(2026, 9, 1)
        let day4 = utc(2026, 9, 4)
        var doc = document()
        let portfolio = Portfolio(name: "Main", createdAt: utc(2026, 8, 1))
        doc.portfolios = [portfolio]
        doc = try HoldingMutations.addHolding(
            portfolioID: portfolio.id, assetID: CanonicalAssetID("bitcoin"),
            assetName: "Bitcoin", quantity: 1, at: day1, document: doc
        )
        doc.quotes = [
            QuoteObservation(
                assetID: try CanonicalAssetID("bitcoin"),
                priceUSD: PreciseDecimal(100),
                providerTime: day1, fetchedAt: day1, provider: "coingecko"
            ),
        ]
        doc = NetWorthCalculator.recordingSample(
            NetWorthCalculator.value(at: day1, scope: .allTracked, document: doc, now: day1),
            in: doc
        )
        doc = try HoldingMutations.addHolding(
            portfolioID: portfolio.id, assetID: CanonicalAssetID("ethereum"),
            assetName: "Ethereum", quantity: 2, at: day4, document: doc
        )
        let result = NetWorthCalculator.value(at: day4, scope: .allTracked, document: doc, now: day4)
        #expect(result.total == nil)
        #expect(result.lastComplete?.value == 100)
        #expect(result.missing.contains { $0.reason == "quote" })
    }

    @Test("Stale quotes remain dated last-known values")
    func staleQuote() throws {
        let quoted = utc(2026, 9, 4, hour: 10)
        let now = utc(2026, 9, 4, hour: 12)
        var doc = document()
        let portfolio = Portfolio(name: "Main", createdAt: utc(2026, 8, 1))
        doc.portfolios = [portfolio]
        doc = try HoldingMutations.addHolding(
            portfolioID: portfolio.id, assetID: CanonicalAssetID("bitcoin"),
            assetName: "Bitcoin", quantity: 1, at: quoted, document: doc
        )
        doc.quotes = [
            QuoteObservation(
                assetID: try CanonicalAssetID("bitcoin"),
                priceUSD: PreciseDecimal(100),
                providerTime: quoted, fetchedAt: quoted, provider: "coingecko"
            ),
        ]
        let result = NetWorthCalculator.value(at: now, scope: .allTracked, document: doc, now: now)
        #expect(result.total == 100)
        #expect(result.stale.count == 1)
        #expect(result.components.first?.isStale == true)
    }

    @Test("Mixed-age bank observations keep per-component freshness")
    func mixedAgeBalances() throws {
        let now = utc(2026, 9, 4, hour: 12)
        var doc = document()
        let fresh = Account(name: "Wise USD", currency: "USD")
        let old = Account(name: "Sample bank", currency: "USD")
        doc.accounts = [fresh, old]
        doc.trackedBankAccountIDs = [fresh.id, old.id]
        doc.bankBalances = [
            BankBalanceObservation(
                id: UUID(), accountID: fresh.id, amount: PreciseDecimal(10),
                currency: "USD", observedAt: now.addingTimeInterval(-3600),
                source: "wise", sourceIdentity: "usd"
            ),
            BankBalanceObservation(
                id: UUID(), accountID: old.id, amount: PreciseDecimal(5),
                currency: "USD", observedAt: now.addingTimeInterval(-40 * 3600),
                source: "manual", sourceIdentity: "monzo"
            ),
        ]
        let result = NetWorthCalculator.value(at: now, scope: .banks, document: doc, now: now)
        #expect(result.total == 15)
        #expect(result.components.first { $0.id == fresh.id }?.isStale == false)
        #expect(result.components.first { $0.id == old.id }?.isStale == true)
    }

    @Test("There is no history before known ownership")
    func noHistoryBeforeOwnership() throws {
        let owned = utc(2026, 9, 4)
        let before = utc(2026, 9, 1)
        var doc = document()
        let portfolio = Portfolio(name: "Main", createdAt: utc(2026, 8, 1))
        doc.portfolios = [portfolio]
        doc = try HoldingMutations.addHolding(
            portfolioID: portfolio.id, assetID: CanonicalAssetID("bitcoin"),
            assetName: "Bitcoin", quantity: 1, at: owned, document: doc
        )
        doc.quotes = [
            QuoteObservation(
                assetID: try CanonicalAssetID("bitcoin"),
                priceUSD: PreciseDecimal(100),
                providerTime: before, fetchedAt: before, provider: "coingecko"
            ),
        ]
        let result = NetWorthCalculator.value(at: before, scope: .allTracked, document: doc, now: owned)
        #expect(result.components.isEmpty)
        #expect(result.total == nil)
        #expect(result.isUnavailable)
    }

    @Test("Today's quote does not reprice a stored past sample")
    func noRepricingPriorSamples() throws {
        let day1 = utc(2026, 9, 1)
        let day4 = utc(2026, 9, 4)
        var doc = document()
        let portfolio = Portfolio(name: "Main", createdAt: utc(2026, 8, 1))
        doc.portfolios = [portfolio]
        doc = try HoldingMutations.addHolding(
            portfolioID: portfolio.id, assetID: CanonicalAssetID("bitcoin"),
            assetName: "Bitcoin", quantity: 1, at: day1, document: doc
        )
        doc.quotes = [
            QuoteObservation(
                assetID: try CanonicalAssetID("bitcoin"),
                priceUSD: PreciseDecimal(100),
                providerTime: day1, fetchedAt: day1, provider: "coingecko"
            ),
            QuoteObservation(
                assetID: try CanonicalAssetID("bitcoin"),
                priceUSD: PreciseDecimal(400),
                providerTime: day4, fetchedAt: day4, provider: "coingecko"
            ),
        ]
        doc = NetWorthCalculator.recordingSample(
            NetWorthCalculator.value(at: day1, scope: .allTracked, document: doc, now: day1),
            in: doc
        )
        let historic = NetWorthCalculator.value(at: day1, scope: .allTracked, document: doc, now: day4)
        #expect(historic.total == 100)
    }

    @Test("UTC midnight is a new observation day")
    func utcRollover() throws {
        let before = utc(2026, 9, 4, hour: 23, minute: 59)
        let after = utc(2026, 9, 5, hour: 0, minute: 1)
        var doc = document()
        let portfolio = Portfolio(name: "Main", createdAt: utc(2026, 8, 1))
        doc.portfolios = [portfolio]
        doc = try HoldingMutations.addHolding(
            portfolioID: portfolio.id, assetID: CanonicalAssetID("bitcoin"),
            assetName: "Bitcoin", quantity: 1, at: before, document: doc
        )
        doc.quotes = [
            QuoteObservation(
                assetID: try CanonicalAssetID("bitcoin"),
                priceUSD: PreciseDecimal(100),
                providerTime: before, fetchedAt: before, provider: "coingecko"
            ),
        ]
        let late = NetWorthCalculator.value(at: before, scope: .allTracked, document: doc, now: after)
        #expect(late.total == 100)
        let nextWeek = utc(2026, 9, 12)
        let gap = NetWorthCalculator.value(at: after, scope: .allTracked, document: doc, now: nextWeek)
        #expect(gap.total == nil)
        #expect(gap.missing.contains { $0.reason == "quote" })
    }

    @Test("A deposit is a change in balance, not a return")
    func depositsAreChange() throws {
        let day1 = utc(2026, 9, 1)
        let day4 = utc(2026, 9, 4)
        var doc = document()
        let account = Account(name: "Wise USD", currency: "USD")
        doc.accounts = [account]
        doc.trackedBankAccountIDs = [account.id]
        doc.bankBalances = [
            BankBalanceObservation(
                id: UUID(), accountID: account.id, amount: PreciseDecimal(100),
                currency: "USD", observedAt: day1, source: "wise", sourceIdentity: "usd"
            ),
        ]
        let first = NetWorthCalculator.value(at: day1, scope: .banks, document: doc, now: day1)
        doc.bankBalances.append(
            BankBalanceObservation(
                id: UUID(), accountID: account.id, amount: PreciseDecimal(150),
                currency: "USD", observedAt: day4, source: "wise", sourceIdentity: "usd"
            )
        )
        let second = NetWorthCalculator.value(at: day4, scope: .banks, document: doc, now: day4)
        let change = NetWorthCalculator.change(from: first, to: second)
        #expect(change?.amount == 50)
    }

    @Test("Two FX dates keep their own rates")
    func datedFX() throws {
        let day1 = utc(2026, 9, 1)
        let day4 = utc(2026, 9, 4)
        var doc = document()
        let eur = Account(name: "Wise EUR", currency: "EUR")
        doc.accounts = [eur]
        doc.trackedBankAccountIDs = [eur.id]
        doc.bankBalances = [
            BankBalanceObservation(
                id: UUID(), accountID: eur.id, amount: PreciseDecimal(100),
                currency: "EUR", observedAt: day1, source: "wise", sourceIdentity: "eur"
            ),
        ]
        doc.fx = [
            FXObservation(
                sourceCurrency: "EUR", targetCurrency: "USD", rate: PreciseDecimal(1),
                providerTime: day1, fetchedAt: day1, provider: "wise"
            ),
            FXObservation(
                sourceCurrency: "EUR", targetCurrency: "USD", rate: PreciseDecimal(2),
                providerTime: day4, fetchedAt: day4, provider: "wise"
            ),
        ]
        doc = NetWorthCalculator.recordingSample(
            NetWorthCalculator.value(at: day1, scope: .banks, document: doc, now: day1),
            in: doc
        )
        let historic = NetWorthCalculator.value(at: day1, scope: .banks, document: doc, now: day4)
        let current = NetWorthCalculator.value(at: day4, scope: .banks, document: doc, now: day4)
        #expect(historic.total == 100)
        #expect(current.total == 200)
    }

    @Test("Full-precision token values still add up to a total")
    func highPrecisionValuation() throws {
        let day = utc(2026, 9, 4)
        var doc = document()
        let bank = Account(name: "Checking", currency: "USD")
        doc.accounts = [bank]
        doc.trackedBankAccountIDs = [bank.id]
        doc.bankBalances = [
            BankBalanceObservation(
                id: UUID(), accountID: bank.id, amount: PreciseDecimal(Decimal(string: "12345.67")!),
                currency: "USD", observedAt: day, source: "manual", sourceIdentity: "checking"
            ),
        ]
        let portfolio = Portfolio(name: "Tokens", createdAt: utc(2026, 8, 1))
        doc.portfolios = [portfolio]
        // 36 significant digits each; their sum with the balance needs 41, more than Decimal holds exactly.
        doc = try HoldingMutations.addHolding(
            portfolioID: portfolio.id, assetID: CanonicalAssetID("tiny-token"),
            assetName: "Tiny", quantity: Decimal(string: "1234.567890123456789012")!, at: day, document: doc
        )
        doc.quotes = [
            QuoteObservation(
                assetID: try CanonicalAssetID("tiny-token"),
                priceUSD: PreciseDecimal(Decimal(string: "0.000012345678901234")!),
                providerTime: day, fetchedAt: day, provider: "coingecko"
            ),
        ]
        let result = NetWorthCalculator.value(at: day, scope: .allTracked, document: doc, now: day)
        let total = try #require(result.total)
        #expect(total > Decimal(string: "12345.685")! && total < Decimal(string: "12345.686")!)
        #expect(result.missing.isEmpty)
        #expect(AssetOwnership.personalValue(at: day, scope: .allTracked, document: doc, now: day).total != nil)
    }

    @Test("A past day's balance is judged stale at that day, not today")
    func historicalStaleness() throws {
        let observed = utc(2026, 9, 1, hour: 9)
        let now = utc(2026, 9, 20)
        var doc = document()
        let account = Account(name: "Sample bank", currency: "USD")
        doc.accounts = [account]
        doc.trackedBankAccountIDs = [account.id]
        doc.bankBalances = [
            BankBalanceObservation(
                id: UUID(), accountID: account.id, amount: PreciseDecimal(10),
                currency: "USD", observedAt: observed, source: "manual", sourceIdentity: "bank"
            ),
        ]
        let sameDay = NetWorthCalculator.value(at: utc(2026, 9, 1, hour: 23, minute: 59), scope: .banks, document: doc, now: now)
        #expect(sameDay.stale.isEmpty && sameDay.components.first?.isStale == false)
        let later = NetWorthCalculator.value(at: utc(2026, 9, 5), scope: .banks, document: doc, now: now)
        #expect(later.components.first?.isStale == true)
    }

    @Test("Rebuilding history rewrites each day in range once per scope and leaves other days alone")
    func rebuildHistoryRange() throws {
        let day1 = utc(2026, 9, 1)
        var doc = document()
        let account = Account(name: "Checking", currency: "USD")
        doc.accounts = [account]
        doc.trackedBankAccountIDs = [account.id]
        doc.bankBalances = [
            BankBalanceObservation(
                id: UUID(), accountID: account.id, amount: PreciseDecimal(100),
                currency: "USD", observedAt: day1, source: "manual", sourceIdentity: "checking"
            ),
        ]
        func sample(_ day: Date, _ total: Decimal) -> DailyValuation {
            DailyValuation(utcDay: UTCDay.start(of: day), scope: .banks, total: PreciseDecimal(total), isComplete: true,
                           components: [], computedAt: day, includedAccountIDs: [], includedPortfolioIDs: [])
        }
        doc.dailyValuations = [sample(utc(2026, 8, 20), 1), sample(day1, 5)]
        let rebuilt = HoldingMutations.rebuildHistory(from: day1, to: utc(2026, 9, 3), document: doc, now: utc(2026, 9, 5))
        // Sep 1 and Sep 2, each for all assets and for banks, plus the untouched August day.
        #expect(rebuilt.dailyValuations.count == 5)
        #expect(rebuilt.storedValuation(day: day1, scope: .banks)?.total?.value == 100)
        #expect(rebuilt.storedValuation(day: utc(2026, 9, 2), scope: .allTracked)?.total?.value == 100)
        #expect(rebuilt.storedValuation(day: utc(2026, 8, 20), scope: .banks)?.total?.value == 1)
    }

    @Test("Months are Gregorian UTC months, whatever calendar or time zone the Mac uses")
    func gregorianUTCMonths() throws {
        let lateSeptember = utc(2026, 9, 30, hour: 23, minute: 30)
        #expect(MonthKey.current(now: lateSeptember) == MonthKey(year: 2026, month: 9))
        #expect(MonthKey.current(now: lateSeptember.addingTimeInterval(3600)) == MonthKey(year: 2026, month: 10))
        // Calendar.current can't be swapped inside a test; a Japanese calendar reads this year as 8 (Reiwa),
        // and the month must not come from it.
        #expect(Calendar(identifier: .japanese).component(.year, from: lateSeptember) == 8)
        #expect(MonthKey.current(now: lateSeptember).year == 2026)
        #expect(AssetOwnership.month(at: lateSeptember) == MonthKey.current(now: lateSeptember))
        #expect(MonthKey(year: 2026, month: 9).title.contains("2026"))
        // Out-of-range months roll into the neighbouring year instead of naming a month that doesn't exist.
        #expect(MonthKey(year: 2026, month: 13) == MonthKey(year: 2027, month: 1))
        #expect(MonthKey(year: 2026, month: 0) == MonthKey(year: 2025, month: 12))
        #expect(DashboardPeriod.interval(month: MonthKey(year: 2025, month: 13), period: .monthly, now: lateSeptember).start == utc(2026, 1, 1, hour: 0))
    }

    @Test("UTC day starts match a UTC Gregorian calendar's")
    func utcDayArithmetic() {
        var seconds: [TimeInterval] = [0, 0.001, -0.001, 86_399.999, 86_400, -86_400, -86_400.5, 978_307_200, 978_307_199.999,
                                       1_000_000_000.25, 1_790_812_799.999, 4_102_444_800, -2_208_988_800]
        seconds += stride(from: -3_000_000_000.0, to: 3_000_000_000.0, by: 7_777_777.777).map { $0 }
        for value in seconds {
            let date = Date(timeIntervalSince1970: value)
            #expect(UTCDay.start(of: date) == UTCDay.calendar.startOfDay(for: date), "\(value)")
        }
    }
}

struct OwnedAssetTests {
    private func date(_ text: String) throws -> Date { try ImportDateFormat.iso.date(text) }
    private func document() -> VaultDocument {
        let key = VaultCrypto.makeInboxKeyPair()
        return VaultDocument.empty(inboxPrivateKeyX963: key.privateX963, inboxPublicKeyX963: key.publicX963)
    }
    private func book() throws -> BusinessBook {
        BusinessBook(id: "agency", name: "Agency", ownership: [.init(fromMonth: "2020-01", numerator: 1, denominator: 3), .init(fromMonth: "2025-01", numerator: 1, denominator: 2)], firstMonth: "2020-01", sourceURL: "", basis: "", fetchedAt: try date("2026-09-06"))
    }
    private func component(_ id: UUID, usd: Decimal?, kind: ValuationComponent.Kind = .bank, currency: String = "USD") -> ValuationComponent {
        ValuationComponent(id: id, kind: kind, label: "Fixture", currency: currency, nativeAmount: PreciseDecimal(999), usdValue: usd.map(PreciseDecimal.init), isStale: false, missing: usd == nil ? "fx" : nil)
    }
    @Test("Profile rows sum USD conversions, including negatives and zero, without hiding missing FX")
    func groupedUSD() throws {
        var doc = document()
        doc.accounts = [Account(name: "Agency · EUR", currency: "EUR", externalProfileID: "a"), Account(name: "Agency · GBP", currency: "GBP", externalProfileID: "a"), Account(name: "Personal", currency: "USD", externalProfileID: "p")]
        doc.businessAccounting = [try book()]
        let values = [component(doc.accounts[0].id, usd: 120, currency: "EUR"), component(doc.accounts[1].id, usd: -20, currency: "GBP"), component(doc.accounts[2].id, usd: 0)]
        let groups = BankBalanceGroup.groups(values, document: doc)
        #expect(groups.map(\.name) == ["Bank balances", "Agency"])
        #expect(groups[1].total == 100 && groups[0].total == 0)
        #expect(groups[1].businessID == "agency" && groups[0].businessID == nil)
        var missing = values; missing[0].usdValue = nil
        #expect(BankBalanceGroup.groups(missing, document: doc)[1].total == nil)
        doc.accounts.append(Account(name: "Monzo", currency: "GBP"))
        let personal = values + [component(doc.accounts[3].id, usd: 300, currency: "GBP")]
        let banks = BankBalanceGroup.banks(BankBalanceGroup.groups(personal, document: doc)[0].components, document: doc)
        #expect(banks.map(\.name) == ["Monzo", "Wise"] && banks[1].components.count == 1)
    }
    @Test("Statements rebuild an account's daily balance history around one known balance")
    func balanceReconstruction() throws {
        var doc = document()
        let monzo = Account(name: "Monzo", currency: "GBP"); doc.accounts = [monzo]; doc.trackedBankAccountIDs = [monzo.id]
        let formatter = BalanceReconstruction.dayFormatter()
        let anchorDay = formatter.date(from: "2026-09-09")!
        doc.bankBalances = [BankBalanceObservation(id: UUID(), accountID: monzo.id, amount: PreciseDecimal(1000), currency: "GBP", observedAt: anchorDay.addingTimeInterval(3600), source: "Import", sourceIdentity: "x")]
        func entry(_ day: String, _ amount: Decimal, outflow: Bool, kind: EntryKind = .expense) -> Entry {
            var e = Entry(month: MonthKey(String(day.prefix(7)))!, kind: kind, amount: amount, currency: "GBP", label: day, source: .csv, sourceRef: monzo.id.uuidString + ":" + day + String(describing: amount))
            e.day = day; e.outflow = outflow; return e
        }
        doc.entries = [entry("2026-09-09", 50, outflow: true), entry("2026-09-07", 200, outflow: true), entry("2026-09-07", 30, outflow: false, kind: .income),
                       entry("2026-09-01", 400, outflow: true, kind: .transfer), entry("2026-09-12", 100, outflow: false, kind: .income)]
        let derived = try #require(BalanceReconstruction.derive(accountID: monzo.id, document: doc, now: formatter.date(from: "2026-09-20")!))
        // Sep 7 end: anchor 1000 + the 50 spent on the 9th = 1050. Sep 1 end: 1050 + 200 − 30 = 1220. Sep 12: 1000 + 100.
        #expect(derived.map { ($0.amount.value, formatter.string(from: $0.observedAt)) }.map { "\($0.0)@\($0.1)" } == ["1220@2026-09-01", "1050@2026-09-07", "1100@2026-09-12"])
        #expect(derived.allSatisfy { $0.source == BalanceReconstruction.source })
        doc.trackedBankAccountIDs = []; doc.setBankTracked(monzo.id, tracked: true, at: anchorDay)
        let start = BalanceReconstruction.apply(accountIDs: [monzo.id], to: &doc, now: formatter.date(from: "2026-09-20")!)
        #expect(start == derived.first?.observedAt && doc.bankBalances.count == 4)
        #expect(doc.isBankTracked(monzo.id, at: formatter.date(from: "2026-09-02")!))
        #expect(BalanceReconstruction.apply(accountIDs: [monzo.id], to: &doc, now: formatter.date(from: "2026-09-20")!) == nil)
        #expect(NetWorthCalculator.value(at: formatter.date(from: "2026-09-05")!, scope: .banks, document: doc).components.first?.nativeAmount?.value == 1220)
    }
    @Test("Company cash and crypto use historical ownership; full balances stay unchanged")
    func historicalOwnership() throws {
        var doc = document(); doc.businessAccounting = [try book()]
        let bank = Account(name: "Agency", currency: "USD", externalProfileID: "agency")
        let personal = Account(name: "Personal", currency: "USD")
        doc.accounts = [bank, personal]
        let portfolio = Portfolio(name: "Company crypto", ownerBusinessID: "agency")
        doc.portfolios = [portfolio]
        let holding = Holding(portfolioID: portfolio.id, assetID: try CanonicalAssetID("bitcoin"), assetName: "Bitcoin")
        doc.holdings = [holding]
        let values = [component(bank.id, usd: 300), component(personal.id, usd: 100), component(holding.id, usd: 600, kind: .holding)]
        #expect(AssetOwnership.personalTotal(values, at: try date("2024-12-31"), document: doc) == 400)
        #expect(AssetOwnership.personalTotal(values, at: try date("2025-01-01"), document: doc) == 550)
        #expect(AssetOwnership.sum(values) == 1000)
        doc.businessAccounting = []
        #expect(AssetOwnership.personalTotal(values, at: try date("2025-01-01"), document: doc) == nil)
    }
    @Test("Historical snapshots are reweighted once, without mutating stored totals")
    func storedSnapshot() throws {
        var doc = document(); doc.businessAccounting = [try book()]
        let account = Account(name: "Agency", currency: "USD", externalProfileID: "agency"); doc.accounts = [account]
        let day = try date("2024-12-31"), now = try date("2026-09-06")
        let values = [component(account.id, usd: 900)]
        doc.dailyValuations = [DailyValuation(utcDay: day, scope: .allTracked, total: PreciseDecimal(900), isComplete: true, components: values, computedAt: day, includedAccountIDs: [account.id], includedPortfolioIDs: [])]
        #expect(AssetOwnership.personalValue(at: day, scope: .allTracked, document: doc, now: now).total == 300)
        #expect(doc.dailyValuations[0].total?.value == 900)
        doc.accounts[0].ownerBusinessID = ""
        #expect(AssetOwnership.personalValue(at: day, scope: .allTracked, document: doc, now: now).total == 900)
    }
    @Test("Owner fields decode older vault records without migration")
    func legacyOwners() throws {
        let portfolio = Portfolio(name: "Legacy")
        let decoded = try JSONDecoder().decode(Portfolio.self, from: JSONEncoder().encode(portfolio))
        #expect(decoded.ownerBusinessID == nil)
        let account = Account(name: "Personal", currency: "USD")
        #expect(try JSONDecoder().decode(Account.self, from: JSONEncoder().encode(account)).ownerBusinessID == nil)
    }
    @Test("The shared period uses calendar boundaries and actual observation dates")
    func intervals() throws {
        let now = try date("2026-09-06")
        let february = DashboardPeriod.interval(month: MonthKey("2024-02")!, period: .monthly, now: now)
        #expect(february.start == (try date("2024-02-01")))
        #expect(february.end == (try date("2024-03-01")).addingTimeInterval(-1))
        let year = DashboardPeriod.interval(month: MonthKey("2024-09")!, period: .annual, now: now)
        #expect(year.start == (try date("2024-01-01")))
        #expect(year.end == (try date("2025-01-01")).addingTimeInterval(-1))
        #expect(DashboardPeriod.interval(month: MonthKey("2026-09")!, period: .monthly, now: now).end == now)
        #expect(DashboardPeriod.interval(month: MonthKey("2024-09")!, period: .allTime, now: now).end == now)
        var doc = document()
        doc.dailyValuations = [DailyValuation(utcDay: try date("2024-02-29"), scope: .banks, total: PreciseDecimal(100), isComplete: true, components: [], computedAt: now, includedAccountIDs: [], includedPortfolioIDs: []), DailyValuation(utcDay: try date("2024-03-01"), scope: .banks, total: PreciseDecimal(200), isComplete: true, components: [], computedAt: now, includedAccountIDs: [], includedPortfolioIDs: [])]
        #expect(DashboardPeriod.samples(in: february, scope: .banks, document: doc).count == 1)
        #expect(DashboardPeriod.samples(in: february, scope: .allTracked, document: doc).isEmpty)
    }
    private func statementRow(_ account: Account, _ day: String, _ amount: Decimal, currency: String = "GBP") -> Entry {
        var entry = Entry(month: MonthKey(String(day.prefix(7)))!, kind: .expense, amount: amount, currency: currency, label: day,
                          source: .csv, sourceRef: account.id.uuidString + ":" + day + currency)
        entry.day = day; entry.outflow = true
        return entry
    }
    private func balance(_ account: Account, _ day: String, _ amount: Decimal) throws -> BankBalanceObservation {
        BankBalanceObservation(id: UUID(), accountID: account.id, amount: PreciseDecimal(amount), currency: account.currency,
                               observedAt: try date(day).addingTimeInterval(3600), source: "manual", sourceIdentity: account.id.uuidString)
    }
    @Test("Statement history is only derived from a balance within a week of the last statement day, in the account's currency")
    func reconstructionNeedsCoveredAnchor() throws {
        var doc = document()
        let monzo = Account(name: "Monzo", currency: "GBP"); doc.accounts = [monzo]
        let now = try date("2026-09-24")
        // A March statement and today's balance: the months between were never imported, so nothing is derived.
        doc.entries = [statementRow(monzo, "2025-03-10", 40), statementRow(monzo, "2025-03-28", 60)]
        doc.bankBalances = [try balance(monzo, "2026-09-20", 1000)]
        #expect(BalanceReconstruction.derive(accountID: monzo.id, document: doc, now: now) == nil)
        // The statement's closing balance anchors it; the later balance is left alone.
        doc.bankBalances.append(try balance(monzo, "2025-03-31", 700))
        #expect(BalanceReconstruction.derive(accountID: monzo.id, document: doc, now: now)?.map(\.amount.value) == [760, 700])
        doc.entries.append(statementRow(monzo, "2025-03-25", 999, currency: "EUR"))
        #expect(BalanceReconstruction.derive(accountID: monzo.id, document: doc, now: now)?.map(\.amount.value) == [760, 700])
    }
    @Test("Rebuilt history starts tracking earlier without dropping later tracking changes")
    func reconstructionKeepsLaterTracking() throws {
        var doc = document()
        let monzo = Account(name: "Monzo", currency: "GBP"); doc.accounts = [monzo]
        doc.setBankTracked(monzo.id, tracked: true, at: try date("2026-01-10"))
        doc.setBankTracked(monzo.id, tracked: false, at: try date("2026-03-01"))
        doc.setBankTracked(monzo.id, tracked: true, at: try date("2026-05-01"))
        doc.entries = [statementRow(monzo, "2025-12-15", 20)]
        doc.bankBalances = [try balance(monzo, "2025-12-20", 500)]
        let now = try date("2026-09-20")
        #expect(BalanceReconstruction.apply(accountIDs: [monzo.id], to: &doc, now: now) != nil)
        #expect(doc.isBankTracked(monzo.id, at: try date("2025-12-16")))
        #expect(!doc.isBankTracked(monzo.id, at: try date("2026-04-01")))
        #expect(doc.isBankTracked(monzo.id, at: now))
    }
    @Test("Deriving the same statements again the same day changes nothing, today's row included")
    func reconstructionIsIdempotent() throws {
        var doc = document()
        let monzo = Account(name: "Monzo", currency: "GBP"); doc.accounts = [monzo]
        let anchor = try balance(monzo, "2026-09-20", 1000)
        doc.bankBalances = [anchor]; doc.setBankTracked(monzo.id, tracked: true, at: anchor.observedAt)
        doc.entries = [statementRow(monzo, "2026-09-18", 30), statementRow(monzo, "2026-09-21", 10)]
        let morning = try date("2026-09-21").addingTimeInterval(9 * 3600)
        #expect(BalanceReconstruction.apply(accountIDs: [monzo.id], to: &doc, now: morning) != nil)
        let saved = doc
        #expect(BalanceReconstruction.apply(accountIDs: [monzo.id], to: &doc, now: morning.addingTimeInterval(8 * 3600)) == nil)
        #expect(doc == saved)
    }
    @Test("A balance dated before an account's first tracked day moves tracking back, unless it was left out in between")
    func backdatedBalanceTracking() throws {
        var doc = document(); let id = UUID(), january = try date("2026-01-01")
        doc.setBankTracked(id, tracked: true, at: try date("2026-03-01"))
        let moved = doc.backdateBankTracking(id, to: january)
        let movedAgain = doc.backdateBankTracking(id, to: january)
        #expect(moved && !movedAgain)
        #expect(doc.isBankTracked(id, at: try date("2026-01-02")))
        var excluded = document()
        excluded.setBankTracked(id, tracked: false, at: try date("2026-02-01"))
        excluded.setBankTracked(id, tracked: true, at: try date("2026-03-01"))
        let movedPastExclusion = excluded.backdateBankTracking(id, to: january)
        #expect(!movedPastExclusion)
        #expect(!excluded.isBankTracked(id, at: try date("2026-01-02")))
    }
    @Test("Only a connected bank profile's name ties an account to a company; ownership labels stay short")
    func companyByProfileNameOnly() throws {
        var doc = document(); doc.businessAccounting = [try book()]
        #expect(AssetOwnership.businessID(for: Account(name: "Agency", currency: "USD"), in: doc) == nil)
        #expect(AssetOwnership.businessID(for: Account(name: "Agency · USD", currency: "USD", externalProfileID: "a"), in: doc) == "agency")
        #expect(OwnershipPeriod(fromMonth: "2025-01", numerator: 2, denominator: 3).label == "66.67%")
        #expect(OwnershipPeriod(fromMonth: "2025-01", numerator: 1, denominator: 2).label == "50%")
    }
}

struct PurchaseLotTests {
    private func utc(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var parts = DateComponents(); parts.calendar = Calendar(identifier: .gregorian); parts.timeZone = TimeZone(secondsFromGMT: 0)
        parts.year = year; parts.month = month; parts.day = day; parts.hour = 12
        return parts.date!
    }
    private func document() -> VaultDocument {
        let inbox = VaultCrypto.makeInboxKeyPair()
        return VaultDocument.empty(inboxPrivateKeyX963: inbox.privateX963, inboxPublicKeyX963: inbox.publicX963)
    }
    @Test("A backdated purchase moves the holding's start back and reports gain against what was paid")
    func backdatedPurchaseWithCost() throws {
        var doc = document()
        let portfolio = Portfolio(name: "Ledger", createdAt: utc(2026, 9, 1))
        doc.portfolios = [portfolio]
        let bought = utc(2026, 3, 10)
        doc = try HoldingMutations.addHolding(portfolioID: portfolio.id, assetID: CanonicalAssetID("bitcoin"), assetName: "Bitcoin", quantity: 1, at: bought, document: doc)
        let holding = try #require(doc.holdings.first)
        #expect(doc.portfolios[0].createdAt == bought && holding.createdAt == bought)
        #expect(doc.effectiveQuantity(holdingID: holding.id, at: utc(2026, 4, 1)) == 1)
        // A later total, then an earlier one inserted before it.
        doc = try HoldingMutations.setQuantity(holdingID: holding.id, quantity: 2, at: utc(2026, 8, 1), document: doc)
        doc = try HoldingMutations.setQuantity(holdingID: holding.id, quantity: 1.5, at: utc(2026, 6, 1), document: doc)
        #expect(doc.effectiveQuantity(holdingID: holding.id, at: utc(2026, 7, 1)) == 1.5)
        #expect(doc.effectiveQuantity(holdingID: holding.id, at: utc(2026, 9, 1)) == 2)
        doc.purchases = [PurchaseLot(holdingID: holding.id, quantity: PreciseDecimal(1), paid: PreciseDecimal(40000), currency: "USD", at: bought),
                         PurchaseLot(holdingID: holding.id, quantity: PreciseDecimal(1), paid: PreciseDecimal(20000), currency: "USD", at: utc(2026, 8, 1))]
        let summary = HoldingPerformance.summary(holdingID: holding.id, valueUSD: 90000, document: doc, at: utc(2026, 9, 4))
        #expect(summary.since == bought && summary.costUSD == 60000 && summary.gainUSD == 30000 && summary.returnFraction == 0.5)
        #expect(UpOnlyFormat.performance(summary) == "Since Mar 2026 · Paid $60,000 · +$30,000 (+50%)")
        let unknown = HoldingPerformance.summary(holdingID: holding.id, valueUSD: 90000, document: doc, at: utc(2026, 3, 1))
        #expect(unknown.costUSD == nil && UpOnlyFormat.performance(unknown) == "Since Mar 2026")
        let foreign = PurchaseLot(holdingID: holding.id, quantity: PreciseDecimal(1), paid: PreciseDecimal(500), currency: "GBP", at: bought)
        doc.purchases = [foreign]
        let native = HoldingPerformance.summary(holdingID: holding.id, valueUSD: 90000, document: doc, at: utc(2026, 9, 4))
        #expect(native.costUSD == nil && native.costNative == 500 && native.costCurrency == "GBP")
    }
    @Test("Cost follows the quantity still held; lots covering less than is held give no gain")
    func averageCostAndCoverage() throws {
        var doc = document()
        let portfolio = Portfolio(name: "Ledger", createdAt: utc(2026, 1, 1))
        doc.portfolios = [portfolio]
        doc = try HoldingMutations.addHolding(portfolioID: portfolio.id, assetID: CanonicalAssetID("bitcoin"), assetName: "Bitcoin", quantity: 2, at: utc(2026, 1, 10), document: doc)
        let holding = try #require(doc.holdings.first)
        doc.purchases = [PurchaseLot(holdingID: holding.id, quantity: PreciseDecimal(2), paid: PreciseDecimal(60000), currency: "USD", at: utc(2026, 1, 10))]
        // Half sold: the remaining coin carries half of what was paid.
        doc = try HoldingMutations.setQuantity(holdingID: holding.id, quantity: 1, at: utc(2026, 5, 1), document: doc)
        let sold = HoldingPerformance.summary(holdingID: holding.id, valueUSD: 70000, document: doc, at: utc(2026, 9, 4))
        #expect(sold.costUSD == 30000 && sold.gainUSD == 40000 && sold.coveredQuantity == nil)
        // Only 2 of 8 have a recorded price: report what those cost, and no gain.
        doc = try HoldingMutations.setQuantity(holdingID: holding.id, quantity: 8, at: utc(2026, 6, 1), document: doc)
        let partial = HoldingPerformance.summary(holdingID: holding.id, valueUSD: 560000, document: doc, at: utc(2026, 9, 4))
        #expect(partial.costUSD == 60000 && partial.gainUSD == nil && partial.returnFraction == nil)
        #expect(partial.coveredQuantity == 2 && partial.heldQuantity == 8)
    }
}

@MainActor struct CashFlowTests {
    private func document() -> VaultDocument {
        let inbox = VaultCrypto.makeInboxKeyPair()
        return VaultDocument.empty(inboxPrivateKeyX963: inbox.privateX963, inboxPublicKeyX963: inbox.publicX963)
    }
    @Test("Reconcile makes a company's payment to you income, never money you sent it")
    func reconcileKeepsDirection() {
        var doc = document()
        doc.businessAccounting = [BusinessBook(id: "studio", name: "Studio", ownership: [OwnershipPeriod(fromMonth: "2026-01", numerator: 1, denominator: 2)], firstMonth: "2026-01", sourceURL: "", basis: "", fetchedAt: Date(), transferCounterparties: ["Studio App"])]
        let account = UUID()
        func row(_ ref: String, outflow: Bool?) -> Entry {
            var entry = Entry(month: MonthKey("2026-02")!, kind: .transfer, amount: 100, currency: "USD", label: "Studio App", source: .csv, sourceRef: account.uuidString + ":" + ref)
            entry.outflow = outflow
            return entry
        }
        doc.entries = [row("in", outflow: false), row("out", outflow: true), row("unknown", outflow: nil)]
        OwnerPayments.reconcile(in: &doc)
        #expect(doc.entries.map(\.kind) == [.income, .transfer, .transfer])
        OwnerPayments.reconcile(in: &doc)
        #expect(doc.entries.map(\.kind) == [.income, .transfer, .transfer])
    }
    @Test("Without accounting, business rows are left out of personal cash flow instead of blocking the month")
    func businessRowsWithoutAccounting() {
        var doc = document(); let month = MonthKey("2026-02")!
        doc.entries = [Entry(month: month, kind: .income, amount: 100, currency: "USD", label: "Salary"),
                       Entry(month: month, bucket: .businessCost, kind: .expense, amount: 40, currency: "USD", label: "Team lunch"),
                       Entry(month: month, bucket: .otherBusiness, kind: .income, amount: 500, currency: "USD", label: "Client")]
        let state = MonthlyLedger.evaluate(month, document: doc)
        #expect(state.unavailable == nil && state.totals?.net == 100 && state.totals?.otherBusiness == 0)
    }
    @Test("Needs attention asks about closed months from the first recorded one, and about last month from this one")
    func attentionClosedMonths() {
        var doc = document(); doc.settings.tracked = [.cashFlow]
        let current = MonthKey.current(), previous = current.previous
        doc.entries = [Entry(month: previous, kind: .expense, amount: 10, currency: "USD", label: "Groceries"),
                       Entry(month: current, kind: .expense, amount: 5, currency: "USD", label: "Coffee")]
        let model = PopoverModel(); model.replace(with: doc)
        // Viewing the open month asks whether the one just ended is complete.
        #expect(model.month == current && model.attention(in: doc).spendingMonths == [previous])
        #expect(DataAttention.evaluate(doc, months: [previous, current]).spendingMonths == [previous])
        // A year view starts at the first recorded month and stops before the open one.
        model.selectPeriod(.annual)
        #expect(model.attention(in: doc).spendingMonths == (previous.year == current.year ? [previous] : []))
        doc.reviewedMonths = [previous.description]; model.replace(with: doc); model.selectPeriod(.monthly)
        #expect(model.attention(in: doc).count == 0)
        // Nothing recorded last month: nothing to ask about yet.
        doc.entries = [Entry(month: current, kind: .expense, amount: 5, currency: "USD", label: "Coffee")]; doc.reviewedMonths = []
        model.replace(with: doc)
        #expect(model.attention(in: doc).spendingMonths.isEmpty)
    }
    @Test("A year whose recorded months all lack rates asks for rates rather than saying nothing was recorded")
    func periodRateGaps() {
        var doc = document(); let month = MonthKey("2025-03")!
        doc.entries = [Entry(month: month, kind: .expense, amount: 20, currency: "GBP", label: "Groceries")]
        let model = PopoverModel(); model.replace(with: doc); model.select(month); model.selectPeriod(.annual)
        #expect(model.state.totals == nil && model.state.unavailable == .exchangeRates(["GBP"]))
    }
}

struct ChartPricesTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private func component(_ id: UUID, kind: ValuationComponent.Kind, value: Decimal?, quoteTime: Date? = nil, currency: String = "USD", amount: Decimal = 1, missing: String? = nil) -> ValuationComponent {
        ValuationComponent(id: id, kind: kind, label: kind == .holding ? "Bitcoin" : "Savings", currency: currency, nativeAmount: PreciseDecimal(amount), usdValue: value.map(PreciseDecimal.init),
                           quoteTime: quoteTime, fxTime: nil, isStale: false, missing: missing)
    }
    private func day(_ offset: Double) -> Date { UTCDay.start(of: now).addingTimeInterval(offset * 86400) }
    @Test("The nearest observation within the window wins, the earlier one on a tie")
    func nearest() {
        let series: [(time: Date, value: Decimal)] = [(day(-10), 1), (day(-4), 2), (day(2), 3)]
        #expect(ChartPrices.nearest(series, to: day(-5))?.value == 2)
        #expect(ChartPrices.nearest(series, to: day(-1))?.value == 2)   // three days back against three days on
        #expect(ChartPrices.nearest(series, to: day(1))?.value == 3)
        #expect(ChartPrices.nearest(series, to: day(-45))?.value == nil)   // more than 30 days from anything
        #expect(ChartPrices.nearest(series, to: day(40))?.value == nil)
        #expect(ChartPrices.nearest([], to: now) == nil)
    }
    @Test("A day without a saved price or rate takes the nearest one and says so; a missing balance can't be filled")
    func filled() throws {
        var doc = VaultDocument.empty(inboxPrivateKeyX963: VaultCrypto.makeInboxKeyPair().privateX963, inboxPublicKeyX963: VaultCrypto.makeInboxKeyPair().publicX963)
        let portfolio = Portfolio(name: "Ledger", createdAt: day(-400))
        doc.portfolios = [portfolio]
        doc = try HoldingMutations.addHolding(portfolioID: portfolio.id, assetID: CanonicalAssetID("bitcoin"), assetName: "Bitcoin", quantity: 2, at: day(-300), document: doc)
        let coin = try #require(doc.holdings.first)
        doc.quotes = [QuoteObservation(assetID: coin.assetID, priceUSD: PreciseDecimal(50000), providerTime: day(-3), fetchedAt: day(-3), provider: "CoinGecko")]
        doc.fx = [FXObservation(sourceCurrency: "EUR", targetCurrency: "USD", rate: PreciseDecimal(Decimal(string: "1.1")!), providerTime: day(-2), fetchedAt: day(-2), provider: "ECB")]
        let prices = ChartPrices(document: doc)
        let bank = UUID()
        let parts = [component(coin.id, kind: .holding, value: nil, amount: 2, missing: "quote"), component(bank, kind: .bank, value: nil, currency: "EUR", amount: 100, missing: "fx")]
        let result = prices.filled(parts, day: day(-1))
        #expect(result.complete)
        #expect(result.components.map { $0.usdValue?.value } == [100000, 110])
        #expect(result.components.allSatisfy { $0.missing == nil })
        #expect(result.estimated.count == 2 && result.estimated[0].hasPrefix("Bitcoin at its ") && result.estimated[0].hasSuffix(" price"))
        #expect(AssetOwnership.sum(result.components) == 100110)
        // A part with its own value is left alone, and a missing balance leaves the day incomplete.
        let balance = prices.filled([component(bank, kind: .bank, value: 5), component(UUID(), kind: .bank, value: nil, missing: "balance")], day: day(-1))
        #expect(!balance.complete && balance.components[0].usdValue?.value == 5 && balance.estimated.isEmpty)
        // Nothing within 30 days: still incomplete.
        #expect(!prices.filled(parts, day: day(-60)).complete)
    }
    @Test("A coin's move over the range compares its latest price with the one nearest the start")
    func priceChange() throws {
        var doc = VaultDocument.empty(inboxPrivateKeyX963: VaultCrypto.makeInboxKeyPair().privateX963, inboxPublicKeyX963: VaultCrypto.makeInboxKeyPair().publicX963)
        let bitcoin = try CanonicalAssetID("bitcoin")
        func quote(_ offset: Double, _ price: Decimal) -> QuoteObservation {
            QuoteObservation(assetID: bitcoin, priceUSD: PreciseDecimal(price), providerTime: day(offset), fetchedAt: day(offset), provider: "CoinGecko")
        }
        doc.quotes = [quote(-31, 80), quote(-29, 100), quote(-1, 110), quote(0, 120)]
        let prices = ChartPrices(document: doc)
        #expect(prices.priceChange(bitcoin, since: day(-30), now: now) == Decimal(string: "0.5"))   // -31 and -29 tie; the earlier wins
        #expect(prices.priceChange(bitcoin, since: day(-28), now: now) == Decimal(string: "0.2"))
        #expect(prices.priceChange(bitcoin, since: day(-200), now: now) == nil)
        #expect(prices.priceChange(try CanonicalAssetID("ethereum"), since: day(-7), now: now) == nil)
    }
    @Test("All-time profit sums the holdings whose purchases cover what's held, and counts the rest")
    func allTimeProfit() throws {
        var doc = VaultDocument.empty(inboxPrivateKeyX963: VaultCrypto.makeInboxKeyPair().privateX963, inboxPublicKeyX963: VaultCrypto.makeInboxKeyPair().publicX963)
        let portfolio = Portfolio(name: "Ledger", createdAt: now.addingTimeInterval(-400 * 86400))
        doc.portfolios = [portfolio]
        doc = try HoldingMutations.addHolding(portfolioID: portfolio.id, assetID: CanonicalAssetID("bitcoin"), assetName: "Bitcoin", quantity: 1, at: now.addingTimeInterval(-300 * 86400), document: doc)
        doc = try HoldingMutations.addHolding(portfolioID: portfolio.id, assetID: CanonicalAssetID("ethereum"), assetName: "Ethereum", quantity: 2, at: now.addingTimeInterval(-300 * 86400), document: doc)
        let bitcoin = try #require(doc.holdings.first { $0.assetID.rawValue == "bitcoin" }), ether = try #require(doc.holdings.first { $0.assetID.rawValue == "ethereum" })
        doc.purchases = [PurchaseLot(holdingID: bitcoin.id, quantity: PreciseDecimal(1), paid: PreciseDecimal(40000), currency: "USD", at: now.addingTimeInterval(-300 * 86400))]
        let parts = [component(bitcoin.id, kind: .holding, value: 60000, quoteTime: now), component(ether.id, kind: .holding, value: 6000, quoteTime: now)]
        let result = try #require(HoldingPerformance.scope(parts, document: doc, at: now))
        #expect(result.gain == 20000 && result.cost == 40000 && result.covered == 1 && result.total == 2)
        doc.purchases = []
        #expect(HoldingPerformance.scope(parts, document: doc, at: now) == nil)
    }
}

struct PeriodChangeTests {
    private func part(_ id: UUID, _ value: Decimal?) -> ValuationComponent {
        ValuationComponent(id: id, kind: .bank, label: "Part", currency: "USD", nativeAmount: PreciseDecimal(1), usdValue: value.map(PreciseDecimal.init),
                           quoteTime: nil, fxTime: nil, isStale: false, missing: value == nil ? "balance" : nil)
    }
    @Test("A change over the range is today's figure against the range's first, and new money counts")
    func change() {
        let change = PeriodChange(from: 4000, to: 5000)
        #expect(change.amount == 1000 && change.fraction == Decimal(string: "0.25") && change.previous == 4000)
        #expect(PeriodChange(from: 0, to: 50).fraction == nil)
        let a = UUID(), b = UUID()
        let parts = PeriodChange(parts: [part(a, 60), part(b, 40)], then: [part(a, 80)])
        #expect(parts?.amount == 20 && parts?.fraction == Decimal(string: "0.25"))
        // Nothing then, or a part that can't be valued, gives no change.
        #expect(PeriodChange(parts: [part(a, 60)], then: []) == nil)
        #expect(PeriodChange(parts: [part(a, nil)], then: [part(a, 80)]) == nil)
    }
}
