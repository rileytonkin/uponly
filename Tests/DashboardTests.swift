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

    @Test("Long charts label month starts, with January as its year; short ones label Mondays")
    func axisLabels() {
        // Weekly stops on Sundays from Sep 21, 2025 to Sep 20, 2026: every other month, January as the year.
        let weekly = days(from: utc(2025, 9, 21), count: 53, every: 7)
        let labels = DashboardChart.axisLabels(weekly, range: .year)
        #expect(labels.compactMap { $0 } == ["Nov", "2026", "Mar", "May", "Jul", "Sep"])
        #expect(labels[0] == nil)
        if let january = weekly.firstIndex(of: utc(2026, 1, 4)) { #expect(labels[january] == "2026") }
        // Five years in 30-day steps: only the years.
        let monthly = (0..<61).map { utc(2026, 9, 24).addingTimeInterval(-Double(60 - $0) * 30 * 86400) }
        #expect(DashboardChart.axisLabels(monthly, range: .fiveYears).compactMap { $0 } == ["2022", "2023", "2024", "2025", "2026"])
        let daily = days(from: utc(2026, 8, 25), count: 31)
        #expect(DashboardChart.axisLabels(daily, range: .month).compactMap { $0 } == ["Aug 31", "Sep 7", "Sep 14", "Sep 21"])
        #expect(UpOnlyFormat.utcDate(utc(2026, 8, 27, hour: 23)) == "Aug 27, 2026")
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

    @Test("The change line shows whole dollars with a true minus and the percent to one decimal")
    func changeFormatting() {
        #expect(UpOnlyFormat.change(4599, from: 9107) == "+$4,599 (+50.5%)")
        #expect(UpOnlyFormat.change(-1200, from: 35000) == "−$1,200 (−3.4%)")
        #expect(UpOnlyFormat.change(500, from: 0) == "+$500")
        #expect(UpOnlyFormat.change(250, from: -100) == "+$250")
        #expect(UpOnlyFormat.change(0, from: 1000) == "$0 (0.0%)")
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

    @Test("Holdings show the quantity with its symbol and the unit price; metal switches to troy ounces from one ounce")
    func holdingLines() {
        #expect(UpOnlyFormat.holding(quantity: Decimal(string: "0.1")!, valueUSD: 5900, symbol: "BTC", metal: false) == "0.1 BTC · $59,000.00")
        #expect(UpOnlyFormat.holding(quantity: 1_000_000, valueUSD: 12, symbol: "SHIB", metal: false) == "1,000,000 SHIB · $0.000012")
        #expect(UpOnlyFormat.holding(quantity: 2, valueUSD: nil, symbol: "Bitcoin", metal: false) == "2 Bitcoin")
        #expect(UpOnlyFormat.holding(quantity: PreciousMetal.gramsPerTroyOunce * 2, valueUSD: 5300, symbol: "", metal: true) == "2 ozt · $2,650.00/ozt")
        #expect(UpOnlyFormat.holding(quantity: 10, valueUSD: 1000, symbol: "", metal: true) == "10 g · $100.00/g")
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
        #expect(WorthRange.allCases.map(\.title) == ["1M", "3M", "1Y", "2Y", "5Y"])
        #expect(WorthRange.year.phrase == "past year" && WorthRange.month.spokenTitle == "Past month")
        #expect(WorthRange.month.seconds == 30 * 86400)
    }
}
