#if UPONLY_FIXTURE
import Foundation

enum UpOnlyFixture {
    static func document(from empty: VaultDocument) throws -> VaultDocument {
        var doc = empty
        doc.settings.setupComplete = true
        let now = Date(), start = Date().addingTimeInterval(-90 * 86400)
        let account = Account(name: "Sample account", currency: "USD")
        doc.accounts = [account]; doc.setBankTracked(account.id, tracked: true, at: start)
        let portfolio = Portfolio(name: "Sample portfolio", createdAt: start)
        doc.portfolios = [portfolio]
        doc = try HoldingMutations.addHolding(portfolioID: portfolio.id, assetID: CanonicalAssetID("bitcoin"), assetName: "Bitcoin", quantity: Decimal(string: "0.1")!, at: start, document: doc)
        for day in 0...90 {
            let date = start.addingTimeInterval(Double(day) * 86400)
            doc.bankBalances.append(BankBalanceObservation(id: UUID(), accountID: account.id, amount: PreciseDecimal(Decimal(1000 + day * 10)), currency: "USD", observedAt: date, source: "Synthetic", sourceIdentity: account.id.uuidString))
            doc.quotes.append(QuoteObservation(assetID: try CanonicalAssetID("bitcoin"), priceUSD: PreciseDecimal(Decimal(50000 + day * 100)), providerTime: date, fetchedAt: date, provider: "Synthetic"))
            for scope: ValuationScope in [.allTracked, .banks, .portfolio(portfolio.id)] {
                doc = NetWorthCalculator.recordingSample(NetWorthCalculator.value(at: date, scope: scope, document: doc, now: date), in: doc)
            }
        }
        var month = MonthKey.current(now: now)
        for index in 0..<12 {
            doc.entries.append(Entry(month: month, kind: .income, amount: Decimal(3000 + index * 100), currency: "USD", label: "Sample income"))
            doc.entries.append(Entry(month: month, kind: .expense, amount: Decimal(2000 + index * 40), currency: "USD", label: "Sample expense"))
            if index > 0 { doc.reviewedMonths.append(month.description) }
            month = month.previous
        }
        return doc
    }
}
#endif
