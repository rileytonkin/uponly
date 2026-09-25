import Foundation
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

    @Test("The x-axis marks days over 7 days, Mondays over 30, months over 12 (January as its year), years for a long All")
    func axisMarks() {
        #expect(DashboardChart.axisMarks(days(from: utc(2026, 9, 17), count: 8), range: .week).compactMap { $0 } == ["Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed", "Thu"])
        #expect(DashboardChart.axisMarks(days(from: utc(2026, 8, 26), count: 30), range: .month).compactMap { $0 } == ["Aug 31", "Sep 7", "Sep 14", "Sep 21"])
        #expect(DashboardChart.axisMarks(days(from: utc(2025, 9, 25), count: 365), range: .year).compactMap { $0 }
                == ["Oct", "Nov", "Dec", "2026", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep"])
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

struct StandInTests {
    @Test("Stand-in figures scale amounts and quantities, and leave percentages, dates and counts alone")
    func scaling() {
        #expect(UpOnlyStandIn.scale("$1,234.56", by: Decimal(string: "0.01")!) == "$12.35")
        #expect(UpOnlyStandIn.scale("−$3,200.00", by: Decimal(string: "0.5")!) == "−$1,600.00")
        #expect(UpOnlyStandIn.scale("£20.00", by: 2) == "£40.00")
        #expect(UpOnlyStandIn.scale("CHF\u{00A0}1,234.00", by: 2) == "CHF\u{00A0}2,468.00")
        #expect(UpOnlyStandIn.scale("0.1 BTC", by: Decimal(string: "0.5")!) == "0.05 BTC")
        // Symbols with a country prefix, one-letter and digit tickers, coin names and bare numbers are scaled too.
        #expect(UpOnlyStandIn.scale("CA$1,000.00", by: 2) == "CA$2,000.00")
        #expect(UpOnlyStandIn.scale("R$50.00", by: 2) == "R$100.00")
        #expect(UpOnlyStandIn.scale("1,200 S", by: 2) == "2,400 S")
        #expect(UpOnlyStandIn.scale("3 1INCH", by: 2) == "6 1INCH")
        #expect(UpOnlyStandIn.scale("12.5 Arbitrum", by: 2) == "25.0 Arbitrum")
        #expect(UpOnlyStandIn.scale("25,000,000", by: 2) == "50,000,000")
        // Short figures are scaled whole, never left showing the real one.
        #expect(UpOnlyStandIn.scale("3.71B PEPE", by: Decimal(string: "0.001")!) == "3.71M PEPE")
        #expect(UpOnlyStandIn.scale("$1.25M", by: Decimal(string: "0.001")!) == "$1,250.00")
        #expect(UpOnlyStandIn.scale("2 ozt", by: Decimal(string: "0.03")!) == "0.06 ozt")
        #expect(UpOnlyStandIn.scale("Since Mar 2025 · Paid $4,200 · +$1,310 (+31%)", by: Decimal(string: "0.1")!) == "Since Mar 2025 · Paid $420 · +$131 (+31%)")
        #expect(UpOnlyStandIn.scale("1 of 2 holdings", by: Decimal(string: "0.1")!) == "1 of 2 holdings")
        #expect(UpOnlyStandIn.scale("Sep 24, 2026", by: Decimal(string: "0.1")!) == "Sep 24, 2026")
    }
    @Test("The stand-in total is small, the same for a vault every time, and moves with the real one")
    func factor() {
        let vault = UUID()
        let factor = UpOnlyStandIn.factor(total: 245_000, vaultID: vault)
        #expect(factor == UpOnlyStandIn.factor(total: 245_000, vaultID: vault))
        let shown = NSDecimalNumber(decimal: 245_000 * factor).doubleValue
        #expect(shown >= 600 && shown <= 12_000)
        #expect(UpOnlyStandIn.factor(total: 300_000, vaultID: vault) == factor)   // same power of ten, same scale
    }
}
