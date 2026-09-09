import Foundation

nonisolated enum Bucket: String, Codable, CaseIterable, Sendable { case personal, otherBusiness, reserve, businessCost }
nonisolated enum EntryKind: String, Codable, Sendable { case income, expense, transfer }
nonisolated enum EntrySource: String, Codable, Sendable { case manual, csv, wise }
nonisolated enum TrackedKind: String, Codable, CaseIterable, Sendable {
    case banks, crypto, metals, cashFlow
    static func normalized<S: Sequence>(_ kinds: S) -> [TrackedKind] where S.Element == TrackedKind {
        let chosen = Set(kinds)
        return allCases.filter { chosen.contains($0) }
    }
    var managementSection: String {
        switch self {
        case .banks: "Accounts"
        case .crypto: "Portfolios"
        case .metals: "Precious metals"
        case .cashFlow: "Entries"
        }
    }
    static func kind(forSection section: String) -> TrackedKind? { allCases.first { $0.managementSection == section } }
}
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
    var importFingerprint: String?
    var kindIsUserEdited: Bool?
    init(month: MonthKey, bucket: Bucket = .personal, kind: EntryKind, amount: Decimal, currency: String, label: String, source: EntrySource = .manual, sourceRef: String? = nil) {
        self.month = month.description; self.bucket = bucket; self.kind = kind
        self.amount = amount; self.currency = currency; self.label = label; self.source = source; self.sourceRef = sourceRef
    }
    /// The bank account a CSV import was saved against (`<account UUID>:<transaction reference>`).
    /// Manual entries and Wise activity have no bank account.
    var accountID: UUID? {
        guard source == .csv, let ref = sourceRef, let prefix = ref.split(separator: ":", maxSplits: 1).first else { return nil }
        return UUID(uuidString: String(prefix))
    }
}
nonisolated struct Account: Codable, Identifiable, Sendable, Hashable {
    var id = UUID()
    var name: String
    var currency: String
    var isActive = true
    // Optional provenance and artwork remain inside the encrypted vault.
    var ownerBusinessID: String?
    var externalProfileID: String?
    var externalBalanceID: String?
    var profileImage: Data?
}
nonisolated struct DormantMark: Codable, Sendable, Hashable { var accountID: UUID; var month: String }
nonisolated struct SetupProgress: Codable, Sendable, Equatable {
    var step = 0
    var tracked: [TrackedKind] = []
    var prices = false
    var fx = false
    var metals = false
    var coinGeckoKey = ""
    var metalHistoryKey = ""
    var normalized: SetupProgress {
        var copy = self
        copy.tracked = TrackedKind.normalized(tracked)
        copy.step = step == 1 && !copy.tracked.isEmpty ? 1 : 0
        return copy
    }
}
nonisolated struct AppSettings: Codable, Sendable, Equatable {
    var setupComplete = false
    var privacyMode = false
    var setupProgress: SetupProgress?
    var automaticPrices = false
    var automaticFX = false
    var automaticMetals = false
    var metalHistoryKey = ""
    var coinGeckoKey = ""
    var tracked: [TrackedKind] = TrackedKind.allCases
    #if UPONLY_PERSONAL
    var automaticWise = false
    #endif
    init() {}
    private enum CodingKeys: String, CodingKey { case setupComplete, privacyMode, setupProgress, automaticPrices, automaticFX, automaticMetals, metalHistoryKey, coinGeckoKey, tracked
        #if UPONLY_PERSONAL
        case automaticWise
        #endif
    }
    // Vaults written before a field existed must still open, so every key is optional on the way in.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        setupComplete = try container.decodeIfPresent(Bool.self, forKey: .setupComplete) ?? false
        privacyMode = try container.decodeIfPresent(Bool.self, forKey: .privacyMode) ?? false
        setupProgress = try container.decodeIfPresent(SetupProgress.self, forKey: .setupProgress)?.normalized
        automaticPrices = try container.decodeIfPresent(Bool.self, forKey: .automaticPrices) ?? false
        automaticFX = try container.decodeIfPresent(Bool.self, forKey: .automaticFX) ?? false
        metalHistoryKey = try container.decodeIfPresent(String.self, forKey: .metalHistoryKey) ?? ""
        automaticMetals = try container.decodeIfPresent(Bool.self, forKey: .automaticMetals) ?? false
        coinGeckoKey = try container.decodeIfPresent(String.self, forKey: .coinGeckoKey) ?? ""
        #if UPONLY_PERSONAL
        automaticWise = try container.decodeIfPresent(Bool.self, forKey: .automaticWise) ?? false
        #endif
        if let raw = try container.decodeIfPresent([String].self, forKey: .tracked) {
            tracked = TrackedKind.normalized(raw.compactMap(TrackedKind.init(rawValue:)))
        } else {
            tracked = TrackedKind.allCases
        }
    }
}
extension VaultDocument {
    func hasData(_ kind: TrackedKind) -> Bool {
        switch kind {
        case .banks: !accounts.isEmpty
        case .crypto: portfolios.contains { !$0.isArchived && $0.kind == .crypto }
        case .metals: portfolios.contains { !$0.isArchived && $0.kind == .metals }
        case .cashFlow: !entries.isEmpty || !(businessAccounting ?? []).isEmpty
        }
    }
    /// A section is shown when the user chose it, or whenever it holds data. Counted money is never hidden.
    func shows(_ kind: TrackedKind) -> Bool { settings.tracked.contains(kind) || hasData(kind) }
    var shownKinds: [TrackedKind] { TrackedKind.allCases.filter { shows($0) } }
    var showsHoldings: Bool { shows(.crypto) || shows(.metals) }
    var showsNetWorth: Bool { shows(.banks) || showsHoldings }
    func showsDestination(_ value: Int) -> Bool { value == 0 ? shows(.cashFlow) : value == 1 && showsNetWorth }
    // Net worth is the headline whenever any asset is shown; cash flow otherwise.
    var defaultDestination: Int { showsNetWorth ? 1 : 0 }
    var defaultManagementSection: String { shownKinds.first?.managementSection ?? "Manage" }
    func showsSection(_ name: String) -> Bool { TrackedKind.kind(forSection: name).map { shows($0) } ?? true }
    func managementSection(forDestination value: Int) -> String {
        if value == 0 {
            if shows(.banks) { return "Accounts" }
            if shows(.cashFlow) { return "Entries" }
            return defaultManagementSection
        }
        if shows(.crypto) { return "Portfolios" }
        if shows(.metals) { return "Precious metals" }
        if shows(.banks) { return "Accounts" }
        return defaultManagementSection
    }
    mutating func track(_ kind: TrackedKind) { settings.tracked = TrackedKind.normalized(settings.tracked + [kind]) }
    mutating func setTracked(_ kind: TrackedKind, _ on: Bool) {
        guard on || !hasData(kind) else { return }
        settings.tracked = TrackedKind.normalized(on ? settings.tracked + [kind] : settings.tracked.filter { $0 != kind })
    }
}
nonisolated struct ImportedStatement: Codable, Sendable, Equatable {
    var digest: Data
    var originalBytes: Data
    var importedAt: Date
    var accountID: UUID?
}
nonisolated struct MonthTotals {
    var personalIncome: Decimal = 0
    var personalSpend: Decimal = 0
    var otherBusiness: Decimal = 0
    var moneyIn: Decimal = 0
    var moneyOut: Decimal = 0
    var net: Decimal { moneyIn - moneyOut + otherBusiness }
}
nonisolated struct CurrencyMonthTotals: Identifiable {
    var currency: String
    var totals: MonthTotals
    var id: String { currency }
}
nonisolated enum MonthUnavailable: Equatable {
    case noEntries
    case exchangeRates([String])
    case invalidAmount
    case accounting([String])
}
nonisolated struct PanelState {
    var totals: MonthTotals?
    var isEstimated: Bool
    var waitingCaption: String?
    var unavailable: MonthUnavailable? = nil
    var partialTotals: MonthTotals? = nil
    var businesses: [BusinessContribution] = []
    var warnings: [String] = []
    var missingMonths: Int = 0
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
    static func nativeTotals(_ month: MonthKey, document: VaultDocument) throws -> [CurrencyMonthTotals] {
        let monthID = month.description
        let entries = document.entries.filter { $0.month == monthID && $0.kind != .transfer && $0.bucket == .personal }
        return try Dictionary(grouping: entries, by: \.currency).map { currency, rows in
            var totals = MonthTotals()
            for row in rows {
                if row.kind == .income { totals.moneyIn = try MoneyInput.add(totals.moneyIn, row.amount) }
                else { totals.moneyOut = try MoneyInput.add(totals.moneyOut, row.amount) }
            }
            _ = try MoneyInput.add(totals.moneyIn, -totals.moneyOut)
            return CurrencyMonthTotals(currency: currency, totals: totals)
        }.sorted { $0.currency < $1.currency }
    }
    static func evaluate(_ month: MonthKey, document: VaultDocument) -> PanelState {
        let monthID = month.description
        var result = personal(month, document: document)
        let books = (document.businessAccounting ?? []).filter { $0.firstMonth <= monthID }
        let hasCompanyActivity = document.entries.contains { $0.month == monthID && ($0.bucket == .otherBusiness || $0.bucket == .businessCost) }
        if books.isEmpty {
            if hasCompanyActivity && document.businessAccounting == nil {
                result.partialTotals = result.totals
                result.totals = nil; result.unavailable = .accounting(["Business profit"])
                result.waitingCaption = "Connect accounting to include business profit."
            }
            return result
        }
        let personalUnavailable = result.unavailable != nil
        var partial = result.totals ?? MonthTotals()
        var missing: [String] = []
        for book in books {
            let observation = book.months.first { $0.month == monthID }
            let ownership = book.ownership(at: monthID)
            let share = observation.flatMap { row in ownership.flatMap { try? $0.portion(row.profitUSD) } }
            result.businesses.append(BusinessContribution(book: book, observation: observation, share: share, ownershipLabel: ownership?.label ?? "Ownership missing"))
            if let share {
                var total = partial
                guard let sum = try? MoneyInput.add(total.otherBusiness, share) else { return PanelState(totals: nil, isEstimated: true, waitingCaption: "An amount is outside the supported range", unavailable: .invalidAmount) }
                total.otherBusiness = sum; partial = total
            } else { missing.append(book.name) }
            if let warning = book.warning { result.warnings.append(book.name + ": " + warning) }
            if let warning = observation?.warning { result.warnings.append(book.name + ": " + warning) }
            if Date().timeIntervalSince(book.fetchedAt) > 86400 { result.warnings.append(book.name + ": showing saved accounting; refresh needed.") }
            result.isEstimated = result.isEstimated || observation?.estimated == true || !result.warnings.isEmpty
        }
        result.partialTotals = partial
        if !missing.isEmpty {
            result.totals = nil; result.isEstimated = true; result.unavailable = .accounting(missing)
            result.waitingCaption = "Accounting unavailable for " + missing.joined(separator: ", ")
            result.missingMonths = 1
        } else if personalUnavailable {
            result.missingMonths = 1; result.isEstimated = true
            if result.unavailable == .noEntries { result.waitingCaption = "Personal income and spending are not recorded for this month. Your known business shares are shown below." }
        } else if result.unavailable == nil {
            result.totals = partial
            result.waitingCaption = result.warnings.isEmpty ? "Personal income − personal spending + your share of business profit." : "Accounting includes estimates or checks needing review."
        }
        return result
    }
    static func personal(_ month: MonthKey, document: VaultDocument) -> PanelState {
        let monthID = month.description
        let entries = document.entries.filter { $0.month == monthID && $0.kind != .transfer && $0.bucket == .personal }
        let provisional = month == .current() || !document.reviewedMonths.contains(monthID)
        guard !entries.isEmpty else { return PanelState(totals: nil, isEstimated: provisional, waitingCaption: "No entries recorded", unavailable: .noEntries) }
        // One dated rate per currency is shared by every entry in this month.
        // Re-scanning years of FX history for each transaction delays unlock.
        let currencies = Set(entries.filter { $0.amount != 0 }.map(\.currency))
        let now = Date()
        let rates = Dictionary(uniqueKeysWithValues: currencies.compactMap { currency in
            rate(currency: currency, month: month, document: document, now: now).map { (currency, $0) }
        })
        let missing = currencies.filter { rates[$0] == nil }.sorted()
        guard missing.isEmpty else {
            return PanelState(totals: nil, isEstimated: true, waitingCaption: "Needs a dated " + missing.joined(separator: ", ") + " exchange rate", unavailable: .exchangeRates(missing))
        }
        var totals = MonthTotals()
        do {
            for e in entries where e.amount != 0 {
                guard let rate = rates[e.currency] else {
                    return PanelState(totals: nil, isEstimated: true, waitingCaption: "Needs a dated " + e.currency + " exchange rate", unavailable: .exchangeRates([e.currency]))
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
        } catch { return PanelState(totals: nil, isEstimated: true, waitingCaption: "An amount is outside the supported range", unavailable: .invalidAmount) }
    }
}
