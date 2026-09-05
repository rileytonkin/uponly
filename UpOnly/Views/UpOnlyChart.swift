import SwiftUI

struct UpOnlyChartPoint: Identifiable {
    var id: String
    var label: String
    var value: Decimal?
    var provisional = false
}

struct UpOnlyChart: View {
    var points: [UpOnlyChartPoint]
    var includesZero = false
    var selected: String?
    var tint: Color = .accentColor
    var onSelect: ((String) -> Void)?
    @State private var hovered: Int?
    @Environment(\.colorSchemeContrast) private var contrast

    private var numbers: [Double] { points.compactMap { $0.value.map { NSDecimalNumber(decimal: $0).doubleValue } } }
    private var low: Double { let v = numbers.min() ?? 0; return includesZero ? min(0, v) : v }
    private var high: Double { let v = numbers.max() ?? 1; return includesZero ? max(0, v) : v }
    private var domainPadding: Double { max((high - low) * 0.12, max(abs(high) * 0.01, 1)) }
    private func x(_ i: Int, _ width: CGFloat) -> CGFloat { points.count > 1 ? CGFloat(i) / CGFloat(points.count - 1) * width : width / 2 }
    private func y(_ value: Decimal, _ height: CGFloat) -> CGFloat {
        let number = NSDecimalNumber(decimal: value).doubleValue
        return height * (1 - (number - low + domainPadding) / (high - low + 2 * domainPadding))
    }
    private func segment(_ i: Int, size: CGSize) -> Path {
        Path { path in
            guard i > 0, let a = points[i-1].value, let b = points[i].value else { return }
            let p = CGPoint(x: x(i-1, size.width), y: y(a, size.height))
            let q = CGPoint(x: x(i, size.width), y: y(b, size.height))
            let middle = (p.x + q.x) / 2
            path.move(to: p)
            path.addCurve(to: q, control1: CGPoint(x: middle, y: p.y), control2: CGPoint(x: middle, y: q.y))
        }
    }
    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geometry in
                let size = geometry.size
                ZStack(alignment: .topLeading) {
                    Canvas { context, canvasSize in
                        for row in 0..<3 {
                            var grid = Path()
                            let yy = CGFloat(row) / 2 * canvasSize.height
                            grid.move(to: CGPoint(x: 0, y: yy)); grid.addLine(to: CGPoint(x: canvasSize.width, y: yy))
                            context.stroke(grid, with: .color(.primary.opacity(contrast == .increased ? 0.18 : 0.055)), lineWidth: 0.5)
                        }
                        if includesZero {
                            var zero = Path()
                            zero.move(to: CGPoint(x: 0, y: y(0, canvasSize.height)))
                            zero.addLine(to: CGPoint(x: canvasSize.width, y: y(0, canvasSize.height)))
                            context.stroke(zero, with: .color(.secondary.opacity(0.35)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                        }
                        for i in points.indices {
                            if i > 0, points[i-1].value != nil, points[i].value != nil {
                                var area = segment(i, size: canvasSize)
                                area.addLine(to: CGPoint(x: x(i, canvasSize.width), y: canvasSize.height))
                                area.addLine(to: CGPoint(x: x(i-1, canvasSize.width), y: canvasSize.height))
                                area.closeSubpath()
                                context.fill(area, with: .linearGradient(Gradient(colors: [tint.opacity(0.065), tint.opacity(0.005)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: canvasSize.height)))
                                context.stroke(segment(i, size: canvasSize), with: .color(tint), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: points[i].provisional || points[i-1].provisional ? [4, 4] : []))
                            }
                            if let value = points[i].value, points.count == 1 || points[i].provisional || selected == points[i].id || hovered == i {
                                let dot = Path(ellipseIn: CGRect(x: x(i, canvasSize.width)-3, y: y(value, canvasSize.height)-3, width: 6, height: 6))
                                context.fill(dot, with: .color(points[i].provisional ? Color(nsColor: .windowBackgroundColor) : tint))
                                context.stroke(dot, with: .color(tint), lineWidth: 1.5)
                            }
                        }
                    }.accessibilityHidden(true)
                    if numbers.isEmpty {
                        Text("History begins with your first observation")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if let hovered, points.indices.contains(hovered) {
                        Text(points[hovered].label + " · " + (points[hovered].value.map { UpOnlyFormat.money($0) } ?? "No observation"))
                            .font(.system(size: 11, weight: .medium)).padding(.horizontal, 6).padding(.vertical, 4)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .offset(y: -8)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        guard !points.isEmpty else { return }
                        hovered = max(0, min(points.count - 1, Int((location.x / max(size.width, 1) * Double(points.count - 1)).rounded())))
                    case .ended: hovered = nil
                    }
                }
                .onTapGesture { if let hovered, points.indices.contains(hovered) { onSelect?(points[hovered].id) } }
            }.frame(height: 104)
            HStack {
                Text(points.first?.label ?? "")
                Spacer()
                if points.count > 2 { Text(points[points.count / 2].label); Spacer() }
                if points.count > 1 { Text(points.last?.label ?? "") }
            }.font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("History")
        .accessibilityValue(points.map { "\($0.label): \($0.value.map(UpOnlyFormat.money) ?? "No observation")" }.joined(separator: ". "))
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
    static func quantity(_ value: Decimal) -> String { NSDecimalNumber(decimal: value).stringValue }
}
