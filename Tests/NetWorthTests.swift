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
        #expect(result.needsUpdate)
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

    @Test("A deposit is labelled Change, not a return")
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
        #expect(change?.kind == .change)
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
    @Test("Company cash and crypto use historical ownership; full balances stay unchanged")
    func historicalOwnership() throws {
        var doc = document(); doc.businessAccounting = [try book()]
        let bank = Account(name: "Agency", currency: "USD")
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
        let account = Account(name: "Agency", currency: "USD"); doc.accounts = [account]
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
}
