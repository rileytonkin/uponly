import Foundation

nonisolated struct MonthKey: Hashable, Comparable, Sendable, CustomStringConvertible {
    let year: Int
    let month: Int

    /// Months outside 1...12 roll into the neighbouring years, so every key names a real month.
    init(year: Int, month: Int) {
        var (years, index) = (month - 1).quotientAndRemainder(dividingBy: 12)
        if index < 0 { years -= 1; index += 12 }
        self.year = year + years
        self.month = index + 1
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

    /// The Gregorian UTC month, like every statement, sync and ownership month, whatever calendar the Mac uses.
    static func current(now: Date = Date()) -> MonthKey {
        let parts = UTCDay.calendar.dateComponents([.year, .month], from: now)
        return MonthKey(year: parts.year ?? 2026, month: parts.month ?? 1)
    }

    var title: String {
        guard let date = UTCDay.calendar.date(from: DateComponents(year: year, month: month)) else { return description }
        return Self.titleFormatter.string(from: date)
    }

    var shortName: String {
        guard let date = UTCDay.calendar.date(from: DateComponents(year: year, month: month)) else { return description }
        return Self.shortFormatter.string(from: date)
    }

    private static let titleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = UTCDay.calendar; f.timeZone = UTCDay.timeZone
        f.dateFormat = "MMMM yyyy"
        return f
    }()

    private static let shortFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = UTCDay.calendar; f.timeZone = UTCDay.timeZone
        f.dateFormat = "MMMM"
        return f
    }()
}
