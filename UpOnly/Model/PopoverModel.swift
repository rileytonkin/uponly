import Foundation
import Observation

@MainActor @Observable final class PopoverModel {
    private(set) var month = MonthKey.current()
    private(set) var state = PanelState(totals: nil, isEstimated: true, waitingCaption: "No entries recorded")
    private(set) var history: [(month: MonthKey, net: Decimal?, settled: Bool)] = []
    private var document: VaultDocument?
    weak var owner: UpOnlySession?
    func replace(with document: VaultDocument) { self.document = document; recompute() }
    func state(for month: MonthKey) -> PanelState {
        document.map { MonthlyLedger.evaluate(month, document: $0) } ?? state
    }
    var canStepForward: Bool { month < .current() }
    var canStepBack: Bool { month > (history.first?.month ?? .current()) }
    func step(by count: Int) { select(count < 0 ? month.previous : month.next) }
    func select(_ month: MonthKey) { guard month <= .current() else { return }; self.month = month; recompute() }
    private func recompute() {
        guard let document else { return }
        state = MonthlyLedger.evaluate(month, document: document)
        let earliest = document.entries.compactMap { MonthKey($0.month) }.min() ?? MonthKey.current()
        var cursor = MonthKey.current(); var rows: [(MonthKey, Decimal?, Bool)] = []
        for i in 0..<1200 {
            let result = MonthlyLedger.evaluate(cursor, document: document)
            rows.append((cursor, result.totals?.net, !result.isEstimated))
            if i >= 11 && cursor <= earliest { break }
            cursor = cursor.previous
        }
        history = rows.reversed()
    }
    func breakdown(_ kind: EntryKind) -> [(label: String, amount: Decimal)] {
        guard let document else { return [] }
        return document.entries.filter { $0.month == month.description && $0.kind == kind && $0.bucket == .personal }.compactMap { entry in
            guard let rate = MonthlyLedger.rate(currency: entry.currency, month: month, document: document),
                  let value = try? MoneyInput.multiply(entry.amount, rate) else { return nil }
            return (entry.label, value)
        }.sorted { $0.amount > $1.amount }
    }
    func markReviewed() { Task { await owner?.perform { doc in if !doc.reviewedMonths.contains(month.description) { doc.reviewedMonths.append(month.description) } } } }
}
