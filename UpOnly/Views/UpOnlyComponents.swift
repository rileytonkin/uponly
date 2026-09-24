import SwiftUI

// Small views, styles and dashboard arithmetic shared across pages.

struct UpOnlyAmount: View {
    @Environment(UpOnlySession.self) private var session
    var value: Decimal
    var signed = false
    var tint: Color = .primary
    /// Shows cents, in secondary colour so the dollars still read first: "$13,710.42".
    var cents = false
    private var sign: String { value < 0 ? "−" : signed && value > 0 ? "+" : "" }
    /// "13,710" and ".42" (or "" without cents).
    private var parts: (whole: String, fraction: String) {
        let text = (cents ? UpOnlyFormat.exactMoney(abs(value)) : UpOnlyFormat.money(abs(value))).replacingOccurrences(of: "$", with: "")
        guard cents, let dot = text.lastIndex(of: ".") else { return (text, "") }
        return (String(text[..<dot]), String(text[dot...]))
    }
    var body: some View {
        if session.privacyMode {
            Text("••••").font(.system(size: 40, weight: .semibold)).foregroundStyle(.primary)
                .accessibilityLabel("Hidden value")
        } else {
        let parts = parts
        ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text(sign + "$").fixedSize(horizontal: false, vertical: true)
                .font(.system(size: 24, weight: .medium))
            Text(parts.whole).fixedSize(horizontal: false, vertical: true)
                .font(.system(size: 40, weight: .semibold).monospacedDigit()).tracking(-1.3)
            if !parts.fraction.isEmpty {
                Text(parts.fraction).font(.system(size: 40, weight: .semibold).monospacedDigit()).tracking(-1.3).foregroundStyle(.secondary)
            }
        }.fixedSize()
            Text(sign + "$" + parts.whole + parts.fraction).fixedSize(horizontal: false, vertical: true).font(.system(size: 24, weight: .semibold).monospacedDigit())
        }.foregroundStyle(tint)
            .accessibilityElement(children: .ignore).accessibilityLabel(sign + "$" + parts.whole + parts.fraction)
        }
    }
}

/// A change as an outlined pill, "↑ 21.0%", green up and red down, as on the admin dashboard.
struct UpOnlyChangeBadge: View {
    var fraction: Decimal
    var body: some View {
        let rounded = UpOnlyFormat.roundedPercent(fraction)
        let tint = UpOnlyTint.signed(rounded)
        HStack(spacing: 2) {
            if rounded != 0 { Image(systemName: rounded > 0 ? "arrow.up" : "arrow.down").font(.system(size: 10, weight: .bold)) }
            Text(UpOnlyFormat.magnitude(fraction)).font(.system(size: 12, weight: .semibold).monospacedDigit())
        }.foregroundStyle(tint).lineLimit(1).fixedSize()
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(tint.opacity(0.1), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.75), lineWidth: 1))
            .accessibilityElement(children: .ignore).accessibilityLabel(UpOnlyFormat.percent(fraction))
    }
}

/// A coin or metal at a glance. The top coins' logos ship with the app, so none is ever fetched (that would tell a
/// server what you hold); any other coin shows its ticker's first letter on a colour fixed by its id, and metals use
/// the bar icon in their own colour.
struct UpOnlyAssetBadge: View {
    var assetID: String
    var symbol: String
    var size: CGFloat = 24
    static let palette: [Color] = [
        Color(red: 0.95, green: 0.58, blue: 0.10), Color(red: 0.38, green: 0.49, blue: 0.92), Color(red: 0.16, green: 0.66, blue: 0.56),
        Color(red: 0.86, green: 0.30, blue: 0.36), Color(red: 0.55, green: 0.36, blue: 0.86), Color(red: 0.13, green: 0.60, blue: 0.84),
        Color(red: 0.84, green: 0.44, blue: 0.70), Color(red: 0.40, green: 0.62, blue: 0.24), Color(red: 0.62, green: 0.48, blue: 0.30),
        Color(red: 0.36, green: 0.44, blue: 0.54)]
    /// Coins people recognise by colour keep it; others get a stable index from the id's characters (Swift's
    /// `hashValue` changes between launches).
    static let known: [String: Int] = ["bitcoin": 0, "ethereum": 1, "tether": 2, "usd-coin": 5, "solana": 4, "ripple": 9, "cardano": 5, "dogecoin": 8]
    static func colourIndex(_ id: String) -> Int { known[id] ?? id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % palette.count }
    static func metalColour(_ metal: PreciousMetal) -> Color {
        switch metal {
        case .gold: Color(red: 0.83, green: 0.66, blue: 0.22)
        case .silver: Color(red: 0.55, green: 0.58, blue: 0.62)
        case .platinum: Color(red: 0.45, green: 0.52, blue: 0.58)
        case .palladium: Color(red: 0.58, green: 0.50, blue: 0.44)
        }
    }
    var body: some View {
        if let metal = PreciousMetal.asset(CanonicalAssetID(rawValue: assetID)) {
            UpOnlySymbolBadge(symbol: TrackedKind.metals.symbol, tint: Self.metalColour(metal), size: size)
        } else if let logo = NSImage(named: "CoinLogos/" + assetID) {
            Image(nsImage: logo).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(width: size, height: size).clipShape(Circle())
                .accessibilityHidden(true)
        } else {
            let tint = Self.palette[Self.colourIndex(assetID)]
            Text(assetID == "bitcoin" ? "₿" : String(symbol.prefix(1)).uppercased())
                .font(.system(size: size * 0.5, weight: .bold, design: .rounded)).foregroundStyle(tint)
                .frame(width: size, height: size).background(tint.opacity(0.15), in: Circle())
                .accessibilityHidden(true)
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
        }.foregroundStyle(session.privacyMode ? Color.accentColor : inMenu ? Color.primary : Color.secondary)
            .accessibilityLabel(session.privacyMode ? "Show values" : "Hide values")
            .accessibilityValue(session.privacyMode ? "Privacy mode on" : "Privacy mode off")
            .accessibilityIdentifier("PrivacyMode")
            .help(session.privacyMode ? "Show values (⇧⌘P)" : "Hide values (⇧⌘P)")
            // One shortcut: the eye by the title is on every dashboard page, so the menu item doesn't register another.
            .keyboardShortcut(inMenu ? nil : KeyboardShortcut("p", modifiers: [.command, .shift]))
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
    case week, month, quarter, year, all
    /// The segment above the chart.
    var title: String {
        switch self { case .week: "1W"; case .month: "1M"; case .quarter: "3M"; case .year: "1Y"; case .all: "All" }
    }
    /// "No saved values in the past year", and the range's spoken name.
    var phrase: String {
        switch self { case .week: "past week"; case .month: "past month"; case .quarter: "past 3 months"; case .year: "past year"; case .all: "all time" }
    }
    var spokenTitle: String { phrase.prefix(1).uppercased() + String(phrase.dropFirst()) }
    /// " in the past year", or nothing for All: "No saved values in the past year."
    var within: String { self == .all ? "" : " in the " + phrase }
    /// What a change is measured against, as on the admin dashboard: "vs $4,304.28 prev 1M".
    var previous: String { self == .all ? "at start" : "prev " + title }
    /// Whole months the company figures cover, ending with the current month. Nil for All: every reported month.
    var months: Int? {
        switch self { case .week, .month: 1; case .quarter: 3; case .year: 12; case .all: nil }
    }
    /// How far back a rolling range reaches. All starts at the first saved value instead.
    var seconds: TimeInterval? {
        switch self { case .week: 7 * 86400; case .month: 30 * 86400; case .quarter: 91 * 86400; case .year: 365 * 86400; case .all: nil }
    }
    /// Days between chart points: every day up to a year (at most 365 points), and for All by how long the
    /// history is, so it too stays near a year's worth of points.
    func chartStepDays(span: TimeInterval) -> Int {
        switch self {
        case .week, .month, .quarter, .year: 1
        case .all: span <= 400 * 86400 ? 1 : span <= 1100 * 86400 ? 3 : 7
        }
    }
    /// Short ranges name days ("Sep 17"); a year or more also names the year ("Sep 24, 2025").
    var showsYear: Bool { self == .year || self == .all }
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
    /// X-axis labels: only the first and last stops, so the axis says the span and the hover says the day.
    static func endLabels(_ days: [Date], range: WorthRange) -> [String?] {
        days.indices.map { index in
            guard index == 0 || index == days.count - 1 else { return nil }
            return range.showsYear ? UpOnlyFormat.utcDate(days[index]) : UpOnlyFormat.utcDay(days[index])
        }
    }
    /// Whether a chart's line ends at or above where it starts, for the green-up / red-down colour. Nil with fewer
    /// than two values.
    static func risesOrHolds(_ values: [Decimal]) -> Bool? {
        guard values.count > 1, let first = values.first, let last = values.last else { return nil }
        return last >= first
    }
    /// Whole percentages of each value that add up to exactly 100 (largest remainder first); zero and negative
    /// values get 0. For each switcher row's share of the whole.
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
