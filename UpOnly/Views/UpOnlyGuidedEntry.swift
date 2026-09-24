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
    /// Accounts whose balance you type in; synced ones (a Wise profile's currencies) update themselves.
    private var activeAccounts: [Account] { accounts.filter { $0.isActive && $0.externalProfileID == nil } }
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
    /// Choosing asks the question; after that the page is named after what's being entered.
    private var headerTitle: String {
        if step > 0, !title.isEmpty { return title }
        switch mode {
        case .bankBalances: return newAccount ? "New account" : "Which account?"
        case .metals: return "Which metal?"
        default: return exactCoin ? "Another coin" : "Which coin?"
        }
    }
    var body: some View {
        Group {
        if discard {
            UpOnlyConfirmation(title: mode == .bankBalances ? "Discard this balance?" : "Discard this holding?", confirmTitle: "Discard", confirm: back, cancel: { discard = false })
        } else {
        VStack(alignment: .leading, spacing: 16) {
            UpOnlyPageHeader(title: headerTitle, back: goBack).disabled(working)
            if step == 0 { chooseAsset }
            else if step == 1 { enterAmount }
            else { reviewAmount }
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
        // Esc is Back when this form is the Add page (in Manage, Manage's own Back handles it).
        .onChange(of: session.backRequests) { if session.addingInMenu, !session.managementInMenu, !working { goBack() } }
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

    // MARK: Choosing

    /// Accounts, coins and metals are all chosen from a list of rows with their logos; something new is the last row.
    @ViewBuilder private var chooseAsset: some View {
        if mode == .bankBalances {
            if newAccount { newAccountForm }
            else {
                let shown = activeAccounts.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
                if activeAccounts.count > 4 { entryField("Find an account", text: $search, symbol: "magnifyingglass") }
                ManageCard {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                        // Each with its bank's logo, its latest balance and when that was.
                        let latest = session.document?.bankBalances.filter { $0.accountID == item.id }.max { $0.observedAt < $1.observedAt }
                        ManageRow(title: item.name, caption: latest.map { "Updated " + UpOnlyManagement.when($0.observedAt) } ?? item.currency,
                                  value: latest.map { UpOnlyFormat.currencyMoney($0.amount.value, currency: item.currency) }, divided: index > 0, chevron: true, action: {
                            row.bank.account = ImportAccount(existingID: item.id, name: item.name, currency: item.currency); step = 1
                        }) {
                            UpOnlyBankBadge(name: item.name, size: 28)
                        } menu: { EmptyView() }
                    }
                    ManageRow(title: "New account", caption: "Name it and pick its currency", divided: !shown.isEmpty, chevron: true, action: {
                        if row.bank.account.existingID != nil { row.bank.account.existingID = nil; row.bank.account.name = "" }
                        customCurrency = !["USD", "GBP", "EUR"].contains(row.bank.account.currency); newAccount = true
                    }) { addBadge } menu: { EmptyView() }
                }
            }
        } else if mode == .metals {
            ManageCard {
                ForEach(Array(PreciousMetal.selectable.enumerated()), id: \.element) { index, metal in
                    ManageRow(title: metal.name, caption: metal.rawValue, divided: index > 0, chevron: true, action: {
                        row.holding.coin = metal.rawValue; row.holding.assetName = metal.name; step = 1
                    }) { UpOnlyEntryBadge(mode: .metals, symbol: metal.rawValue, size: 28) } menu: { EmptyView() }
                }
            }
        } else if exactCoin {
            VStack(spacing: 16) {
                ManageCard {
                    UpOnlyFormRow(label: "CoinGecko ID") { formField("e.g. bitcoin", text: $row.holding.resolvedCoinID).accessibilityLabel("CoinGecko ID") }
                    UpOnlyFormRow(label: "Name", divided: true) { formField("e.g. Bitcoin", text: $row.holding.assetName).accessibilityLabel("Display name") }
                }
                primary("Continue") { row.holding.coin = row.holding.resolvedCoinID; step = 1 }.disabled(row.holding.resolvedCoinID.isEmpty)
            }
        } else {
            let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
            entryField("Search coins", text: $search, symbol: "magnifyingglass")
                .accessibilityLabel("Search coins").focused($searchFocused).onAppear { searchFocused = true }
                .task(id: query.lowercased()) {
                    if !query.isEmpty { try? await Task.sleep(for: .milliseconds(250)); await session.searchCatalog(search) }
                }
            // Before typing, offer the best-known coins rather than an empty list.
            let suggestions = query.isEmpty ? Array(ImportCoins.common.prefix(6)) : ImportCoins.suggestions(search, coins: coins)
            ManageCard {
                ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, coin in
                    ManageRow(title: coin.name, caption: coin.symbol.uppercased(), divided: index > 0, chevron: true, action: {
                        row.holding.coin = coin.id; row.holding.resolvedCoinID = coin.id; row.holding.assetName = coin.name; step = 1
                    }) {
                        UpOnlyAssetBadge(assetID: coin.id, symbol: coin.symbol, size: 28)
                    } menu: { EmptyView() }
                    .help(coin.id).accessibilityIdentifier("ChooseCoin-" + coin.id)
                }
                // A coin the list doesn't know is found by its CoinGecko ID.
                if !query.isEmpty {
                    ManageRow(title: "Another coin", caption: suggestions.isEmpty ? "No match here, so enter its CoinGecko ID" : "Enter its CoinGecko ID",
                              divided: !suggestions.isEmpty, chevron: true, action: {
                        row.holding.resolvedCoinID = query.lowercased().replacingOccurrences(of: " ", with: "-"); exactCoin = true
                    }) { addBadge } menu: { EmptyView() }
                }
            }
        }
    }
    private var addBadge: some View { UpOnlySymbolBadge(symbol: "plus", tint: .accentColor, size: 28) }
    /// A new account: its bank's logo appears as the name is typed; the currency and owner are choices below it.
    private var newAccountForm: some View {
        VStack(spacing: 16) {
            UpOnlyBankBadge(name: row.bank.account.name, size: 44).frame(maxWidth: .infinity)
            ManageCard {
                UpOnlyFormRow(label: "Name") {
                    formField("Everyday account", text: $row.bank.account.name).focused($searchFocused).accessibilityLabel("Account name")
                }
                UpOnlyFormRow(label: "Currency", divided: true) {
                    UpOnlyFormMenu(value: customCurrency ? "Other" : row.bank.account.currency, label: "Currency") {
                        ForEach(["USD", "GBP", "EUR"], id: \.self) { code in Button(code) { customCurrency = false; row.bank.account.currency = code } }
                        Divider()
                        Button("Other…") { customCurrency = true; row.bank.account.currency = "" }
                    }
                }
                if customCurrency {
                    UpOnlyFormRow(label: "Code", divided: true) { formField("e.g. CHF", text: $row.bank.account.currency).accessibilityLabel("Account currency") }
                }
                ownerRow($row.bank.account.ownerBusinessID)
            }
            primary("Continue") { step = 1 }.disabled(row.bank.account.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || row.bank.account.currency.trimmingCharacters(in: .whitespacesAndNewlines).count != 3)
        }.onAppear { searchFocused = true }
    }

    // MARK: The amount

    /// The same page for a balance, a coin or a metal: the amount large under the logo, the details in one card.
    private var enterAmount: some View {
        VStack(spacing: 16) {
            hero(editable: true)
            ManageCard {
                if mode == .metals {
                    UpOnlyFormRow(label: "Unit") {
                        UpOnlyFormMenu(value: ((try? MetalWeightUnit.resolve(row.holding.unit)) ?? .grams).title, label: "Weight unit") {
                            ForEach(MetalWeightUnit.allCases, id: \.self) { unit in Button(unit.title) { row.holding.unit = unit.rawValue } }
                        }
                    }
                }
                UpOnlyFormRow(label: "Date", divided: mode == .metals) { UpOnlyDateButton(date: mode == .bankBalances ? date : holdingDate) }
                if mode != .bankBalances {
                    // What it cost, if you like, so the app can show the gain since.
                    UpOnlyFormRow(label: "Cost", note: "optional", divided: true) {
                        UpOnlyValueField("0.00", text: $row.holding.paid).textFieldStyle(.plain).multilineTextAlignment(.trailing)
                            .font(UpOnlyType.row.weight(.medium).monospacedDigit()).frame(maxWidth: 110).accessibilityLabel("Amount paid")
                        TextField("USD", text: $row.holding.paidCurrency).textFieldStyle(.plain).font(UpOnlyType.row.weight(.medium)).foregroundStyle(.secondary)
                            .frame(width: 32).accessibilityLabel("Currency paid")
                    }
                    UpOnlyFormRow(label: "Portfolio", divided: true) {
                        if portfolios.isEmpty {
                            formField(mode == .metals ? "Home safe" : "Ledger or Coinbase", text: $row.holding.portfolioName).accessibilityLabel("Portfolio name")
                        } else {
                            UpOnlyFormMenu(value: row.holding.portfolioID == nil ? "New portfolio" : row.holding.portfolioName, label: "Portfolio") {
                                ForEach(portfolios) { portfolio in Button(portfolio.name) { row.holding.portfolioID = portfolio.id; row.holding.portfolioName = portfolio.name } }
                                Divider()
                                Button("New portfolio") { row.holding.portfolioID = nil; row.holding.portfolioName = "" }
                            }
                        }
                    }
                    if !portfolios.isEmpty, row.holding.portfolioID == nil {
                        UpOnlyFormRow(label: "Name", divided: true) {
                            formField(mode == .metals ? "Home safe" : "Ledger or Coinbase", text: $row.holding.portfolioName).accessibilityLabel("Portfolio name")
                        }
                    }
                    if row.holding.portfolioID == nil { ownerRow($row.holding.ownerBusinessID) }
                }
            }
            primary("Review") { Task { await evaluate() } }.disabled(quantity.wrappedValue.isEmpty || working)
        }.task { amountFocused = true }
    }
    /// The logo, the amount large with its unit after it, and what it's worth now (or, before anything is typed, what
    /// to enter). Review shows the same, read back as the app understood it.
    private func hero(editable: Bool) -> some View {
        VStack(spacing: 10) {
            badge
            if editable {
                UpOnlyAmountEntry(text: quantity, unit: unitText, label: mode == .bankBalances ? "Bank balance" : mode == .metals ? "Weight" : "Total quantity", focused: $amountFocused)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // What the app read, not what was typed, so "0,125" can't pass as 125 unseen.
                    UpOnlyPrivateText(entered.map { readBack($0, fraction: (mode == .bankBalances ? 2 : 0)...18) } ?? quantity.wrappedValue)
                        .font(UpOnlyAmountEntry.font(quantity.wrappedValue.count)).lineLimit(1).minimumScaleFactor(0.6)
                    Text(unitText).font(.system(size: 20, weight: .medium)).foregroundStyle(.secondary).fixedSize()
                }.frame(maxWidth: .infinity)
            }
            heroCaption(review: !editable).font(UpOnlyType.body.monospacedDigit()).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding(.vertical, 4)
    }
    @ViewBuilder private var badge: some View {
        if mode == .bankBalances {
            if let image = account?.profileImage { UpOnlyProfileImage(data: image, name: title, size: 44) }
            else { UpOnlyBankBadge(name: row.bank.account.name, size: 44) }
        } else {
            UpOnlyEntryBadge(mode: mode, symbol: mode == .metals ? row.holding.coin : coin?.symbol.uppercased() ?? "",
                             assetID: mode == .holdings ? row.holding.resolvedCoinID.nilIfEmpty ?? row.holding.coin : nil, image: nil, size: 44)
        }
    }
    /// "GBP", "BTC", or the metal's weight unit.
    private var unitText: String {
        switch mode {
        case .bankBalances: return row.bank.account.currency.uppercased()
        case .metals:
            switch (try? MetalWeightUnit.resolve(row.holding.unit)) ?? .grams { case .grams: return "g"; case .kilograms: return "kg"; case .troyOunces: return "oz t" }
        default: return coin.map { $0.symbol.isEmpty ? $0.name : $0.symbol.uppercased() } ?? row.holding.resolvedCoinID.uppercased()
        }
    }
    @ViewBuilder private func heroCaption(review: Bool) -> some View {
        let worth = mode == .bankBalances && row.bank.account.currency.uppercased() == "USD" ? nil : approxUSD
        // A metal entered in ounces or kilos is kept in grams; say how many.
        let unit = (try? MetalWeightUnit.resolve(row.holding.unit)) ?? .grams
        let grams = mode == .metals && unit != .grams && !session.privacyMode ? entered.flatMap { try? unit.grams($0) }.map { readBack($0, fraction: 0...4) + " g" } : nil
        if worth != nil || grams != nil {
            UpOnlyPrivateText([worth.map { "≈ " + UpOnlyFormat.exactMoney($0) }, grams].compactMap { $0 }.joined(separator: " · "))
        } else if !review {
            Text(mode == .bankBalances ? "Balance" : mode == .metals ? "Pure metal weight" : "Total you hold")
        }
    }
    /// What the amount is worth now, from the latest saved price or rate; nothing when the app has none yet.
    private var approxUSD: Decimal? {
        guard let amount = entered, amount != 0, let document = session.document else { return nil }
        switch mode {
        case .bankBalances:
            let currency = row.bank.account.currency.uppercased()
            guard let rate = document.fx.filter({ $0.sourceCurrency == currency && $0.targetCurrency == "USD" }).max(by: { $0.providerTime < $1.providerTime })?.rate.value else { return nil }
            return try? MoneyInput.multiply(amount, rate, allowingRounding: true)
        case .metals:
            guard let metal = try? PreciousMetal.resolve(row.holding.coin), let grams = try? MetalWeightUnit.resolve(row.holding.unit).grams(amount),
                  let price = latestPrice(metal.assetID) else { return nil }
            return try? MoneyInput.multiply(grams, price, allowingRounding: true)
        default:
            guard let price = latestPrice(CanonicalAssetID(rawValue: row.holding.resolvedCoinID)) else { return nil }
            return try? MoneyInput.multiply(amount, price, allowingRounding: true)
        }
    }
    private func latestPrice(_ asset: CanonicalAssetID) -> Decimal? {
        session.document?.quotes.filter { $0.assetID == asset }.max { $0.providerTime < $1.providerTime }?.priceUSD.value
    }

    // MARK: Review

    private var reviewAmount: some View {
        let asOf = (mode == .bankBalances ? date.wrappedValue : holdingDate.wrappedValue).formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: UTCDay.timeZone))
        let paid = row.holding.paid.trimmingCharacters(in: .whitespacesAndNewlines)
        let paidValue = (try? numberFormat.decimal(paid, typed: true)).map { readBack($0, fraction: 2...18) } ?? paid
        return VStack(spacing: 16) {
            hero(editable: false)
            ManageCard {
                if mode == .bankBalances {
                    UpOnlyFormRow(label: "Account") { formValue(row.bank.account.name, badge: row.bank.account.existingID == nil ? "New" : nil) }
                    UpOnlyFormRow(label: "Date", divided: true) { formValue(asOf) }
                } else {
                    UpOnlyFormRow(label: "Portfolio") { formValue(row.holding.portfolioName, badge: row.holding.portfolioID == nil ? "New" : nil) }
                    UpOnlyFormRow(label: "Date", divided: true) { formValue(asOf) }
                    UpOnlyFormRow(label: "Cost", divided: true) {
                        formValue(paid.isEmpty ? "Not recorded" : paidValue + " " + row.holding.paidCurrency.uppercased(), muted: paid.isEmpty, isPrivate: !paid.isEmpty)
                    }
                }
            }
            if mode != .bankBalances, !holdingNotes.isEmpty || review?.states[row.id] != nil {
                VStack(alignment: .leading, spacing: 8) {
                    if let state = review?.states[row.id] { Label(reviewSummary(state), systemImage: "checkmark.circle").font(UpOnlyType.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    ForEach(holdingNotes, id: \.self) { note in
                        Label(note, systemImage: "info.circle").font(UpOnlyType.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            // No Return shortcut here, so a second Return after Review can't save unseen.
            primary("Save", shortcut: false) { Task { await save() } }.disabled(working || review?.hasErrors != false || review?.added == 0)
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

    // MARK: Pieces

    /// Personal or a company, for a new account or portfolio, when there are companies to choose from.
    @ViewBuilder private func ownerRow(_ owner: Binding<String?>) -> some View {
        let books = session.document?.businessAccounting ?? []
        if !books.isEmpty || owner.wrappedValue != nil {
            UpOnlyFormRow(label: "Owner", divided: true) {
                UpOnlyFormMenu(value: owner.wrappedValue.map { id in books.first { $0.id == id }?.name ?? "Company unavailable" } ?? "Personal", label: "Asset owner") {
                    Button("Personal") { owner.wrappedValue = nil }
                    ForEach(books) { book in Button(book.name) { owner.wrappedValue = book.id } }
                }
            }
        }
    }
    private func formValue(_ value: String, badge: String? = nil, muted: Bool = false, isPrivate: Bool = false) -> some View {
        HStack(spacing: 6) {
            if let badge { Text(badge).font(.system(size: 10, weight: .semibold)).padding(.horizontal, 6).padding(.vertical, 2).background(UpOnlyTint.cashFlow.opacity(0.18), in: Capsule()).foregroundStyle(UpOnlyTint.cashFlow) }
            Group { if isPrivate { UpOnlyPrivateText(value) } else { Text(value) } }
                .font(UpOnlyType.row.weight(.medium)).foregroundStyle(muted ? .tertiary : .primary).lineLimit(1).truncationMode(.middle)
        }
    }
    /// A text field inside a form row, typed at the right like the other rows' values.
    private func formField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text).textFieldStyle(.plain).multilineTextAlignment(.trailing).font(UpOnlyType.row.weight(.medium))
    }
    private func entryField(_ placeholder: String, text: Binding<String>, size: CGFloat = 14, symbol: String? = nil) -> some View {
        HStack(spacing: 8) {
            if let symbol { Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(.secondary) }
            TextField(placeholder, text: text, axis: .vertical)
                .font(.system(size: size, weight: size > 18 ? .medium : .regular)).textFieldStyle(.plain)
        }.padding(.vertical, 10)
            .overlay(alignment: .bottom) { Rectangle().fill(.primary.opacity(0.12)).frame(height: 1) }
    }
    private func primary(_ title: String, shortcut: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.system(size: 14, weight: .medium)).frame(maxWidth: .infinity).frame(height: 28) }
            .buttonStyle(.glassProminent).buttonBorderShape(.capsule).controlSize(.large).keyboardShortcut(shortcut ? KeyboardShortcut.defaultAction : nil)
    }
    /// One step back: from review to the amount, from the amount to the choice, and out when nothing would be lost.
    private func goBack() {
        if discard { discard = false }
        else if step == 2 || (step == 1 && !preselected) { step -= 1; error = nil; review = nil }
        else if step == 0 && mode == .bankBalances && newAccount && !activeAccounts.isEmpty && !addingAccount { newAccount = false }
        else if step == 0 && exactCoin { exactCoin = false }
        // Nothing typed, or the prefilled value left as it was, is nothing to lose.
        else if quantity.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || row.content == initial { back() }
        else { discard = true }
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

