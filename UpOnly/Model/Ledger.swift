import Foundation

nonisolated enum Bucket: String, Codable, CaseIterable, Sendable { case personal, otherBusiness, reserve, businessCost }
nonisolated enum EntryKind: String, Codable, Sendable { case income, expense, transfer }
nonisolated enum EntrySource: String, Codable, Sendable { case manual, csv }
nonisolated struct Entry: Codable, Identifiable, Sendable, Equatable {
    var id = UUID()
    var month: String
    var bucket: Bucket
    var kind: EntryKind
    var amount: Decimal
    var currency: String
    var label: String
    var source: EntrySource
    var sourceRef: String?
    init(month: MonthKey, bucket: Bucket = .personal, kind: EntryKind, amount: Decimal, currency: String, label: String, source: EntrySource = .manual, sourceRef: String? = nil) {
        self.month = month.description; self.bucket = bucket; self.kind = kind
        self.amount = amount; self.currency = currency; self.label = label; self.source = source; self.sourceRef = sourceRef
    }
}
nonisolated struct Account: Codable, Identifiable, Sendable, Hashable {
    var id = UUID()
    var name: String
    var currency: String
    var isActive = true
}
nonisolated struct DormantMark: Codable, Sendable, Hashable { var accountID: UUID; var month: String }
nonisolated struct AppSettings: Codable, Sendable, Equatable {
    var setupComplete = false
    var automaticPrices = false
    var automaticFX = false
    var coinGeckoKey = ""
}
nonisolated struct ImportedStatement: Codable, Sendable, Equatable {
    var digest: Data
    var originalBytes: Data
    var importedAt: Date
}
nonisolated struct MonthTotals {
    var personalIncome: Decimal = 0
    var personalSpend: Decimal = 0
    var otherBusiness: Decimal = 0
    var moneyIn: Decimal = 0
    var moneyOut: Decimal = 0
    var net: Decimal { moneyIn - moneyOut }
}
nonisolated struct PanelState {
    var totals: MonthTotals?
    var isEstimated: Bool
    var waitingCaption: String?
}
nonisolated enum MonthlyLedger {
    static func rate(currency: String, month: MonthKey, document: VaultDocument, now: Date = Date()) -> Decimal? {
        if currency == "USD" { return 1 }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = UTCDay.timeZone
        guard let end = calendar.date(from: DateComponents(year: month.next.year, month: month.next.month, day: 1)) else { return nil }
        let cutoff = min(end.addingTimeInterval(-1), now)
        return document.fx.filter { $0.sourceCurrency == currency && $0.targetCurrency == "USD" && $0.providerTime <= cutoff && cutoff.timeIntervalSince($0.providerTime) <= 7 * 86400 }
            .max(by: { $0.providerTime < $1.providerTime })?.rate.value
    }
    static func evaluate(_ month: MonthKey, document: VaultDocument) -> PanelState {
        let entries = document.entries.filter { $0.month == month.description && $0.kind != .transfer && $0.bucket != .reserve }
        let provisional = month == .current() || !document.reviewedMonths.contains(month.description)
        guard !entries.isEmpty else { return PanelState(totals: nil, isEstimated: provisional, waitingCaption: "No entries recorded") }
        var totals = MonthTotals()
        do {
            for e in entries {
                guard let rate = rate(currency: e.currency, month: month, document: document) else {
                    return PanelState(totals: nil, isEstimated: true, waitingCaption: "Needs a dated " + e.currency + " exchange rate")
                }
                let value = try MoneyInput.multiply(e.amount, rate)
                if e.kind == .income { totals.moneyIn = try MoneyInput.add(totals.moneyIn, value) }
                else { totals.moneyOut = try MoneyInput.add(totals.moneyOut, value) }
                if e.bucket == .otherBusiness || e.bucket == .businessCost {
                    totals.otherBusiness = try MoneyInput.add(totals.otherBusiness, e.kind == .income ? value : -value)
                } else if e.kind == .income { totals.personalIncome = try MoneyInput.add(totals.personalIncome, value) }
                else { totals.personalSpend = try MoneyInput.add(totals.personalSpend, value) }
            }
            _ = try MoneyInput.add(totals.moneyIn, -totals.moneyOut)
            return PanelState(totals: totals, isEstimated: provisional, waitingCaption: provisional ? "Based on recorded entries" : nil)
        } catch { return PanelState(totals: nil, isEstimated: true, waitingCaption: "An amount is outside the supported range") }
    }
}
