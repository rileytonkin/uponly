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
            if let actionTitle { Button(actionTitle, action: action).buttonStyle(.glassProminent).padding(.top, 4) }
        }.padding(UpOnlyLayout.cardInset).frame(maxWidth: .infinity, alignment: .leading).modifier(UpOnlyContentSurface())
    }
}

/// Rows in one card, divided as the home list is. Every Manage list uses it.
struct ManageCard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 0) { content() }
            .padding(.horizontal, UpOnlyLayout.cardInset).padding(.vertical, 2).modifier(UpOnlyContentSurface())
    }
}
/// One Manage row in the home list's style: a badge, the name over a caption, a value, and a chevron or a quiet "…".
/// The row itself does the obvious thing; anything else is in the menu.
struct ManageRow<Badge: View, Options: View>: View {
    var title: String
    var caption: String? = nil
    /// The caption is an amount (a balance, a quantity), hidden in privacy mode.
    var captionIsPrivate = false
    var value: String? = nil
    var valueTint: Color = .primary
    /// A second amount under the value, such as a foreign balance under its dollar value.
    var valueDetail: String? = nil
    var divided = false
    var chevron = false
    var action: (() -> Void)? = nil
    @ViewBuilder var badge: () -> Badge
    @ViewBuilder var menu: () -> Options
    @Environment(UpOnlySession.self) private var session
    var body: some View {
        VStack(spacing: 0) {
            if divided { Divider().opacity(0.5) }
            HStack(spacing: 6) {
                Button { action?() } label: {
                    HStack(spacing: 10) {
                        badge()
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title).font(UpOnlyType.row.weight(.medium)).foregroundStyle(.primary).lineLimit(1).truncationMode(.middle)
                            if let caption {
                                Group { if captionIsPrivate { UpOnlyPrivateText(caption) } else { Text(caption) } }
                                    .font(UpOnlyType.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }.frame(minWidth: 96, alignment: .leading)
                        Spacer(minLength: 8)
                        if let value {
                            VStack(alignment: .trailing, spacing: 1) {
                                UpOnlyPrivateText(value).font(UpOnlyType.row.monospacedDigit()).foregroundStyle(valueTint).lineLimit(1)
                                    .minimumScaleFactor(value.count > 13 ? 0.7 : 1)
                                if let valueDetail { UpOnlyPrivateText(valueDetail).font(UpOnlyType.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1) }
                            }.layoutPriority(1)
                        }
                        if chevron { Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary) }
                    }.padding(.vertical, 8).contentShape(Rectangle())
                }.buttonStyle(UpOnlyRowButtonStyle()).disabled(action == nil)
                    .accessibilityLabel(title).accessibilityValue([session.privacyMode && captionIsPrivate ? nil : caption, session.privacyMode ? (value == nil ? nil : "Hidden value") : value, session.privacyMode ? nil : valueDetail]
                        .compactMap { $0 }.joined(separator: ", "))
                menu()
            }
        }
    }
}
/// The quiet "…" at the end of a Manage row.
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
        Button(action: action) {
            Image(systemName: "plus").font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary).frame(width: 32, height: 32).contentShape(Circle())
        }.buttonStyle(.plain).glassEffect(.regular, in: .circle).accessibilityLabel(label).help(label)
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
            Picker("Period", selection: $days) { Text("1 month").tag(30); Text("3 months").tag(90); Text("1 year").tag(365); Text("All").tag(0) }
                .pickerStyle(.segmented).labelsHidden().accessibilityLabel("Metal chart period")
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
