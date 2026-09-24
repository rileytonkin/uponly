import SwiftUI
import AppKit

struct UpOnlyGuidedEntry: View {
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
    /// Opened from an account's or holding's Update, straight to the amount.
    @State private var preselected = false
    /// Opened from Manage's "Add account", straight to naming it.
    @State private var addingAccount = false
    @State private var initial: ImportRowContent?
    @State private var configured = false
    @FocusState private var searchFocused: Bool
    @FocusState private var amountFocused: Bool
    private var accounts: [Account] { session.document?.accounts ?? [] }
    private var activeAccounts: [Account] { accounts.filter(\.isActive) }
    private var portfolios: [Portfolio] { session.document?.portfolios.filter { !$0.isArchived && $0.kind == mode.kind } ?? [] }
    private var coins: [CatalogCoin] { ImportCoinList.coins(document: session.document, catalog: session.catalog) }
    private var coin: CatalogCoin? { coins.first { $0.id == row.holding.resolvedCoinID } }
    private var account: Account? { accounts.first { $0.id == row.bank.account.existingID } }
    private var title: String { mode == .bankBalances ? row.bank.account.name : mode == .metals ? ((try? PreciousMetal.resolve(row.holding.coin))?.name ?? "Metal") : row.holding.assetName.isEmpty ? row.holding.resolvedCoinID : row.holding.assetName }
    private var quantity: Binding<String> { mode == .bankBalances ? $row.bank.balance : $row.holding.quantity }
    private var date: Binding<Date> { Binding(get: { (try? ImportDateFormat.iso.date(row.bank.date)) ?? Date() }, set: { row.bank.date = ImportDateFormat.today($0) }) }
    private var holdingDate: Binding<Date> { Binding(get: { (try? ImportDateFormat.iso.date(row.holding.date)) ?? Date() }, set: { row.holding.date = ImportDateFormat.today($0) }) }
    private var numberFormat: ImportNumberFormat { session.importDraft?.sources.first(where: { $0.id == row.sourceID })?.numberFormat ?? .point }
    /// The amount as the app reads it, which is what gets saved.
    private var entered: Decimal? { try? numberFormat.decimal(quantity.wrappedValue, typed: true) }
    var body: some View {
        Group {
        if discard {
            UpOnlyConfirmation(title: mode == .bankBalances ? "Discard this balance?" : "Discard this holding?", confirmTitle: "Discard", confirm: back, cancel: { discard = false })
        } else {
        VStack(alignment: .leading, spacing: 16) {
            UpOnlyPageHeader(title: mode == .bankBalances ? "Bank balance" : mode == .holdings ? "Crypto" : "Gold & silver") {
                if step == 2 || (step == 1 && !preselected) { step -= 1; error = nil; review = nil }
                else if step == 0 && mode == .bankBalances && newAccount && !activeAccounts.isEmpty && !addingAccount { newAccount = false }
                else if step == 0 && exactCoin { exactCoin = false }
                // Nothing typed, or the prefilled value left as it was, is nothing to lose.
                else if quantity.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || row.content == initial { back() }
                else { discard = true }
            }.disabled(working)
            Divider()
            if step == 0 { chooseAsset }
            else {
                HStack(spacing: 12) {
                    UpOnlyEntryBadge(mode: mode, symbol: mode == .metals ? row.holding.coin : coin?.symbol.uppercased() ?? "", image: mode == .bankBalances ? account?.profileImage : nil, size: 36)
                    Text(title).font(UpOnlyType.title).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                if step == 1 { enterAmount }
                else { reviewAmount }
            }
            if unchanged {
                Text(mode == .bankBalances ? "This balance is already saved." : "This quantity is already saved.")
                    .font(UpOnlyType.body).foregroundStyle(.secondary)
                Button("Done", action: back).buttonStyle(.bordered)
            }
            if let error { Label(error, systemImage: "exclamationmark.circle").font(UpOnlyType.body).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            if working { HStack(spacing: 8) { ProgressView().controlSize(.small); Text(step == 2 ? "Saving…" : "Checking…").font(UpOnlyType.body).foregroundStyle(.secondary) } }
        }
        }
        }
        .disabled(working || session.isBusy)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: step)
        .onChange(of: row.content) { _, _ in unchanged = false; error = nil }
        .onChange(of: step) { _, _ in unchanged = false }
        .onAppear {
            // The modifier sits on a Group whose branches swap with the discard prompt (and the menu can reopen), so
            // set up once; running again would take the typed value as the starting one.
            guard !configured else { return }
            configured = true
            if mode == .bankBalances && session.importStartsNewAccount {
                row.bank.account = ImportAccount(); addingAccount = true; session.importStartsNewAccount = false
            }
            initial = row.content
            newAccount = addingAccount || activeAccounts.isEmpty || (row.bank.account.existingID == nil && !row.bank.account.name.isEmpty)
            customCurrency = !["USD", "GBP", "EUR"].contains(row.bank.account.currency)
            if mode == .bankBalances ? row.bank.account.existingID != nil : mode == .metals ? !row.holding.coin.isEmpty : !row.holding.resolvedCoinID.isEmpty { step = 1; preselected = true }
            #if UPONLY_FIXTURE
            if ProcessInfo.processInfo.environment["UPONLY_PREVIEW_ENTRY_STEP"] == "choose" { step = 0 }
            if ProcessInfo.processInfo.environment["UPONLY_PREVIEW_ENTRY_STEP"] == "account" { step = 0; newAccount = true; row.bank.account = ImportAccount() }
            if ProcessInfo.processInfo.environment["UPONLY_PREVIEW_ENTRY_STEP"] == "review" { Task { await evaluate() } }
            #endif
        }
    }
    @ViewBuilder private var chooseAsset: some View {
        Text(mode == .bankBalances ? (newAccount ? "Name your account" : "Which account?") : mode == .holdings ? "Which coin?" : "Which metal?")
            .font(UpOnlyType.title)
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
                if activeAccounts.count > 4 { entryField("Find an account", text: $search, symbol: "magnifyingglass") }
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(activeAccounts.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { item in
                            assetButton(name: item.name, caption: item.currency, mode: .bankBalances, image: item.profileImage) {
                                row.bank.account = ImportAccount(existingID: item.id, name: item.name, currency: item.currency); step = 1
                            }
                        }
                    }
                }.frame(maxHeight: activeAccounts.count > 3 ? 208 : CGFloat(activeAccounts.count) * 64)
                Button {
                    if row.bank.account.existingID != nil { row.bank.account.existingID = nil; row.bank.account.name = "" }
                    customCurrency = !["USD", "GBP", "EUR"].contains(row.bank.account.currency); newAccount = true
                } label: { Label("New account", systemImage: "plus") }
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
                            Text(metal.name).font(UpOnlyType.row.weight(.medium))
                        }.frame(maxWidth: .infinity).padding(.vertical, 18)
                            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: UpOnlyLayout.radius))
                    }.buttonStyle(UpOnlyCardButtonStyle(radius: UpOnlyLayout.radius))
                }
            }
        } else if exactCoin {
            ImportField(title: "CoinGecko ID") { entryField("e.g. bitcoin", text: $row.holding.resolvedCoinID) }
            ImportField(title: "Display name") { entryField("e.g. Bitcoin", text: $row.holding.assetName) }
            primary("Continue") { row.holding.coin = row.holding.resolvedCoinID; step = 1 }.disabled(row.holding.resolvedCoinID.isEmpty)
        } else {
            entryField("Search coins", text: $search, symbol: "magnifyingglass")
                .accessibilityLabel("Search coins").focused($searchFocused).onAppear { searchFocused = true }
                .task(id: search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
                    if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { try? await Task.sleep(for: .milliseconds(250)); await session.searchCatalog(search) }
                }
            // Before typing, offer the best-known coins rather than an empty list.
            let suggestions = search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Array(ImportCoins.common.prefix(6)) : ImportCoins.suggestions(search, coins: coins)
            if !suggestions.isEmpty {
                VStack(spacing: 6) {
                    ForEach(suggestions) { coin in
                        Button {
                            row.holding.coin = coin.id; row.holding.resolvedCoinID = coin.id; row.holding.assetName = coin.name; step = 1
                        } label: {
                            HStack {
                                Text(coin.name).font(UpOnlyType.row.weight(.medium))
                                Spacer(minLength: 6)
                                Text(coin.symbol.uppercased()).font(UpOnlyType.caption).foregroundStyle(.secondary)
                                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                            }.frame(maxWidth: .infinity, minHeight: 28).contentShape(Rectangle())
                        }.buttonStyle(.bordered).help(coin.id).accessibilityIdentifier("ChooseCoin-" + coin.id)
                    }
                }
            } else if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("No matching coins").font(UpOnlyType.body).foregroundStyle(.secondary)
            }
            if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("Enter an exact coin ID") {
                    row.holding.resolvedCoinID = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: " ", with: "-"); exactCoin = true
                }.buttonStyle(.bordered).font(UpOnlyType.body).foregroundStyle(.secondary)
            }
        }
    }
    private var enterAmount: some View {
        VStack(spacing: 16) {
            VStack(spacing: 5) {
                Text(mode == .bankBalances ? "Balance · " + row.bank.account.currency : mode == .metals ? "Pure metal weight" : "Total quantity")
                    .font(UpOnlyType.caption).foregroundStyle(.secondary)
                // No placeholder: a centered one sits under the insertion point.
                UpOnlyValueField("", text: quantity)
                    .font(.system(size: 38, weight: .medium).monospacedDigit()).textFieldStyle(.plain).multilineTextAlignment(.center)
                    .focused($amountFocused).accessibilityLabel(mode == .bankBalances ? "Bank balance" : "Total quantity")
            }.padding(.vertical, 8).frame(maxWidth: .infinity)
            if mode == .metals {
                Picker("Weight unit", selection: $row.holding.unit) { Text("Grams").tag("g"); Text("Kilograms").tag("kg"); Text("Troy oz").tag("ozt") }.pickerStyle(.segmented).labelsHidden()
            }
            if mode == .bankBalances {
                HStack { Text("As of").font(UpOnlyType.body).foregroundStyle(.secondary); Spacer(); UpOnlyDateButton(date: date) }
                    .padding(UpOnlyLayout.cardInset).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: UpOnlyLayout.radius))
            } else {
                // When it was held, and optionally what it cost, so the app can show gain since purchase.
                VStack(spacing: 10) {
                    HStack { Text("As of").font(UpOnlyType.body).foregroundStyle(.secondary); Spacer(); UpOnlyDateButton(date: holdingDate) }
                    Divider().opacity(0.5)
                    HStack(spacing: 8) {
                        Text("Paid").font(UpOnlyType.body).foregroundStyle(.secondary)
                        Text("optional").font(UpOnlyType.caption).foregroundStyle(.tertiary)
                        Spacer()
                        UpOnlyValueField("0.00", text: $row.holding.paid).textFieldStyle(.plain).multilineTextAlignment(.trailing)
                            .font(.system(size: 13, weight: .medium).monospacedDigit()).frame(width: 96).accessibilityLabel("Amount paid")
                        TextField("USD", text: $row.holding.paidCurrency).textFieldStyle(.plain).font(.system(size: 12, weight: .medium)).frame(width: 40)
                            .accessibilityLabel("Currency paid")
                    }
                }.padding(UpOnlyLayout.cardInset).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: UpOnlyLayout.radius))
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Portfolio").font(UpOnlyType.body).foregroundStyle(.secondary)
                        Spacer()
                        if !portfolios.isEmpty {
                            Menu {
                                ForEach(portfolios) { portfolio in Button(portfolio.name) { row.holding.portfolioID = portfolio.id; row.holding.portfolioName = portfolio.name } }
                                Divider()
                                Button("New portfolio") { row.holding.portfolioID = nil; row.holding.portfolioName = "" }
                            } label: { Text(row.holding.portfolioID == nil ? "Choose existing" : row.holding.portfolioName).fixedSize(horizontal: false, vertical: true).font(UpOnlyType.body) }.menuStyle(.borderedButton)
                        }
                    }
                    if row.holding.portfolioID == nil {
                        entryField(mode == .metals ? "Home safe" : "Ledger or Coinbase", text: $row.holding.portfolioName).accessibilityLabel("Portfolio name")
                        UpOnlyOwnerPicker(owner: $row.holding.ownerBusinessID)
                    }
                }.padding(UpOnlyLayout.cardInset).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: UpOnlyLayout.radius))
            }
            primary("Next") { Task { await evaluate() } }.disabled(quantity.wrappedValue.isEmpty || working)
        }.task { amountFocused = true }
    }
    private var reviewAmount: some View {
        let asOf = (mode == .bankBalances ? date.wrappedValue : holdingDate.wrappedValue).formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: UTCDay.timeZone))
        let paid = row.holding.paid.trimmingCharacters(in: .whitespacesAndNewlines)
        let paidValue = (try? numberFormat.decimal(paid, typed: true)).map { readBack($0, fraction: 2...18) } ?? paid
        return VStack(spacing: 16) {
            Text("Does this look right?").font(UpOnlyType.title).frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 6) {
                // What the app read, not what was typed, so "0,125" can't pass as 125 unseen.
                UpOnlyPrivateText(entered.map { readBack($0, fraction: (mode == .bankBalances ? 2 : 0)...18) } ?? quantity.wrappedValue)
                    .font(.system(size: 40, weight: .semibold).monospacedDigit()).fixedSize(horizontal: false, vertical: true)
                Text(unitCaption).font(UpOnlyType.body.weight(.medium)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity).padding(.vertical, 10)
            VStack(spacing: 0) {
                if mode == .bankBalances {
                    reviewLine("Account", row.bank.account.name, badge: row.bank.account.existingID == nil ? "New" : nil)
                    Divider().opacity(0.4)
                    reviewLine("As of", asOf)
                } else {
                    reviewLine("Portfolio", row.holding.portfolioName, badge: row.holding.portfolioID == nil ? "New" : nil)
                    Divider().opacity(0.4)
                    reviewLine("As of", asOf)
                    Divider().opacity(0.4)
                    reviewLine("Paid", paid.isEmpty ? "Not recorded" : paidValue + " " + row.holding.paidCurrency.uppercased(), muted: paid.isEmpty, isPrivate: !paid.isEmpty)
                }
            }.padding(.horizontal, 14).padding(.vertical, 4).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: UpOnlyLayout.radius))
            if mode != .bankBalances, !holdingNotes.isEmpty || review?.states[row.id] != nil {
                VStack(alignment: .leading, spacing: 8) {
                    if let state = review?.states[row.id] { Label(reviewSummary(state), systemImage: "checkmark.circle").font(UpOnlyType.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    ForEach(holdingNotes, id: \.self) { note in
                        Label(note, systemImage: "info.circle").font(UpOnlyType.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            // No Return shortcut here, so a second Return after Next can't save unseen.
            primary("Save", shortcut: false) { Task { await save() } }.disabled(working || review?.hasErrors != false || review?.added == 0)
        }
    }
    /// "GBP", "BTC", or for metals the unit and metal with the weight in grams ("troy ounces of gold · 31.1035 g").
    private var unitCaption: String {
        switch mode {
        case .bankBalances: return row.bank.account.currency
        case .metals:
            let unit = (try? MetalWeightUnit.resolve(row.holding.unit)) ?? .grams
            var caption = unit.title.lowercased() + " of " + ((try? PreciousMetal.resolve(row.holding.coin))?.name.lowercased() ?? "metal")
            if unit != .grams, !session.privacyMode, let grams = entered.flatMap({ try? unit.grams($0) }) { caption += " · " + readBack(grams, fraction: 0...4) + " g" }
            return caption
        default: return coin.map { $0.symbol.isEmpty ? $0.name : $0.symbol.uppercased() } ?? "total quantity"
        }
    }
    /// Turns the import engine's "previous → new Coin" state into a sentence.
    private func reviewSummary(_ state: ImportRowState) -> String {
        guard case .ready(let text) = state, let arrow = text.range(of: " → ") else { return state.displayText(privacy: session.privacyMode) }
        let previous = String(text[..<arrow.lowerBound])
        let name = mode == .metals ? ((try? PreciousMetal.resolve(row.holding.coin))?.name ?? "metal") : coin?.name ?? "holding"
        if session.privacyMode { return previous == "New" ? "Adds a new " + name + " holding to " + row.holding.portfolioName + "." : "Replaces the current " + name + " total in " + row.holding.portfolioName + "." }
        // Metal totals are kept in grams, whatever unit was typed.
        let total = Decimal(string: previous).map { mode == .metals ? readBack($0, fraction: 0...4) + " g" : readBack($0, fraction: 0...18) } ?? previous
        return previous == "New" ? "Adds a new " + name + " holding to " + row.holding.portfolioName + "." : "Replaces the current " + name + " total of " + total + " in " + row.holding.portfolioName + "."
    }
    // Say out loud what a past date or a cost without an increase will do before it is saved.
    private var holdingNotes: [String] {
        guard mode != .bankBalances, let document = session.document else { return [] }
        // Today is saved as now, so compare with now too.
        let date = UTCDay.isSameDay(holdingDate.wrappedValue, Date()) ? Date() : holdingDate.wrappedValue
        var notes: [String] = []
        let when = date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: UTCDay.timeZone))
        if let portfolio = portfolios.first(where: { $0.id == row.holding.portfolioID }), UTCDay.start(of: date) < UTCDay.start(of: portfolio.createdAt) {
            notes.append("Dates " + portfolio.name + " back to " + when + ".")
        }
        if !row.holding.paid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let holding = document.holdings.first(where: { $0.portfolioID == row.holding.portfolioID && $0.archivedAt == nil && $0.assetID.rawValue == (mode == .metals ? ((try? PreciousMetal.resolve(row.holding.coin))?.assetID.rawValue ?? "") : row.holding.resolvedCoinID) }),
           let before = document.effectiveQuantity(holdingID: holding.id, at: date),
           let total = mode == .metals ? entered.flatMap({ try? MetalWeightUnit.resolve(row.holding.unit).grams($0) }) : entered, total <= before {
            notes.append("No increase on " + when + ", so this cost is recorded for the whole position.")
        }
        return notes
    }
    private func reviewLine(_ label: String, _ value: String, badge: String? = nil, muted: Bool = false, isPrivate: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let badge { Text(badge).font(.system(size: 10, weight: .semibold)).padding(.horizontal, 6).padding(.vertical, 2).background(UpOnlyTint.cashFlow.opacity(0.18), in: Capsule()).foregroundStyle(UpOnlyTint.cashFlow) }
            Group { if isPrivate { UpOnlyPrivateText(value) } else { Text(value) } }
                .font(UpOnlyType.row.weight(.medium)).foregroundStyle(muted ? .tertiary : .primary).multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
        }.font(UpOnlyType.body).padding(.vertical, 10)
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
    private func primary(_ title: String, shortcut: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.system(size: 14, weight: .medium)).frame(maxWidth: .infinity).frame(height: 28) }
            .buttonStyle(.glassProminent).buttonBorderShape(.capsule).controlSize(.large).keyboardShortcut(shortcut ? KeyboardShortcut.defaultAction : nil)
    }
    private func assetButton(name: String, caption: String, mode: ImportMode, symbol: String = "", image: Data? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                UpOnlyEntryBadge(mode: mode, symbol: symbol, image: image, size: 36)
                VStack(alignment: .leading, spacing: 3) { Text(name).font(UpOnlyType.row.weight(.medium)); Text(caption).font(UpOnlyType.caption).foregroundStyle(.secondary) }.fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary)
            }.padding(11).frame(maxWidth: .infinity, alignment: .leading).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: UpOnlyLayout.radius)).contentShape(RoundedRectangle(cornerRadius: UpOnlyLayout.radius))
        }.buttonStyle(UpOnlyCardButtonStyle(radius: UpOnlyLayout.radius))
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
            if token == session.sessionToken {
                // A record dated after the month on screen would otherwise look like it vanished.
                let recorded = mode == .bankBalances ? date.wrappedValue : holdingDate.wrappedValue
                if let model = session.monthModel, model.period == .monthly, recorded > model.selectedInterval().end { model.select(.current()) }
                saved()
            }
        } catch { if token == session.sessionToken { self.error = error.localizedDescription; working = false } }
    }
}

