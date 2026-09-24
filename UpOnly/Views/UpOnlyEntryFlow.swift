import SwiftUI
import AppKit

// The Add page and the pieces its guided forms share: date picker, badge and number read-back.

struct UpOnlyDateButton: View {
    @Binding var date: Date
    @State private var showingCalendar = false
    private var label: String {
        ImportDateFormat.today(date) == ImportDateFormat.today() ? "Today" : date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: UTCDay.timeZone))
    }
    var body: some View {
        Button { showingCalendar = true } label: {
            HStack(spacing: 7) {
                Image(systemName: "calendar").font(.system(size: 13))
                Text(label).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }.foregroundStyle(Color.accentColor).contentShape(Rectangle())
        }.buttonStyle(.bordered)
            .accessibilityLabel("Observation date").accessibilityValue(label)
            .popover(isPresented: $showingCalendar) {
                UpOnlyDateCalendar(date: $date) { showingCalendar = false }
            }
    }
}

struct UpOnlyDateCalendar: View {
    @Binding var date: Date
    var done: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            DatePicker("Observation date", selection: $date, in: ...Date(), displayedComponents: .date)
                .datePickerStyle(.graphical).labelsHidden().environment(\.timeZone, UTCDay.timeZone)
            HStack {
                Button("Today") { date = Date() }.buttonStyle(.bordered).foregroundStyle(UpOnlyTint.netWorth)
                Spacer()
                Button("Done", action: done).buttonStyle(.glassProminent).buttonBorderShape(.capsule).keyboardShortcut(.defaultAction)
            }.font(.system(size: 12))
        }.padding(16).fixedSize().background(Color(nsColor: .windowBackgroundColor))
            .onExitCommand(perform: done)
    }
}

struct UpOnlyEntryFlow: View {
    @Environment(UpOnlySession.self) private var session
    var compact: Bool
    @State private var saved: String?
    @State private var addingEntry = false
    var body: some View {
        Group {
            if let saved {
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 46, weight: .light)).foregroundStyle(UpOnlyTint.cashFlow)
                    Text(saved).font(UpOnlyType.title)
                    primary("Done") { session.addingInMenu = false; session.managementInMenu = false }
                    Button("Add another") { self.saved = nil }.buttonStyle(.bordered).font(UpOnlyType.body).foregroundStyle(.secondary)
                }.padding(.vertical, 18)
            } else if addingEntry {
                UpOnlyEditSheet(editor: .entry,
                                onCancel: { addingEntry = false },
                                onSave: { addingEntry = false; saved = "Transaction saved" })
                    .onAppear { session.entryEditorInMenu = true }
                    .onDisappear { session.entryEditorInMenu = false }
            } else if let batch = session.importDraft, batch.mode != .statements, batch.rows.count <= 1, batch.sources.allSatisfy({ $0.grid.isEmpty }) {
                if let row = batch.rows.first {
                    UpOnlyGuidedEntry(mode: batch.mode, row: Binding(get: { session.importDraft?.rows.first ?? row }, set: { session.importDraft?.rows = [$0] }),
                                      back: { session.discardImport() },
                                      saved: { if compact { saved = batch.mode == .bankBalances ? "Balance saved" : "Holding saved" } })
                        .id(batch.id)
                } else { ProgressView().controlSize(.small).task { seed(batch.mode) } }
            } else if let batch = session.importDraft, batch.mode != .statements, batch.rows.count > 1, batch.sources.allSatisfy(\.isManual) {
                // "Update holdings" and "Update all balances" fill in several rows, which belong in the table rather than the Add chooser.
                ProgressView().controlSize(.small).onAppear(perform: openTable)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    if !session.managementInMenu {
                        UpOnlyPageHeader(title: "Add", backLabel: "Back to overview") { session.addingInMenu = false }
                    }
                    VStack(spacing: 9) {
                        ForEach([ImportMode.bankBalances, .holdings, .metals], id: \.self) { mode in
                            addCard(UpOnlyEntryBadge(mode: mode, size: 32),
                                    title: mode == .bankBalances ? "Bank balance" : mode == .holdings ? "Crypto" : "Gold & silver",
                                    detail: mode == .bankBalances ? "What’s in an account, as of a date" : mode == .holdings ? "Coins you hold, by quantity" : "Bars and coins, by weight") {
                                if session.startImport(mode) { seed(mode) }
                            }
                        }
                        addCard(UpOnlySymbolBadge(symbol: TrackedKind.cashFlow.symbol, tint: UpOnlyTint.cashFlow, size: 32),
                                title: "Income or expense", detail: "One transaction, typed in") { addingEntry = true }
                        addCard(UpOnlySymbolBadge(symbol: "doc.text.fill", tint: UpOnlyTint.cashFlow, size: 32),
                                title: "Bank statement", detail: "Import transactions from a CSV file", action: importStatement)
                    }
                    Button(session.importDraft == nil ? "Import several at once from a spreadsheet…" : "Continue your unfinished import…", action: showBulk)
                        .buttonStyle(.plain).font(UpOnlyType.body).foregroundStyle(.secondary).accessibilityIdentifier("BulkImport")
                }
            }
        }.frame(maxWidth: compact ? .infinity : 400)
            .padding(UpOnlyLayout.inset)
            .frame(maxWidth: .infinity, maxHeight: compact ? nil : .infinity, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
    }
    private func addCard<Badge: View>(_ badge: Badge, title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                badge
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(UpOnlyType.row.weight(.medium))
                    Text(detail).font(UpOnlyType.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }.padding(UpOnlyLayout.cardInset).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: UpOnlyLayout.radius)).contentShape(RoundedRectangle(cornerRadius: UpOnlyLayout.radius))
        }.buttonStyle(UpOnlyCardButtonStyle(radius: UpOnlyLayout.radius)).accessibilityLabel(title).accessibilityHint(detail)
    }
    // A statement goes straight to the file picker; the summary and review follow.
    private func importStatement() {
        guard session.startImport(.statements) else { showBulk(); return }
        session.importTableMode = false
        if compact { session.addingInMenu = false; session.managementSection = "Add your info"; session.managementInMenu = true; session.importReturnsHome = true }
        Task { await session.chooseImportFiles() }
    }
    private func seed(_ mode: ImportMode) {
        guard var batch = session.importDraft, batch.rows.isEmpty, let source = batch.sources.first else { return }
        let portfolios = session.document?.portfolios.filter { !$0.isArchived && $0.kind == mode.kind } ?? []
        let portfolio = portfolios.count == 1 ? portfolios.first : nil
        let content: ImportRowContent = mode == .bankBalances ? .bankBalance(BankBalanceInput()) : .holding(HoldingInput(portfolioID: portfolio?.id, portfolioName: portfolio?.name ?? (mode == .metals ? "My metals" : "My crypto")))
        batch.rows = [ImportDraftRow(sourceID: source.id, line: 1, content: content)]
        session.importDraft = batch
    }
    private func showBulk() {
        if var draft = session.importDraft, draft.rows.count == 1, let row = draft.rows.first {
            let untouched: Bool = switch row.content {
            case .bankBalance(let bank): bank.balance.isEmpty && bank.account.name.isEmpty && bank.account.existingID == nil
            case .holding(let holding): holding.quantity.isEmpty && holding.coin.isEmpty && holding.resolvedCoinID.isEmpty
            case .statement: false
            }
            if untouched { draft.rows = []; session.importDraft = draft }
        }
        session.importTableMode = true
        if compact { session.addingInMenu = false; session.managementSection = "Add your info"; session.managementInMenu = true }
    }
    private func openTable() {
        session.importTableMode = true
        if compact { session.addingInMenu = false; session.managementSection = "Add your info"; session.managementInMenu = true; session.importReturnsHome = true }
    }
    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).frame(maxWidth: .infinity).frame(minHeight: 24) }
            .buttonStyle(.glassProminent).buttonBorderShape(.capsule).controlSize(.large)
    }
}

struct UpOnlyEntryBadge: View {
    var mode: ImportMode
    var symbol = ""
    var image: Data?
    var size: CGFloat = 56
    private var tint: Color {
        if mode == .metals {
            switch symbol {
            case "XAG": return Color(red: 0.62, green: 0.68, blue: 0.76)
            case "XPT": return Color(red: 0.54, green: 0.70, blue: 0.70)
            case "XPD": return Color(red: 0.67, green: 0.62, blue: 0.76)
            default: break
            }
        }
        return mode.kind.tint
    }
    var body: some View {
        Group {
            if let image { UpOnlyProfileImage(data: image, name: "Account", size: size) }
            else if mode == .metals {
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: size * 0.46, weight: .medium))
                    .foregroundStyle(LinearGradient(colors: [tint.opacity(0.6), tint], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: size, height: size).background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.28))
            } else if mode == .holdings, !symbol.isEmpty {
                Text(symbol == "BTC" ? "₿" : symbol == "ETH" ? "Ξ" : symbol).font(.system(size: symbol.count > 2 && symbol != "BTC" ? size * 0.25 : size * 0.48, weight: .medium))
                    .foregroundStyle(tint).frame(width: size, height: size).background(tint.opacity(0.12), in: Circle())
            } else { UpOnlySymbolBadge(symbol: mode.kind.symbol, tint: tint, size: size) }
        }.accessibilityHidden(true)
    }
}



/// "Wise · EUR" rather than "Wise · EUR · EUR" for an account already named after its currency.
func accountTitle(_ name: String, _ currency: String) -> String {
    name.hasSuffix(" · " + currency) ? name : name + " · " + currency
}

/// A typed amount as the app read it, grouped the way this Mac writes numbers, with "−" for negatives.
func readBack(_ value: Decimal, fraction: ClosedRange<Int>) -> String {
    value.formatted(.number.precision(.fractionLength(fraction))).replacingOccurrences(of: "-", with: "−")
}

/// The coin list merges built-in coins, saved holdings and search results and sorts them by name. Views read it
/// several times per update, so it is rebuilt only when one of those changes.
@MainActor enum ImportCoinList {
    private static var cache: (key: [String], coins: [CatalogCoin])?
    static func coins(document: VaultDocument?, catalog: [CatalogCoin]) -> [CatalogCoin] {
        guard let document else { return ImportCoins.common }
        let key = [String(catalog.count), catalog.first?.id ?? "", catalog.last?.id ?? ""] + document.holdings.map { $0.assetID.rawValue + ":" + $0.assetName }
        if let cache, cache.key == key { return cache.coins }
        let coins = ImportCoins.available(document: document, catalog: catalog)
        cache = (key, coins)
        return coins
    }
}
