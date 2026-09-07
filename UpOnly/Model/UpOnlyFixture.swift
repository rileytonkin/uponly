#if UPONLY_FIXTURE
import Foundation

enum UpOnlyFixture {
    static func document(from empty: VaultDocument, tracked: [TrackedKind] = TrackedKind.allCases) throws -> VaultDocument {
        var doc = empty
        doc.settings.setupComplete = true
        doc.settings.tracked = TrackedKind.normalized(tracked)
        let now = Date(), start = Date().addingTimeInterval(-90 * 86400)
        var account: Account?
        var portfolio: Portfolio?
        if tracked.contains(.banks) {
            let sample = Account(name: "Sample account", currency: "USD")
            doc.accounts = [sample]; doc.setBankTracked(sample.id, tracked: true, at: start)
            account = sample
        }
        if tracked.contains(.crypto) {
            let sample = Portfolio(name: "Sample portfolio", createdAt: start)
            doc.portfolios = [sample]
            doc = try HoldingMutations.addHolding(portfolioID: sample.id, assetID: CanonicalAssetID("bitcoin"), assetName: "Bitcoin", quantity: Decimal(string: "0.1")!, at: start, document: doc)
            portfolio = sample
        }
        var metalPortfolio: Portfolio?
        if tracked.contains(.metals) {
            let sample = Portfolio(name: "Sample safe", createdAt: start, kind: .metals)
            doc.portfolios.append(sample); metalPortfolio = sample
            doc = try HoldingMutations.addHolding(portfolioID: sample.id, assetID: PreciousMetal.gold.assetID, assetName: "Gold", quantity: PreciousMetal.gramsPerTroyOunce, at: start, document: doc)
        }
        var scopes: [ValuationScope] = [.allTracked]
        if account != nil { scopes.append(.banks) }
        if let portfolio { scopes.append(.portfolio(portfolio.id)) }
        if let metalPortfolio { scopes.append(.portfolio(metalPortfolio.id)) }
        for day in 0...90 {
            let date = start.addingTimeInterval(Double(day) * 86400)
            if let account {
                doc.bankBalances.append(BankBalanceObservation(id: UUID(), accountID: account.id, amount: PreciseDecimal(Decimal(1000 + day * 10)), currency: "USD", observedAt: date, source: "Synthetic", sourceIdentity: account.id.uuidString))
            }
            if portfolio != nil {
                doc.quotes.append(QuoteObservation(assetID: try CanonicalAssetID("bitcoin"), priceUSD: PreciseDecimal(Decimal(50000 + day * 100)), providerTime: date, fetchedAt: date, provider: "Synthetic"))
            }
            if metalPortfolio != nil { doc.quotes.append(QuoteObservation(assetID: PreciousMetal.gold.assetID, priceUSD: PreciseDecimal(Decimal(100 + day)), providerTime: date, fetchedAt: date, provider: "Synthetic")) }
            for scope in scopes {
                doc = NetWorthCalculator.recordingSample(NetWorthCalculator.value(at: date, scope: scope, document: doc, now: date), in: doc)
            }
        }
        if tracked.contains(.cashFlow) {
            var month = MonthKey.current(now: now)
            for index in 0..<12 {
                doc.entries.append(Entry(month: month, kind: .income, amount: Decimal(3000 + index * 100), currency: "USD", label: "Sample income"))
                doc.entries.append(Entry(month: month, kind: .expense, amount: Decimal(2000 + index * 40), currency: "USD", label: "Sample expense"))
                if index > 0 { doc.reviewedMonths.append(month.description) }
                month = month.previous
            }
        }
        return doc
    }
}
#endif
