import SwiftUI

// Small pieces shared by the Manage pages.

/// Keeps a page mounted but out of sight while a confirmation covers it, so Cancel returns to it unchanged.
struct UpOnlyHiddenWhile: ViewModifier {
    let hidden: Bool
    func body(content: Content) -> some View {
        content.frame(height: hidden ? 0 : nil).clipped()
            .opacity(hidden ? 0 : 1).allowsHitTesting(!hidden).accessibilityHidden(hidden)
    }
}

/// Every empty Manage page: a badge, what is missing, one line of help and the action that fills it.
struct ManageEmptyState: View {
    let title: String
    let detail: String
    let symbol: String
    var tint = UpOnlyTint.netWorth
    var actionTitle: String?
    var action: () -> Void = {}
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            UpOnlySymbolBadge(symbol: symbol, tint: tint, size: 30)
            Text(title).font(UpOnlyType.title).fixedSize(horizontal: false, vertical: true)
            Text(detail).font(UpOnlyType.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let actionTitle { Button(actionTitle, action: action).buttonStyle(.upOnlyPrimary).padding(.top, 4) }
        }.padding(UpOnlyLayout.cardInset).frame(maxWidth: .infinity, alignment: .leading).modifier(UpOnlyContentSurface())
    }
}

/// `UpOnlyRow`s in one card, as the home list is. Every list uses it, on the dashboard and in Manage.
struct ManageCard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 0) { content() }
            .padding(.horizontal, UpOnlyLayout.cardInset).padding(.vertical, 4).modifier(UpOnlyContentSurface())
    }
}
/// The quiet "…" at the end of a row.
struct ManageRowMenu<Content: View>: View {
    var label: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        Menu { content() } label: {
            Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).frame(width: 22, height: 22).contentShape(Rectangle())
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel(label)
    }
}
/// The dashboard's round glass + button, for a page's own Add.
struct ManageAddButton: View {
    var label: String
    var action: () -> Void
    var body: some View {
        UpOnlyCircleButton(symbol: "plus", label: label, action: action)
    }
}

/// Every transaction type picker lists the types in this order.
let entryKinds: [EntryKind] = [.expense, .income, .refund, .transfer]
func kindTitle(_ kind: EntryKind) -> String {
    switch kind { case .income: "Income"; case .expense: "Spending"; case .refund: "Refund"; case .transfer: "Transfer" }
}
func kindSign(_ kind: EntryKind) -> String { kind == .expense ? "−" : kind == .transfer ? "" : "+" }

/// Changes to one transaction, made from Transactions and from the month review.
@MainActor enum TransactionEdits {
    static func reclassify(_ entry: Entry, as kind: EntryKind, in session: UpOnlySession) {
        Task { await session.perform { doc in
            if let index = doc.entries.firstIndex(where: { $0.id == entry.id }) { doc.entries[index].kind = kind; doc.entries[index].kindIsUserEdited = true }
        } }
    }
    /// Moves a transaction between your personal money and the business. A business cost paid from a personal
    /// account leaves personal spending; it does not change the company's accounting.
    static func reassign(_ entry: Entry, to bucket: Bucket, business: String?, in session: UpOnlySession) {
        Task { await session.perform { doc in
            if let index = doc.entries.firstIndex(where: { $0.id == entry.id }) { doc.entries[index].bucket = bucket; doc.entries[index].businessID = business }
        } }
    }
    static func setTransferCounterparty(_ label: String, enabled: Bool, in session: UpOnlySession) {
        Task { await session.perform { doc in OwnerPayments.setTransferCounterparty(label, enabled: enabled, in: &doc) } }
    }
}

/// Holding amounts as the dashboard shows them: coins with their symbol, metal in troy ounces from one ounce up, otherwise grams.
enum ManageFormat {
    static func amount(_ value: Decimal, of holding: Holding, catalog: [CatalogCoin]) -> String {
        let id = holding.assetID.rawValue
        let coin = catalog.first(where: { $0.id == id }) ?? ImportCoins.common.first(where: { $0.id == id })
        return UpOnlyFormat.holding(quantity: value, valueUSD: nil, symbol: coin?.symbol.uppercased() ?? "", metal: PreciousMetal.asset(holding.assetID) != nil)
            .trimmingCharacters(in: .whitespaces)
    }
    /// "Aug 12" for a stored UTC day such as "2026-08-12".
    static func day(_ raw: String) -> String? { dayParser.date(from: raw).map { UpOnlyFormat.utcDay($0) } }
    private static let dayParser: DateFormatter = {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = UTCDay.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}


struct UpOnlyMetalHistory: View {
    var metal: PreciousMetal
    var document: VaultDocument
    @State private var days = 90
    private var observations: [QuoteObservation] { document.quotes.filter { $0.assetID == metal.assetID }.sorted { $0.providerTime < $1.providerTime } }
    private func chartPoints(_ observations: [QuoteObservation]) -> [UpOnlyChartPoint] {
        guard let first = observations.first else { return [] }
        let end = UTCDay.start(of: Date())
        let start = max(UTCDay.start(of: first.providerTime), days == 0 ? UTCDay.start(of: first.providerTime) : end.addingTimeInterval(-Double(days - 1) * 86400))
        let daily = Dictionary(grouping: observations, by: { UTCDay.start(of: $0.providerTime) })
        return stride(from: start.timeIntervalSince1970, through: end.timeIntervalSince1970, by: 86400).map { timestamp in
            let date = Date(timeIntervalSince1970: timestamp), label = ImportDateFormat.today(date)
            let quote = daily[date]?.last
            let value = quote.flatMap { try? MoneyInput.multiply($0.priceUSD.value, PreciousMetal.gramsPerTroyOunce) }
            return UpOnlyChartPoint(id: label, label: label, value: value)
        }
    }
    var body: some View {
        let observations = self.observations
        let points = chartPoints(observations)
        VStack(alignment: .leading, spacing: 12) {
            Text("USD per troy ounce").font(UpOnlyType.caption).foregroundStyle(.secondary)
            UpOnlySegments(options: [(30, "1M", "1 month"), (90, "3M", "3 months"), (365, "1Y", "1 year"), (0, "All", "All")], selection: $days, label: "Metal chart period")
            if let quote = observations.last, let price = try? MoneyInput.multiply(quote.priceUSD.value, PreciousMetal.gramsPerTroyOunce) {
                UpOnlyPrivateText(UpOnlyFormat.money(price)).font(.system(size: 24, weight: .medium).monospacedDigit()).fixedSize(horizontal: false, vertical: true)
                Text(quote.provider + " · " + quote.providerTime.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: UTCDay.timeZone)))
                    .font(UpOnlyType.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if points.contains(where: { $0.value != nil }) {
                UpOnlyChart(points: points, tint: UpOnlyTint.metals)
            } else {
                Text("Price history will appear here after the first update.").font(UpOnlyType.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct UpOnlyOwnerPicker: View {
    @Environment(UpOnlySession.self) private var session
    @Binding var owner: String?
    var body: some View {
        if !(session.document?.businessAccounting ?? []).isEmpty || owner != nil {
            Picker("Owner", selection: $owner) {
                Text("Personal").tag(Optional<String>.none)
                ForEach(session.document?.businessAccounting ?? []) { book in Text(book.name).tag(Optional(book.id)) }
                if let owner, !(session.document?.businessAccounting ?? []).contains(where: { $0.id == owner }) {
                    Text("Company unavailable").tag(Optional(owner))
                }
            }.pickerStyle(.menu).font(UpOnlyType.body).accessibilityLabel("Asset owner")
        }
    }
}
extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
