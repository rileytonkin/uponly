import SwiftUI
import AppKit

// The Add page and the pieces its guided forms share: date picker, badge and number read-back.

struct UpOnlyDateButton: View {
    @Binding var date: Date
    /// Shown instead of the date while only the month is known ("August 2026").
    var title: String? = nil
    @State private var showingCalendar = false
    private var label: String {
        title ?? (ImportDateFormat.today(date) == ImportDateFormat.today() ? "Today" : date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: UTCDay.timeZone)))
    }
    var body: some View {
        // A form value like every other choice: the date and a small chevron, no box.
        Button { showingCalendar = true } label: { UpOnlyFormValue(value: label) }.buttonStyle(.plain)
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
            // No focus ring: the calendar is the popover's only control.
            DatePicker("Observation date", selection: $date, in: ...Date(), displayedComponents: .date)
                .datePickerStyle(.graphical).labelsHidden().environment(\.timeZone, UTCDay.timeZone).focusEffectDisabled()
            HStack {
                Button("Today") { date = Date() }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
                Spacer()
                Button("Done", action: done).buttonStyle(.glassProminent).buttonBorderShape(.capsule).keyboardShortcut(.defaultAction)
            }.font(.system(size: 12))
        }.padding(16).fixedSize().background(Color(nsColor: .windowBackgroundColor))
            .onExitCommand(perform: done)
    }
}

struct UpOnlyEntryFlow: View {
    @Environment(UpOnlySession.self) private var session
    @State private var saved: UpOnlySavedSummary?
    @State private var addingEntry = false
    var body: some View {
        Group {
            if let saved {
                savedPage(saved)
            } else if addingEntry {
                UpOnlyEditSheet(editor: .entry,
                                onCancel: { addingEntry = false },
                                onSave: { addingEntry = false },
                                onSaved: { summary in addingEntry = false; saved = summary })
                    .onAppear { session.entryEditorInMenu = true }
                    .onDisappear { session.entryEditorInMenu = false }
            } else if let batch = session.importDraft, batch.mode != .statements, batch.rows.count <= 1, batch.sources.allSatisfy({ $0.grid.isEmpty }) {
                if let row = batch.rows.first {
                    UpOnlyGuidedEntry(mode: batch.mode, row: Binding(get: { session.importDraft?.rows.first ?? row }, set: { session.importDraft?.rows = [$0] }),
                                      // Opened to update one thing from a page: backing out returns to that page.
                                      back: { session.discardImport(); if session.addOpenedForUpdate { session.addingInMenu = false } },
                                      saved: { summary in saved = summary })
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
                    // One list in the home style: what you have, then what came in and went out.
                    ManageCard {
                        ForEach(Array([ImportMode.bankBalances, .holdings, .metals].enumerated()), id: \.element) { index, mode in
                            UpOnlyRow(title: mode == .bankBalances ? "Bank balance" : mode == .holdings ? "Crypto" : "Metals",
                                      caption: mode == .bankBalances ? "What’s in an account, as of a date" : mode == .holdings ? "Coins you hold, by quantity" : "Bars and coins, by weight",
                                      divided: index > 0, chevron: true, action: { if session.startImport(mode) { seed(mode) } }) {
                                UpOnlyEntryBadge(mode: mode, size: 28)
                            }
                        }
                    }
                    ManageCard {
                        UpOnlyRow(title: "Transaction", caption: "Spending or income, typed in", chevron: true, action: { addingEntry = true }) {
                            UpOnlySymbolBadge(symbol: TrackedKind.cashFlow.symbol, tint: UpOnlyTint.cashFlow, size: 28)
                        }
                        UpOnlyRow(title: "Bank statement", caption: "Import transactions from a CSV file", divided: true, chevron: true, action: importStatement) {
                            UpOnlySymbolBadge(symbol: "doc.text.fill", tint: UpOnlyTint.cashFlow, size: 28)
                        }
                    }
                    // Many at once is its own row, not a line of grey text.
                    ManageCard {
                        UpOnlyRow(title: session.importDraft == nil ? "Several at once" : "Continue your import",
                                  caption: session.importDraft == nil ? "Paste a spreadsheet, or update everything you track" : "Your unfinished import is still here",
                                  chevron: true, action: showBulk) {
                            UpOnlySymbolBadge(symbol: "tablecells", tint: UpOnlyTint.netWorth, size: 28)
                        }
                        .accessibilityIdentifier("BulkImport")
                    }
                }
            }
        }.frame(maxWidth: .infinity)
            .padding(UpOnlyLayout.inset)
            .frame(maxWidth: .infinity, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
            // Esc: out of the transaction form, else off the Add page. A guided form handles its own steps.
            .onChange(of: session.backRequests) {
                guard session.addingInMenu, !session.managementInMenu, session.importDraft == nil else { return }
                if addingEntry { addingEntry = false } else { session.addingInMenu = false }
            }
    }
    /// After saving: what was saved, large, under its logo with a check; where it went, one click away; then Done.
    /// Centred in the page, which keeps the dashboard's height.
    private func savedPage(_ summary: UpOnlySavedSummary) -> some View {
        VStack(spacing: 20) {
            Spacer(minLength: 0)
            VStack(spacing: 12) {
                summary.badge.view(size: 56)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 22)).symbolRenderingMode(.palette)
                            .foregroundStyle(.white, UpOnlyTint.gain)
                            .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(-2)).offset(x: 7, y: 7)
                    }
                Text(summary.title).font(UpOnlyType.body.weight(.semibold)).foregroundStyle(UpOnlyTint.gain).padding(.top, 6)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    UpOnlyPrivateText(summary.amount).font(UpOnlyAmountEntry.font(summary.amount.count)).lineLimit(1).minimumScaleFactor(0.6)
                    Text(summary.unit).font(.system(size: 20, weight: .medium)).foregroundStyle(.secondary).fixedSize()
                }
                if let detail = summary.detail {
                    UpOnlyPrivateText(detail).font(UpOnlyType.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }.frame(maxWidth: .infinity)
            ManageCard {
                if let destination = summary.destination {
                    UpOnlyRow(title: destination.title, caption: "See it on the dashboard", chevron: true, action: {
                        session.showDashboard(destination.selection)
                        session.addingInMenu = false; session.managementInMenu = false
                    }) { summary.badge.view(size: 28) }
                }
                UpOnlyRow(title: "Add another", caption: "A balance, holding or transaction", divided: summary.destination != nil, chevron: true,
                          action: { saved = nil }) {
                    UpOnlySymbolBadge(symbol: "plus", tint: .accentColor, size: 28)
                }
            }
            Spacer(minLength: 0)
            primary("Done") { session.addingInMenu = false; session.managementInMenu = false }.keyboardShortcut(.defaultAction)
        }.frame(minHeight: max(0, (session.dashboardHeight ?? 0) - 2 * UpOnlyLayout.inset))
    }
    // A statement goes straight to the file picker; the summary and review follow.
    private func importStatement() {
        guard session.startImport(.statements) else { showBulk(); return }
        session.importTableMode = false
        session.addingInMenu = false; session.managementSection = "Add your info"; session.managementInMenu = true; session.importReturnsHome = true
        Task { await session.chooseImportFiles() }
    }
    private func seed(_ mode: ImportMode) {
        guard var batch = session.importDraft, batch.rows.isEmpty, let source = batch.sources.first else { return }
        let portfolios = session.document?.portfolios.filter { !$0.isArchived && $0.kind == mode.kind } ?? []
        // The only portfolio when there's one; with several, the form asks which after the coin or metal is chosen.
        let portfolio = portfolios.count == 1 ? portfolios.first : nil
        let content: ImportRowContent = mode == .bankBalances ? .bankBalance(BankBalanceInput())
            : .holding(HoldingInput(portfolioID: portfolio?.id, portfolioName: portfolio?.name ?? (portfolios.isEmpty ? (mode == .metals ? "My metals" : "My crypto") : "")))
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
        session.addingInMenu = false; session.managementSection = "Add your info"; session.managementInMenu = true
    }
    private func openTable() {
        session.importTableMode = true
        session.addingInMenu = false; session.managementSection = "Add your info"; session.managementInMenu = true; session.importReturnsHome = true
    }
    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).frame(maxWidth: .infinity).frame(minHeight: 24) }
            .buttonStyle(.glassProminent).buttonBorderShape(.capsule).controlSize(.large)
    }
}

/// The large amount every add form starts with: a field as wide as what's typed, its unit just after it, and a faint
/// 0 until something is. A sign in front says which way the money moved.
struct UpOnlyAmountEntry: View {
    @Environment(UpOnlySession.self) private var session
    @Binding var text: String
    var unit: String
    var sign = ""
    var tint: Color = .primary
    var label: String
    var focused: FocusState<Bool>.Binding
    /// Smaller as the number grows, so a long one still fits the menu's width beside its unit.
    static func font(_ count: Int) -> Font { .system(size: count > 14 ? 22 : count > 12 ? 26 : count > 9 ? 32 : 38, weight: .medium).monospacedDigit() }
    var body: some View {
        let font = Self.font(text.count)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                if !sign.isEmpty { Text(sign).font(font).foregroundStyle(tint.opacity(text.isEmpty ? 0.35 : 1)).accessibilityHidden(true) }
                Text(text.isEmpty ? "0" : text).font(font).lineLimit(1).opacity(0).padding(.trailing, 4).accessibilityHidden(true)
                    .overlay(alignment: .leading) {
                        ZStack(alignment: .leading) {
                            if text.isEmpty { Text("0").font(font).foregroundStyle(.tertiary).accessibilityHidden(true) }
                            Group { if session.privacyMode { SecureField("", text: $text) } else { TextField("", text: $text) } }
                                .textFieldStyle(.plain).font(font).foregroundStyle(tint).focused(focused).accessibilityLabel(label)
                        }
                    }
            }.fixedSize()
            Text(unit).font(.system(size: 20, weight: .medium)).foregroundStyle(.secondary).fixedSize()
        }.frame(maxWidth: .infinity)
    }
}
/// Every place a currency is entered uses this one field: USD (or the place's own default) unless another code is
/// typed, any ISO code, with matching currencies (by code or name) suggested while typing. Left empty, it goes back
/// to its default. It takes the look of the text around it: each place sets the font and field style.
struct UpOnlyCurrencyField: View {
    @Binding var code: String
    /// What an empty field means, shown as its placeholder: USD, or the file's own currency for a statement's new account.
    var fallback = "USD"
    var label = "Currency code"
    @FocusState private var focused: Bool
    var body: some View {
        TextField(fallback, text: $code)
            .textInputSuggestions {
                ForEach(CurrencyCodes.suggestions(for: code), id: \.self) { choice in
                    Text(choice + " · " + CurrencyCodes.name(choice)).textInputCompletion(choice)
                }
            }
            .focused($focused)
            // Three letters, capitals, as currency codes are written.
            .onChange(of: code) { _, next in
                let clean = CurrencyCodes.cleaned(next)
                if clean != next { code = clean }
            }
            .onChange(of: focused) { _, now in if !now, code.isEmpty { code = fallback } }
            .help(CurrencyCodes.isValid(code) ? CurrencyCodes.name(code) : "A three-letter currency code, such as " + fallback)
            .accessibilityLabel(label)
    }
}
/// The currencies the currency field knows: the ones people most often hold first, then every other ISO code.
nonisolated enum CurrencyCodes {
    static let all: [String] = {
        let first = ["USD", "EUR", "GBP", "JPY", "CAD", "AUD", "CHF", "CNY", "HKD", "SGD", "INR", "BRL", "MXN", "COP", "ARS", "CLP", "PEN", "NZD", "SEK", "NOK", "DKK", "PLN", "AED", "ZAR", "KRW", "TRY"]
        return first + Locale.commonISOCurrencyCodes.filter { !first.contains($0) }.sorted()
    }()
    /// "British Pound" for GBP, in this Mac's language.
    static func name(_ code: String, locale: Locale = .current) -> String { locale.localizedString(forCurrencyCode: code) ?? code }
    /// What's typed, as a code is written: letters only, in capitals, at most three.
    static func cleaned(_ typed: String) -> String { String(typed.uppercased().filter { $0.isASCII && $0.isLetter }.prefix(3)) }
    /// A code saving accepts, by the same check.
    static func isValid(_ code: String) -> Bool { (try? MoneyInput.normalizeCurrency(code)) != nil }
    /// Up to `limit` currencies whose code starts with what's typed or whose name contains it; none once it's a valid code.
    static func suggestions(for typed: String, limit: Int = 5, locale: Locale = .current) -> [String] {
        let text = typed.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !isValid(text) else { return [] }
        return Array(all.lazy.filter { $0.hasPrefix(text.uppercased()) || name($0, locale: locale).localizedCaseInsensitiveContains(text) }.prefix(limit))
    }
}
/// What the Add page's confirmation shows after a save: the amount and unit, what it's worth or what it was for, its
/// logo, and the dashboard page it now shows on.
struct UpOnlySavedSummary {
    enum Badge {
        case asset(ImportMode, symbol: String, assetID: String?)
        case bank(String)
        case symbol(String, Color)
        @ViewBuilder func view(size: CGFloat) -> some View {
            switch self {
            case .asset(let mode, let symbol, let assetID): UpOnlyEntryBadge(mode: mode, symbol: symbol, assetID: assetID, size: size)
            case .bank(let name): UpOnlyBankBadge(name: name, size: size)
            case .symbol(let symbol, let tint): UpOnlySymbolBadge(symbol: symbol, tint: tint, size: size)
            }
        }
    }
    var title: String
    var amount: String
    var unit: String
    var detail: String?
    var badge: Badge
    var destination: (title: String, selection: UpOnlySession.DashboardSelection)?
}
/// A form row's value that opens a choice: the value and a small chevron, as a date or a menu.
struct UpOnlyFormValue: View {
    var value: String
    var body: some View {
        HStack(spacing: 5) {
            Text(value).font(UpOnlyType.row.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
        }.contentShape(Rectangle())
    }
}
/// A choice in a form row (a portfolio, a currency, a unit), drawn as `UpOnlyFormValue`.
struct UpOnlyFormMenu<Content: View>: View {
    var value: String
    var label: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        Menu { content() } label: { UpOnlyFormValue(value: value) }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().accessibilityLabel(label).accessibilityValue(value)
    }
}
/// One line of a form card: what it is on the left, its value or field on the right, rows the same height.
struct UpOnlyFormRow<Trailing: View>: View {
    var label: String
    var note: String? = nil
    var divided = false
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        VStack(spacing: 0) {
            if divided { Divider().opacity(0.5) }
            HStack(spacing: 8) {
                Text(label).font(UpOnlyType.row).foregroundStyle(.secondary)
                if let note { Text(note).font(UpOnlyType.caption).foregroundStyle(.tertiary) }
                Spacer(minLength: 12)
                trailing()
            }.frame(minHeight: 40)
        }
    }
}

struct UpOnlyEntryBadge: View {
    var mode: ImportMode
    var symbol = ""
    /// The coin's ID, for its logo.
    var assetID: String? = nil
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
            if mode == .metals {
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: size * 0.46, weight: .medium))
                    .foregroundStyle(LinearGradient(colors: [tint.opacity(0.6), tint], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: size, height: size).background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.28))
            } else if mode == .holdings, let assetID, NSImage(named: "CoinLogos/" + assetID) != nil {
                UpOnlyAssetBadge(assetID: assetID, symbol: symbol, size: size)
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
