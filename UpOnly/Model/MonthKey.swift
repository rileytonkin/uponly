import Foundation

nonisolated struct MonthKey: Hashable, Comparable, Sendable, CustomStringConvertible {
    let year: Int
    let month: Int

    init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    init?(_ raw: String) {
        let parts = raw.split(separator: "-")
        guard parts.count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), (1900...9998).contains(year), raw.count == 7,
              (1...12).contains(month) else { return nil }
        self.init(year: year, month: month)
    }

    var description: String { String(format: "%04d-%02d", year, month) }

    var previous: MonthKey {
        month > 1 ? MonthKey(year: year, month: month - 1)
                  : MonthKey(year: year - 1, month: 12)
    }

    var next: MonthKey {
        month < 12 ? MonthKey(year: year, month: month + 1)
                   : MonthKey(year: year + 1, month: 1)
    }

    static func < (lhs: MonthKey, rhs: MonthKey) -> Bool {
        (lhs.year, lhs.month) < (rhs.year, rhs.month)
    }

    static func current(now: Date = Date(), calendar: Calendar = .current) -> MonthKey {
        let parts = calendar.dateComponents([.year, .month], from: now)
        return MonthKey(year: parts.year ?? 2026, month: parts.month ?? 1)
    }

    static func lastComplete(now: Date = Date(), calendar: Calendar = .current) -> MonthKey {
        current(now: now, calendar: calendar).previous
    }

    var displayTitle: String {
        var components = DateComponents()
        components.year = year
        components.month = month
        guard let date = Calendar.current.date(from: components) else { return description }
        return Self.titleFormatter.string(from: date).uppercased()
    }

    var title: String {
        var components = DateComponents()
        components.year = year
        components.month = month
        guard let date = Calendar.current.date(from: components) else { return description }
        return Self.titleFormatter.string(from: date)
    }

    var shortName: String {
        var components = DateComponents()
        components.year = year
        components.month = month
        guard let date = Calendar.current.date(from: components) else { return description }
        return Self.shortFormatter.string(from: date)
    }

    nonisolated(unsafe) private static let titleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f
    }()

    nonisolated(unsafe) private static let shortFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM"
        return f
    }()
}
