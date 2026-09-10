import SwiftUI

struct UpOnlyChartPoint: Identifiable, Equatable {
    var id: String
    var label: String
    var value: Decimal?
    var provisional = false
    var detailLabel: String?
    /// The value counts only what could be priced that day. Drawn lighter and dashed, with `note` on hover.
    var partial = false
    var note: String?
}

/// Rendering-only scale. Exact money stays Decimal in the ledger and tooltip.
nonisolated struct UpOnlyChartScale {
    var lower: Double
    var upper: Double
    var ticks: [Double]
    init(values: [Decimal], includesZero: Bool) {
        let values = values.map { NSDecimalNumber(decimal: $0).doubleValue }.filter(\.isFinite)
        guard let minimum = values.min(), let maximum = values.max() else {
            lower = 0; upper = 1; ticks = [0, 0.5, 1]; return
        }
        var rawLow = includesZero ? min(0, minimum) : minimum
        var rawHigh = includesZero ? max(0, maximum) : maximum
        // A near-flat series is widened to 4% of its size so the tick labels stay distinct.
        let minimumSpan = max(max(abs(rawLow), abs(rawHigh)) * 0.04, 0.01)
        if rawHigh - rawLow < minimumSpan {
            let midpoint = (rawLow + rawHigh) / 2
            rawLow = includesZero && rawLow == 0 ? 0 : midpoint - minimumSpan / 2
            rawHigh = midpoint + minimumSpan / 2
        }
        let span = rawHigh - rawLow
        // The smallest round step that keeps the gridlines to four, so the top line lands just above the peak
        // instead of spending a third of the plot on headroom.
        let magnitude = pow(10, floor(log10(span)) - 1)
        let candidates = [1.0, 2, 2.5, 5, 10, 20, 25, 50, 100].map { $0 * magnitude }
        let step = candidates.first { (ceil(rawHigh / $0) - floor(rawLow / $0)) <= 4 } ?? span
        var high = ceil(rawHigh / step) * step
        var low = floor(rawLow / step) * step
        if includesZero, rawLow >= 0 { low = 0 }
        // A small dip below zero gets a little room, not a whole band.
        if includesZero, rawLow < 0, abs(rawLow) < step * 0.35 { low = -step * 0.35 }
        if high == low { high = low + step }
        if !includesZero, high - rawHigh < step * 0.1 { high += step * 0.2 }
        lower = low; upper = high
        var marks: [Double] = []
        var tick = ceil(low / step) * step
        while tick <= high + step / 2 { marks.append(tick); tick += step }
        if includesZero, low < 0, !marks.contains(0) { marks.append(0) }
        ticks = marks.sorted()
    }
    func fraction(_ value: Decimal) -> Double {
        (NSDecimalNumber(decimal: value).doubleValue - lower) / (upper - lower)
    }
    static func label(_ value: Double) -> String {
        let magnitude = abs(value)
        let divisor: Double = magnitude >= 1_000_000_000 ? 1_000_000_000 : magnitude >= 1_000_000 ? 1_000_000 : magnitude >= 1_000 ? 1_000 : 1
        let suffix = divisor == 1_000_000_000 ? "B" : divisor == 1_000_000 ? "M" : divisor == 1_000 ? "k" : ""
        let formatter = NumberFormatter(); formatter.locale = Locale(identifier: "en_US")
        formatter.maximumFractionDigits = divisor > 1 ? 2 : magnitude < 1 ? 4 : 2
        return (value < 0 ? "−" : "") + "$" + (formatter.string(from: NSNumber(value: magnitude / divisor)) ?? "0") + suffix
    }
}

// Tick selection uses measured text bounds, including edge clamping. Omitting
// intermediate labels never removes data points, markers or hover targets.
nonisolated enum UpOnlyChartAxis {
    struct Tick: Identifiable, Equatable {
        var index: Int
        var center: CGFloat
        var width: CGFloat
        var id: Int { index }
    }
    static func ticks(widths: [CGFloat], plotWidth: CGFloat, gap: CGFloat = 10) -> [Tick] {
        guard !widths.isEmpty, plotWidth > 0 else { return [] }
        let count = widths.count
        let candidates: [Int]
        if count <= 8 { candidates = Array(widths.indices) }
        else if count <= 12 { candidates = Array(Set(stride(from: 0, to: count - 2, by: 2)).union([count - 1])).sorted() }
        else { candidates = [0, count / 2, count - 1] }
        let ticks = candidates.compactMap { index -> Tick? in
            let width = widths[index]
            guard width <= plotWidth else { return nil }
            let anchor = count > 1 ? CGFloat(index) / CGFloat(count - 1) * plotWidth : 12
            return Tick(index: index, center: min(max(anchor, width / 2), plotWidth - width / 2), width: width)
        }
        guard let first = ticks.first, let last = ticks.last, first.index != last.index else { return ticks }
        func fits(_ a: Tick, before b: Tick) -> Bool { a.center + a.width / 2 + gap <= b.center - b.width / 2 }
        guard fits(first, before: last) else { return [last] }
        var result = [first]
        for tick in ticks.dropFirst().dropLast() where fits(tick, before: last) {
            if fits(result[result.count - 1], before: tick) { result.append(tick) }
        }
        result.append(last)
        return result
    }
}

struct UpOnlyChart: View {
    @Environment(UpOnlySession.self) private var session
    @Environment(\.colorSchemeContrast) private var contrast
    var points: [UpOnlyChartPoint]
    var includesZero = false
    var showsAllMarkers = false
    var selected: String?
    var tint: Color = .accentColor
    var onSelect: ((String) -> Void)?
    @State private var hovered: Int?
    private let plotHeight: CGFloat = 112
    // Do not reserve empty leading/trailing history before the first actual observation.
    // Interior missing months remain explicit gaps in the line.
    private var visiblePoints: [UpOnlyChartPoint] {
        guard let first = points.firstIndex(where: { $0.value != nil }), let last = points.lastIndex(where: { $0.value != nil }) else { return points }
        return Array(points[first...last])
    }
    private var scale: UpOnlyChartScale { UpOnlyChartScale(values: visiblePoints.compactMap(\.value), includesZero: includesZero) }
    private var runs: [[Int]] {
        var result: [[Int]] = [], run: [Int] = []
        for i in visiblePoints.indices {
            if visiblePoints[i].value != nil { run.append(i) }
            else if !run.isEmpty { result.append(run); run = [] }
        }
        if !run.isEmpty { result.append(run) }
        return result
    }
    private func x(_ i: Int, width: CGFloat) -> CGFloat {
        visiblePoints.count > 1 ? CGFloat(i) / CGFloat(visiblePoints.count - 1) * width : 12
    }
    private func y(_ value: Decimal, scale: UpOnlyChartScale) -> CGFloat { 6 + (1 - scale.fraction(value)) * (plotHeight - 12) }
    private func nearest(_ location: CGFloat, width: CGFloat) -> Int? {
        guard !visiblePoints.isEmpty else { return nil }
        return max(0, min(visiblePoints.count - 1, Int((location / max(width, 1) * CGFloat(visiblePoints.count - 1)).rounded())))
    }
    private func line(_ run: [Int], width: CGFloat, scale: UpOnlyChartScale) -> Path {
        let pts = run.compactMap { index -> CGPoint? in
            visiblePoints[index].value.map { CGPoint(x: x(index, width: width), y: y($0, scale: scale)) }
        }
        var path = Path()
        guard let first = pts.first else { return path }
        path.move(to: first)
        guard pts.count > 1 else { return path }
        // Cubic through the points with handles at a third of the neighbour distance: the admin Earnings
        // chart's tension of 0.3. Handles are clamped vertically so the curve never invents a peak or dip.
        for i in 1..<pts.count {
            let p0 = pts[max(i - 2, 0)], p1 = pts[i - 1], p2 = pts[i], p3 = pts[min(i + 1, pts.count - 1)]
            let low = min(p1.y, p2.y), high = max(p1.y, p2.y)
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: min(high, max(low, p1.y + (p2.y - p0.y) / 6)))
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: min(high, max(low, p2.y - (p3.y - p1.y) / 6)))
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }
    private var accessibilitySummary: String {
        session.privacyMode ? "Values hidden" : points.map { "\($0.detailLabel ?? $0.label): \($0.value.map(UpOnlyFormat.exactMoney) ?? "Not reported")" }.joined(separator: ". ")
    }
    var body: some View {
        Group {
            if !points.contains(where: { $0.value != nil }) {
                Text("No recorded values in this period").font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
            } else { historyChart }
        }
        .accessibilityRepresentation {
            Text(accessibilitySummary).accessibilityLabel("History, " + accessibilitySummary)
        }
    }
    private var historyChart: some View {
        GeometryReader { geometry in
            let bounds = scale
            let axisWidth = (bounds.ticks.map { (UpOnlyChartScale.label($0) as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)]).width }.max() ?? 24) + 9
            let plotWidth = max(1, geometry.size.width - axisWidth - 3)
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    for tick in bounds.ticks where !runs.isEmpty {
                        let yy = y(Decimal(tick), scale: bounds)
                        var grid = Path(); grid.move(to: CGPoint(x: axisWidth - 4, y: yy)); grid.addLine(to: CGPoint(x: size.width, y: yy))
                        let zero = tick == 0 && includesZero
                        context.stroke(grid, with: .color(.primary.opacity(zero ? 0.28 : contrast == .increased ? 0.18 : 0.09)), lineWidth: 1)
                        if !session.privacyMode {
                            context.draw(Text(UpOnlyChartScale.label(tick)).font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(.secondary.opacity(0.85)), at: CGPoint(x: axisWidth - 8, y: yy), anchor: .trailing)
                        }
                    }
                    var plot = context; plot.translateBy(x: axisWidth, y: 0)
                    let zeroY = includesZero ? y(0, scale: bounds) : plotHeight - 6
                    let loss = Color(nsColor: .systemRed)
                    for wholeRun in runs {
                        guard let lone = wholeRun.first else { continue }
                        if wholeRun.count == 1, let value = visiblePoints[lone].value {
                            // A lone value is a point, not a bar; the hover shows its figure.
                            let dot = Path(ellipseIn: CGRect(x: x(lone, width: plotWidth) - 3, y: y(value, scale: bounds) - 3, width: 6, height: 6))
                            plot.fill(dot, with: .color(tint))
                            continue
                        }
                        // Days that could only be partly valued are drawn dashed and lighter, without fill, so the
                        // estimate is visible as an estimate. Each stretch shares its boundary point with its neighbour.
                        var stretches: [(indices: [Int], partial: Bool)] = []
                        for index in wholeRun {
                            let partial = visiblePoints[index].partial
                            if let lastStretch = stretches.last, lastStretch.partial == partial { stretches[stretches.count - 1].indices.append(index) }
                            else {
                                if let previous = stretches.last?.indices.last { stretches.append(([previous, index], partial)) } else { stretches.append(([index], partial)) }
                            }
                        }
                        for stretch in stretches where stretch.partial && stretch.indices.count > 1 {
                            plot.stroke(line(stretch.indices, width: plotWidth, scale: bounds), with: .color(tint.opacity(0.55)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: [3, 4]))
                        }
                        for stretch in stretches where !stretch.partial && stretch.indices.count > 1 {
                            let run = stretch.indices, first = run[0], last = run[run.count - 1]
                            var area = line(run, width: plotWidth, scale: bounds)
                            area.addLine(to: CGPoint(x: x(last, width: plotWidth), y: zeroY)); area.addLine(to: CGPoint(x: x(first, width: plotWidth), y: zeroY)); area.closeSubpath()
                            let stroke = line(run, width: plotWidth, scale: bounds)
                            if includesZero {
                                // Above zero green, below red, so the answer is a colour before it is a number.
                                var above = plot; above.clip(to: Path(CGRect(x: 0, y: 0, width: plotWidth, height: zeroY)))
                                above.fill(area, with: .linearGradient(Gradient(colors: [tint.opacity(0.22), tint.opacity(0.02)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: zeroY)))
                                above.stroke(stroke, with: .color(tint), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                                var below = plot; below.clip(to: Path(CGRect(x: 0, y: zeroY, width: plotWidth, height: plotHeight - zeroY)))
                                below.fill(area, with: .linearGradient(Gradient(colors: [loss.opacity(0.02), loss.opacity(0.22)]), startPoint: CGPoint(x: 0, y: zeroY), endPoint: CGPoint(x: 0, y: plotHeight)))
                                below.stroke(stroke, with: .color(loss), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                            } else {
                                plot.fill(area, with: .linearGradient(Gradient(colors: [tint.opacity(0.22), tint.opacity(0.02)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: plotHeight)))
                                // Only the still-provisional tail is dashed.
                                let provisionalTail = last == visiblePoints.count - 1 && visiblePoints[last].provisional
                                let solid = provisionalTail ? Array(run.dropLast()) : run
                                plot.stroke(line(solid, width: plotWidth, scale: bounds), with: .color(tint), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                                if provisionalTail { plot.stroke(line(Array(run.suffix(2)), width: plotWidth, scale: bounds), with: .color(tint), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [2, 4])) }
                            }
                        }
                        let run = wholeRun
                        // Points only where they help: a sparse monthly series, the selection, and the hover.
                        for index in run where visiblePoints.count <= 12 || selected == visiblePoints[index].id || hovered == index {
                            let value = visiblePoints[index].value!
                            let isActive = hovered == index || selected == visiblePoints[index].id
                            let colour = includesZero && value < 0 ? loss : tint
                            let radius: CGFloat = isActive ? 5.5 : 2.5
                            let dot = Path(ellipseIn: CGRect(x: x(index, width: plotWidth) - radius, y: y(value, scale: bounds) - radius, width: radius * 2, height: radius * 2))
                            if isActive {
                                plot.fill(dot, with: .color(Color(nsColor: .windowBackgroundColor)))
                                let core = Path(ellipseIn: CGRect(x: x(index, width: plotWidth) - 3.5, y: y(value, scale: bounds) - 3.5, width: 7, height: 7))
                                plot.fill(core, with: .color(colour))
                            } else { plot.fill(dot, with: .color(colour)) }
                        }
                    }
                    if let active = hovered ?? visiblePoints.firstIndex(where: { $0.id == selected }), visiblePoints.indices.contains(active) {
                        var crosshair = Path(); let xx = x(active, width: plotWidth)
                        crosshair.move(to: CGPoint(x: xx, y: 4)); crosshair.addLine(to: CGPoint(x: xx, y: plotHeight - 4))
                        plot.stroke(crosshair, with: .color(.secondary.opacity(0.35)), lineWidth: 1)
                    }
                }.frame(height: plotHeight).accessibilityHidden(true)
                if runs.isEmpty {
                    Text("No recorded result in this period").font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(width: plotWidth, height: plotHeight).offset(x: axisWidth)
                }
                if let hovered, visiblePoints.indices.contains(hovered) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(visiblePoints[hovered].detailLabel ?? visiblePoints[hovered].label).font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(session.privacyMode ? "Value hidden" : visiblePoints[hovered].value.map(UpOnlyFormat.exactMoney) ?? "No observation")
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        if let note = visiblePoints[hovered].note { Text(note).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    }.padding(8).frame(width: 142, alignment: .leading)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.12)))
                        .offset(x: min(max(axisWidth + x(hovered, width: plotWidth) - 71, axisWidth), max(axisWidth, geometry.size.width - 142)), y: -8)
                        .allowsHitTesting(false)
                }
                Rectangle().fill(.clear).contentShape(Rectangle()).frame(width: plotWidth, height: plotHeight)
                    .onContinuousHover { phase in
                        switch phase { case .active(let location): hovered = nearest(location.x, width: plotWidth); case .ended: hovered = nil }
                    }
                    .gesture(SpatialTapGesture().onEnded { value in if let index = nearest(value.location.x, width: plotWidth) { onSelect?(visiblePoints[index].id) } })
                    .offset(x: axisWidth)
                ZStack(alignment: .topLeading) {
                    let widths = visiblePoints.map { ($0.label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10)]).width }
                    ForEach(UpOnlyChartAxis.ticks(widths: widths, plotWidth: plotWidth)) { tick in
                        Text(visiblePoints[tick.index].label).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize()
                            .position(x: tick.center, y: 6)
                    }
                }.frame(width: plotWidth, height: 14).offset(x: axisWidth, y: plotHeight + 6)

            }
        }.frame(height: plotHeight + 20)
            .onChange(of: points) { hovered = nil }
            .accessibilityElement(children: .ignore).accessibilityLabel("History")
            .accessibilityValue(session.privacyMode ? "Values hidden" : points.map { "\($0.detailLabel ?? $0.label): \($0.value.map(UpOnlyFormat.exactMoney) ?? "No observation")" }.joined(separator: ". "))
            #if UPONLY_FIXTURE
            .onAppear { if ProcessInfo.processInfo.environment["UPONLY_PREVIEW_CHART_HOVER"] == "1", !visiblePoints.isEmpty { hovered = visiblePoints.count / 2 } }
            #endif
    }
}

enum UpOnlyFormat {
    static func utcDay(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.timeZone = UTCDay.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter.string(from: date)
    }
    static func money(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency; formatter.currencyCode = "USD"
        formatter.locale = Locale(identifier: "en_US")
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "—"
    }
    static func currencyMoney(_ value: Decimal, currency: String) -> String {
        let formatter = NumberFormatter(); formatter.numberStyle = .currency; formatter.currencyCode = currency
        formatter.locale = Locale(identifier: "en_US"); formatter.minimumFractionDigits = 2; formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? currency + " —"
    }
    static func exactMoney(_ value: Decimal) -> String {
        let formatter = NumberFormatter(); formatter.numberStyle = .currency; formatter.currencyCode = "USD"
        formatter.locale = Locale(identifier: "en_US"); formatter.minimumFractionDigits = 2; formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "—"
    }
    static func quantity(_ value: Decimal) -> String { NSDecimalNumber(decimal: value).stringValue }
    /// "Since Mar 2025 · Paid $4,200 · +$1,310 (+31%)", or nil when nothing is known.
    static func performance(_ summary: HoldingPerformance) -> String? {
        var parts: [String] = []
        if let since = summary.since {
            let month = AssetOwnership.month(at: since)
            parts.append("Since " + String(month.shortName.prefix(3)) + " " + String(month.year))
        }
        if let cost = summary.costUSD { parts.append("Paid " + money(cost)) }
        else if let native = summary.costNative, let currency = summary.costCurrency { parts.append("Paid " + currencyMoney(native, currency: currency) + " " + currency) }
        if let gain = summary.gainUSD {
            var text = (gain >= 0 ? "+" : "−") + money(abs(gain))
            if let fraction = summary.returnFraction {
                let percent = NSDecimalNumber(decimal: fraction * 100).doubleValue
                text += String(format: " (%@%.0f%%)", percent >= 0 ? "+" : "−", abs(percent))
            }
            parts.append(text)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

enum UpOnlyTint {
    static let metals = Color(red: 0.60, green: 0.47, blue: 0.23)
    static let cashFlow = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.36, green: 0.78, blue: 0.62, alpha: 1)
            : NSColor(srgbRed: 0.13, green: 0.51, blue: 0.39, alpha: 1)
    })
    static let netWorth = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.52, green: 0.64, blue: 0.94, alpha: 1)
            : NSColor(srgbRed: 0.29, green: 0.39, blue: 0.67, alpha: 1)
    })
    static let crypto = Color(red: 0.82, green: 0.52, blue: 0.18)
}
