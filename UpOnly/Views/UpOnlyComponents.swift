import SwiftUI

// Small views, styles and dashboard arithmetic shared across pages.

struct UpOnlyAmount: View {
    @Environment(UpOnlySession.self) private var session
    var value: Decimal
    var signed = false
    var tint: Color = .primary
    private var sign: String { value < 0 ? "−" : signed && value > 0 ? "+" : "" }
    var body: some View {
        if session.privacyMode {
            Text("••••").font(.system(size: 40, weight: .semibold)).foregroundStyle(.primary)
                .accessibilityLabel("Hidden value")
        } else {
        ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text(sign + "$").fixedSize(horizontal: false, vertical: true)
                .font(.system(size: 24, weight: .medium))
            Text(UpOnlyFormat.money(abs(value)).replacingOccurrences(of: "$", with: "")).fixedSize(horizontal: false, vertical: true)
                .font(.system(size: 40, weight: .semibold).monospacedDigit()).tracking(-1.3)
        }.fixedSize()
            Text(sign + UpOnlyFormat.money(abs(value))).fixedSize(horizontal: false, vertical: true).font(.system(size: 24, weight: .semibold).monospacedDigit())
        }.foregroundStyle(tint)
            .accessibilityElement(children: .ignore).accessibilityLabel(sign + UpOnlyFormat.money(abs(value)))
        }
    }
}

/// A label and a value on one line, or stacked when they don't fit. VoiceOver reads "<label>, <value>".
struct UpOnlyValueRow: View {
    @Environment(UpOnlySession.self) private var session
    var label: String
    var value: String
    var primaryLabel = false
    var body: some View {
        ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).fixedSize().foregroundStyle(primaryLabel ? Color.primary : Color.secondary)
            Spacer(minLength: 8)
            UpOnlyPrivateText(value).fixedSize().monospacedDigit().foregroundStyle(.primary)
        }
            VStack(alignment: .leading, spacing: 4) {
                Text(label).fixedSize(horizontal: false, vertical: true).foregroundStyle(primaryLabel ? Color.primary : Color.secondary)
                UpOnlyPrivateText(value).fixedSize(horizontal: false, vertical: true).monospacedDigit().foregroundStyle(.primary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
        }.font(UpOnlyType.row).frame(maxWidth: .infinity, minHeight: 28, alignment: .leading).contentShape(Rectangle())
            .accessibilityElement(children: .ignore).accessibilityLabel(label)
            .accessibilityValue(session.privacyMode ? "Hidden value" : value)
    }
}


struct UpOnlyPrivacyButton: View {
    var inMenu = false
    @Environment(UpOnlySession.self) private var session
    var body: some View {
        if inMenu { button }
        else { button.buttonStyle(UpOnlyToolbarButtonStyle()) }
    }
    // Never disabled while a save runs: hiding values has to work at once, even during a history rebuild.
    private var button: some View {
        Button {
            Task {
                let token = session.sessionToken
                do { try await session.togglePrivacyMode() }
                catch {
                    if session.sessionToken == token, session.state == .unlocked {
                        session.message = "Couldn’t save privacy mode. Please try again."
                    }
                }
            }
        } label: {
            if inMenu { Label(session.privacyMode ? "Show values" : "Hide values", systemImage: session.privacyMode ? "eye.slash" : "eye") }
            else { Image(systemName: session.privacyMode ? "eye.slash" : "eye").font(.system(size: 13, weight: .medium)).frame(width: 16, height: 16) }
        }.foregroundStyle(session.privacyMode ? Color.accentColor : Color.primary)
            .accessibilityLabel(session.privacyMode ? "Show values" : "Hide values")
            .accessibilityValue(session.privacyMode ? "Privacy mode on" : "Privacy mode off")
            .accessibilityIdentifier("PrivacyMode")
            .help(session.privacyMode ? "Show values (⇧⌘P)" : "Hide values (⇧⌘P)")
            .keyboardShortcut("p", modifiers: [.command, .shift])
    }
}

/// Replace the text, not merely its pixels, so hidden values are absent from accessibility.
struct UpOnlyPrivateText: View {
    @Environment(UpOnlySession.self) private var session
    let value: String
    init(_ value: String) { self.value = value }
    var body: some View {
        if session.privacyMode { Text("••••").accessibilityLabel("Hidden value") }
        else { Text(value) }
    }
}

/// Native secure entry retains editing and paste without exposing a financial amount.
struct UpOnlyValueField: View {
    @Environment(UpOnlySession.self) private var session
    let placeholder: String
    @Binding var text: String
    init(_ placeholder: String, text: Binding<String>) { self.placeholder = placeholder; _text = text }
    var body: some View {
        if session.privacyMode { SecureField(placeholder, text: $text) }
        else { TextField(placeholder, text: $text, axis: .vertical) }
    }
}

// Equal hit regions and one shared glass surface keep toolbar actions aligned.
struct UpOnlyToolbarButtonStyle: ButtonStyle {
    var size: CGFloat = 32
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(width: size, height: size)
            .contentShape(Rectangle())
            .background(.primary.opacity(configuration.isPressed ? 0.14 : 0), in: Capsule())
            .opacity(isEnabled ? 1 : 0.4)
    }
}

// macOS substitutes a native menu label, so padding inside its label closure is
// discarded. Size the menu itself before applying its glass surface.
struct UpOnlyPillMenu: ViewModifier {
    /// 26 pt for menus that act; 22 pt for the quieter pill that names what a page's figure covers.
    var height: CGFloat = 26
    func body(content: Content) -> some View {
        content.menuStyle(.borderlessButton).menuIndicator(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, height < 26 ? 9 : 10).frame(minHeight: height)
            .glassEffect(.regular, in: .capsule)
    }
}
/// A flat list row: it darkens while pressed and stays lightly tinted while selected.
struct UpOnlyRowButtonStyle: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background {
            RoundedRectangle(cornerRadius: 8).fill(configuration.isPressed ? Color.primary.opacity(0.06) : selected ? UpOnlyTint.netWorth.opacity(0.1) : .clear)
                .padding(.horizontal, -6)
        }
    }
}
/// A source of personal transactions: a bank account, a Wise profile, or "Added by hand".
struct PersonalAccountGroup: Identifiable {
    var id: String
    var name: String
    var entries: [Entry]
}
/// How much net worth history the chart shows. The headline value is always today's.
nonisolated enum WorthRange: CaseIterable {
    case month, quarter, year, twoYears, fiveYears
    /// The chip under the chart.
    var title: String {
        switch self { case .month: "1M"; case .quarter: "3M"; case .year: "1Y"; case .twoYears: "2Y"; case .fiveYears: "5Y" }
    }
    /// How the change line names the range: "+$4,599 (+50.5%) · past year".
    var phrase: String {
        switch self { case .month: "past month"; case .quarter: "past 3 months"; case .year: "past year"; case .twoYears: "past 2 years"; case .fiveYears: "past 5 years" }
    }
    var spokenTitle: String { phrase.prefix(1).uppercased() + String(phrase.dropFirst()) }
    /// Whole months shown on monthly charts, ending with the current month.
    var months: Int {
        switch self { case .month: 1; case .quarter: 3; case .year: 12; case .twoYears: 24; case .fiveYears: 60 }
    }
    /// Every range is rolling, ending now.
    var seconds: TimeInterval {
        switch self { case .month: 30 * 86400; case .quarter: 91 * 86400; case .year: 365 * 86400; case .twoYears: 730 * 86400; case .fiveYears: 1826 * 86400 }
    }
    /// Days between chart points: daily up to three months, weekly for a year or two, monthly for five.
    var chartStepDays: Int {
        switch self { case .month, .quarter: 1; case .year, .twoYears: 7; case .fiveYears: 30 }
    }
    /// Longer ranges label every this many months on the x-axis, always including January (shown as its year).
    /// Nil labels Mondays instead.
    var axisMonthStep: Int? {
        switch self { case .month, .quarter: nil; case .year: 2; case .twoYears: 3; case .fiveYears: 12 }
    }
}

/// Dashboard arithmetic kept out of the views, so it can be tested on its own.
nonisolated enum DashboardChart {
    /// Chart stops walk back from the last sample's day every `strideDays` days to the start of the range, so the
    /// last point is always the latest value. Each stop takes the latest sample in (stop − stride, stop]: a real
    /// valuation from that day, week or month, never an invented one. `sampleDays` must be in ascending order; the
    /// result runs oldest first, with the index of each stop's sample.
    static func stops(sampleDays: [Date], rangeStart: Date, strideDays: Int) -> [(day: Date, sample: Int?)] {
        guard let first = sampleDays.first, let last = sampleDays.last else { return [] }
        let stride = TimeInterval(max(1, strideDays) * 86400)
        let start = min(UTCDay.start(of: first), UTCDay.start(of: rangeStart))
        var days: [Date] = [], cursor = UTCDay.start(of: last)
        while cursor >= start && days.count < 10000 { days.append(cursor); cursor = cursor.addingTimeInterval(-stride) }
        var result: [(day: Date, sample: Int?)] = [], next = 0
        for day in days.reversed() {
            var chosen: Int?
            while next < sampleDays.count, UTCDay.start(of: sampleDays[next]) <= day {
                if UTCDay.start(of: sampleDays[next]) > day.addingTimeInterval(-stride) { chosen = next }
                next += 1
            }
            result.append((day, chosen))
        }
        return result
    }
    /// X-axis labels for chart stops. Short ranges mark Mondays ("Sep 7"). Longer ones mark the first stop of every
    /// `axisMonthStep`-th month ("Mar"), with January shown as its year ("2026"), so the labels are month starts
    /// rather than whichever dates the stops happen to fall on.
    static func axisLabels(_ days: [Date], range: WorthRange) -> [String?] {
        let calendar = UTCDay.calendar
        guard let step = range.axisMonthStep else {
            return days.map { calendar.component(.weekday, from: $0) == 2 ? UpOnlyFormat.utcDay($0) : nil }
        }
        var labels: [String?] = [], previous: Int?
        for day in days {
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let month = parts.month ?? 1
            // The first stop in a month; the chart's first stop counts only if it's that close to the month's start.
            let starts = previous.map { $0 != month } ?? ((parts.day ?? 99) <= range.chartStepDays)
            labels.append(starts && (month - 1) % step == 0 ? (month == 1 ? String(parts.year ?? 0) : UpOnlyFormat.monthName(day)) : nil)
            previous = month
        }
        return labels
    }
    /// Whole percentages of each value that add up to exactly 100 (largest remainder first); zero and negative
    /// values get 0. For the allocation legend.
    static func percentages(_ values: [Decimal]) -> [Int] {
        let parts = values.map { max($0, 0) }
        let total = parts.reduce(Decimal(0), +)
        guard total > 0 else { return values.map { _ in 0 } }
        let exact = parts.map { NSDecimalNumber(decimal: $0 / total * 100).doubleValue }
        var result = exact.map { Int($0.rounded(.down)) }
        let remainders = exact.indices.map { exact[$0] - Double(result[$0]) }
        let order = exact.indices.sorted { remainders[$0] != remainders[$1] ? remainders[$0] > remainders[$1] : $0 < $1 }
        for index in order.prefix(max(0, 100 - result.reduce(0, +))) { result[index] += 1 }
        return result
    }
}
