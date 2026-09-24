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
    /// A date worth marking on the x-axis ("Oct", "2026", "Sep 7"). When any point has one, only those points are labelled.
    var axisLabel: String?
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
        // A near-flat series is widened to 4% of its size, and to at least $10, so the tick labels stay distinct
        // and a flat $0 series isn't labelled in fractions of a cent.
        let minimumSpan = max(max(abs(rawLow), abs(rawHigh)) * 0.04, 10)
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
        let step = candidates.first { (ceil(rawHigh / $0) - floor(rawLow / $0)) <= 4 } ?? span  // at most five gridlines
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
        let formatter = divisor == 1 && magnitude < 1 ? fine : coarse
        return (value < 0 ? "−" : "") + "$" + (formatter.string(from: NSNumber(value: magnitude / divisor)) ?? "0") + suffix
    }
    private static let coarse = decimalFormatter(maximumFractionDigits: 2)
    private static let fine = decimalFormatter(maximumFractionDigits: 4)
    private static func decimalFormatter(maximumFractionDigits: Int) -> NumberFormatter {
        let formatter = NumberFormatter(); formatter.locale = Locale(identifier: "en_US")
        formatter.maximumFractionDigits = maximumFractionDigits
        return formatter
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
        else {
            // Up to eight evenly spaced labels, like the admin axis's maxTicksLimit; overlaps are dropped below.
            let step = max(1, Int((Double(count - 1) / 7).rounded(.up)))
            candidates = Array(Set(stride(from: 0, to: count - 1, by: step)).union([count - 1])).sorted()
        }
        let ticks = candidates.compactMap { index -> Tick? in
            widths[index] <= plotWidth ? tick(index, widths: widths, plotWidth: plotWidth) : nil
        }
        guard let first = ticks.first, let last = ticks.last, first.index != last.index else { return ticks }
        guard fits(first, before: last, gap: gap) else { return [last] }
        var result = [first]
        for tick in ticks.dropFirst().dropLast() where fits(tick, before: last, gap: gap) {
            if fits(result[result.count - 1], before: tick, gap: gap) { result.append(tick) }
        }
        result.append(last)
        return result
    }
    /// Labels only at the marked points (month starts, Mondays): every one of them when they fit, otherwise every
    /// second, third… so the spacing stays even and no two labels collide. `widths` has one entry per point.
    static func ticks(labelled: [Int], widths: [CGFloat], plotWidth: CGFloat, gap: CGFloat = 10) -> [Tick] {
        let fitting = labelled.filter { widths.indices.contains($0) && widths[$0] <= plotWidth }
        guard plotWidth > 0, !fitting.isEmpty else { return [] }
        for step in 1...fitting.count {
            let ticks = stride(from: 0, to: fitting.count, by: step).map { tick(fitting[$0], widths: widths, plotWidth: plotWidth) }
            if zip(ticks, ticks.dropFirst()).allSatisfy({ fits($0, before: $1, gap: gap) }) { return ticks }
        }
        return [tick(fitting[0], widths: widths, plotWidth: plotWidth)]
    }
    private static func tick(_ index: Int, widths: [CGFloat], plotWidth: CGFloat) -> Tick {
        let width = widths[index], count = widths.count
        let anchor = count > 1 ? CGFloat(index) / CGFloat(count - 1) * plotWidth : 12
        return Tick(index: index, center: min(max(anchor, width / 2), plotWidth - width / 2), width: width)
    }
    private static func fits(_ a: Tick, before b: Tick, gap: CGFloat) -> Bool { a.center + a.width / 2 + gap <= b.center - b.width / 2 }
}

/// What the chart derives from its points, worked out once when the points arrive rather than on every hover.
nonisolated struct UpOnlyChartLayout {
    var visible: [UpOnlyChartPoint]
    /// Stretches of consecutive points that have a value; gaps between them stay gaps.
    var runs: [[Int]]
    var scale: UpOnlyChartScale
    var markers: Bool
    /// Points carrying an axis label, or nil to label from every point's `label`.
    var labelled: [Int]?
    var summary: String
    init(points: [UpOnlyChartPoint], includesZero: Bool, showsAllMarkers: Bool = false, selected: String? = nil, spansRange: Bool = false) {
        // Don't reserve empty history before the first or after the last observation, but keep the selected
        // point in range so its highlight never disappears. Interior missing points remain explicit gaps.
        // Everything is worked out in locals first: a closure may not read `self` before every property is set.
        var visible = points
        if let first = points.firstIndex(where: { $0.value != nil }), let last = points.lastIndex(where: { $0.value != nil }) {
            let chosen = points.firstIndex { $0.id == selected }
            visible = Array(points[(spansRange ? 0 : min(first, chosen ?? first))...max(last, chosen ?? last)])
        }
        var runs: [[Int]] = [], run: [Int] = []
        for index in visible.indices {
            if visible[index].value != nil { run.append(index) }
            else if !run.isEmpty { runs.append(run); run = [] }
        }
        if !run.isEmpty { runs.append(run) }
        let values = visible.compactMap(\.value)
        let marked = visible.indices.filter { visible[$0].axisLabel != nil }
        self.visible = visible
        self.runs = runs
        scale = UpOnlyChartScale(values: values, includesZero: includesZero)
        // Points only when there are ten or fewer values (the admin's showPoints rule), unless every one is asked for.
        markers = showsAllMarkers || values.count <= 10
        labelled = marked.isEmpty ? nil : marked
        summary = Self.summary(visible)
    }
    /// What VoiceOver reads: each value when there are a dozen or fewer, otherwise the span, low, high and latest.
    /// Points without a value are counted, not read out one by one.
    static func summary(_ points: [UpOnlyChartPoint]) -> String {
        let valued = points.compactMap { point in point.value.map { (name: point.detailLabel ?? point.label, value: $0) } }
        guard let first = valued.first, let last = valued.last,
              let low = valued.min(by: { $0.value < $1.value }), let high = valued.max(by: { $0.value < $1.value }) else { return "No recorded values" }
        let empty = points.count - valued.count
        let gaps = empty > 0 ? ". \(empty) with no recorded value" : ""
        if valued.count <= 12 { return valued.map { $0.name + ": " + UpOnlyFormat.exactMoney($0.value) }.joined(separator: ". ") + gaps }
        return "\(valued.count) values from " + first.name + " to " + last.name + ". Lowest " + UpOnlyFormat.exactMoney(low.value) + " on " + low.name
            + ", highest " + UpOnlyFormat.exactMoney(high.value) + " on " + high.name + ", latest " + UpOnlyFormat.exactMoney(last.value) + gaps
    }
}

struct UpOnlyChart: View {
    @Environment(UpOnlySession.self) private var session
    @Environment(\.colorSchemeContrast) private var contrast
    let points: [UpOnlyChartPoint]
    var includesZero: Bool
    var selected: String?
    var tint: Color
    var onSelect: ((String) -> Void)?
    private let layout: UpOnlyChartLayout
    private let axisWidth: CGFloat
    /// One x-axis label width per visible point (zero where a point has no label).
    private let labelWidths: [CGFloat]
    @State private var hovered: Int? = nil
    private let plotHeight: CGFloat = 112
    /// Room past the last point for the largest marker, so it isn't clipped at the right edge.
    private let edge: CGFloat = 6
    /// `spansRange` keeps the leading empty points so the line sits at its true position across the whole range,
    /// running to the right edge where the gridlines end. Off for monthly charts that trim to their data.
    init(points: [UpOnlyChartPoint], includesZero: Bool = false, showsAllMarkers: Bool = false, selected: String? = nil,
         tint: Color = .accentColor, onSelect: ((String) -> Void)? = nil, spansRange: Bool = false) {
        self.points = points; self.includesZero = includesZero; self.selected = selected; self.tint = tint; self.onSelect = onSelect
        let layout = UpOnlyChartLayout(points: points, includesZero: includesZero, showsAllMarkers: showsAllMarkers, selected: selected, spansRange: spansRange)
        self.layout = layout
        let tickFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), labelFont = NSFont.systemFont(ofSize: 10)
        axisWidth = (layout.scale.ticks.map { (UpOnlyChartScale.label($0) as NSString).size(withAttributes: [.font: tickFont]).width }.max() ?? 24) + 9
        labelWidths = layout.visible.map { point in
            guard let text = layout.labelled == nil ? point.label : point.axisLabel else { return 0 }
            return (text as NSString).size(withAttributes: [.font: labelFont]).width
        }
    }
    private func x(_ i: Int, width: CGFloat) -> CGFloat {
        layout.visible.count > 1 ? CGFloat(i) / CGFloat(layout.visible.count - 1) * width : 12
    }
    private func y(_ value: Decimal) -> CGFloat { 6 + (1 - layout.scale.fraction(value)) * (plotHeight - 12) }
    private func nearest(_ location: CGFloat, width: CGFloat) -> Int? {
        guard !layout.visible.isEmpty else { return nil }
        return max(0, min(layout.visible.count - 1, Int((location / max(width, 1) * CGFloat(layout.visible.count - 1)).rounded())))
    }
    private func line(_ run: [Int], width: CGFloat) -> Path {
        let pts = run.compactMap { index -> CGPoint? in
            layout.visible[index].value.map { CGPoint(x: x(index, width: width), y: y($0)) }
        }
        var path = Path()
        guard let first = pts.first else { return path }
        path.move(to: first)
        guard pts.count > 1 else { return path }
        // The admin Earnings chart's line tension (REPORTING_LINE_TENSION = 0.08): a barely softened line whose
        // handles are clamped vertically so it never invents a peak or dip between real observations.
        let tension: CGFloat = 0.08
        for i in 1..<pts.count {
            let p0 = pts[max(i - 2, 0)], p1 = pts[i - 1], p2 = pts[i], p3 = pts[min(i + 1, pts.count - 1)]
            let low = min(p1.y, p2.y), high = max(p1.y, p2.y)
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) * tension, y: min(high, max(low, p1.y + (p2.y - p0.y) * tension)))
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) * tension, y: min(high, max(low, p2.y - (p3.y - p1.y) * tension)))
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }
    var body: some View {
        Group {
            if !points.contains(where: { $0.value != nil }) {
                Text("No recorded values in this period").font(UpOnlyType.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
            } else { historyChart }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("History")
        .accessibilityValue(session.privacyMode ? "Values hidden" : layout.summary)
        .accessibilityActions {
            // Choosing a month is otherwise a click on the plot; VoiceOver lists it as an action instead.
            if let onSelect {
                ForEach(layout.visible.filter { $0.value != nil }) { point in
                    Button("Show " + (point.detailLabel ?? point.label)) { onSelect(point.id) }
                }
            }
        }
    }
    private var historyChart: some View {
        GeometryReader { geometry in
            let plotWidth = max(1, geometry.size.width - axisWidth - edge)
            let visible = layout.visible
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    for tick in layout.scale.ticks where !layout.runs.isEmpty {
                        let yy = y(Decimal(tick))
                        var grid = Path(); grid.move(to: CGPoint(x: axisWidth - 4, y: yy)); grid.addLine(to: CGPoint(x: axisWidth + plotWidth, y: yy))
                        // Gridlines at 4.5% (the admin's rgba(255,255,255,0.045)); the zero line a little firmer on cash-flow charts.
                        let zero = tick == 0 && includesZero
                        context.stroke(grid, with: .color(.primary.opacity(zero ? 0.2 : contrast == .increased ? 0.14 : 0.06)), lineWidth: 1)
                        if !session.privacyMode {
                            // Axis labels in the series colour at 68%, as the admin chart does.
                            context.draw(Text(UpOnlyChartScale.label(tick)).font(.system(size: 10).monospacedDigit()).foregroundStyle(tint.opacity(0.68)), at: CGPoint(x: axisWidth - 7, y: yy), anchor: .trailing)
                        }
                    }
                    var plot = context; plot.translateBy(x: axisWidth, y: 0)
                    let zeroY = includesZero ? y(0) : plotHeight - 6
                    let loss = UpOnlyTint.loss
                    let solidStyle = StrokeStyle(lineWidth: 2.25, lineCap: .round, lineJoin: .round)
                    let dashedStyle = StrokeStyle(lineWidth: 2.25, lineCap: .round, lineJoin: .round, dash: [4, 4])
                    for wholeRun in layout.runs {
                        guard let lone = wholeRun.first else { continue }
                        if wholeRun.count == 1, let value = visible[lone].value {
                            // A lone value is a point, not a bar; the hover shows its figure.
                            let dot = Path(ellipseIn: CGRect(x: x(lone, width: plotWidth) - 3, y: y(value) - 3, width: 6, height: 6))
                            plot.fill(dot, with: .color(includesZero && value < 0 ? loss : tint))
                            continue
                        }
                        // Days that could only be partly valued are drawn dashed and lighter, without fill, so the
                        // estimate is visible as an estimate. Each stretch shares its boundary point with its neighbour.
                        var stretches: [(indices: [Int], partial: Bool)] = []
                        for index in wholeRun {
                            let partial = visible[index].partial
                            if let lastStretch = stretches.last, lastStretch.partial == partial { stretches[stretches.count - 1].indices.append(index) }
                            else {
                                if let previous = stretches.last?.indices.last { stretches.append(([previous, index], partial)) } else { stretches.append(([index], partial)) }
                            }
                        }
                        for stretch in stretches where stretch.partial && stretch.indices.count > 1 {
                            plot.stroke(line(stretch.indices, width: plotWidth), with: .color(tint.opacity(0.55)), style: dashedStyle)
                        }
                        for stretch in stretches where !stretch.partial && stretch.indices.count > 1 {
                            let run = stretch.indices, first = run[0], last = run[run.count - 1]
                            var area = line(run, width: plotWidth)
                            area.addLine(to: CGPoint(x: x(last, width: plotWidth), y: zeroY)); area.addLine(to: CGPoint(x: x(first, width: plotWidth), y: zeroY)); area.closeSubpath()
                            // Only a still-provisional last point (the open month) is dashed.
                            let provisionalTail = last == visible.count - 1 && visible[last].provisional
                            let solid = line(provisionalTail ? Array(run.dropLast()) : run, width: plotWidth)
                            let tail = provisionalTail ? line(Array(run.suffix(2)), width: plotWidth) : nil
                            if includesZero {
                                // Above zero green, below red, so the answer is a colour before it is a number.
                                var above = plot; above.clip(to: Path(CGRect(x: 0, y: 0, width: plotWidth, height: zeroY)))
                                above.fill(area, with: .linearGradient(Gradient(colors: [tint.opacity(0.19), tint.opacity(0)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: zeroY)))
                                above.stroke(solid, with: .color(tint), style: solidStyle)
                                if let tail { above.stroke(tail, with: .color(tint), style: dashedStyle) }
                                var below = plot; below.clip(to: Path(CGRect(x: 0, y: zeroY, width: plotWidth, height: plotHeight - zeroY)))
                                below.fill(area, with: .linearGradient(Gradient(colors: [loss.opacity(0), loss.opacity(0.19)]), startPoint: CGPoint(x: 0, y: zeroY), endPoint: CGPoint(x: 0, y: plotHeight)))
                                below.stroke(solid, with: .color(loss), style: solidStyle)
                                if let tail { below.stroke(tail, with: .color(loss), style: dashedStyle) }
                            } else {
                                plot.fill(area, with: .linearGradient(Gradient(colors: [tint.opacity(0.19), tint.opacity(0)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: plotHeight)))
                                plot.stroke(solid, with: .color(tint), style: solidStyle)
                                if let tail { plot.stroke(tail, with: .color(tint), style: dashedStyle) }
                            }
                        }
                        // Markers, plus the selection and the hover: a 5pt dot ringed in the background colour.
                        for index in wholeRun where layout.markers || selected == visible[index].id || hovered == index {
                            guard let value = visible[index].value else { continue }
                            let isActive = hovered == index || selected == visible[index].id
                            let colour = includesZero && value < 0 ? loss : tint
                            let radius: CGFloat = isActive ? 5 : 2.5
                            let centre = CGPoint(x: x(index, width: plotWidth), y: y(value))
                            let dot = Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
                            plot.fill(dot, with: .color(colour))
                            if isActive { plot.stroke(dot, with: .color(Color(nsColor: .windowBackgroundColor)), lineWidth: 2) }
                        }
                    }
                    if let active = hovered ?? visible.firstIndex(where: { $0.id == selected }), visible.indices.contains(active) {
                        var crosshair = Path(); let xx = x(active, width: plotWidth)
                        crosshair.move(to: CGPoint(x: xx, y: 4)); crosshair.addLine(to: CGPoint(x: xx, y: plotHeight - 4))
                        plot.stroke(crosshair, with: .color(.primary.opacity(0.18)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                }.frame(height: plotHeight).accessibilityHidden(true)
                if let hovered, visible.indices.contains(hovered) {
                    let point = visible[hovered]
                    let anchor = axisWidth + x(hovered, width: plotWidth)
                    // Beside the crosshair rather than over the point: to its right when there is room, else to its left.
                    let left = anchor + 160 <= geometry.size.width ? anchor + 10 : max(0, anchor - 160)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(point.detailLabel ?? point.label).font(.system(size: 10, weight: .medium)).foregroundStyle(Color(red: 0.553, green: 0.553, blue: 0.592))
                        Text(session.privacyMode ? "Value hidden" : point.value.map(UpOnlyFormat.exactMoney) ?? "No recorded value")
                            .font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(Color(red: 0.957, green: 0.957, blue: 0.961))
                        // Notes can cite amounts (a company's revenue and expenses), so privacy mode hides them too.
                        if !session.privacyMode, let note = point.note { Text(note).font(.system(size: 10)).foregroundStyle(Color(red: 0.553, green: 0.553, blue: 0.592)).fixedSize(horizontal: false, vertical: true) }
                    }.padding(11).frame(width: 150, alignment: .leading)
                        .background(Color(red: 0.039, green: 0.039, blue: 0.051).opacity(0.94), in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.1)))
                        .offset(x: left, y: -8)
                        .allowsHitTesting(false)
                }
                Rectangle().fill(.clear).contentShape(Rectangle()).frame(width: plotWidth + edge, height: plotHeight)
                    .onContinuousHover { phase in
                        switch phase { case .active(let location): hovered = nearest(location.x, width: plotWidth); case .ended: hovered = nil }
                    }
                    .gesture(SpatialTapGesture().onEnded { value in if let index = nearest(value.location.x, width: plotWidth) { onSelect?(visible[index].id) } })
                    .offset(x: axisWidth)
                ZStack(alignment: .topLeading) {
                    let ticks = layout.labelled.map { UpOnlyChartAxis.ticks(labelled: $0, widths: labelWidths, plotWidth: plotWidth) }
                        ?? UpOnlyChartAxis.ticks(widths: labelWidths, plotWidth: plotWidth)
                    ForEach(ticks) { tick in
                        Text(layout.labelled == nil ? visible[tick.index].label : visible[tick.index].axisLabel ?? "").font(.system(size: 10))
                            .foregroundStyle(.primary.opacity(contrast == .increased ? 0.75 : 0.5)).fixedSize()
                            .position(x: tick.center, y: 6)
                    }
                }.frame(width: plotWidth, height: 14).offset(x: axisWidth, y: plotHeight + 6)
            }
        }.frame(height: plotHeight + 20)
            .onChange(of: points) { hovered = nil }
            #if UPONLY_FIXTURE
            .onAppear { if ProcessInfo.processInfo.environment["UPONLY_PREVIEW_CHART_HOVER"] == "1", !layout.visible.isEmpty { hovered = layout.visible.count / 2 } }
            #endif
    }
}

enum UpOnlyFormat {
    private static let usdWhole: NumberFormatter = {
        let formatter = NumberFormatter(); formatter.numberStyle = .currency; formatter.currencyCode = "USD"
        formatter.locale = Locale(identifier: "en_US"); formatter.maximumFractionDigits = 0
        return formatter
    }()
    private static let usdCents = currencyFormatter("USD")
    private static let usdSmall: NumberFormatter = {
        let formatter = currencyFormatter("USD"); formatter.maximumFractionDigits = 6
        return formatter
    }()
    private static let oneDecimal = decimalFormatter(fractionDigits: 1...1)
    private static let coinAmount = decimalFormatter(fractionDigits: 0...8)
    private static let metalWeight = decimalFormatter(fractionDigits: 0...4)
    private static let dayFormatter = dateFormatter("MMMd")
    private static let dateWithYear = dateFormatter("MMMdyyyy")
    private static let monthFormatter = dateFormatter("MMM")
    private static let monthYearFormatter = dateFormatter("MMMyyyy")
    private static func currencyFormatter(_ code: String) -> NumberFormatter {
        let formatter = NumberFormatter(); formatter.numberStyle = .currency; formatter.currencyCode = code
        formatter.locale = Locale(identifier: "en_US"); formatter.minimumFractionDigits = 2; formatter.maximumFractionDigits = 2
        return formatter
    }
    private static func decimalFormatter(fractionDigits: ClosedRange<Int>) -> NumberFormatter {
        let formatter = NumberFormatter(); formatter.numberStyle = .decimal; formatter.locale = Locale(identifier: "en_US")
        formatter.minimumFractionDigits = fractionDigits.lowerBound; formatter.maximumFractionDigits = fractionDigits.upperBound
        return formatter
    }
    /// Dates are UTC days, in the same English as the rest of the app.
    private static func dateFormatter(_ template: String) -> DateFormatter {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US")
        formatter.calendar = UTCDay.calendar; formatter.timeZone = UTCDay.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }
    private static func rounded(_ value: Decimal, scale: Int) -> Decimal {
        var input = value, output = Decimal()
        NSDecimalRound(&output, &input, scale, .plain)
        return output
    }
    /// "Sep 24".
    static func utcDay(_ date: Date) -> String { dayFormatter.string(from: date) }
    /// "Sep 24, 2026".
    static func utcDate(_ date: Date) -> String { dateWithYear.string(from: date) }
    /// "Sep": the month's own abbreviation, not the first three letters of its name.
    static func monthName(_ month: MonthKey) -> String {
        guard let date = UTCDay.calendar.date(from: DateComponents(year: month.year, month: month.month, day: 15)) else { return month.description }
        return monthFormatter.string(from: date)
    }
    static func monthName(_ date: Date) -> String { monthFormatter.string(from: date) }
    /// Whole dollars with a true minus sign: "−$1,234".
    static func money(_ value: Decimal) -> String {
        let whole = rounded(value, scale: 0)
        return (whole < 0 ? "−" : "") + (usdWhole.string(from: NSDecimalNumber(decimal: abs(whole))) ?? "—")
    }
    static func currencyMoney(_ value: Decimal, currency: String) -> String {
        (rounded(value, scale: 2) < 0 ? "−" : "") + (currencyFormatter(currency).string(from: NSDecimalNumber(decimal: abs(value))) ?? currency + " —")
    }
    /// Dollars and cents with a true minus sign: "−$3,200.00".
    static func exactMoney(_ value: Decimal) -> String {
        (rounded(value, scale: 2) < 0 ? "−" : "") + (usdCents.string(from: NSDecimalNumber(decimal: abs(value))) ?? "—")
    }
    static func quantity(_ value: Decimal) -> String { NSDecimalNumber(decimal: value).stringValue }
    /// A signed percentage with one decimal: "+18.0%", "−3.4%", "0.0%".
    static func percent(_ fraction: Decimal) -> String {
        let value = rounded(fraction * 100, scale: 1)
        return (value > 0 ? "+" : value < 0 ? "−" : "") + (oneDecimal.string(from: NSDecimalNumber(decimal: abs(value))) ?? "0.0") + "%"
    }
    /// "+$4,599 (+50.5%)": the change in whole dollars, and as a share of where it started when that was above zero.
    static func change(_ amount: Decimal, from baseline: Decimal) -> String {
        let whole = rounded(amount, scale: 0)
        let text = (whole > 0 ? "+" : "") + money(whole)
        return baseline > 0 ? text + " (" + percent(amount / baseline) + ")" : text
    }
    /// "0.1 BTC · $59,000.00" for a coin. Metal is weighed in troy ounces from one ounce up, otherwise in grams,
    /// and priced per that unit: "2 ozt · $2,650.00/ozt", "10 g · $100.00/g". `quantity` is grams for metal.
    static func holding(quantity: Decimal, valueUSD: Decimal?, symbol: String, metal: Bool) -> String {
        var amount = quantity, unit = symbol
        if metal {
            let ounces = quantity / PreciousMetal.gramsPerTroyOunce
            if ounces >= 1 { amount = ounces; unit = "ozt" } else { unit = "g" }
        }
        let formatter = metal ? metalWeight : coinAmount
        var text = (formatter.string(from: NSDecimalNumber(decimal: amount)) ?? quantity.description) + " " + unit
        if let valueUSD, amount > 0 {
            let price = valueUSD / amount
            // Sub-dollar coins keep their significant digits: "$0.000012", not "$0.00".
            text += " · " + (price < 1 ? usdSmall.string(from: NSDecimalNumber(decimal: price)) ?? "—" : exactMoney(price)) + (metal ? "/" + unit : "")
        }
        return text
    }
    /// "Since Mar 2025 · Paid $4,200 · +$1,310 (+31%)", or nil when nothing is known.
    static func performance(_ summary: HoldingPerformance, metal: Bool = false) -> String? {
        var parts: [String] = []
        if let since = summary.since { parts.append("Since " + monthYearFormatter.string(from: since)) }
        // Lots that cover only part of the holding give a cost for that part and no gain: "Paid $30,000 for 0.5 of 2".
        var covered = ""
        if let part = summary.coveredQuantity, let held = summary.heldQuantity {
            // Metal quantities are grams; say them in the same unit as the holding line ("for 1 ozt of 2 ozt").
            let amount = { (value: Decimal) in metal ? holding(quantity: value, valueUSD: nil, symbol: "", metal: true) : coinAmount.string(from: NSDecimalNumber(decimal: value)) ?? "" }
            covered = " for " + amount(part) + " of " + amount(held)
        }
        if let cost = summary.costUSD { parts.append("Paid " + money(cost) + covered) }
        else if let native = summary.costNative, let currency = summary.costCurrency { parts.append("Paid " + currencyMoney(native, currency: currency) + " " + currency + covered) }
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
    /// Money up and money down, used for every signed figure (changes, cash flow, profit).
    static let gain = cashFlow
    static let loss = Color(nsColor: .systemRed)
    /// Gain for up, loss for down, and quiet for no change.
    static func signed(_ value: Decimal) -> Color { value > 0 ? gain : value < 0 ? loss : .secondary }
}
