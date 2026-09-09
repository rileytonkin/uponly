import SwiftUI
import AppKit

/// Action rows wrap as a whole, keeping native button titles readable in narrow windows.
// Shared menu geometry. Content surfaces stay quiet; navigation uses native glass.
enum UpOnlyLayout {
    static let inset: CGFloat = 16
    static let cardInset: CGFloat = 12
    static let radius: CGFloat = 14
}
struct UpOnlyPageHeader: View {
    let title: String
    var backLabel = "Back"
    var profileImage: Data?
    let back: () -> Void
    var subtitle: String?
    var trailing: AnyView?
    var body: some View {
        HStack(spacing: 12) {
            Button(action: back) { Label("Back", systemImage: "chevron.left") }
                .buttonStyle(.glass).accessibilityLabel(backLabel)
            if let profileImage { UpOnlyProfileImage(data: profileImage, name: title, size: 24) }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 0)
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
            Text(title).font(.system(size: 18, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            if !detail.isEmpty { Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
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
    var title: String { switch self { case .banks: "Bank accounts"; case .crypto: "Crypto"; case .metals: "Gold & silver"; case .cashFlow: "Income & spending" } }
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
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(tint)
                Spacer()
                HStack(spacing: 5) {
                    ForEach(1...total, id: \.self) { value in
                        Capsule().fill(value == step ? tint : Color.secondary.opacity(0.2)).frame(width: value == step ? 18 : 6, height: 6)
                    }
                }.accessibilityHidden(true)
            }
            Text(title).fixedSize(horizontal: false, vertical: true).font(.system(size: 22, weight: .semibold)).tracking(-0.4).fixedSize(horizontal: false, vertical: true)
            if !subtitle.isEmpty { Text(subtitle).fixedSize(horizontal: false, vertical: true).font(.system(size: 12)).foregroundStyle(.secondary) }
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
            Button {
                NSPasteboard.general.clearContents()
                copied = NSPasteboard.general.setString(code.canonical, forType: .string)
            } label: { Label(copied ? "Copied" : "Copy recovery code", systemImage: copied ? "checkmark" : "doc.on.doc").fixedSize(horizontal: false, vertical: true) }
                .controlSize(.small)
        }.padding(14).frame(maxWidth: .infinity)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.15)))
            .task(id: copied) { if copied { try? await Task.sleep(for: .seconds(2)); if !Task.isCancelled { copied = false } } }
    }
}
struct UpOnlySetup: View {
    @Environment(UpOnlySession.self) private var session
    @State private var automatic = true
    @State private var error: String?
    @State private var saving = false
    @State private var showSourceDetails = false
    private var progress: SetupProgress { SetupProgress(step: 1, tracked: TrackedKind.allCases, prices: false, fx: automatic, metals: automatic) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            UpOnlySetupHeader(step: 2, symbol: "arrow.triangle.2.circlepath", title: "Keep values current",
                              subtitle: "Up Only can fetch reference exchange rates and gold and silver prices while it runs. Your balances never leave this Mac.")
            HStack(spacing: 10) {
                UpOnlySymbolBadge(symbol: "arrow.triangle.2.circlepath", tint: UpOnlyTint.cashFlow, size: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Automatic prices and exchange rates").font(.system(size: 13, weight: .medium))
                    Text(automatic ? "Updates while the app runs." : "You can turn this on later in Manage.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Toggle("Automatic prices and exchange rates", isOn: $automatic).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .accessibilityIdentifier("AutomaticSources")
            }.padding(12).frame(maxWidth: .infinity).modifier(UpOnlyContentSurface())
            DisclosureGroup("What providers receive", isExpanded: $showSourceDetails) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Frankfurter receives currency codes. Gold API receives metal symbols. Both see your IP address; neither receives balances, quantities or names.")
                    Text("Crypto prices need a free CoinGecko key. Up Only asks for it when you add your first coin, or in Manage → Prices & rates.")
                }.font(.system(size: 12)).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            }.font(.system(size: 12)).foregroundStyle(.secondary)
            VStack(spacing: 9) {
                Button { Task { await finish(addData: true) } } label: {
                    Text("Add your first balance").frame(maxWidth: .infinity)
                }.buttonStyle(.glassProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                Button { Task { await finish(addData: false) } } label: {
                    Text("Do this later").frame(maxWidth: .infinity)
                }.buttonStyle(.bordered).controlSize(.large)
            }.disabled(saving || session.isBusy)
            if let error { Text(error).fixedSize(horizontal: false, vertical: true).font(.caption).foregroundStyle(.red) }
            if let message = session.setupProgressMessage {
                Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                Button("Save progress again") { session.checkpointSetup(progress) }.buttonStyle(.bordered).font(.caption)
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
            try await session.completeSetup(tracked: TrackedKind.allCases, prices: false, fx: automatic, key: "", metals: automatic)
            guard token == session.sessionToken else { return }
            if addData { session.addingInMenu = true }
        } catch { if token == session.sessionToken { self.error = "Setup could not be saved. Please try again." } }
    }
}
struct UpOnlySettingsCard<Content: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    var tint = UpOnlyTint.netWorth
    var isOn: Binding<Bool>?
    var controlDisabled = false
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                UpOnlySymbolBadge(symbol: symbol, tint: tint, size: 36)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    if !subtitle.isEmpty { Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if let isOn {
                    Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .disabled(controlDisabled).padding(.top, 4)
                }
            }
            content()
        }.padding(UpOnlyLayout.cardInset).frame(maxWidth: .infinity, alignment: .leading)
            .modifier(UpOnlyContentSurface())
    }
}

/// Whether a live source is actually delivering data, not just switched on.
struct UpOnlySourceStatus: View {
    enum Kind { case wise, crypto, metals, fx }
    let kind: Kind
    let savedOn: Bool
    /// How often the source updates on its own, shown under the status.
    var interval = "Updates every hour"
    /// Runs a manual update; nil hides the button.
    var refresh: (() -> Void)?
    var refreshDisabled = false
    @Environment(UpOnlySession.self) private var session
    private var lastUpdate: Date? {
        guard let doc = session.document else { return nil }
        switch kind {
        case .wise: return doc.bankBalances.filter { $0.source == "Wise" }.map(\.observedAt).max()
        case .crypto: return doc.quotes.filter { $0.provider.hasPrefix("CoinGecko") }.map(\.fetchedAt).max()
        case .metals: return doc.quotes.filter { $0.provider.hasPrefix("Gold API") }.map(\.fetchedAt).max()
        case .fx: return doc.fx.filter { $0.provider.hasPrefix("Frankfurter") }.map(\.fetchedAt).max()
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
    private var busy: Bool {
        #if UPONLY_PERSONAL
        if kind == .wise { return session.wiseRefreshing }
        #endif
        return session.refreshing
    }
    var body: some View {
        let last = lastUpdate
        let stale = last.map { Date().timeIntervalSince($0) > (kind == .wise ? 36 : 3) * 3600 } ?? true
        let (color, text): (Color, String) = {
            if !savedOn { return (.secondary, "Off") }
            if busy { return (.secondary, "Updating…") }
            if let problem { return (Color(nsColor: .systemRed), "Not receiving data. " + problem) }
            guard let last else { return (Color(nsColor: .systemOrange), "Waiting for first data") }
            let when = last.formatted(.relative(presentation: .named))
            return stale ? (Color(nsColor: .systemOrange), "Last data " + when) : (UpOnlyTint.cashFlow, "Connected · updated " + when)
        }()
        return HStack(alignment: .center, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(text).font(.system(size: 12)).foregroundStyle(savedOn ? .primary : .secondary).fixedSize(horizontal: false, vertical: true)
                    if savedOn { Text(interval).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
            }.accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            if savedOn, let refresh {
                Button(action: refresh) { Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(.bordered).controlSize(.small).disabled(refreshDisabled || busy)
                    .help("Update now").accessibilityLabel("Update now")
            }
        }
    }
}

struct UpOnlySources: View {
    @Binding var pendingChanges: Bool
    @Environment(UpOnlySession.self) private var session
    @State private var wise = false
    @State private var prices = false
    @State private var fx = false
    @State private var metals = false
    @State private var metalKey = ""
    @State private var key = ""
    @State private var message: String?
    @State private var loaded = false
    private var showsCrypto: Bool { session.document?.shows(.crypto) == true }
    private var showsFX: Bool { session.document?.shows(.banks) == true || session.document?.shows(.cashFlow) == true }
    private var hasChanges: Bool {
        guard let settings = session.document?.settings else { return false }
        #if UPONLY_PERSONAL
        if wise != settings.automaticWise { return true }
        #endif
        return prices != settings.automaticPrices || fx != settings.automaticFX || key != settings.coinGeckoKey || metals != settings.automaticMetals || metalKey != settings.metalHistoryKey
    }
    var body: some View {
        UpOnlyMenuScroll {
        VStack(alignment: .leading, spacing: 16) {

            #if UPONLY_PERSONAL
            UpOnlySettingsCard(title: "Wise", subtitle: "Balances and transactions from your linked profiles.",
                               symbol: "building.columns.fill", tint: UpOnlyTint.netWorth,
                               isOn: $wise,
                               controlDisabled: session.isBusy) {
                UpOnlySourceStatus(kind: .wise, savedOn: session.document?.settings.automaticWise == true, interval: "Updates every 12 hours",
                                   refresh: { Task { await session.refreshWise() } },
                                   refreshDisabled: session.isBusy || session.document?.settings.automaticWise != true)
                HStack(alignment: .top, spacing: 16) {
                    ForEach(session.wiseProfiles) { profile in
                        VStack(spacing: 7) {
                            UpOnlyProfileImage(data: profile.image, name: profile.name, size: 38)
                            Text(profile.name).font(.system(size: 12, weight: .medium)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity)
                    }
                }.padding(.vertical, 3)
                if let message = session.wiseMessage { Text(message).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                DisclosureGroup("About your Wise connection") {
                    Text("Balances come directly from Wise. Completed transactions are kept up to date, with transfers between your linked profiles excluded from cash flow. Review other transfers in Transactions.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
            #endif
            if showsCrypto {
                UpOnlySettingsCard(title: "Crypto prices", subtitle: "Current USD prices for the coins you track.",
                                   symbol: "bitcoinsign.circle.fill", tint: UpOnlyTint.crypto, isOn: $prices,
                                   controlDisabled: session.isBusy) {
                    UpOnlySourceStatus(kind: .crypto, savedOn: session.document?.settings.automaticPrices == true, interval: "Updates every hour",
                                       refresh: { Task { await session.refreshPrices() } }, refreshDisabled: session.isBusy)
                    if prices {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("CoinGecko Demo API key").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            SecureField("Paste your Demo API key", text: $key).textFieldStyle(.roundedBorder).onSubmit { save() }
                            UpOnlyFlow(spacing: 8) {
                                if key != session.document?.settings.coinGeckoKey {
                                    Button("Save key") { save() }.buttonStyle(.glassProminent).controlSize(.small)
                                        .disabled(session.isBusy || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                }
                                Link("Get a free Demo key", destination: URL(string: "https://www.coingecko.com/en/api/pricing")!).font(.system(size: 12)).buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                    }
                    DisclosureGroup("What CoinGecko receives") {
                        Text("Coin IDs, your API key and network information. Your quantities, portfolio names and balances stay private.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if session.document?.shows(.metals) == true {
                UpOnlySettingsCard(title: "Gold & silver prices", subtitle: "Estimated market value of your metals.", symbol: "square.stack.3d.up.fill", tint: UpOnlyTint.metals, isOn: $metals, controlDisabled: session.isBusy) {
                    UpOnlySourceStatus(kind: .metals, savedOn: session.document?.settings.automaticMetals == true, interval: "Updates every hour",
                                       refresh: { Task { await session.refreshPrices() } }, refreshDisabled: session.isBusy)
                    if metals {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Gold API history key (optional)").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            SecureField("Paste your history key", text: $metalKey).textFieldStyle(.roundedBorder).onSubmit { save() }
                            UpOnlyFlow(spacing: 8) {
                                if metalKey != session.document?.settings.metalHistoryKey {
                                    Button("Save key") { save() }.buttonStyle(.glassProminent).controlSize(.small).disabled(session.isBusy)
                                }
                                Link("Get a free history key", destination: URL(string: "https://gold-api.com/pricing")!).font(.system(size: 12)).buttonStyle(.bordered).controlSize(.small)
                            }
                            Text("Live prices need no key and are saved on this Mac every hour, building your own price history. A key only fills gaps from time offline. Your weights and storage locations stay private.")
                                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if showsFX {
                UpOnlySettingsCard(title: "Exchange rates", subtitle: "Convert your balances and cash flow to USD.",
                                   symbol: "arrow.triangle.2.circlepath", tint: UpOnlyTint.cashFlow, isOn: $fx,
                                   controlDisabled: session.isBusy) {
                    UpOnlySourceStatus(kind: .fx, savedOn: session.document?.settings.automaticFX == true, interval: "Updates every 15 minutes",
                                       refresh: { Task { await session.refreshPrices() } }, refreshDisabled: session.isBusy)
                    DisclosureGroup("About exchange rates") {
                        Text("Frankfurter provides reference rates and receives currency codes and network information. Your balances stay private. Historical entries need a rate dated near the end of their month.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if let status = message ?? session.sourceMessage {
                Text(status).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if prices && key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Add a CoinGecko key, or turn Crypto prices off to save.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            sourceActions
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }.task(id: message) {
            if message == "Changes saved." { try? await Task.sleep(for: .seconds(2)); if !Task.isCancelled { message = nil } }
        }.onChange(of: hasChanges) { _, changed in pendingChanges = changed }
        // Switches save themselves. Keys save on Return or with Save key, since a half-typed key must not be stored.
        .onChange(of: wise) { if loaded { save() } }
        .onChange(of: fx) { if loaded { save() } }
        .onChange(of: metals) { if loaded { save() } }
        .onChange(of: prices) { _, on in if loaded, !on || !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { save() } }
        .onAppear {
            if let settings = session.document?.settings {
                #if UPONLY_PERSONAL
                wise = settings.automaticWise
                #endif
                prices = settings.automaticPrices; fx = settings.automaticFX; key = settings.coinGeckoKey; metals = settings.automaticMetals; metalKey = settings.metalHistoryKey }
            Task { @MainActor in loaded = true }
        }
    }
    private func save() {
        guard hasChanges, !(prices && key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) else { return }
        Task {
            do { try await session.saveSources(prices: prices, fx: fx, key: key, metals: metals, metalKey: metalKey, wise: wise); message = "Changes saved." }
            catch { message = error.localizedDescription }
        }
    }
    @ViewBuilder private var sourceActions: some View {
            if showsCrypto || showsFX || session.document?.shows(.metals) == true {
                UpOnlyFlow(spacing: 12) {
                    if hasChanges {
                    Button("Save changes") { Task {
                        do { try await session.saveSources(prices: prices, fx: fx, key: key, metals: metals, metalKey: metalKey, wise: wise); message = "Changes saved." }
                        catch { message = error.localizedDescription }
                    } }.buttonStyle(.glassProminent)
                        .disabled(session.isBusy || !hasChanges || (prices && key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                    }
                }.padding(.top, 4)
            } else {
                Text("Add an account or holding to see price options.").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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

struct UpOnlyMonthPicker: View {
    @Binding var month: MonthKey
    private var current: MonthKey { .current() }
    var body: some View {
        HStack(spacing: 12) {
            Picker("Month", selection: Binding(get: { month.month }, set: { month = MonthKey(year: month.year, month: $0) })) {
                ForEach(1...(month.year == current.year ? current.month : 12), id: \.self) { value in
                    Text(DateFormatter().monthSymbols[value - 1]).tag(value)
                }
            }.accessibilityLabel("Entry month")
            Picker("Year", selection: Binding(get: { month.year }, set: { value in month = MonthKey(year: value, month: value == current.year ? min(month.month, current.month) : month.month) })) {
                ForEach((1900...current.year).reversed(), id: \.self) { Text(String($0)).tag($0) }
            }.accessibilityLabel("Entry year")
        }
    }
}

/// Full-card actions keep one visible outline, with the same native control states.
struct UpOnlyCardButtonStyle: ButtonStyle {
    var radius: CGFloat = 12
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(.primary.opacity(isEnabled ? 0.22 : 0.10)))
            .background(.primary.opacity(configuration.isPressed ? 0.08 : 0), in: RoundedRectangle(cornerRadius: radius))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
    }
}
