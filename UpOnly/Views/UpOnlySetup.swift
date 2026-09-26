import SwiftUI
import AppKit

/// Action rows wrap as a whole, keeping native button titles readable in narrow windows.
// Shared menu geometry. Content surfaces stay quiet; navigation uses native glass.
enum UpOnlyLayout {
    /// Side margin of every page in the menu panel: dashboard, Add, Manage, setup and unlock.
    static let inset: CGFloat = 16
    static let cardInset: CGFloat = 12
    static let radius: CGFloat = 14
}
/// Type roles shared by every page, so the same kind of text looks the same everywhere.
enum UpOnlyType {
    /// The dashboard's title, beside the switcher box ("All assets", a portfolio's name).
    static let pageTitle = Font.system(size: 20, weight: .semibold)
    /// Page and empty-state titles ("Which account?", "Nothing here yet").
    static let title = Font.system(size: 18, weight: .semibold)
    /// A page's own groups, above the sections inside them ("Accounts", "Crypto" on Manage).
    static let group = Font.system(size: 15, weight: .semibold)
    /// Section headings inside a page or card ("Holdings", "Bank accounts", "Transactions").
    static let section = Font.system(size: 13, weight: .semibold)
    /// Row names and row amounts.
    static let row = Font.system(size: 13)
    /// Explanations under a title or card.
    static let body = Font.system(size: 12)
    /// Captions, eyebrows and secondary row lines.
    static let caption = Font.system(size: 11)
}
struct UpOnlyPageHeader: View {
    let title: String
    var backLabel = "Back"
    /// The visible button title: "Back", or "Cancel" or "Done" when the page is an editor.
    var backTitle = "Back"
    let back: () -> Void
    var subtitle: String?
    var trailing: AnyView?
    /// The same header as the dashboard's: a small box to go back (or ✕ to cancel an editor) and the page's title
    /// beside it at the dashboard's title size, with the page's own actions on the right.
    var body: some View {
        HStack(spacing: 8) {
            Button(action: back) {
                HStack(spacing: 8) {
                    Image(systemName: backTitle == "Cancel" ? "xmark" : backTitle == "Done" ? "checkmark" : "chevron.left")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).frame(width: 26, height: 26)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(UpOnlyType.pageTitle).foregroundStyle(.primary).lineLimit(1).truncationMode(.middle)
                        if let subtitle { Text(subtitle).font(UpOnlyType.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(backLabel).help(backLabel)
            Spacer(minLength: 8)
            if let trailing { trailing }
        }.controlSize(.regular).frame(minHeight: 32)
    }
}
struct UpOnlyConfirmation: View {
    let title: String
    var detail: String = ""
    let confirmTitle: String
    var cancelTitle = "Cancel"
    let confirm: () -> Void
    let cancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(UpOnlyType.title).fixedSize(horizontal: false, vertical: true)
            if !detail.isEmpty { Text(detail).font(UpOnlyType.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 12) {
                Button(cancelTitle, action: cancel).keyboardShortcut(.cancelAction)
                Spacer(minLength: 0)
                Button(confirmTitle, role: .destructive, action: confirm)
                    .accessibilityIdentifier("ConfirmDestructiveAction")
            }.buttonStyle(.glass).controlSize(.regular)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct UpOnlyContentSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: UpOnlyLayout.radius))
            .overlay(RoundedRectangle(cornerRadius: UpOnlyLayout.radius).strokeBorder(Color.primary.opacity(0.06)))
    }
}
/// One look for problems on every page: a warning asks for a fix; an error says something failed.
struct UpOnlyNotice: View {
    enum Style { case warning, error }
    let text: String
    var style: Style
    init(_ text: String, style: Style = .warning) { self.text = text; self.style = style }
    var body: some View {
        Label(text, systemImage: style == .warning ? "exclamationmark.triangle" : "xmark.octagon")
            .font(UpOnlyType.body).foregroundStyle(style == .warning ? Color.orange : Color(nsColor: .systemRed))
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct UpOnlyFlow: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.reduce(CGFloat.zero) { $0 + $1.sizeThatFits(.unspecified).width + spacing }
        let positions = positions(width: width, subviews: subviews)
        return CGSize(width: width, height: positions.map { $0.0.y + $0.1.height }.max() ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, item) in positions(width: bounds.width, subviews: subviews).enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + item.0.x, y: bounds.minY + item.0.y), proposal: ProposedViewSize(item.1))
        }
    }
    private func positions(width: CGFloat, subviews: Subviews) -> [(CGPoint, CGSize)] {
        var result: [(CGPoint, CGSize)] = [], x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let ideal = view.sizeThatFits(.unspecified)
            let size = view.sizeThatFits(ProposedViewSize(width: min(ideal.width, width), height: nil))
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            result.append((CGPoint(x: x, y: y), size)); x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return result
    }
}

extension TrackedKind {
    var title: String { switch self { case .banks: "Bank accounts"; case .crypto: "Crypto"; case .metals: "Metals"; case .cashFlow: "Income & spending" } }
    var summary: String { switch self { case .banks: "Your dated balances, in one place."; case .crypto: "Coins and quantities across portfolios."; case .metals: "Gold and silver."; case .cashFlow: "What comes in and what goes out." } }
    var symbol: String { switch self { case .banks: "building.columns.fill"; case .crypto: "bitcoinsign.circle.fill"; case .metals: "square.stack.3d.up.fill"; case .cashFlow: "arrow.up.arrow.down.circle.fill" } }
    var tint: Color { switch self { case .banks: UpOnlyTint.netWorth; case .crypto: UpOnlyTint.crypto; case .metals: UpOnlyTint.metals; case .cashFlow: UpOnlyTint.cashFlow } }
}
struct UpOnlySymbolBadge: View {
    var symbol: String
    var tint: Color = UpOnlyTint.netWorth
    var size: CGFloat = 36
    var body: some View {
        Image(systemName: symbol).font(.system(size: size * 0.48, weight: .medium))
            .foregroundStyle(tint).frame(width: size, height: size)
            .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: size * 0.28))
            .accessibilityHidden(true)
    }
}
struct UpOnlySetupHeader: View {
    var step: Int
    var total = 2
    var symbol: String
    var tint: Color = UpOnlyTint.netWorth
    var title: String
    var subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                UpOnlyBrandMark(width: 20).foregroundStyle(.primary)
                Label("Step \(step) of \(total)", systemImage: symbol)
                    .font(UpOnlyType.caption.weight(.medium)).foregroundStyle(tint)
                Spacer()
                HStack(spacing: 5) {
                    ForEach(1...total, id: \.self) { value in
                        Capsule().fill(value == step ? tint : Color.secondary.opacity(0.2)).frame(width: value == step ? 18 : 6, height: 6)
                    }
                }.accessibilityHidden(true)
            }
            Text(title).fixedSize(horizontal: false, vertical: true).font(.system(size: 22, weight: .semibold)).tracking(-0.4).fixedSize(horizontal: false, vertical: true)
            if !subtitle.isEmpty { Text(subtitle).fixedSize(horizontal: false, vertical: true).font(UpOnlyType.body).foregroundStyle(.secondary) }
        }
    }
}
struct UpOnlyRecoveryCodeCard: View {
    let code: RecoveryCode
    @State private var copied = false
    private var formatted: String {
        let groups = code.canonical.split(separator: "-")
        return stride(from: 0, to: groups.count, by: 2).map { groups[$0...min($0 + 1, groups.count - 1)].joined(separator: "-") }.joined(separator: "\n")
    }
    var body: some View {
        VStack(spacing: 10) {
            Text(formatted).fixedSize(horizontal: false, vertical: true).font(.system(size: 14, weight: .medium, design: .monospaced)).lineSpacing(3)
                .textSelection(.enabled).fixedSize().accessibilityLabel("Recovery code, " + code.canonical)
            Button(action: copy) { Label(copied ? "Copied" : "Copy recovery code", systemImage: copied ? "checkmark" : "doc.on.doc").fixedSize(horizontal: false, vertical: true) }
                .controlSize(.small).help("Clears from the clipboard after a minute.")
        }.padding(UpOnlyLayout.cardInset).frame(maxWidth: .infinity)
            .modifier(UpOnlyContentSurface())
            .task(id: copied) { if copied { try? await Task.sleep(for: .seconds(2)); if !Task.isCancelled { copied = false } } }
    }
    /// The code is marked concealed and transient so clipboard managers and history skip it,
    /// and it is cleared after a minute unless something else has been copied since.
    private func copy() {
        let pasteboard = NSPasteboard.general
        let markers = [NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"), NSPasteboard.PasteboardType("org.nspasteboard.TransientType")]
        pasteboard.declareTypes([NSPasteboard.PasteboardType.string] + markers, owner: nil)
        copied = pasteboard.setString(code.canonical, forType: .string)
        for marker in markers { pasteboard.setData(Data(), forType: marker) }
        let change = pasteboard.changeCount
        // Not tied to the view: the code must still be cleared after the user moves on.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(60))
            if NSPasteboard.general.changeCount == change { NSPasteboard.general.clearContents() }
        }
    }
}
struct UpOnlySetup: View {
    @Environment(UpOnlySession.self) private var session
    @State private var automatic = true
    @State private var error: String?
    @State private var saving = false
    private var progress: SetupProgress { SetupProgress(step: 1, tracked: TrackedKind.allCases, prices: false, fx: automatic, metals: automatic) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            UpOnlySetupHeader(step: 2, symbol: "arrow.triangle.2.circlepath", title: "Keep values current",
                              subtitle: "Up Only can fetch reference exchange rates and gold and silver prices while it runs. Your balances never leave this Mac.")
            HStack(spacing: 10) {
                UpOnlySymbolBadge(symbol: "arrow.triangle.2.circlepath", size: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Automatic prices and exchange rates").font(UpOnlyType.row.weight(.medium))
                    Text(automatic ? "Updates while the app runs." : "You can turn this on later in Manage.").font(UpOnlyType.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Toggle("Automatic prices and exchange rates", isOn: $automatic).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .accessibilityIdentifier("AutomaticSources")
            }.padding(UpOnlyLayout.cardInset).frame(maxWidth: .infinity).modifier(UpOnlyContentSurface())
            Text("Prices and rates come from Binance, CoinGecko, Gold API and Frankfurter. They see coin tickers and currency codes, never your amounts.")
                .font(UpOnlyType.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 9) {
                Button { Task { await finish(addData: true) } } label: {
                    Text("Add your first balance").frame(maxWidth: .infinity)
                }.buttonStyle(.glassProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                Button { Task { await finish(addData: false) } } label: {
                    Text("Skip for now").frame(maxWidth: .infinity)
                }.buttonStyle(.bordered).controlSize(.large)
            }.disabled(saving || session.isBusy)
            if let error { UpOnlyNotice(error, style: .error) }
            if let message = session.setupProgressMessage {
                UpOnlyNotice(message)
                Button("Save progress again") { session.checkpointSetup(progress) }.buttonStyle(.bordered).controlSize(.small)
            }
            if saving { ProgressView().controlSize(.small) }
        }.padding(UpOnlyLayout.inset).frame(maxWidth: 380).fixedSize(horizontal: false, vertical: true)
            .onChange(of: automatic) { _, _ in session.checkpointSetup(progress) }
            .onAppear {
                if let saved = session.document?.settings.setupProgress, saved.step > 0 { automatic = saved.fx || saved.metals }
            }
    }
    private func finish(addData: Bool) async {
        guard !saving, !session.isBusy else { return }
        saving = true; error = nil
        defer { saving = false }
        let token = session.sessionToken
        do {
            try await session.completeSetup(tracked: TrackedKind.allCases, prices: automatic, fx: automatic, key: "", metals: automatic)
            guard token == session.sessionToken else { return }
            if addData { session.addingInMenu = true }
        } catch { if token == session.sessionToken { self.error = "Setup could not be saved. Please try again." } }
    }
}
/// One data source as a row: what it is, whether it's delivering, and its switch. How often it updates, or what went
/// wrong, is the tooltip.
struct UpOnlySourceRow: View {
    enum Kind: Hashable { case wise, crypto, metals, fx }
    let kind: Kind
    @Binding var isOn: Bool
    var divided = false
    @Environment(UpOnlySession.self) private var session
    private var title: String {
        switch kind { case .wise: "Wise"; case .crypto: "Crypto prices"; case .metals: "Gold & silver prices"; case .fx: "Exchange rates" }
    }
    private var symbol: String {
        switch kind { case .wise: "building.columns.fill"; case .crypto: "bitcoinsign.circle.fill"; case .metals: "square.stack.3d.up.fill"; case .fx: "arrow.triangle.2.circlepath" }
    }
    private var tint: Color { kind == .crypto ? UpOnlyTint.crypto : kind == .metals ? UpOnlyTint.metals : UpOnlyTint.netWorth }
    private var interval: String { kind == .wise ? "Updates every 12 hours" : kind == .fx ? "Updates every 15 minutes" : "Updates every hour" }
    private var savedOn: Bool {
        guard let settings = session.document?.settings else { return false }
        switch kind {
        case .wise:
            #if UPONLY_PERSONAL
            return settings.automaticWise
            #else
            return false
            #endif
        case .crypto: return settings.automaticPrices
        case .metals: return settings.automaticMetals
        case .fx: return settings.automaticFX
        }
    }
    private var lastUpdate: Date? {
        guard let doc = session.document else { return nil }
        switch kind {
        case .wise: return doc.bankBalances.filter { $0.source == "Wise" }.map(\.observedAt).max()
        case .crypto: return doc.quotes.filter { PreciousMetal.asset($0.assetID) == nil && ($0.provider.hasPrefix("CoinGecko") || $0.provider.hasPrefix("Binance")) }.map(\.fetchedAt).max()
        case .metals: return doc.quotes.filter { PreciousMetal.asset($0.assetID) != nil }.map(\.fetchedAt).max()
        // Wise's rates count as much as Frankfurter's: with Wise on, it's the one asked first.
        case .fx: return doc.fx.filter { $0.provider.hasPrefix("Frankfurter") || $0.provider.hasPrefix("Wise") }.map(\.fetchedAt).max()
        }
    }
    private var problem: String? {
        switch kind {
        case .wise:
            #if UPONLY_PERSONAL
            if let error = session.wiseError { return error }
            #endif
            return session.backgroundIssues.contains("Bank balances") ? "The last background sync failed." : nil
        case .crypto: return session.sourceIssues["crypto"] ?? (session.backgroundIssues.contains(where: { $0.hasPrefix("Crypto") }) ? "The last price update failed." : nil)
        case .metals: return session.sourceIssues["metals"] ?? (session.backgroundIssues.contains(where: { $0.hasPrefix("Metals") }) ? "The last price update failed." : nil)
        case .fx: return session.sourceIssues["fx"] ?? (session.backgroundIssues.contains(where: { $0.hasPrefix("Exchange rates") }) ? "The last rate update failed." : nil)
        }
    }
    /// Metal prices are only fetched for gold or silver you hold, so without any there's nothing to wait for.
    private var nothingToPrice: Bool {
        guard kind == .metals, let doc = session.document else { return false }
        let now = Date()
        return !doc.holdings.contains { PreciousMetal.asset($0.assetID) != nil && $0.isActive(at: now) }
    }
    private var busy: Bool {
        #if UPONLY_PERSONAL
        if kind == .wise { return session.wiseRefreshing }
        #endif
        return session.refreshing
    }
    private var status: (color: Color, text: String) {
        let last = lastUpdate, when = lastUpdate?.formatted(.relative(presentation: .named)) ?? ""
        if !savedOn { return (Color.secondary.opacity(0.5), "Off") }
        if busy { return (.secondary, "Updating…") }
        if nothingToPrice { return (Color.secondary.opacity(0.5), "Nothing to price yet") }
        if problem != nil { return (Color(nsColor: .systemRed), "Couldn’t update" + (last == nil ? "" : " · last " + when)) }
        guard let last else { return (Color(nsColor: .systemOrange), "Waiting for the first update") }
        let stale = Date().timeIntervalSince(last) > (kind == .wise ? 36 : 3) * 3600
        return (stale ? Color(nsColor: .systemOrange) : UpOnlyTint.cashFlow, "Updated " + when)
    }
    var body: some View {
        let status = self.status
        VStack(spacing: 0) {
            if divided { Divider().opacity(0.5) }
            HStack(spacing: 10) {
                UpOnlySymbolBadge(symbol: symbol, tint: tint, size: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(UpOnlyType.row.weight(.medium)).lineLimit(1)
                    HStack(spacing: 5) {
                        Circle().fill(status.color).frame(width: 6, height: 6).accessibilityHidden(true)
                        Text(status.text).font(UpOnlyType.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }.padding(.vertical, 9).contentShape(Rectangle()).help(problem ?? interval)
                .accessibilityElement(children: .combine)
        }
    }
}

struct UpOnlySources: View {
    @Binding var pendingChanges: Bool
    /// Inside Settings, which scrolls and pads its own page; on its own, the list scrolls and pads itself.
    var embedded = false
    @Environment(UpOnlySession.self) private var session
    @State private var wise = false
    @State private var prices = false
    @State private var fx = false
    @State private var metals = false
    @State private var message: String?
    @State private var failure: String?
    @State private var loaded = false
    private var hasChanges: Bool {
        guard let settings = session.document?.settings else { return false }
        #if UPONLY_PERSONAL
        if wise != settings.automaticWise { return true }
        #endif
        return prices != settings.automaticPrices || fx != settings.automaticFX || metals != settings.automaticMetals
    }
    /// The sources for what you track, in one list.
    private var kinds: [UpOnlySourceRow.Kind] {
        guard let doc = session.document else { return [] }
        var kinds: [UpOnlySourceRow.Kind] = []
        #if UPONLY_PERSONAL
        kinds.append(.wise)
        #endif
        if doc.shows(.crypto) { kinds.append(.crypto) }
        if doc.shows(.metals) { kinds.append(.metals) }
        if doc.shows(.banks) || doc.shows(.cashFlow) { kinds.append(.fx) }
        return kinds
    }
    private func binding(_ kind: UpOnlySourceRow.Kind) -> Binding<Bool> {
        switch kind { case .wise: $wise; case .crypto: $prices; case .metals: $metals; case .fx: $fx }
    }
    var body: some View {
        Group {
            if embedded { list } else {
                UpOnlyMenuScroll { list.padding(.horizontal, UpOnlyLayout.inset).padding(.bottom, UpOnlyLayout.inset) }
            }
        }.task(id: message) {
            if message == "Changes saved." { try? await Task.sleep(for: .seconds(2)); if !Task.isCancelled { message = nil } }
        }.onChange(of: hasChanges) { _, changed in pendingChanges = changed }
        // Switches save themselves. No source asks for a key: the app's providers work without one.
        .onChange(of: wise) { if loaded { save() } }
        .onChange(of: fx) { if loaded { save() } }
        .onChange(of: metals) { if loaded { save() } }
        .onChange(of: prices) { if loaded { save() } }
        .onAppear {
            if let settings = session.document?.settings {
                #if UPONLY_PERSONAL
                wise = settings.automaticWise
                #endif
                prices = settings.automaticPrices; fx = settings.automaticFX; metals = settings.automaticMetals }
            Task { @MainActor in loaded = true }
        }
    }
    private var list: some View {
        VStack(alignment: .leading, spacing: 12) {
            let kinds = self.kinds
            if kinds.isEmpty {
                Text("Add an account or holding to see price options.").font(UpOnlyType.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                ManageCard {
                    ForEach(Array(kinds.enumerated()), id: \.element) { index, kind in UpOnlySourceRow(kind: kind, isOn: binding(kind), divided: index > 0) }
                }
                // The arrow turns while anything is updating.
                Button(action: updateNow) {
                    Label { Text(session.refreshing ? "Updating…" : "Update now") } icon: {
                        Image(systemName: "arrow.clockwise").symbolEffect(.rotate, options: .repeat(.continuous), isActive: session.refreshing)
                    }.frame(maxWidth: .infinity)
                }
                    .buttonStyle(.bordered).controlSize(.large).disabled(session.isBusy || session.refreshing)
            }
            if let failure { UpOnlyNotice(failure, style: .error) }
            else if let status = message ?? session.sourceMessage {
                Text(status).font(UpOnlyType.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !kinds.isEmpty {
                Text(sourcesNote).font(UpOnlyType.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    /// Everything switched on, now: Wise, then prices and rates.
    private func updateNow() {
        Task {
            #if UPONLY_PERSONAL
            if session.document?.settings.automaticWise == true { await session.refreshWise() }
            #endif
            await session.refreshPrices()
        }
    }
    /// Where the data comes from, and what those services learn.
    private var sourcesNote: String {
        #if UPONLY_PERSONAL
        let rates = "Wise and Frankfurter"
        #else
        let rates = "Frankfurter"
        #endif
        return "Prices come from Binance, CoinGecko and Gold API, and exchange rates from " + rates + ". They see coin tickers and currency codes, never your amounts."
    }
    /// The one save path. A key saved by an earlier version is kept as it was; nothing here asks for one.
    private func save() {
        guard let settings = session.document?.settings else { return }
        #if UPONLY_PERSONAL
        let wiseChanged = wise != settings.automaticWise
        #else
        let wiseChanged = false
        #endif
        guard wiseChanged || prices != settings.automaticPrices || fx != settings.automaticFX || metals != settings.automaticMetals else { return }
        Task {
            failure = nil
            do { try await session.saveSources(prices: prices, fx: fx, key: settings.coinGeckoKey, metals: metals, metalKey: settings.metalHistoryKey, wise: wise); message = "Changes saved." }
            catch { failure = error.localizedDescription }
        }
    }
}

struct UpOnlyProfileImage: View {
    var data: Data?
    var name: String
    var size: CGFloat = 28
    var body: some View {
        Group {
            if let data, let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFill() }
            else { Text(String(name.split(separator: " ").prefix(2).compactMap(\.first))).fixedSize(horizontal: false, vertical: true).font(.system(size: size * 0.36, weight: .semibold)).foregroundStyle(UpOnlyTint.netWorth).frame(maxWidth: .infinity, maxHeight: .infinity).background(UpOnlyTint.netWorth.opacity(0.12)) }
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.3)).accessibilityHidden(true)
    }
}
