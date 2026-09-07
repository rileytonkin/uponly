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
    let back: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Button(action: back) { Label("Back", systemImage: "chevron.left") }
                .buttonStyle(.glass).accessibilityLabel(backLabel)
            Text(title).font(.system(size: 14, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
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
    var title: String { switch self { case .banks: "Bank accounts"; case .crypto: "Crypto"; case .metals: "Precious metals"; case .cashFlow: "Income & spending" } }
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
    var symbol: String
    var tint: Color = UpOnlyTint.netWorth
    var title: String
    var subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                UpOnlyBrandMark(width: 20).foregroundStyle(.primary)
                Label("Step \(step) of 3", systemImage: symbol)
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(tint)
                Spacer()
                HStack(spacing: 5) {
                    ForEach(1...3, id: \.self) { value in
                        Capsule().fill(value == step ? tint : Color.secondary.opacity(0.2)).frame(width: value == step ? 18 : 6, height: 6)
                    }
                }.accessibilityHidden(true)
            }
            Text(title).fixedSize(horizontal: false, vertical: true).font(.system(size: 22, weight: .semibold)).tracking(-0.4).fixedSize(horizontal: false, vertical: true)
            if !subtitle.isEmpty { Text(subtitle).fixedSize(horizontal: false, vertical: true).font(.system(size: 12)).foregroundStyle(.secondary) }
        }
    }
}
struct UpOnlyKindCard: View {
    var kind: TrackedKind
    var selected: Bool
    var action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                UpOnlySymbolBadge(symbol: kind.symbol, tint: kind.tint, size: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(kind.title).fixedSize(horizontal: false, vertical: true).font(.system(size: 13, weight: .semibold))
                    Text(kind.summary).fixedSize(horizontal: false, vertical: true).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? kind.tint : Color.secondary.opacity(0.4))
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? kind.tint.opacity(0.07) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? kind.tint.opacity(0.5) : Color.secondary.opacity(0.13)))
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(UpOnlyCardButtonStyle(radius: 12)).accessibilityLabel(kind.title).accessibilityHint(kind.summary)
            .accessibilityIdentifier("Track-" + kind.rawValue).accessibilityAddTraits(selected ? .isSelected : [])
            .animation(reduceMotion ? nil : .snappy, value: selected)
    }
}
struct UpOnlySourceRow: View {
    var symbol: String
    var tint: Color
    var title: String
    @Binding var isOn: Bool
    var key: Binding<String>?
    var keyPrompt = ""
    var keyLinkTitle = ""
    var keyLink: URL?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                UpOnlySymbolBadge(symbol: symbol, tint: tint, size: 26)
                Text(title).font(.system(size: 13, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true).accessibilityHidden(true)
                Spacer(minLength: 8)
                Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            if isOn, let key {
                SecureField(keyPrompt, text: key).textFieldStyle(.roundedBorder)
                if let keyLink {
                    Link(keyLinkTitle, destination: keyLink).font(.system(size: 11)).buttonStyle(.bordered).controlSize(.small)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }.padding(12)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = 0
    @State private var tracked: Set<TrackedKind> = []
    @State private var prices = false
    @State private var fx = false
    @State private var metals = false
    @State private var metalKey = ""
    @State private var key = ""
    @State private var error: String?
    @State private var saving = false
    @State private var showSourceDetails = false
    private var wantsCrypto: Bool { tracked.contains(.crypto) }
    private var wantsFX: Bool { tracked.contains(.banks) || tracked.contains(.cashFlow) }
    private var progress: SetupProgress { SetupProgress(step: step, tracked: TrackedKind.normalized(tracked), prices: prices, fx: fx, metals: metals, coinGeckoKey: key, metalHistoryKey: metalKey) }
    private var cannotFinish: Bool { saving || session.isBusy || (wantsCrypto && prices && key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if step == 0 {
                UpOnlySetupHeader(step: 2, symbol: "square.grid.2x2.fill", title: "What do you want to track?", subtitle: "")
                VStack(spacing: 8) {
                    ForEach(TrackedKind.allCases, id: \.self) { kind in
                        UpOnlyKindCard(kind: kind, selected: tracked.contains(kind)) {
                            if tracked.contains(kind) { tracked.remove(kind) } else { tracked.insert(kind) }
                        }
                    }
                }
                Text("Choose at least one.").fixedSize(horizontal: false, vertical: true).font(.system(size: 11)).foregroundStyle(.secondary)
                Button { Task { await continueSetup() } } label: {
                    Text("Continue").frame(maxWidth: .infinity)
                }.buttonStyle(.glassProminent).controlSize(.large).keyboardShortcut(.defaultAction).disabled(tracked.isEmpty || session.isBusy)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        UpOnlyBrandMark(width: 22)
                        Spacer()
                        Text("Step 3 of 3").font(.system(size: 11)).foregroundStyle(.secondary)
                    }.padding(.bottom, 2)
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Keep it current").font(.system(size: 22, weight: .semibold)).tracking(-0.4)
                        Text("Automatic updates, if you want them.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(.bottom, 4)
                VStack(spacing: 0) {
                    if wantsCrypto {
                        UpOnlySourceRow(symbol: "bitcoinsign.circle.fill", tint: UpOnlyTint.crypto, title: "Crypto prices", isOn: $prices,
                                        key: $key, keyPrompt: "CoinGecko Demo API key", keyLinkTitle: "Get a free key",
                                        keyLink: URL(string: "https://www.coingecko.com/en/api/pricing")!)
                    }
                    if tracked.contains(.metals) {
                        if wantsCrypto { Divider().padding(.horizontal, 12) }
                        UpOnlySourceRow(symbol: "square.stack.3d.up.fill", tint: UpOnlyTint.metals, title: "Metal prices", isOn: $metals,
                                        key: $metalKey, keyPrompt: "Gold API history key (optional)", keyLinkTitle: "Add a free key for price history",
                                        keyLink: URL(string: "https://gold-api.com/pricing")!)
                    }
                    if wantsFX {
                        if wantsCrypto || tracked.contains(.metals) { Divider().padding(.horizontal, 12) }
                        UpOnlySourceRow(symbol: "dollarsign.arrow.trianglehead.counterclockwise.rotate.90", tint: UpOnlyTint.cashFlow, title: "Exchange rates", isOn: $fx)
                    }
                }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.06)))
                if wantsCrypto && prices && key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Add a CoinGecko key, or turn Crypto prices off to continue.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                DisclosureGroup("Providers & privacy", isExpanded: $showSourceDetails) {
                    sourceDetails.padding(.top, 8)
                }.font(.system(size: 12)).foregroundStyle(.secondary).padding(.bottom, 4)
                VStack(spacing: 9) {
                    Button { Task { await finish(addData: true) } } label: {
                        Text("Add your info").frame(maxWidth: .infinity)
                    }.buttonStyle(.glassProminent).controlSize(.large).keyboardShortcut(.defaultAction).disabled(cannotFinish)
                    HStack { Button("Back") { step = 0; error = nil }; Spacer(); Button("Do this later") { Task { await finish(addData: false) } }.disabled(cannotFinish) }.buttonStyle(.bordered).font(.system(size: 12))
                }.disabled(saving || session.isBusy)
            }
            if let error { Text(error).fixedSize(horizontal: false, vertical: true).font(.caption).foregroundStyle(.red) }
            if let message = session.setupProgressMessage {
                Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                Button("Save progress again") { session.checkpointSetup(progress) }.buttonStyle(.bordered).font(.caption)
            }
            if saving { ProgressView().controlSize(.small) }
        }.padding(UpOnlyLayout.inset).frame(maxWidth: 380).fixedSize(horizontal: false, vertical: true)
            .animation(reduceMotion ? nil : .snappy, value: step)
            .onChange(of: progress) { _, value in session.checkpointSetup(value) }
            .onAppear {
                if let saved = session.document?.settings.setupProgress {
                    step = saved.step; tracked = Set(saved.tracked); prices = saved.prices; fx = saved.fx; metals = saved.metals
                    key = saved.coinGeckoKey; metalKey = saved.metalHistoryKey
                }
                #if UPONLY_FIXTURE
                if ProcessInfo.processInfo.environment["UPONLY_PREVIEW_DESTINATION"] == "sources" {
                    tracked = Set(ProcessInfo.processInfo.environment["UPONLY_PREVIEW_TRACKED"].map { $0.split(separator: ",").compactMap { TrackedKind(rawValue: String($0)) } } ?? TrackedKind.allCases)
                    step = 1
                    if ProcessInfo.processInfo.environment["UPONLY_PREVIEW_SOURCES_ENABLED"] == "1" {
                        prices = wantsCrypto; metals = tracked.contains(.metals); fx = wantsFX
                    }
                }
                #endif
            }
    }
    private func continueSetup() async {
        guard !tracked.isEmpty, !saving else { return }
        saving = true; error = nil
        defer { saving = false }
        let token = session.sessionToken
        var next = progress; next.step = 1
        session.checkpointSetup(next)
        do {
            try await session.flushSetupProgress()
            if token == session.sessionToken { step = 1 }
        } catch { if token == session.sessionToken { self.error = "Setup progress could not be saved. Please try again." } }
    }
    private var sourceDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            if wantsCrypto {
                Text("CoinGecko receives coin IDs, your API key and IP address. A free Demo key is required.")
            }
            if tracked.contains(.metals) {
                Text("Gold API receives metal symbols and your IP address. A history key is optional for current prices and required for past prices.")
            }
            if wantsFX {
                Text("Frankfurter receives currency codes and your IP address. Values are converted to USD.")
            }
            Text("These price providers never receive your balances or quantities.")
        }.font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
    }
    private func finish(addData: Bool) async {
        guard !cannotFinish else { return }
        saving = true; error = nil
        defer { saving = false }
        let token = session.sessionToken
        do {
            try await session.completeSetup(tracked: TrackedKind.normalized(tracked), prices: wantsCrypto && prices, fx: wantsFX && fx, key: wantsCrypto && prices ? key : "", metals: tracked.contains(.metals) && metals, metalKey: metalKey)
            key = ""
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
                HStack(alignment: .top, spacing: 16) {
                    ForEach(session.wiseProfiles) { profile in
                        VStack(spacing: 7) {
                            UpOnlyProfileImage(data: profile.image, name: profile.name, size: 38)
                            Text(profile.name).font(.system(size: 12, weight: .medium)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity)
                    }
                }.padding(.vertical, 3)
                if wise {
                Divider().opacity(0.5)
                UpOnlyFlow(spacing: 12) {
                    Button { Task { await session.refreshWise() } } label: {
                        Label(session.wiseRefreshing ? "Syncing Wise…" : "Sync now", systemImage: "arrow.clockwise")
                    }.disabled(hasChanges || session.wiseRefreshing || session.isBusy || session.document?.settings.automaticWise != true)
                    Text("Checks every 15 minutes in the background").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                }
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
                    if prices {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("CoinGecko Demo API key").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            SecureField("Paste your Demo API key", text: $key).textFieldStyle(.roundedBorder)
                            Link("Get a free Demo key", destination: URL(string: "https://www.coingecko.com/en/api/pricing")!).font(.system(size: 12)).buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                    DisclosureGroup("What CoinGecko receives") {
                        Text("Coin IDs, your API key and network information. Your quantities, portfolio names and balances stay private.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if session.document?.shows(.metals) == true {
                UpOnlySettingsCard(title: "Precious metal prices", subtitle: "Estimated market value of your gold and silver.", symbol: "square.stack.3d.up.fill", tint: UpOnlyTint.metals, isOn: $metals, controlDisabled: session.isBusy) {
                    Text("Current prices need no API key.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    if metals {
                        DisclosureGroup("Price history") {
                            VStack(alignment: .leading, spacing: 8) {
                                SecureField("Gold API history key", text: $metalKey).textFieldStyle(.roundedBorder)
                                Link("Get a free history key", destination: URL(string: "https://gold-api.com/pricing")!).buttonStyle(.bordered)
                                Text("A key fills gaps after time offline. Your weights and storage locations stay private.")
                                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }.padding(.top, 8)
                        }.font(.system(size: 12))
                    }
                }
            }
            if showsFX {
                UpOnlySettingsCard(title: "Exchange rates", subtitle: "Convert your balances and cash flow to USD.",
                                   symbol: "arrow.triangle.2.circlepath", tint: UpOnlyTint.cashFlow, isOn: $fx,
                                   controlDisabled: session.isBusy) {
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
        .onAppear {
            if let settings = session.document?.settings {
                #if UPONLY_PERSONAL
                wise = settings.automaticWise
                #endif
                prices = settings.automaticPrices; fx = settings.automaticFX; key = settings.coinGeckoKey; metals = settings.automaticMetals; metalKey = settings.metalHistoryKey }
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
                    } else if session.document?.settings.automaticPrices == true || session.document?.settings.automaticFX == true || session.document?.settings.automaticMetals == true {
                    Button(session.refreshing ? "Refreshing…" : "Refresh prices and rates") { Task { await session.refreshPrices() } }
                        .disabled(hasChanges || session.refreshing || session.isBusy || (session.document?.settings.automaticPrices != true && session.document?.settings.automaticFX != true && session.document?.settings.automaticMetals != true))
                    }
                }.padding(.top, 4)
            } else {
                Text("Choose what to track in Tracking to see relevant price sources.").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
