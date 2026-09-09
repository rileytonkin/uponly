import Foundation
import Observation

nonisolated enum PerformanceScope: Hashable { case all, personal, business(String) }
nonisolated enum PerformancePeriod: String, CaseIterable { case monthly = "Monthly", annual = "Annual", allTime = "All time" }

@MainActor @Observable final class PopoverModel {
    private(set) var month = MonthKey.current()
    private(set) var scope = PerformanceScope.all
    private(set) var period = PerformancePeriod.monthly
    private(set) var state = PanelState(totals: nil, isEstimated: true, waitingCaption: "No entries recorded")
    private(set) var history: [(month: MonthKey, net: Decimal?, settled: Bool)] = []
    private var document: VaultDocument?
    private var choseInitialMonth = false
    private var explicitlySelectedMonth = false
    weak var owner: UpOnlySession?
    var books: [BusinessBook] { document?.businessAccounting ?? [] }
    var scopeTitle: String {
        switch scope { case .all: "All"; case .personal: "Personal"; case .business(let id): books.first { $0.id == id }?.name ?? "Company" }
    }
    var periodTitle: String { period == .monthly ? month.title : period == .annual ? String(month.year) : "All time" }
    // One selection drives both dashboard sections. Asset history must not be
    // anchored to today while the visible selector names a historical month.
    func selectedInterval(now: Date = Date()) -> DateInterval {
        DashboardPeriod.interval(month: month, period: period, now: now)
    }
    var selectableMonths: [MonthKey] {
        guard let document else { return [.current()] }
        let dates = document.dailyValuations.map(\.utcDay) + document.bankBalances.map(\.observedAt) + document.quantities.map(\.effectiveAt)
        let months = document.entries.compactMap { MonthKey($0.month) }
            + books.compactMap { MonthKey($0.firstMonth) }
            + dates.map { AssetOwnership.month(at: $0) }
        let first = min(month, months.filter { $0 <= .current() }.min() ?? .current())
        var cursor = MonthKey.current(), result: [MonthKey] = []
        for _ in 0..<1200 {
            result.append(cursor)
            if cursor <= first { break }
            cursor = cursor.previous
        }
        return result
    }
    var canStepPeriodBack: Bool {
        let first = selectableMonths.last ?? .current()
        return period == .monthly ? month > first : period == .annual && month.year > first.year
    }
    var canStepPeriodForward: Bool {
        period == .monthly ? canStepForward : period == .annual && month.year < MonthKey.current().year
    }
    func stepPeriod(by count: Int) {
        if period == .monthly { step(by: count) }
        else if period == .annual { select(MonthKey(year: month.year + count, month: 1)) }
    }
    var attentionMonths: [MonthKey] {
        switch period {
        case .monthly: [month]
        case .annual: chartHistory.map(\.month)
        case .allTime: history.map(\.month)
        }
    }
    func attention(in document: VaultDocument, includePerformance: Bool = true) -> DataAttention {
        let months = includePerformance ? attentionMonths : []
        let personal = scope == .all || scope == .personal
        let books = scope == .personal ? [] : document.businessAccounting ?? []
        let selectedBooks = books.filter { scope == .all || scope == .business($0.id) }
        return DataAttention.evaluate(document, months: months, includePersonal: personal,
                                      books: selectedBooks, valuationAt: selectedInterval().end)
    }
    var chartHistory: [(month: MonthKey, net: Decimal?, settled: Bool)] {
        switch period {
        case .monthly, .annual:
            let last = month.year == MonthKey.current().year ? MonthKey.current().month : 12
            return (1...last).map { number in
                let key = MonthKey(year: month.year, month: number)
                return history.first { $0.month == key } ?? (key, nil, false)
            }
        case .allTime: return history
        }
    }
    func replace(with document: VaultDocument) {
        self.document = document
        if case .business(let id) = scope, !books.contains(where: { $0.id == id }) { scope = .all }
        if !choseInitialMonth, !books.isEmpty, let latest = latestAccountingMonth {
            if !explicitlySelectedMonth { month = latest }
            choseInitialMonth = true
        }
        recompute()
    }
    var latestAccountingMonth: MonthKey? {
        guard !books.isEmpty else { return nil }
        return books.flatMap(\.months).compactMap { MonthKey($0.month) }.filter { candidate in
            candidate <= .current() && books.allSatisfy { candidate.description < $0.firstMonth || $0.months.contains { $0.month == candidate.description } }
        }.max()
    }
    var availableTotals: MonthTotals? {
        if let totals = state.totals { return totals }
        // Keep exchange-rate repair and invalid-input states actionable.
        switch state.unavailable { case .accounting?, .noEntries?: break; default: return nil }
        guard let document, period == .monthly,
              state.businesses.contains(where: { $0.share != nil }) || MonthlyLedger.personal(month, document: document).totals != nil else { return nil }
        return state.partialTotals
    }
    var pendingAccounting: [String] { state.businesses.filter { $0.observation == nil && !$0.book.months.isEmpty }.map { $0.book.name } }
    func selectScope(_ scope: PerformanceScope) { self.scope = scope; recompute() }
    func selectPeriod(_ period: PerformancePeriod) { self.period = period; recompute() }
    func state(for month: MonthKey) -> PanelState { state(for: month, scope: scope) }
    private func state(for month: MonthKey, scope: PerformanceScope) -> PanelState {
        guard let document else { return state }
        switch scope {
        case .all: return MonthlyLedger.evaluate(month, document: document)
        case .personal: return MonthlyLedger.personal(month, document: document)
        case .business(let id):
            guard let book = books.first(where: { $0.id == id }) else { return PanelState(totals: nil, isEstimated: true, waitingCaption: "Accounting unavailable") }
            let row = book.months.first { $0.month == month.description }
            let ownership = book.ownership(at: month.description)
            let share = row.flatMap { row in ownership.flatMap { try? $0.portion(row.profitUSD) } }
            let contribution = BusinessContribution(book: book, observation: row, share: share, ownershipLabel: ownership?.label ?? "Ownership missing")
            let warnings = [book.warning, row?.warning, Date().timeIntervalSince(book.fetchedAt) > 86400 ? "Showing saved accounting; refresh needed." : nil].compactMap { $0 }
            return PanelState(totals: row.map { MonthTotals(otherBusiness: $0.profitUSD) }, isEstimated: month == .current() || row?.estimated == true || !warnings.isEmpty,
                              waitingCaption: row == nil ? "No accounting result for this month." : book.basis,
                              unavailable: row == nil ? .accounting([book.name]) : nil,
                              businesses: [contribution], warnings: warnings, missingMonths: row == nil ? 1 : 0)
        }
    }
    var canStepForward: Bool { month < .current() }
    var canStepBack: Bool { month > (history.first?.month ?? .current()) }
    func step(by count: Int) { select(count < 0 ? month.previous : month.next) }
    func select(_ month: MonthKey) { guard month <= .current() else { return }; explicitlySelectedMonth = true; self.month = month; recompute() }
    func drillInto(_ month: MonthKey) { period = .monthly; select(month) }
    private func recompute() {
        guard let document else { return }
        let entryStart = document.entries.filter { $0.bucket == .personal }.compactMap { MonthKey($0.month) }.min()
        let bookStart = books.compactMap { MonthKey($0.firstMonth) }.min()
        let earliest: MonthKey
        switch scope {
        case .personal: earliest = entryStart ?? .current()
        case .all: earliest = [entryStart, bookStart].compactMap { $0 }.min() ?? .current()
        case .business(let id): earliest = books.first { $0.id == id }.flatMap { MonthKey($0.firstMonth) } ?? .current()
        }
        var cursor = MonthKey.current(); var rows: [(MonthKey, Decimal?, Bool)] = []
        for _ in 0..<1200 {
            let result = state(for: cursor)
            rows.append((cursor, result.totals?.net, !result.isEstimated))
            if cursor <= min(earliest, month) { break }
            cursor = cursor.previous
        }
        history = rows.reversed()
        if period == .monthly { state = state(for: month); return }
        let months = history.map(\.month).filter { $0 >= earliest && (period == .allTime || $0.year == month.year) }
        state = aggregate(months: months, scope: scope)
    }
    // Overview and expanded personal activity use the same monthly ledger and
    // period aggregation. Company shares and transfers never enter this subtotal.
    var personalState: PanelState {
        if period == .monthly { return state(for: month, scope: .personal) }
        let earliest = document?.entries.filter { $0.bucket == .personal && $0.kind != .transfer }.compactMap { MonthKey($0.month) }.min() ?? .current()
        return aggregate(months: history.map(\.month).filter { $0 >= earliest && (period == .allTime || $0.year == month.year) }, scope: .personal)
    }
    var personalEntries: [Entry] {
        (document?.entries ?? []).filter {
            $0.bucket == .personal && $0.kind != .transfer && MonthKey($0.month).map { $0 <= .current() } == true
                && (period == .allTime || (period == .annual ? $0.month.hasPrefix(String(month.year) + "-") : $0.month == month.description))
        }.sorted { $0.month == $1.month ? $0.label.localizedStandardCompare($1.label) == .orderedAscending : $0.month > $1.month }
    }
    var personalChartHistory: [(month: MonthKey, net: Decimal?, settled: Bool)] {
        chartHistory.map { row in
            let result = state(for: row.month, scope: .personal)
            return (row.month, result.totals?.net, !result.isEstimated)
        }
    }
    private func aggregate(months: [MonthKey], scope: PerformanceScope) -> PanelState {
        var totals = MonthTotals(), known = 0, missing = 0, estimated = false
        var warnings = Set<String>(), contributions: [String: BusinessContribution] = [:]
        do {
            for m in months {
                let result = state(for: m, scope: scope)
                if result.totals == nil { missing += 1 }
                if let value = result.totals ?? result.partialTotals {
                    totals.personalIncome = try MoneyInput.add(totals.personalIncome, value.personalIncome)
                    totals.personalSpend = try MoneyInput.add(totals.personalSpend, value.personalSpend)
                    totals.moneyIn = try MoneyInput.add(totals.moneyIn, value.moneyIn)
                    totals.moneyOut = try MoneyInput.add(totals.moneyOut, value.moneyOut)
                    totals.otherBusiness = try MoneyInput.add(totals.otherBusiness, value.otherBusiness)
                    totals.ownerPayments = try MoneyInput.add(totals.ownerPayments, value.ownerPayments)
                    known += 1
                }
                estimated = estimated || result.isEstimated
                warnings.formUnion(result.warnings)
                for row in result.businesses where row.observation != nil {
                    if var existing = contributions[row.id], var observation = existing.observation, let next = row.observation {
                        observation.profitUSD = try MoneyInput.add(observation.profitUSD, next.profitUSD); observation.sourceRange = "Monthly accounting results"
                        if let warning = next.warning, observation.warning?.contains(warning) != true {
                            observation.warning = [observation.warning, warning].compactMap { $0 }.joined(separator: " ")
                        }
                        if let a = observation.revenueUSD, let b = next.revenueUSD { observation.revenueUSD = try MoneyInput.add(a, b) } else { observation.revenueUSD = nil }
                        if let a = observation.expensesUSD, let b = next.expensesUSD { observation.expensesUSD = try MoneyInput.add(a, b) } else { observation.expensesUSD = nil }
                        existing.observation = observation
                        if let a = existing.share, let b = row.share { existing.share = try MoneyInput.add(a, b) } else { existing.share = nil }
                        if existing.ownershipLabel != row.ownershipLabel { existing.ownershipLabel = "Historical ownership" }
                        contributions[row.id] = existing
                    } else { contributions[row.id] = row }
                }
            }
            return PanelState(totals: known > 0 ? totals : nil, isEstimated: estimated || missing > 0,
                               waitingCaption: missing > 0 ? "Partial result · \(missing) month\(missing == 1 ? "" : "s") unavailable" : "All recorded months in this period",
                               unavailable: known == 0 ? .noEntries : nil, businesses: contributions.values.sorted { $0.book.name < $1.book.name }, warnings: warnings.sorted(), missingMonths: missing)
        } catch { return PanelState(totals: nil, isEstimated: true, waitingCaption: "An amount is outside the supported range", unavailable: .invalidAmount) }
    }
    func breakdown(_ kind: EntryKind) -> [(label: String, amount: Decimal)] {
        guard let document else { return [] }
        return document.entries.filter { $0.month == month.description && $0.kind == kind && $0.bucket == .personal }.compactMap { entry in
            guard let rate = MonthlyLedger.rate(currency: entry.currency, month: month, document: document), let value = try? MoneyInput.multiply(entry.amount, rate) else { return nil }
            return (entry.label, value)
        }.sorted { $0.amount > $1.amount }
    }
    func markReviewed() { Task { await owner?.perform { doc in if !doc.reviewedMonths.contains(month.description) { doc.reviewedMonths.append(month.description) } } } }
}

// Review is an explicit user assertion, never inferred from a balance, an import
// timestamp, or the presence of a few transactions. No account coverage is invented.
struct DataAttention {
    var spendingMonths: [MonthKey] = []
    var balances: [Account] = []
    var quantities: [Holding] = []
    var pricesNeeded = false
    var accountingNames: [String] = []
    var count: Int {
        (spendingMonths.isEmpty ? 0 : 1) + (balances.isEmpty ? 0 : 1)
        + (quantities.isEmpty ? 0 : 1) + (pricesNeeded ? 1 : 0)
        + (accountingNames.isEmpty ? 0 : 1)
    }
    static func evaluate(_ document: VaultDocument, months: [MonthKey], includePersonal: Bool = true,
                         books: [BusinessBook] = [], now: Date = Date(), valuationAt: Date? = nil) -> DataAttention {
        var result = DataAttention()
        let assetDate = valuationAt ?? now
        let current = MonthKey.current(now: now)
        let selected = Array(Set(months.filter { $0 <= current })).sorted()
        if includePersonal && document.shows(.cashFlow) {
            let reviewed = Set(document.reviewedMonths)
            result.spendingMonths = selected.filter { month in
                if month == current || !reviewed.contains(month.description) { return true }
                return MonthlyLedger.personal(month, document: document).unavailable != nil
            }
        }
        result.balances = document.accounts.filter { account in
            document.isBankTracked(account.id, at: assetDate)
            && !document.bankBalances.contains { $0.accountID == account.id && $0.observedAt <= assetDate }
        }
        result.quantities = document.holdings.filter { holding in
            holding.isActive(at: assetDate) && document.portfolio(id: holding.portfolioID)?.isActive(at: assetDate) == true
            && document.effectiveQuantity(holdingID: holding.id, at: assetDate) == nil
        }
        let valuation = NetWorthCalculator.value(at: assetDate, scope: .allTracked, document: document, now: now)
        result.pricesNeeded = valuation.missing.contains { ["quote", "fx"].contains($0.reason) }
        result.accountingNames = books.filter { book in
            selected.contains { month in
                month.description >= book.firstMonth &&
                (!book.months.contains { $0.month == month.description } || book.ownership(at: month.description) == nil)
            }
        }.map(\.name).sorted()
        return result
    }
}

nonisolated enum DashboardPeriod {
    static func interval(month: MonthKey, period: PerformancePeriod, now: Date) -> DateInterval {
        if period == .allTime { return DateInterval(start: .distantPast, end: now) }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = UTCDay.timeZone
        let firstMonth = period == .annual ? 1 : month.month
        let start = calendar.date(from: DateComponents(year: month.year, month: firstMonth, day: 1))!
        let next = calendar.date(byAdding: period == .annual ? .year : .month, value: 1, to: start)!
        return DateInterval(start: min(start, now), end: min(now, next.addingTimeInterval(-1)))
    }
    static func samples(in interval: DateInterval, scope: ValuationScope, document: VaultDocument) -> [DailyValuation] {
        document.dailyValuations.filter {
            $0.scope == scope && UTCDay.start(of: $0.utcDay) >= UTCDay.start(of: interval.start)
            && UTCDay.start(of: $0.utcDay) <= UTCDay.start(of: interval.end)
        }.sorted { $0.utcDay == $1.utcDay ? $0.computedAt < $1.computedAt : $0.utcDay < $1.utcDay }
    }
}
