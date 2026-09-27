import AppKit
import Foundation
import SwiftUI
import Testing
@testable import UpOnly

struct DashboardTests {
    private func utc(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        var parts = DateComponents()
        parts.calendar = Calendar(identifier: .gregorian)
        parts.timeZone = TimeZone(secondsFromGMT: 0)
        parts.year = year
        parts.month = month
        parts.day = day
        parts.hour = hour
        return parts.date!
    }
    private func days(from start: Date, count: Int, every step: Int = 1) -> [Date] {
        (0..<count).map { start.addingTimeInterval(TimeInterval($0 * step * 86400)) }
    }

    @Test("A one-month chart has a point for every day, each showing that day's own sample")
    func dailyStops() {
        // Daily samples from Sep 1 to Sep 24, in a range that began on Aug 25.
        let samples = days(from: utc(2026, 9, 1, hour: 12), count: 24)
        let stops = DashboardChart.stops(sampleDays: samples, rangeStart: utc(2026, 8, 25, hour: 9), strideDays: 1)
        #expect(stops.count == 31)
        #expect(stops.first?.day == utc(2026, 8, 25) && stops.last?.day == utc(2026, 9, 24))
        #expect(stops.prefix(7).allSatisfy { $0.sample == nil })
        for (offset, stop) in stops.dropFirst(7).enumerated() { #expect(stop.sample == offset) }
    }

    @Test("Weekly stops take the latest sample in each week, not only one on the exact day")
    func weeklyStops() {
        let samples = [utc(2026, 8, 30), utc(2026, 9, 1), utc(2026, 9, 3), utc(2026, 9, 20)]
        let stops = DashboardChart.stops(sampleDays: samples, rangeStart: utc(2026, 8, 20), strideDays: 7)
        #expect(stops.map { $0.day } == [utc(2026, 8, 23), utc(2026, 8, 30), utc(2026, 9, 6), utc(2026, 9, 13), utc(2026, 9, 20)])
        #expect(stops.map { $0.sample } == [nil, 0, 2, nil, 3])
        #expect(DashboardChart.stops(sampleDays: [], rangeStart: utc(2026, 8, 20), strideDays: 7).isEmpty)
    }

    @Test("The x-axis marks days over 7 days, Mondays over 30, months over 12 (January too, not its year), years for a long All")
    func axisMarks() {
        #expect(DashboardChart.axisMarks(days(from: utc(2026, 9, 17), count: 8), range: .week).compactMap { $0 } == ["Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed", "Thu"])
        #expect(DashboardChart.axisMarks(days(from: utc(2026, 8, 26), count: 30), range: .month).compactMap { $0 } == ["Aug 31", "Sep 7", "Sep 14", "Sep 21"])
        #expect(DashboardChart.axisMarks(days(from: utc(2025, 9, 25), count: 365), range: .year).compactMap { $0 }
                == ["Oct", "Nov", "Dec", "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep"])
        #expect(DashboardChart.axisMarks(days(from: utc(2021, 6, 1), count: 270, every: 7), range: .all).compactMap { $0 } == ["2022", "2023", "2024", "2025", "2026"])
        // Only the first point of a period is marked, not the first point of the chart.
        #expect(DashboardChart.axisMarks(days(from: utc(2026, 3, 15), count: 60), range: .year).compactMap { $0 } == ["Apr", "May"])
        #expect(UpOnlyFormat.utcDate(utc(2026, 8, 27, hour: 23)) == "Aug 27, 2026")
    }
    @Test("The 24-hour axis marks every six hours, with the weekday at midnight")
    func hourMarks() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = utc(2026, 9, 23, hour: 10).addingTimeInterval(7 * 60)
        let moments = [start] + (1...23).map { utc(2026, 9, 23, hour: 10).addingTimeInterval(TimeInterval($0) * 3600) }
        #expect(DashboardChart.hourMarks(moments, calendar: calendar).compactMap { $0 } == ["12 PM", "6 PM", "Thu", "6 AM"])
    }

    @Test("A chart is green when it ends at or above where it started, red when below")
    func trend() {
        #expect(DashboardChart.risesOrHolds([100, 90, 120]) == true)
        #expect(DashboardChart.risesOrHolds([100, 100]) == true)
        #expect(DashboardChart.risesOrHolds([100, 130, 99]) == false)
        #expect(DashboardChart.risesOrHolds([100]) == nil)
    }

    @Test("Moves read as a signed amount with an arrow and one-decimal percent")
    func movements() {
        #expect(UpOnlyFormat.movement(Decimal(string: "66.59")!, fraction: Decimal(string: "0.0133")!, cents: true) == "+$66.59  ▲ 1.3%")
        #expect(UpOnlyFormat.movement(-22953, fraction: Decimal(string: "-0.8198")!, cents: false) == "−$22,953  ▼ 82.0%")
        #expect(UpOnlyFormat.movement(0, fraction: 0, cents: true) == "$0.00  0.0%")
        #expect(UpOnlyFormat.movement(1310, fraction: nil, cents: false) == "+$1,310")
        #expect(UpOnlyFormat.arrowPercent(Decimal(string: "-0.0585")!) == "▼ 5.9%")
    }

    @Test("Holdings split into quantity and unit price, metal switching to troy ounces from one ounce")
    func holdingColumns() {
        #expect(UpOnlyFormat.quantityText(Decimal(string: "0.1")!, symbol: "BTC", metal: false) == "0.1 BTC")
        #expect(UpOnlyFormat.unitPrice(quantity: Decimal(string: "0.1")!, valueUSD: 5900, metal: false) == "$59,000.00")
        #expect(UpOnlyFormat.quantityText(PreciousMetal.gramsPerTroyOunce * 2, symbol: "XAU", metal: true) == "2 ozt")
        #expect(UpOnlyFormat.unitPrice(quantity: PreciousMetal.gramsPerTroyOunce * 2, valueUSD: 5300, metal: true) == "$2,650.00/ozt")
        #expect(UpOnlyFormat.unitPrice(quantity: 0, valueUSD: 10, metal: false) == nil)
    }

    @Test("Coin badges keep their colour between launches")
    func badgeColours() {
        #expect(UpOnlyAssetBadge.colourIndex("bitcoin") == 0)  // Bitcoin orange
        #expect(UpOnlyAssetBadge.colourIndex("some-new-coin") == UpOnlyAssetBadge.colourIndex("some-new-coin"))
        #expect((0..<UpOnlyAssetBadge.palette.count).contains(UpOnlyAssetBadge.colourIndex("a-very-long-coin-identifier-from-coingecko")))
    }

    @Test("Marked axis labels are thinned evenly and never collide")
    func labelledTicks() {
        let widths: [CGFloat] = (0..<91).map { $0 % 7 == 0 ? 34 : 0 }
        let labelled = widths.indices.filter { widths[$0] > 0 }
        for plot: CGFloat in [120, 262, 600] {
            let ticks = UpOnlyChartAxis.ticks(labelled: labelled, widths: widths, plotWidth: plot)
            #expect(!ticks.isEmpty && ticks.allSatisfy { labelled.contains($0.index) })
            for tick in ticks { #expect(tick.center - tick.width / 2 >= 0 && tick.center + tick.width / 2 <= plot) }
            for (left, right) in zip(ticks, ticks.dropFirst()) { #expect(left.center + left.width / 2 + 10 <= right.center - right.width / 2) }
            #expect(Set(zip(ticks, ticks.dropFirst()).map { $1.index - $0.index }).count <= 1)
        }
        #expect(UpOnlyChartAxis.ticks(labelled: [], widths: widths, plotWidth: 262).isEmpty)
    }

    @Test("Money and percentages use a true minus and one decimal")
    func changeFormatting() {
        #expect(UpOnlyFormat.percent(Decimal(string: "0.18")!) == "+18.0%")
        #expect(UpOnlyFormat.percent(Decimal(string: "-0.0342")!) == "−3.4%")
        #expect(UpOnlyFormat.money(-1234) == "−$1,234")
        #expect(UpOnlyFormat.exactMoney(-3200) == "−$3,200.00")
        #expect(UpOnlyFormat.currencyMoney(-12.5, currency: "GBP") == "−£12.50")
    }

    @Test("Allocation percentages are whole numbers that always add up to 100")
    func allocationPercentages() {
        #expect(DashboardChart.percentages([14, 43, 43]) == [14, 43, 43])
        #expect(DashboardChart.percentages([1, 1, 1]) == [34, 33, 33])
        #expect(DashboardChart.percentages([2, 1, 0]) == [67, 33, 0])
        #expect(DashboardChart.percentages([-5, 10]) == [0, 100])
        #expect(DashboardChart.percentages([0, 0]) == [0, 0])
        for values: [Decimal] in [[1, 2, 3, 4, 5, 6, 7], [Decimal(string: "0.1")!, Decimal(string: "0.2")!, Decimal(string: "999.7")!], [3333, 3333, 3334], [1, 1, 1, 1, 1, 1]] {
            #expect(DashboardChart.percentages(values).reduce(0, +) == 100)
        }
    }

    @Test("A million or more is written short, in three significant digits, everywhere amounts and quantities are shown")
    func compactFigures() {
        #expect(UpOnlyFormat.compact(999_999) == nil)
        #expect(UpOnlyFormat.compact(1_000_000) == "1M" && UpOnlyFormat.compact(3_710_000_000) == "3.71B")
        #expect(UpOnlyFormat.compact(12_540_000) == "12.5M" && UpOnlyFormat.compact(371_400_000_000) == "371B")
        #expect(UpOnlyFormat.compact(999_996_000) == "1B" && UpOnlyFormat.compact(2_500_000_000_000) == "2.5T")
        #expect(UpOnlyFormat.quantityText(3_710_000_000, symbol: "PEPE", metal: false) == "3.71B PEPE")
        #expect(UpOnlyFormat.exactMoney(-1_254_300) == "−$1.25M" && UpOnlyFormat.money(34_281) == "$34,281")
        #expect(UpOnlyFormat.currencyMoney(3_700_000, currency: "EUR") == "€3.7M")
    }
    @Test("Holdings show the quantity with its symbol and the unit price; metal switches to troy ounces from one ounce")
    func holdingLines() {
        #expect(UpOnlyFormat.holding(quantity: Decimal(string: "0.1")!, valueUSD: 5900, symbol: "BTC", metal: false) == "0.1 BTC · $59,000.00")
        #expect(UpOnlyFormat.holding(quantity: 1_000_000, valueUSD: 12, symbol: "SHIB", metal: false) == "1M SHIB · $0.000012")
        #expect(UpOnlyFormat.holding(quantity: 2, valueUSD: nil, symbol: "Bitcoin", metal: false) == "2 Bitcoin")
        #expect(UpOnlyFormat.holding(quantity: PreciousMetal.gramsPerTroyOunce * 2, valueUSD: 5300, symbol: "", metal: true) == "2 ozt · $2,650.00/ozt")
        #expect(UpOnlyFormat.holding(quantity: 10, valueUSD: 1000, symbol: "", metal: true) == "10 g · $3,110.35/ozt")
        #expect(UpOnlyFormat.holding(quantity: 50000, valueUSD: nil, symbol: "", metal: true) == "1,607.5373 ozt")
    }

    @Test("A holding whose lots cover only part of it says what the cost covers")
    func partialCost() {
        let summary = HoldingPerformance(costUSD: 30000, coveredQuantity: Decimal(string: "0.5"), heldQuantity: 2)
        #expect(UpOnlyFormat.performance(summary) == "Paid $30,000 for 0.5 of 2")
    }

    @Test("The chart keeps a selected empty month in view and summarises long series for VoiceOver")
    func chartLayout() {
        let points = (1...6).map { UpOnlyChartPoint(id: "m\($0)", label: "M\($0)", value: $0 < 5 ? Decimal($0 * 100) : nil) }
        let selected = UpOnlyChartLayout(points: points, includesZero: true, selected: "m6")
        #expect(selected.visible.count == 6 && selected.runs == [[0, 1, 2, 3]])
        #expect(UpOnlyChartLayout(points: points, includesZero: true).visible.count == 4)
        let year = (1...12).map { UpOnlyChartPoint(id: "\($0)", label: "\($0)", value: Decimal($0)) }
        #expect(UpOnlyChartLayout(points: year, includesZero: true, showsAllMarkers: true).markers)
        #expect(!UpOnlyChartLayout(points: year, includesZero: true).markers)
        let daily = (0..<30).map { UpOnlyChartPoint(id: "\($0)", label: "D\($0)", value: $0 % 2 == 0 ? Decimal($0) : nil) }
        let summary = UpOnlyChartLayout(points: daily, includesZero: false).summary
        #expect(summary.hasPrefix("15 values from D0 to D28.") && summary.hasSuffix("14 with no recorded value"))
        #expect(!summary.contains("Not reported"))
    }

    @Test("A flat $0 series isn't labelled in fractions of a cent")
    func flatZeroScale() {
        for zero in [true, false] {
            let scale = UpOnlyChartScale(values: [0, 0, 0], includesZero: zero)
            #expect(scale.ticks.allSatisfy { ($0 * 100).rounded() == $0 * 100 })
            #expect(!scale.ticks.map(UpOnlyChartScale.label).contains { $0.contains("0.00") })
        }
    }

    @Test("Ranges are rolling and named the way the change line says them")
    func ranges() {
        #expect(WorthRange.allCases.map(\.title) == ["24H", "7D", "30D", "1Y", "All"])
        #expect(WorthRange.year.phrase == "past year" && WorthRange.month.spokenTitle == "Past 30 days" && WorthRange.all.spokenTitle == "All time")
        #expect(WorthRange.day.seconds == 86400 && WorthRange.week.seconds == 7 * 86400 && WorthRange.month.seconds == 30 * 86400 && WorthRange.all.seconds == nil)
        #expect(WorthRange.day.hourly && !WorthRange.week.hourly && WorthRange.month.previous == "prev 30D" && WorthRange.all.previous == "at start")
        #expect(WorthRange.all.within == "" && WorthRange.year.within == " in the past year")
        // Every day up to a year; All by how long the history is.
        #expect(WorthRange.year.chartStepDays(span: 365 * 86400) == 1)
        #expect(WorthRange.all.chartStepDays(span: 60 * 86400) == 1 && WorthRange.all.chartStepDays(span: 800 * 86400) == 3 && WorthRange.all.chartStepDays(span: 2500 * 86400) == 7)
        #expect(WorthRange.all.months == nil && WorthRange.day.months == 1 && WorthRange.year.months == 12)
    }
}

struct PrivacyFormatTests {
    @Test("In privacy mode a move keeps its sign and percentage but not its amount")
    func hiddenMoves() {
        #expect(UpOnlyFormat.hiddenMovement(Decimal(string: "-12.5")!, fraction: Decimal(string: "-0.0385")!) == "−••••  ▼ 3.9%")
        #expect(UpOnlyFormat.hiddenMovement(3, fraction: nil) == "+••••")
        #expect(UpOnlyFormat.hiddenMovement(0, fraction: 0) == "••••  0.0%")
    }
}

@MainActor struct PrivacyPlaceholderTests {
    private func points(_ values: [Decimal]) -> [UpOnlyChartPoint] {
        values.enumerated().map { UpOnlyChartPoint(id: "\($0.offset)", label: "\($0.offset)", value: $0.element) }
    }
    @Test("A hidden chart's value axis is as wide for a fortune as for pocket change, so its width can't say how much")
    func hiddenAxisWidth() {
        let small = points([12, 40]), large = points([12_000_000, 84_000_000])
        #expect(UpOnlyChartCanvas(points: small, hidden: true).axisWidth == UpOnlyChartCanvas(points: large, hidden: true).axisWidth)
        // Shown, the axis fits its labels ("$40" against "$100M").
        #expect(UpOnlyChartCanvas(points: small).axisWidth < UpOnlyChartCanvas(points: large).axisWidth)
    }
}

@MainActor struct RecoveryClipboardTests {
    @Test("A copied recovery code is marked concealed and transient, and cleared on quit unless something else was copied since")
    func copyAndClear() {
        // A pasteboard of the test's own, so this Mac's clipboard is never touched. Only its types are read.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("org.uponly.tests." + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"), transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        #expect(UpOnlyRecoveryClipboard.copy(.random(), to: pasteboard))
        #expect(Set(pasteboard.types ?? []).isSuperset(of: [.string, concealed, transient]))
        UpOnlyRecoveryClipboard.clear()
        #expect(pasteboard.types?.isEmpty != false)
        // Something copied since stays.
        #expect(UpOnlyRecoveryClipboard.copy(.random(), to: pasteboard))
        pasteboard.clearContents(); pasteboard.setString("something else", forType: .string)
        let change = pasteboard.changeCount
        UpOnlyRecoveryClipboard.clear()
        #expect(pasteboard.changeCount == change && pasteboard.types?.contains(.string) == true)
    }
}

@MainActor struct RecoveryCaptureShieldTests {
    @Test("A window showing a recovery code is kept out of screen capture, and put back once the code is gone")
    func shieldsWindow() async throws {
        // Off screen and never ordered in, so nothing appears on this Mac's screen.
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 344, height: 300), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        #expect(window.sharingType == .readOnly)
        let host = NSHostingView(rootView: UpOnlyRecoveryCodeCard(code: .random()))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        #expect(window.sharingType == .none)
        window.contentView = NSView()
        #expect(window.sharingType == .readOnly)
    }
}

/// A day typed in the date popover: the common ways people write one, in this Mac's day/month order, never after today.
@Suite("Typed dates")
struct TypedDateTests {
    private let today = UTCDay.calendar.date(from: DateComponents(year: 2026, month: 9, day: 27))!
    private func day(_ text: String, _ locale: String = "en_US") -> String? {
        UpOnlyDateParser.parse(text, today: today, locale: Locale(identifier: locale)).map(ImportDateFormat.today)
    }
    @Test("Written, numeric and relative days read as that day's UTC midnight")
    func reads() {
        for text in ["12 Mar 2021", "March 12, 2021", "2021-03-12", "12th March 2021", "mar 12 21"] { #expect(day(text) == "2021-03-12", "\(text)") }
        #expect(day("3/12/21") == "2021-03-12" && day("12/3/21", "en_AU") == "2021-03-12")
        // A number over 12 can only be the day, whatever the Mac's order.
        #expect(day("13/3/2021") == "2021-03-13" && day("3/13/2021", "en_AU") == "2021-03-13")
        #expect(day("Mar 2021") == "2021-03-01" && day("3/2021") == "2021-03-01" && day("Dec 25 99") == "1999-12-25")
        // Without a year, the latest such day up to today.
        #expect(day("12 Mar") == "2026-03-12" && day("1 Dec") == "2025-12-01")
        #expect(day("today") == "2026-09-27" && day("yesterday") == "2026-09-26" && day("3 weeks ago") == "2026-09-06" && day("2y") == "2024-09-27")
        #expect(day("29 Feb 2024") == "2024-02-29" && day("29 Feb") == "2024-02-29")
    }
    @Test("Anything else, an impossible day or a day after today reads as nothing")
    func refuses() {
        for text in ["", "hello", "5", "1 1 1", "31/2/2021", "29 Feb 2023", "12 Foo 2021", "2030-01-01", "9999 years ago", "500 y"] { #expect(day(text) == nil, "\(text)") }
        #expect(UpOnlyDateParser.isFuture("2030-01-01", today: today) && !UpOnlyDateParser.isFuture("hello", today: today))
    }
}

/// The coin logos past the asset catalog's, and every packed coin's ticker: found by CoinGecko ID in the bundled pack,
/// and nothing read out of bounds.
@Suite("Coin logo pack")
struct CoinLogoPackTests {
    private func pack(_ entries: [(id: String, ticker: String, image: Data)]) -> Data {
        let sorted = entries.sorted { Array($0.id.utf8).lexicographicallyPrecedes(Array($1.id.utf8)) }
        func le<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        var index = Data(), text = Data(), images = Data()
        let header = 12 + sorted.count * 19, textLength = sorted.reduce(0) { $0 + $1.id.utf8.count + $1.ticker.utf8.count }
        for entry in sorted {
            let idAt = header + text.count
            text += Data(entry.id.utf8)
            index += le(UInt32(idAt)) + le(UInt16(entry.id.utf8.count)) + le(UInt32(header + text.count)) + le(UInt8(entry.ticker.utf8.count))
                + le(UInt32(entry.image.isEmpty ? 0 : header + textLength + images.count)) + le(UInt32(entry.image.count))
            text += Data(entry.ticker.utf8); images += entry.image
        }
        return Data("UOLOGOS2".utf8) + le(UInt32(sorted.count)) + index + text + images
    }
    @Test("Each id finds its own ticker and image; others, and a damaged pack, find none")
    func lookup() {
        let file = pack([("bitcoin", "BTC", Data()), ("chex-token", "CHEX", Data([2, 2])), ("zcash", "ZEC", Data([3, 3, 3])), ("a", "", Data([4]))])
        #expect(CoinLogos.find("chex-token", in: file)?.image == Data([2, 2]) && CoinLogos.find("chex-token", in: file)?.ticker == "CHEX")
        #expect(CoinLogos.find("zcash", in: file)?.image == Data([3, 3, 3]) && CoinLogos.find("a", in: file)?.image == Data([4]))
        // A coin whose logo is in the asset catalog has only its ticker here; one without a ticker has only its logo.
        #expect(CoinLogos.find("bitcoin", in: file)?.ticker == "BTC" && CoinLogos.find("bitcoin", in: file)?.image == nil)
        #expect(CoinLogos.find("a", in: file)?.ticker == nil)
        #expect(CoinLogos.find("chex", in: file) == nil && CoinLogos.find("", in: file) == nil && CoinLogos.find("zzz", in: file) == nil)
        #expect(CoinLogos.find("bitcoin", in: Data("UOLOGOS2".utf8) + Data([0xff, 0xff, 0xff, 0xff])) == nil)
        #expect(CoinLogos.find("zcash", in: file.prefix(file.count - 1))?.image == nil)
        #expect(CoinLogos.find("bitcoin", in: Data("UOLOGOS1".utf8) + file.dropFirst(8)) == nil)
    }
    @Test("The app's pack has logos and tickers for coins past the catalog's 250, and they decode")
    @MainActor func bundled() {
        #expect(NSImage(named: "CoinLogos/chex-token") == nil)
        #expect(CoinLogos.image("chex-token") != nil && CoinLogos.image("bitcoin") != nil && CoinLogos.image("not-a-coin-at-all") == nil)
        #expect(CoinLogos.ticker("chex-token") == "CHEX" && CoinLogos.ticker("zignaly") == "ZIG" && CoinLogos.ticker("not-a-coin-at-all") == nil)
        #expect(ImportCoins.ticker("zignaly", catalog: []) == "ZIG" && ImportCoins.ticker("bitcoin", catalog: []) == "BTC")
        // ONDO's logo is a black mark on a clear background, so it gets a white disc; Bitcoin's orange coin doesn't.
        #expect(CoinLogos.isDarkOnClear(NSImage(named: "CoinLogos/ondo-finance")!) && !CoinLogos.isDarkOnClear(NSImage(named: "CoinLogos/bitcoin")!))
    }
    @Test("List rows write amounts short, as market apps do")
    func shortQuantities() {
        func short(_ text: String) -> String { UpOnlyFormat.shortQuantity(Decimal(string: text)!, symbol: "X", metal: false) }
        #expect(short("116514.96") == "116.5K X" && short("10000") == "10K X" && short("999960") == "1M X" && short("3710000000") == "3.71B X")
        #expect(short("9098.44") == "9,098 X" && short("2417.9") == "2,418 X")
        #expect(short("952.32") == "952.32 X" && short("725.9") == "725.9 X" && short("8.25") == "8.25 X")
        #expect(short("0.0421349") == "0.04213 X" && short("0.1") == "0.1 X")
    }
}

/// A company's ownership set in the app: typed shares read as fractions, and a refresh from the accounting
/// connection keeps what was set.
@Suite("Company ownership")
struct CompanyOwnershipTests {
    @Test("Shares read as percents or fractions, a third as a third")
    func shares() {
        func share(_ text: String) -> String? { OwnershipPeriod.share(text).map { "\($0.numerator)/\($0.denominator)" } }
        #expect(share("50") == "1/2" && share("50%") == "1/2" && share("100") == "1/1" && share("25.5") == "51/200")
        #expect(share("33") == "1/3" && share("33.33") == "1/3" && share("1/3") == "1/3" && share("66.67") == "2/3" && share("2/4") == "1/2")
        #expect(share("32") == "8/25" && share("33.5") == "67/200" && share("12,5") == "1/8" && share("66.7") == "2/3")
        for text in ["", "0", "-5", "101", "abc", "4/3", "1/0", "0/3", "50abc", "1e2"] { #expect(share(text) == nil, "\(text)") }
    }
    @Test("A refresh keeps ownership set in the app, and takes the connection's otherwise")
    func refreshKeepsEdits() {
        func book(_ ownership: [OwnershipPeriod], at: Date, edited: Bool? = nil) -> BusinessBook {
            var book = BusinessBook(id: "syrup", name: "Syrup", ownership: ownership, firstMonth: "2021-01", sourceURL: "", basis: "", fetchedAt: at)
            book.ownershipEdited = edited
            return book
        }
        let half = [OwnershipPeriod(fromMonth: "2021-01", numerator: 1, denominator: 2)]
        let edited = [OwnershipPeriod(fromMonth: "2021-01", numerator: 1, denominator: 3), OwnershipPeriod(fromMonth: "2024-06", numerator: 1, denominator: 2)]
        let saved = book(edited, at: Date(timeIntervalSince1970: 1000), edited: true)
        let merged = AccountingHistory.merging([book(half, at: Date(timeIntervalSince1970: 2000))], into: [saved])
        #expect(merged.first?.ownership == edited && merged.first?.ownershipEdited == true)
        #expect(merged.first?.ownership(at: "2023-12")?.label == "⅓" && merged.first?.ownership(at: "2024-06")?.label == "50%")
        let plain = AccountingHistory.merging([book(half, at: Date(timeIntervalSince1970: 2000))], into: [book(edited, at: Date(timeIntervalSince1970: 1000))])
        #expect(plain.first?.ownership == half)
    }
}
