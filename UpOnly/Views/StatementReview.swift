import SwiftUI
import AppKit

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
                    Text(saved).font(.system(size: 22, weight: .semibold))
                    primary("Done") { session.addingInMenu = false; session.managementInMenu = false }
                    Button("Add another") { self.saved = nil }.buttonStyle(.bordered).font(.system(size: 12)).foregroundStyle(.secondary)
                }.padding(.vertical, 18)
            } else if addingEntry {
                UpOnlyEditSheet(editor: .entry, compact: true,
                                onCancel: { addingEntry = false },
                                onSave: { addingEntry = false; saved = "Entry saved" })
            } else if let batch = session.importDraft, batch.mode != .statements, batch.rows.count <= 1, batch.sources.allSatisfy({ $0.grid.isEmpty }) {
                if let row = batch.rows.first {
                    UpOnlyGuidedEntry(mode: batch.mode, row: Binding(get: { session.importDraft?.rows.first ?? row }, set: { session.importDraft?.rows = [$0] }),
                                      back: { session.discardImport() },
                                      saved: { if compact { saved = batch.mode == .bankBalances ? "Balance saved" : "Holding saved" } })
                        .id(batch.id)
                } else { ProgressView().controlSize(.small).task { seed(batch.mode) } }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    if !session.managementInMenu {
                    HStack {
                        UpOnlyBrandMark(width: 26)
                        Spacer()
                        Button { session.addingInMenu = false } label: { Label("Back", systemImage: "chevron.left").font(.system(size: 12)) }.buttonStyle(.bordered).foregroundStyle(.secondary).accessibilityLabel("Back to overview")
                    }
                    }
                    VStack(spacing: 9) {
                        Button { addingEntry = true } label: {
                            HStack(spacing: 12) {
                                UpOnlySymbolBadge(symbol: TrackedKind.cashFlow.symbol, tint: UpOnlyTint.cashFlow, size: 32)
                                Text("Income or expense").font(.system(size: 14, weight: .medium))
                                Spacer()
                                Image(systemName: "arrow.right").font(.system(size: 12)).foregroundStyle(.secondary)
                            }.padding(12).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14)).contentShape(RoundedRectangle(cornerRadius: 14))
                        }.buttonStyle(UpOnlyCardButtonStyle(radius: 14))
                        ForEach([ImportMode.bankBalances, .holdings, .metals], id: \.self) { mode in
                            Button {
                                if session.startImport(mode) { seed(mode) }
                            } label: {
                                HStack(spacing: 12) {
                                    UpOnlyEntryBadge(mode: mode, size: 32)
                                    Text(mode == .bankBalances ? "Bank balance" : mode == .holdings ? "Crypto" : "Precious metals").font(.system(size: 14, weight: .medium))
                                    Spacer()
                                    Image(systemName: "arrow.right").font(.system(size: 12)).foregroundStyle(.secondary)
                                }.padding(12).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14)).contentShape(RoundedRectangle(cornerRadius: 14))
                            }.buttonStyle(UpOnlyCardButtonStyle(radius: 14))
                        }
                    }
                    Button(session.importDraft == nil ? "Statements & bulk import…" : "Continue your existing import…", action: showBulk)
                        .buttonStyle(.bordered).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }.frame(maxWidth: compact ? .infinity : 400)
            .padding(UpOnlyLayout.inset)
            .frame(maxWidth: .infinity, maxHeight: compact ? nil : .infinity, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
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
    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).frame(maxWidth: .infinity).frame(minHeight: 24) }
            .buttonStyle(.glassProminent).buttonBorderShape(.capsule).controlSize(.large)
    }
}

private struct UpOnlyEntryBadge: View {
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

private struct UpOnlyGuidedEntry: View {
    @Environment(UpOnlySession.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var mode: ImportMode
    @Binding var row: ImportDraftRow
    var back: () -> Void
    var saved: () -> Void
    @State private var step = 0
    @State private var search = ""
    @State private var newAccount = false
    @State private var customCurrency = false
    @State private var unchanged = false
    @State private var exactCoin = false
    @State private var error: String?
    @State private var review: ImportEvaluation?
    @State private var working = false
    @State private var discard = false
    @FocusState private var searchFocused: Bool
    @FocusState private var amountFocused: Bool
    private var accounts: [Account] { session.document?.accounts ?? [] }
    private var portfolios: [Portfolio] { session.document?.portfolios.filter { !$0.isArchived && $0.kind == mode.kind } ?? [] }
    private var coins: [CatalogCoin] { session.document.map { ImportCoins.available(document: $0, catalog: session.catalog) } ?? ImportCoins.common }
    private var coin: CatalogCoin? { coins.first { $0.id == row.holding.resolvedCoinID } }
    private var account: Account? { accounts.first { $0.id == row.bank.account.existingID } }
    private var title: String { mode == .bankBalances ? row.bank.account.name : mode == .metals ? ((try? PreciousMetal.resolve(row.holding.coin))?.name ?? "Metal") : row.holding.assetName.isEmpty ? row.holding.resolvedCoinID : row.holding.assetName }
    private var quantity: Binding<String> { mode == .bankBalances ? $row.bank.balance : $row.holding.quantity }
    private var date: Binding<Date> { Binding(get: { (try? ImportDateFormat.iso.date(row.bank.date)) ?? Date() }, set: { row.bank.date = ImportDateFormat.today($0) }) }
    var body: some View {
        Group {
        if discard {
            UpOnlyConfirmation(title: "Discard this entry?", confirmTitle: "Discard entry", confirm: back, cancel: { discard = false })
        } else {
        VStack(alignment: .leading, spacing: 16) {
            UpOnlyPageHeader(title: mode == .bankBalances ? "Bank balance" : mode == .holdings ? "Crypto holding" : "Precious metals") {
                if step > 0 { step -= 1; error = nil; review = nil }
                else if mode == .bankBalances && newAccount && !accounts.isEmpty { newAccount = false }
                else if exactCoin { exactCoin = false }
                else if row.bank.balance.isEmpty && row.holding.quantity.isEmpty { back() }
                else { discard = true }
            }.disabled(working)
            Divider()
            if step == 0 { chooseAsset }
            else {
                HStack(spacing: 12) {
                    UpOnlyEntryBadge(mode: mode, symbol: mode == .metals ? row.holding.coin : coin?.symbol.uppercased() ?? "", image: mode == .bankBalances ? account?.profileImage : nil, size: 36)
                    Text(title).font(.system(size: 16, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                if step == 1 { enterAmount }
                else { reviewAmount }
            }
            if unchanged {
                Text(mode == .bankBalances ? "This balance is already saved." : "This quantity is already saved.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Button("Done", action: back).buttonStyle(.bordered)
            }
            if let error { Label(error, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            if working { HStack(spacing: 8) { ProgressView().controlSize(.small); Text(step == 2 ? "Saving…" : "Checking your entry…").font(.system(size: 12)).foregroundStyle(.secondary) } }
        }
        }
        }
        .disabled(working || session.isBusy)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: step)
        .onChange(of: row.content) { _, _ in unchanged = false; error = nil }
        .onChange(of: step) { _, _ in unchanged = false }
        .onAppear {
            newAccount = accounts.isEmpty || (row.bank.account.existingID == nil && !row.bank.account.name.isEmpty)
            customCurrency = !["USD", "GBP", "EUR"].contains(row.bank.account.currency)
            if mode == .bankBalances ? row.bank.account.existingID != nil : mode == .metals ? !row.holding.coin.isEmpty : !row.holding.resolvedCoinID.isEmpty { step = 1 }
            #if UPONLY_FIXTURE
            if ProcessInfo.processInfo.environment["UPONLY_PREVIEW_ENTRY_STEP"] == "choose" { step = 0 }
            if ProcessInfo.processInfo.environment["UPONLY_PREVIEW_ENTRY_STEP"] == "account" { step = 0; newAccount = true; row.bank.account = ImportAccount() }
            if ProcessInfo.processInfo.environment["UPONLY_PREVIEW_ENTRY_STEP"] == "review" { Task { await evaluate() } }
            #endif
        }
    }
    @ViewBuilder private var chooseAsset: some View {
        Text(mode == .bankBalances ? (newAccount ? "Name your account" : "Which account?") : mode == .holdings ? "Which coin?" : "Which metal?")
            .font(.system(size: 22, weight: .semibold)).tracking(-0.4)
        if mode == .bankBalances {
            if newAccount {
                VStack(alignment: .leading, spacing: 16) {
                    entryField("Everyday account", text: $row.bank.account.name, size: 22).accessibilityLabel("Account name")
                    UpOnlyOwnerPicker(owner: $row.bank.account.ownerBusinessID)
                    ImportField(title: "Currency") {
                        HStack(spacing: 8) {
                            ForEach(["USD", "GBP", "EUR"], id: \.self) { code in
                                currencyButton(code, selected: !customCurrency && row.bank.account.currency == code) { customCurrency = false; row.bank.account.currency = code }
                            }
                            currencyButton("Other", selected: customCurrency) { customCurrency = true; row.bank.account.currency = "" }
                        }
                        if customCurrency { entryField("Currency code, e.g. CHF", text: $row.bank.account.currency).accessibilityLabel("Account currency") }
                    }
                }
                primary("Continue") { step = 1 }.disabled(row.bank.account.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || row.bank.account.currency.trimmingCharacters(in: .whitespacesAndNewlines).count != 3)
            } else {
                if accounts.count > 4 { entryField("Find an account", text: $search, symbol: "magnifyingglass") }
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(accounts.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { item in
                            assetButton(name: item.name, caption: item.currency, mode: .bankBalances, image: item.profileImage) {
                                row.bank.account = ImportAccount(existingID: item.id, name: item.name, currency: item.currency); step = 1
                            }
                        }
                    }
                }.frame(maxHeight: accounts.count > 3 ? 208 : CGFloat(accounts.count) * 64)
                Button { if row.bank.account.existingID != nil { row.bank.account.existingID = nil; row.bank.account.name = "" }; newAccount = true } label: { Label("New account", systemImage: "plus") }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large)
            }
        } else if mode == .metals {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(PreciousMetal.selectable, id: \.self) { metal in
                    Button {
                        row.holding.coin = metal.rawValue; row.holding.assetName = metal.name; step = 1
                    } label: {
                        VStack(spacing: 10) {
                            UpOnlyEntryBadge(mode: .metals, symbol: metal.rawValue, size: 44)
                            Text(metal.name).font(.system(size: 13, weight: .medium))
                        }.frame(maxWidth: .infinity).padding(.vertical, 18)
                            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 18))
                    }.buttonStyle(UpOnlyCardButtonStyle(radius: 18))
                }
            }
        } else if exactCoin {
            ImportField(title: "CoinGecko ID") { entryField("e.g. bitcoin", text: $row.holding.resolvedCoinID) }
            ImportField(title: "Display name") { entryField("e.g. Bitcoin", text: $row.holding.assetName) }
            primary("Continue") { row.holding.coin = row.holding.resolvedCoinID; step = 1 }.disabled(row.holding.resolvedCoinID.isEmpty)
        } else {
            entryField("Search coins", text: $search, symbol: "magnifyingglass")
                .accessibilityLabel("Search coins").focused($searchFocused).onAppear { searchFocused = true }
                .task(id: search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && session.catalog.isEmpty { await session.loadCatalog() }
                }
            let suggestions = ImportCoins.suggestions(search, coins: coins)
            if !suggestions.isEmpty {
                VStack(spacing: 6) {
                    ForEach(suggestions) { coin in
                        Button {
                            row.holding.coin = coin.id; row.holding.resolvedCoinID = coin.id; row.holding.assetName = coin.name; step = 1
                        } label: {
                            HStack {
                                Text(coin.name).font(.system(size: 13, weight: .medium))
                                Spacer(minLength: 6)
                                Text(coin.symbol.uppercased()).font(.system(size: 11)).foregroundStyle(.secondary)
                                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                            }.frame(maxWidth: .infinity, minHeight: 28).contentShape(Rectangle())
                        }.buttonStyle(.bordered).help(coin.id).accessibilityIdentifier("ChooseCoin-" + coin.id)
                    }
                }
            } else if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("No matching coins").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("Enter an exact coin ID") { exactCoin = true }.buttonStyle(.bordered).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
    private var enterAmount: some View {
        VStack(spacing: 16) {
            VStack(spacing: 5) {
                Text(mode == .bankBalances ? "Balance · " + row.bank.account.currency : mode == .metals ? "Pure metal weight" : "Total quantity")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                UpOnlyValueField(mode == .bankBalances ? "0.00" : "0", text: quantity)
                    .font(.system(size: 38, weight: .medium).monospacedDigit()).textFieldStyle(.plain).multilineTextAlignment(.center)
                    .focused($amountFocused).accessibilityLabel(mode == .bankBalances ? "Bank balance" : "Total quantity")
            }.padding(.vertical, 8).frame(maxWidth: .infinity)
            if mode == .metals {
                Picker("Weight unit", selection: $row.holding.unit) { Text("Grams").tag("g"); Text("Kilograms").tag("kg"); Text("Troy oz").tag("ozt") }.pickerStyle(.segmented).labelsHidden()
            }
            if mode == .bankBalances {
                HStack { Text("As of").font(.system(size: 12)).foregroundStyle(.secondary); Spacer(); UpOnlyDateButton(date: date) }
                    .padding(12).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Portfolio").font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                        if !portfolios.isEmpty {
                            Menu {
                                ForEach(portfolios) { portfolio in Button(portfolio.name) { row.holding.portfolioID = portfolio.id; row.holding.portfolioName = portfolio.name } }
                                Divider()
                                Button("New portfolio") { row.holding.portfolioID = nil; row.holding.portfolioName = "" }
                            } label: { Text(row.holding.portfolioID == nil ? "Choose existing" : row.holding.portfolioName).fixedSize(horizontal: false, vertical: true).font(.system(size: 12)) }.menuStyle(.borderedButton)
                        }
                    }
                    if row.holding.portfolioID == nil {
                        entryField(mode == .metals ? "Home safe" : "Ledger or Coinbase", text: $row.holding.portfolioName).accessibilityLabel("Portfolio name")
                        UpOnlyOwnerPicker(owner: $row.holding.ownerBusinessID)
                    }
                }.padding(12).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
            }
            primary(mode == .bankBalances ? "Review balance" : "Review holding") { Task { await evaluate() } }.disabled(quantity.wrappedValue.isEmpty || working)
        }.task { amountFocused = true }
    }
    private var reviewAmount: some View {
        VStack(spacing: 16) {
            VStack(spacing: 5) {
                UpOnlyPrivateText(quantity.wrappedValue).font(.system(size: 34, weight: .semibold).monospacedDigit()).fixedSize(horizontal: false, vertical: true)
                Text(mode == .bankBalances ? row.bank.account.currency : mode == .metals ? row.holding.unit + " pure metal weight" : coin?.symbol.uppercased() ?? "total quantity").font(.system(size: 12)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity).padding(.vertical, 6)
            VStack(spacing: 12) {
                if mode == .bankBalances { reviewLine("As of", date.wrappedValue.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: UTCDay.timeZone))); reviewLine("Account", row.bank.account.existingID == nil ? "Create new" : "Update balance") }
                else {
                    reviewLine("Portfolio", row.holding.portfolioName)
                    if let state = review?.states[row.id] { Text(state.displayText(privacy: session.privacyMode)).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
            }.padding(14).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
            primary(mode == .bankBalances ? "Save balance" : "Save holding") { Task { await save() } }.disabled(working || review?.hasErrors != false || review?.added == 0)
        }
    }
    private func reviewLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) { Text(label).foregroundStyle(.secondary); Spacer(minLength: 8); Text(value).multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true) }.font(.system(size: 12))
    }
    private func entryField(_ placeholder: String, text: Binding<String>, size: CGFloat = 14, symbol: String? = nil) -> some View {
        HStack(spacing: 8) {
            if let symbol { Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(.secondary) }
            TextField(placeholder, text: text, axis: .vertical)
                .font(.system(size: size, weight: size > 18 ? .medium : .regular)).textFieldStyle(.plain)
        }.padding(.vertical, 10)
            .overlay(alignment: .bottom) { Rectangle().fill(.primary.opacity(0.12)).frame(height: 1) }
    }
    private func currencyButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if selected { Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)) }
                Text(title).font(.system(size: 12, weight: selected ? .medium : .regular))
            }.frame(maxWidth: .infinity).padding(.vertical, 9)
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
                .background(selected ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.045), in: Capsule())
                .contentShape(Capsule())
        }.buttonStyle(UpOnlyCardButtonStyle(radius: 18)).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.system(size: 14, weight: .medium)).frame(maxWidth: .infinity).frame(height: 28) }
            .buttonStyle(.glassProminent).buttonBorderShape(.capsule).controlSize(.large).keyboardShortcut(.defaultAction)
    }
    private func assetButton(name: String, caption: String, mode: ImportMode, symbol: String = "", image: Data? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                UpOnlyEntryBadge(mode: mode, symbol: symbol, image: image, size: 36)
                VStack(alignment: .leading, spacing: 3) { Text(name).font(.system(size: 13, weight: .medium)); Text(caption).font(.system(size: 11)).foregroundStyle(.secondary) }.fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary)
            }.padding(11).frame(maxWidth: .infinity, alignment: .leading).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16)).contentShape(RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(UpOnlyCardButtonStyle(radius: 16))
    }
    private func evaluate() async {
        guard let batch = session.importDraft, let document = session.document else { return }
        working = true; error = nil; unchanged = false
        let token = session.sessionToken, catalog = session.catalog
        let result = await Task.detached(priority: .userInitiated) { ImportBatchProcessor.evaluate(batch, document: document, catalog: catalog) }.value
        guard token == session.sessionToken else { return }
        working = false; review = result
        if result.hasErrors { error = result.globalError ?? result.sourceErrors.values.first ?? result.states.values.first(where: \.blocksSave)?.text }
        else if result.added == 0 { unchanged = true }
        else { amountFocused = false; step = 2 }
    }
    private func save() async {
        guard let batch = session.importDraft, review?.hasErrors == false else { return }
        working = true; error = nil
        let token = session.sessionToken
        do {
            try await session.commitImportBatch(batch)
            if token == session.sessionToken { saved() }
        } catch { if token == session.sessionToken { self.error = error.localizedDescription; working = false } }
    }
}

struct UpOnlyImportView: View {
    @Environment(UpOnlySession.self) private var session
    @State private var review: ImportEvaluation?
    @State private var reviewing = false
    @State private var reviewTask: Task<ImportEvaluation, Never>?
    @State private var mappingTask: Task<[ImportDraftRow], Error>?
    @State private var reviewRevision = UUID()
    @State private var mappingChanged = Set<UUID>()
    @State private var selection = Set<UUID>()
    @State private var page = 0
    @State private var error: String?
    @State private var dropTargeted = false
    @State private var discard = false
    @State private var starterRow: (id: UUID, content: ImportRowContent)?
    private let pageSize = 50
    private var accounts: [Account] { session.document?.accounts ?? [] }
    private var portfolios: [Portfolio] { session.document?.portfolios.filter { !$0.isArchived && $0.kind == (session.importDraft?.mode.kind ?? .crypto) } ?? [] }
    private var coins: [CatalogCoin] { session.document.map { ImportCoins.available(document: $0, catalog: session.catalog) } ?? ImportCoins.common }
    private var busy: Bool { reviewing || session.importLoading || session.isBusy }
    var body: some View {
        Group {
        if discard {
            UpOnlyConfirmation(title: "Discard this unsaved draft?", detail: "Your saved information stays unchanged.", confirmTitle: "Discard draft", confirm: { discard = false; session.discardImport(); resetView() }, cancel: { discard = false }).padding(16)
        } else {
        Group {
        if let batch = session.importDraft, batch.mode != .statements, batch.rows.count <= 1, batch.sources.allSatisfy({ $0.grid.isEmpty }), !session.importTableMode {
            UpOnlyMenuScroll { UpOnlyEntryFlow(compact: true) }
        } else {
        UpOnlyMenuScroll {
        VStack(alignment: .leading, spacing: 16) {
            if let batch = session.importDraft {
                batchHeader(batch)
                inputActions
                if let message = session.importMessage { Text(message).fixedSize(horizontal: false, vertical: true).font(.callout).foregroundStyle(.secondary) }
                if session.importLoading {
                    HStack { ProgressView().controlSize(.small); Text("Reading your files on this Mac…").fixedSize(horizontal: false, vertical: true); Spacer(); Button("Cancel reading") { session.cancelImport() } }
                }
                ForEach(batch.sources) { source in
                    if !source.grid.isEmpty || (batch.mode == .statements && batch.rows.contains(where: { $0.sourceID == source.id })) { sourceCard(source, mode: batch.mode) }
                }
                if !batch.rows.isEmpty {
                    if batch.rows.count > 1 || batch.mode == .statements { rowActions(batch) }
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(batch.rows.dropFirst(page * pageSize).prefix(pageSize))) { row in
                            ImportRowEditor(row: rowBinding(row), mode: batch.mode, accounts: accounts, portfolios: portfolios, coins: coins,
                                            usesDebitCredit: batch.sources.first(where: { $0.id == row.sourceID }).map { $0.mapping[.debit] != nil || $0.mapping[.credit] != nil } ?? false,
                                            sourceName: batch.sources.first(where: { $0.id == row.sourceID })?.filename ?? "", state: review?.states[row.id], selected: selection.contains(row.id),
                                            manual: batch.sources.first(where: { $0.id == row.sourceID })?.grid.isEmpty == true,
                                            select: { if selection.contains(row.id) { selection.remove(row.id) } else { selection.insert(row.id) } },
                                            remove: { invalidateReview(); session.importDraft?.rows.removeAll { $0.id == row.id }; clampPage() }).disabled(busy)
                        }
                    }
                    if batch.rows.count > pageSize {
                        HStack {
                            Button("Previous rows") { page = max(0, page - 1) }.disabled(page == 0)
                            Text("\(page * pageSize + 1)–\(min((page + 1) * pageSize, batch.rows.count)) of \(batch.rows.count)").fixedSize(horizontal: false, vertical: true).font(.caption).monospacedDigit()
                            Button("Next rows") { page += 1 }.disabled((page + 1) * pageSize >= batch.rows.count)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        UpOnlySymbolBadge(symbol: batch.mode == .statements ? "doc.on.doc" : batch.mode.kind.symbol, tint: batch.mode.kind.tint, size: 42)
                        Text(batch.mode == .statements ? "Drop your statements here" : "Start with one, add as many as you like").fixedSize(horizontal: false, vertical: true).font(.headline)
                        Text(batch.mode == .statements ? "Choose several CSVs at once. You’ll review them before saving." : "Type a balance or paste a table from your spreadsheet.").fixedSize(horizontal: false, vertical: true).font(.callout).foregroundStyle(.secondary)
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                        .background(batch.mode.kind.tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                }
                if let error { Text(error).fixedSize(horizontal: false, vertical: true).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                if let review {
                    if let global = review.globalError { Text(global).fixedSize(horizontal: false, vertical: true).foregroundStyle(.red) }
                    ForEach(batch.sources) { source in
                        if let problem = review.sourceErrors[source.id] { Text(source.filename + ": " + problem).fixedSize(horizontal: false, vertical: true).font(.caption).foregroundStyle(.red) }
                    }
                }
                if !mappingChanged.isEmpty { Text("Apply your column mapping before reviewing.").fixedSize(horizontal: false, vertical: true).font(.caption).foregroundStyle(.secondary) }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Menu {
                        ForEach(orderedModes, id: \.self) { mode in
                            Button(mode.title) { openMode(mode, bulk: true) }
                        }
                    } label: { Label("Import or paste…", systemImage: "doc.on.clipboard") }
                        .menuStyle(.borderedButton).fixedSize().accessibilityIdentifier("BulkImportOptions")
                }
                if let message = session.importMessage { Label(message, systemImage: "checkmark.circle.fill").fixedSize(horizontal: false, vertical: true).foregroundStyle(UpOnlyTint.cashFlow) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 14)], spacing: 14) {
                    ForEach(orderedModes, id: \.self) { mode in
                        VStack(alignment: .leading, spacing: 16) {
                        Button { openMode(mode) } label: {
                        VStack(alignment: .leading, spacing: 16) {
                            UpOnlySymbolBadge(symbol: mode.kind.symbol, tint: mode.kind.tint, size: 40)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(mode.title).fixedSize(horizontal: false, vertical: true).font(.system(size: 16, weight: .semibold))
                                Text(modeDescription(mode)).fixedSize(horizontal: false, vertical: true).font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            Label(mode == .statements ? "Choose statements" : "Add manually", systemImage: "arrow.right").font(.system(size: 12, weight: .medium)).foregroundStyle(mode.kind.tint)
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.bordered)
                        if mode != .statements, session.document?.hasData(mode.kind) == true {
                            Button(mode == .bankBalances ? "Update existing balances" : mode == .holdings ? "Update existing quantities" : "Update existing weights") { session.startImport(mode, prefill: true); resetView() }
                                .buttonStyle(.bordered).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        }.padding(UpOnlyLayout.inset).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.06)))
                    }
                }
            }
            if let batch = session.importDraft, batch.mode != .statements || !batch.rows.isEmpty || busy { importFooter(batch) }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }.background(Color(nsColor: .windowBackgroundColor))
        }
        }
        }
        }
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(dropTargeted ? UpOnlyTint.netWorth : .clear, lineWidth: 2))
        .dropDestination(for: URL.self) { urls, _ in
            guard !busy, !urls.isEmpty else { return false }
            if session.importDraft == nil { session.startImport(.statements) }
            prepareExternalInput(); Task { await session.readImportFiles(urls) }; return true
        } isTargeted: { dropTargeted = $0 }
        .onChange(of: session.importRevision) { _, _ in invalidateReview(); clampPage() }
        .onAppear { if let batch = session.importDraft, batch.mode != .statements, batch.rows.isEmpty, batch.sources.allSatisfy({ $0.grid.isEmpty }) { addRow() } }
        .onDisappear { invalidateReview() }
    }
    private func importFooter(_ batch: ImportBatchDraft) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let review {
                UpOnlyFlow(spacing: 12) {
                    Label(review.readyRows == 0 && review.added > 0 ? "Statement updates ready to save" : "\(review.readyRows) ready to save", systemImage: "checkmark.circle").foregroundStyle(UpOnlyTint.cashFlow)
                    if review.duplicates > 0 { Text("\(review.duplicates) duplicates skipped").foregroundStyle(.secondary) }
                    if review.hasErrors { Label("Needs attention", systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
                }.font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            }
            UpOnlyFlow(spacing: 8) {
                if session.importLoading {
                    ProgressView().controlSize(.small)
                    Button("Cancel reading") { session.cancelImport() }.buttonStyle(.bordered)
                } else if reviewing {
                    ProgressView().controlSize(.small)
                    Button("Cancel review") { invalidateReview() }.buttonStyle(.bordered)
                } else if review != nil {
                    Button("Back to editing") { invalidateReview() }.buttonStyle(.bordered)
                } else if batch.mode != .statements {
                    Button { addRow() } label: { Label(addRowTitle(batch.mode), systemImage: "plus") }.buttonStyle(.bordered).disabled(busy)
                }
                if let review {
                    Button("Save reviewed changes") { Task { await save() } }.buttonStyle(.glassProminent)
                        .disabled(busy || review.hasErrors || review.added == 0 || !mappingChanged.isEmpty)
                } else if !batch.rows.isEmpty {
                    Button("Review changes") { beginReview() }.buttonStyle(.glassProminent)
                        .disabled(busy || batch.rows.isEmpty || !mappingChanged.isEmpty)
                }
            }.controlSize(.regular).font(.system(size: 12))
        }.padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Divider() }
    }
    private var orderedModes: [ImportMode] {
        ImportMode.allCases.sorted { lhs, rhs in
            let left = session.document?.shows(lhs.kind) == true, right = session.document?.shows(rhs.kind) == true
            if left != right { return left }
            return ImportMode.allCases.firstIndex(of: lhs)! < ImportMode.allCases.firstIndex(of: rhs)!
        }
    }
    private func modeDescription(_ mode: ImportMode) -> String {
        switch mode {
        case .statements: "Your income and spending, from CSV files."
        case .bankBalances: "What’s in each account, as of a date."
        case .metals: "Your gold and silver weights."
        case .holdings: "The coins you own, wherever you keep them."
        }
    }
    private func batchHeader(_ batch: ImportBatchDraft) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(batch.mode == .statements ? "Import transactions, with an optional closing balance." : batch.mode == .metals ? "Enter pure metal weight, excluding alloys. Prices exclude dealer premiums." : batch.mode == .holdings ? "Enter total quantities, not changes in quantity." : "A snapshot of your accounts. Overdrafts and zero balances are welcome.").fixedSize(horizontal: false, vertical: true)
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private var inputActions: some View {
        if session.importDraft?.mode == .statements {
            if session.importDraft?.rows.isEmpty == true {
                Button { prepareExternalInput(); Task { await session.chooseImportFiles() } } label: {
                    Label("Choose CSV files…", systemImage: "doc.badge.plus")
                }.buttonStyle(.glassProminent).disabled(busy)
            } else {
                Menu {
                    Button("Add CSV files…") { prepareExternalInput(); Task { await session.chooseImportFiles() } }
                    Divider()
                    Button("Discard draft…", role: .destructive) { discard = true }
                } label: { Label("CSV files", systemImage: "doc.on.doc") }
                    .modifier(UpOnlyPillMenu()).accessibilityLabel("Statement files").disabled(busy)
            }
        } else {
        Menu {
            Button("Choose CSV files…") { prepareExternalInput(); Task { await session.chooseImportFiles() } }
            Button("Paste from spreadsheet") {
                guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { error = "Copy some spreadsheet cells first."; return }
                prepareExternalInput(); Task { await session.pasteImport(text) }
            }
            Button("Download CSV template…") { Task { await session.saveImportTemplate() } }
            if let batch = session.importDraft, !batch.rows.isEmpty {
                Divider()
                Button("Discard draft…", role: .destructive) { discard = true }
            }
        } label: { Label("Import options", systemImage: "doc.badge.plus") }
            .modifier(UpOnlyPillMenu()).accessibilityLabel("Import options").disabled(busy)
        }
    }
    private func openMode(_ mode: ImportMode, bulk: Bool = false) {
        guard session.startImport(mode) else { return }; resetView()
        session.importTableMode = bulk
        if mode != .statements { addRow() }
    }
    private func addRowTitle(_ mode: ImportMode) -> String {
        switch mode { case .statements: "Add transaction"; case .bankBalances: "Add account"; case .holdings: "Add coin"; case .metals: "Add metal" }
    }
    private func sourceCard(_ source: ImportSourceDraft, mode: ImportMode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(source.filename, systemImage: source.grid.isEmpty ? "square.and.pencil" : "doc.text").fixedSize(horizontal: false, vertical: true).font(.headline)
                Spacer()
                let count = session.importDraft?.rows.filter { $0.sourceID == source.id }.count ?? 0
                Text("\(count) \(count == 1 ? "row" : "rows")").fixedSize(horizontal: false, vertical: true).font(.caption).foregroundStyle(.secondary)
                Button { invalidateReview(); session.importDraft?.rows.removeAll { $0.sourceID == source.id }; session.importDraft?.sources.removeAll { $0.id == source.id }; mappingChanged.remove(source.id); clampPage() } label: { Image(systemName: "xmark.circle") }.buttonStyle(.bordered).help("Remove this source and its rows").accessibilityLabel("Remove " + source.filename)
            }
            if let review {
                let rows = session.importDraft?.rows.filter { $0.sourceID == source.id } ?? []
                let states = rows.compactMap { review.states[$0.id] }
                UpOnlyFlow(spacing: 10) {
                    Text("\(states.filter { if case .ready = $0 { return true }; return false }.count) new")
                    let duplicates = states.filter { $0 == .duplicate }.count
                    if duplicates > 0 { Text("\(duplicates) duplicates") }
                    let errors = states.filter(\.blocksSave).count
                    if errors > 0 { Text("\(errors) need attention").foregroundStyle(.orange) }
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if mode == .statements {
                ImportAccountEditor(account: Binding(get: { source.account }, set: { account in
                    let previousCurrency = source.account.currency
                    sourceBinding(source, \.account).wrappedValue = account
                    if source.mapping[.currency] == nil, var batch = session.importDraft {
                        for index in batch.rows.indices where batch.rows[index].sourceID == source.id && batch.rows[index].statement.currency == previousCurrency {
                            batch.rows[index].statement.currency = account.currency
                            batch.rows[index].duplicateApproved = false
                        }
                        session.importDraft = batch
                    }
                }), accounts: accounts)
                HStack {
                    UpOnlyValueField("Optional bank balance", text: sourceBinding(source, \.balance)).textFieldStyle(.roundedBorder)
                    UpOnlyDateButton(date: Binding(get: { (try? ImportDateFormat.iso.date(source.balanceDate)) ?? Date() }, set: { sourceBinding(source, \.balanceDate).wrappedValue = ImportDateFormat.today($0) }))
                    if !source.balance.isEmpty, (try? ImportDateFormat.iso.date(source.balanceDate)) == nil {
                        Text("Choose a valid balance date.").font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                if !mode.isHolding { Picker("Dates", selection: sourceBinding(source, \.dateFormat)) { ForEach(ImportDateFormat.allCases, id: \.self) { Text($0.rawValue).fixedSize(horizontal: false, vertical: true).tag($0) } } }
                Picker("Numbers", selection: sourceBinding(source, \.numberFormat)) { ForEach(ImportNumberFormat.allCases, id: \.self) { Text($0.rawValue).fixedSize(horizontal: false, vertical: true).tag($0) } }
            }.font(.caption)
            if !source.grid.isEmpty {
                DisclosureGroup("Map columns · \(source.hasHeader ? "First row is a header" : "No header")") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("First row contains column names", isOn: Binding(get: { source.hasHeader }, set: { value in
                            var updated = source; updated.hasHeader = value
                            if value { updated.mapping = ImportParser.guessMapping(source.grid.first ?? [], mode: mode) }
                            replaceSource(updated); mappingChanged.insert(source.id)
                        })).toggleStyle(.checkbox)
                        LazyVGrid(columns: [GridItem(.flexible())], alignment: .leading) {
                            ForEach(mode.columns, id: \.self) { column in
                                Picker(column.title, selection: Binding(get: { source.mapping[column] ?? -1 }, set: { index in
                                    var updated = source
                                    if index < 0 { updated.mapping.removeValue(forKey: column) } else { updated.mapping[column] = index }
                                    replaceSource(updated); mappingChanged.insert(source.id)
                                })) {
                                    Text("Not provided").fixedSize(horizontal: false, vertical: true).tag(-1)
                                    ForEach(Array(source.headers.enumerated()), id: \.offset) { index, _ in Text("Column \(index + 1)").fixedSize(horizontal: false, vertical: true).tag(index) }
                                }
                            }
                        }
                        DisclosureGroup("Full column names") {
                            ForEach(Array(source.headers.enumerated()), id: \.offset) { index, title in
                                Text("Column \(index + 1): " + title).font(.caption).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Text("Applying mapping rebuilds this source’s rows. Make row corrections afterward.").fixedSize(horizontal: false, vertical: true).font(.caption).foregroundStyle(.secondary)
                        Button("Apply mapping") { applyMapping(source) }.disabled(busy)
                    }.padding(.top, 8)
                }.font(.callout)
            }
        }.padding(14).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12)).disabled(busy)
    }
    private func rowActions(_ batch: ImportBatchDraft) -> some View {
        UpOnlyFlow {
            Menu(selection.isEmpty ? "Select rows" : "Selected rows (\(selection.count))") {
                Button(selection.count == batch.rows.count ? "Clear selection" : "Select all rows") { selection = selection.count == batch.rows.count ? [] : Set(batch.rows.map(\.id)) }
                if !selection.isEmpty {
                    Divider()
                    if batch.mode == .statements {
                        Button("Mark as Income") { editSelected { $0.statement.kind = .income } }
                        Button("Mark as Expense") { editSelected { $0.statement.kind = .expense } }
                        Button("Mark as Transfer") { editSelected { $0.statement.kind = .transfer } }
                    }
                    Button("Exclude") { editSelected { $0.included = false } }
                    Button("Include") { editSelected { $0.included = true } }
                }
            }
            Spacer()
            Text("\(batch.rows.filter(\.included).count) included").fixedSize(horizontal: false, vertical: true).font(.caption).foregroundStyle(.secondary)
        }.font(.caption).disabled(busy)
    }
    private func sourceBinding<T>(_ source: ImportSourceDraft, _ path: WritableKeyPath<ImportSourceDraft, T>) -> Binding<T> {
        Binding(get: { session.importDraft?.sources.first(where: { $0.id == source.id })?[keyPath: path] ?? source[keyPath: path] }, set: { value in
            guard let index = session.importDraft?.sources.firstIndex(where: { $0.id == source.id }) else { return }
            invalidateReview(); session.importDraft?.sources[index][keyPath: path] = value
        })
    }
    private func rowBinding(_ row: ImportDraftRow) -> Binding<ImportDraftRow> {
        Binding(get: { session.importDraft?.rows.first(where: { $0.id == row.id }) ?? row }, set: { value in
            guard let index = session.importDraft?.rows.firstIndex(where: { $0.id == row.id }) else { return }
            var updated = value
            if session.importDraft?.rows[index].content != updated.content { updated.duplicateApproved = false }
            invalidateReview(); session.importDraft?.rows[index] = updated
        })
    }
    private func replaceSource(_ source: ImportSourceDraft) {
        guard let index = session.importDraft?.sources.firstIndex(where: { $0.id == source.id }) else { return }
        invalidateReview(); session.importDraft?.sources[index] = source
    }
    private func applyMapping(_ source: ImportSourceDraft) {
        guard let mode = session.importDraft?.mode else { return }
        invalidateReview(); reviewing = true
        let token = session.sessionToken, revision = reviewRevision
        Task {
            do {
                let task = Task.detached(priority: .userInitiated) { try ImportParser.rows(source: source, mode: mode) }
                mappingTask = task
                let rows = try await task.value
                guard token == session.sessionToken, revision == reviewRevision else { return }
                session.importDraft?.rows.removeAll { $0.sourceID == source.id }
                session.importDraft?.rows.append(contentsOf: rows)
                mappingChanged.remove(source.id); clampPage()
            } catch { if token == session.sessionToken, revision == reviewRevision { self.error = error.localizedDescription } }
            if token == session.sessionToken, revision == reviewRevision { reviewing = false }
        }
    }
    private func editSelected(_ change: (inout ImportDraftRow) -> Void) {
        guard var batch = session.importDraft else { return }; invalidateReview()
        for index in batch.rows.indices where selection.contains(batch.rows[index].id) { change(&batch.rows[index]) }
        session.importDraft = batch
    }
    private func addRow() {
        guard var batch = session.importDraft, batch.mode != .statements else { return }; invalidateReview()
        if !batch.sources.contains(where: { $0.grid.isEmpty }) { batch.sources.append(ImportSourceDraft(filename: "Manual entry", bytes: Data(), grid: [])) }
        let source = batch.sources.first(where: { $0.grid.isEmpty })!
        let previous = batch.mode.isHolding ? batch.rows.last?.holding : nil
        let portfolio = portfolios.count == 1 ? portfolios.first : nil
        let content: ImportRowContent
        switch batch.mode {
        case .statements: return
        case .bankBalances: content = .bankBalance(BankBalanceInput())
        case .holdings, .metals: content = .holding(HoldingInput(portfolioID: previous?.portfolioID ?? portfolio?.id, portfolioName: previous?.portfolioName ?? portfolio?.name ?? (batch.mode == .metals ? "My metals" : "My crypto")))
        }
        let row = ImportDraftRow(sourceID: source.id, line: batch.rows.filter { $0.sourceID == source.id }.count + 1, content: content)
        if batch.rows.isEmpty { starterRow = (row.id, content) }
        batch.rows.append(row)
        session.importDraft = batch; page = (batch.rows.count - 1) / pageSize
    }
    private func prepareExternalInput() {
        invalidateReview()
        if let starterRow { session.importDraft?.rows.removeAll { $0.id == starterRow.id && $0.content == starterRow.content } }
        starterRow = nil
    }
    private func beginReview() {
        guard let batch = session.importDraft, let document = session.document else { return }
        invalidateReview(); reviewing = true
        let token = session.sessionToken, revision = reviewRevision, catalog = session.catalog
        let task = Task.detached(priority: .userInitiated) { ImportBatchProcessor.evaluate(batch, document: document, catalog: catalog) }
        reviewTask = task
        Task {
            let evaluated = await task.value
            guard token == session.sessionToken, revision == reviewRevision, !task.isCancelled else { return }
            review = evaluated; reviewing = false; reviewTask = nil
        }
    }
    private func invalidateReview() {
        reviewTask?.cancel(); reviewTask = nil; mappingTask?.cancel(); mappingTask = nil; review = nil; reviewing = false; error = nil; reviewRevision = UUID()
    }
    private func clampPage() { page = min(page, max(0, ((session.importDraft?.rows.count ?? 0) - 1) / pageSize)) }
    private func resetView() { invalidateReview(); mappingChanged = []; selection = []; page = 0; starterRow = nil }
    private func save() async {
        guard let batch = session.importDraft, let review, !review.hasErrors else { return }
        let token = session.sessionToken
        do { try await session.commitImportBatch(batch); resetView() }
        catch { if token == session.sessionToken { invalidateReview(); self.error = error.localizedDescription } }
    }
}

private struct ImportField<Content: View>: View {
    var title: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
private struct ImportAccountEditor: View {
    @Binding var account: ImportAccount
    var accounts: [Account]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ImportField(title: "Account") {
                HStack(spacing: 8) {
                    if account.existingID == nil { TextField("e.g. Everyday account", text: $account.name, axis: .vertical).textFieldStyle(.roundedBorder).accessibilityLabel("New account name") }
                    else { Text(account.name).font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading) }
                    Menu {
                        Button("Create new account") { account.existingID = nil; account.name = "" }
                        ForEach(accounts) { item in
                            Button(item.name + " · " + item.currency) { account = ImportAccount(existingID: item.id, name: item.name, currency: item.currency) }
                        }
                    } label: { Label(account.existingID == nil ? "Choose existing" : "Change", systemImage: "chevron.down").font(.system(size: 11)) }
                        .menuStyle(.borderedButton).menuIndicator(.hidden).fixedSize().disabled(accounts.isEmpty && account.existingID == nil)
                }
            }
            ImportField(title: "Currency") {
                TextField("USD", text: $account.currency, axis: .vertical).textFieldStyle(.roundedBorder).disabled(account.existingID != nil).accessibilityLabel("Account currency")
            }.frame(width: 76)
            if account.existingID == nil { UpOnlyOwnerPicker(owner: $account.ownerBusinessID) }
        }
    }
}
private struct ImportRowEditor: View {
    @Environment(UpOnlySession.self) private var session
    @Binding var row: ImportDraftRow
    var mode: ImportMode
    var accounts: [Account]
    var portfolios: [Portfolio]
    var coins: [CatalogCoin]
    var usesDebitCredit: Bool
    var sourceName: String
    var state: ImportRowState?
    var selected: Bool
    var manual: Bool
    var select: () -> Void
    var remove: () -> Void
    @State private var search = ""
    @State private var choosingCoin = false
    private var matches: [CatalogCoin] { ImportCoins.suggestions(search, coins: coins) }
    var body: some View {
        VStack(alignment: .leading, spacing: mode == .statements ? 10 : 18) {
            HStack {
                if mode == .statements || !manual {
                    Button(action: select) { Image(systemName: selected ? "checkmark.square.fill" : "square") }.buttonStyle(.bordered).accessibilityLabel("Select row \(row.line)")
                }
                Text(manual ? (mode == .bankBalances ? "Bank balance" : mode == .metals ? "Metal holding" : mode == .holdings ? "Crypto holding" : "Transaction") : sourceName + " · Row \(row.line)")
                    .fixedSize(horizontal: false, vertical: true).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                if !row.included { Text("Excluded").font(.caption).foregroundStyle(.secondary) }
                Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                    .accessibilityLabel("Remove row \(row.line)")
            }
            Group {
                switch mode {
                case .statements: statementFields
                case .bankBalances: bankFields
                case .holdings, .metals: holdingFields
                }
            }.disabled(!row.included).opacity(row.included ? 1 : 0.5)
            if let state {
                Label(state.displayText(privacy: session.privacyMode), systemImage: state.blocksSave ? "exclamationmark.circle" : "checkmark.circle")
                    .fixedSize(horizontal: false, vertical: true).font(.system(size: 12)).foregroundStyle(state.blocksSave ? Color.orange : UpOnlyTint.cashFlow)
                if case .needsReview = state {
                    Button("This is a separate payment") { row.duplicateApproved = true }.font(.caption)
                }
            }
            if row.duplicateApproved { Label("Confirmed as a separate payment", systemImage: "checkmark").fixedSize(horizontal: false, vertical: true).font(.caption).foregroundStyle(.secondary) }
            if let issue = row.parseError {
                Text(issue).fixedSize(horizontal: false, vertical: true).font(.caption).foregroundStyle(.orange)
                Button("I’ve corrected this row’s fields") { row.parseError = nil }.font(.caption)
            }
        }.padding(mode == .statements ? 14 : 20).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? mode.kind.tint : Color.primary.opacity(0.06)))
            .textFieldStyle(.roundedBorder)
    }
    private var statementFields: some View {
        VStack(spacing: 8) {
            TextField("Description", text: $row.statement.label, axis: .vertical)
            HStack {
                TextField("Date", text: $row.statement.date, axis: .vertical)
                TextField("Currency", text: $row.statement.currency, axis: .vertical).frame(width: 60)
            }
            VStack(alignment: .leading, spacing: 8) {
                if usesDebitCredit {
                    UpOnlyValueField("Money out", text: $row.statement.debit)
                    UpOnlyValueField("Money in", text: $row.statement.credit)
                } else { UpOnlyValueField("Amount", text: $row.statement.amount) }
                Picker("Type", selection: $row.statement.kind) {
                    Text("Income").fixedSize(horizontal: false, vertical: true).tag(EntryKind.income); Text("Expense").fixedSize(horizontal: false, vertical: true).tag(EntryKind.expense); Text("Transfer").fixedSize(horizontal: false, vertical: true).tag(EntryKind.transfer)
                }.frame(width: 155)
                TextField("Transaction ID (optional)", text: $row.statement.transactionID, axis: .vertical)
            }
        }
    }
    private var bankFields: some View {
        VStack(spacing: 16) {
            ImportAccountEditor(account: $row.bank.account, accounts: accounts)
            VStack(alignment: .leading, spacing: 12) {
                ImportField(title: "Balance") {
                    UpOnlyValueField("0.00", text: $row.bank.balance)
                        .font(.system(size: 24, weight: .medium).monospacedDigit()).textFieldStyle(.plain).accessibilityLabel("Bank balance")
                }
                ImportField(title: "As of") {
                    if manual, (try? ImportDateFormat.iso.date(row.bank.date)) != nil {
                        UpOnlyDateButton(date: Binding(get: { (try? ImportDateFormat.iso.date(row.bank.date)) ?? Date() }, set: { row.bank.date = ImportDateFormat.today($0) }))
                    } else {
                        TextField("yyyy-MM-dd", text: $row.bank.date, axis: .vertical).accessibilityLabel("Balance observation date")
                    }
                }.frame(width: 142)
            }
        }
    }
    private var holdingFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            if mode == .metals {
                VStack(alignment: .leading, spacing: 12) {
                    ImportField(title: "Metal") {
                    Picker("Metal", selection: Binding(get: { (try? PreciousMetal.resolve(row.holding.coin))?.rawValue ?? row.holding.coin }, set: { row.holding.coin = $0 })) {
                        Text("Choose metal").tag("")
                        if !row.holding.coin.isEmpty && (try? PreciousMetal.resolve(row.holding.coin)) == nil { Text("Check metal").tag(row.holding.coin) }
                        ForEach(PreciousMetal.selectable, id: \.self) { Text($0.name).tag($0.rawValue) }
                    }.labelsHidden()
                    }
                    ImportField(title: "Unit") {
                    Picker("Unit", selection: Binding(get: { (try? MetalWeightUnit.resolve(row.holding.unit))?.rawValue ?? row.holding.unit }, set: { row.holding.unit = $0 })) {
                        if (try? MetalWeightUnit.resolve(row.holding.unit)) == nil { Text(row.holding.unit.isEmpty ? "Choose unit" : "Check unit").tag(row.holding.unit) }
                        ForEach(MetalWeightUnit.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                    }.labelsHidden()
                    }
                }
                if !row.holding.coin.isEmpty && (try? PreciousMetal.resolve(row.holding.coin)) == nil {
                    Text("Choose a supported metal for “" + row.holding.coin + "”.").font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if !row.holding.unit.isEmpty && (try? MetalWeightUnit.resolve(row.holding.unit)) == nil {
                    Text("Choose grams, kilograms or troy ounces for “" + row.holding.unit + "”.").font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ImportField(title: "Coin") {
                    Button { search = row.holding.resolvedCoinID.isEmpty ? row.holding.coin : ""; choosingCoin = true } label: {
                        HStack(spacing: 10) {
                            UpOnlySymbolBadge(symbol: "circle.hexagongrid.fill", tint: UpOnlyTint.crypto, size: 30)
                            Text(row.holding.resolvedCoinID.isEmpty ? (row.holding.coin.isEmpty ? "Choose a coin" : "Resolve “" + row.holding.coin + "”") : row.holding.assetName.isEmpty ? row.holding.resolvedCoinID : row.holding.assetName)
                                .font(.system(size: 14, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Image(systemName: "chevron.down").font(.system(size: 10)).foregroundStyle(.secondary)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.bordered).accessibilityIdentifier("ImportCoinPicker").popover(isPresented: $choosingCoin) { coinPicker }
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                ImportField(title: mode == .metals ? "Total pure metal weight" : "Total quantity") {
                    UpOnlyValueField("0", text: $row.holding.quantity)
                        .font(.system(size: 24, weight: .medium).monospacedDigit()).textFieldStyle(.plain)
                        .accessibilityLabel(mode == .metals ? "Total fine metal weight" : "Total coin quantity")
                }
                ImportField(title: "Portfolio") {
                    if row.holding.portfolioID == nil {
                        TextField(mode == .metals ? "My metals" : "My crypto", text: $row.holding.portfolioName, axis: .vertical).accessibilityLabel("New portfolio name")
                        UpOnlyOwnerPicker(owner: $row.holding.ownerBusinessID)
                    }
                    Menu {
                        Button("Create new portfolio") { row.holding.portfolioID = nil; row.holding.portfolioName = "" }
                        ForEach(portfolios) { portfolio in
                            Button(portfolio.name) { row.holding.portfolioID = portfolio.id; row.holding.portfolioName = portfolio.name }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(row.holding.portfolioID == nil ? "Choose existing" : row.holding.portfolioName).fixedSize(horizontal: false, vertical: true)
                            Image(systemName: "chevron.down").font(.system(size: 9))
                        }.font(.system(size: 12))
                    }.menuStyle(.borderedButton).menuIndicator(.hidden).disabled(portfolios.isEmpty && row.holding.portfolioID == nil)
                }
            }
            if mode == .holdings {
                DisclosureGroup("Enter an exact coin ID") {
                    HStack {
                        TextField("CoinGecko ID", text: $row.holding.resolvedCoinID, axis: .vertical)
                        TextField("Display name", text: $row.holding.assetName, axis: .vertical)
                    }
                    .padding(.top, 8)
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
    private var coinPicker: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose a coin").font(.system(size: 16, weight: .semibold))
            TextField("Search name, ticker or ID", text: $search).textFieldStyle(.roundedBorder).accessibilityLabel("Search coins")
                .task(id: search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && session.catalog.isEmpty { await session.loadCatalog() }
                }
            if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(matches) { coin in
                        Button {
                            row.holding.coin = coin.id; row.holding.resolvedCoinID = coin.id; row.holding.assetName = coin.name; choosingCoin = false
                        } label: {
                            HStack(spacing: 10) {
                                Text(coin.symbol.uppercased()).font(.system(size: 10, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                                    .frame(width: 38, height: 32).background(UpOnlyTint.crypto.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(coin.name).font(.system(size: 13, weight: .medium))
                                    Text(coin.id).font(.system(size: 11)).foregroundStyle(.secondary)
                                }.fixedSize(horizontal: false, vertical: true)
                                Spacer()
                                if row.holding.resolvedCoinID == coin.id { Image(systemName: "checkmark").foregroundStyle(UpOnlyTint.crypto) }
                            }.padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.bordered).accessibilityIdentifier("ImportCoin-" + coin.id)
                    }
                    if matches.isEmpty { Text("No match. Try another name, or enter the exact coin ID in your form.").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
            }.frame(height: min(280, CGFloat(max(matches.count, 1)) * 64))
            }
            Text("Select the exact asset; tickers can be shared.").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(18).frame(width: 310)
    }
}
