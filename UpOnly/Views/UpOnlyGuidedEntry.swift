import SwiftUI
import OSLog
import AppKit

struct UpOnlyGuidedEntry: View {
    @Environment(UpOnlySession.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var mode: ImportMode
    @Binding var row: ImportDraftRow
    var back: () -> Void
    var saved: (UpOnlySavedSummary) -> Void
    @State private var step = 0
    @State private var search = ""
    @State private var newAccount = false
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
    /// Today's price of what's being entered, fetched when it's chosen: per coin, per gram of metal, or dollars per
    /// unit of an account's currency. Keyed by what it prices, so a changed choice never shows another's value.
    @State private var livePrice: (key: String, price: Decimal)?
    /// The chosen day's average price, when a past date is picked: what fills in an empty cost.
    @State private var closePrice: (key: String, price: Decimal)?
    /// The cost was filled in from that day's price rather than typed, so review says so.
    @State private var costFromClose = false
    /// With more than one portfolio of this kind, which one: asked after the coin or metal is chosen.
    @State private var choosingPortfolio = false
    /// Several buys, each with its day, instead of one total (nil). Their costs fill in from each day's price.
    @State private var buys: [BuyLine]?
    struct BuyLine: Identifiable, Equatable { var id = UUID(); var quantity = ""; var date = UTCDay.today() }
    /// Each buy day's average price, keyed by asset and day.
    @State private var dayPrices: [String: Decimal] = [:]
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
    private var date: Binding<Date> { Binding(get: { (try? ImportDateFormat.iso.date(row.bank.date)) ?? UTCDay.today() }, set: { row.bank.date = ImportDateFormat.today($0) }) }
    private var holdingDate: Binding<Date> { Binding(get: { (try? ImportDateFormat.iso.date(row.holding.date)) ?? UTCDay.today() }, set: { row.holding.date = ImportDateFormat.today($0) }) }
    /// Whether a picked day is today on this Mac, which takes today's price rather than that day's.
    private func isToday(_ day: Date) -> Bool { UTCDay.start(of: day) == UTCDay.today() }
    private var numberFormat: ImportNumberFormat { session.importDraft?.sources.first(where: { $0.id == row.sourceID })?.numberFormat ?? .point }
    /// The amount as the app reads it, which is what gets saved.
    private var entered: Decimal? { try? numberFormat.decimal(quantity.wrappedValue, typed: true) }
    /// Choosing asks the question; after that the page is named after what's being entered.
    private var headerTitle: String {
        if choosingPortfolio { return "Which portfolio?" }
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
            else if buys != nil { reviewBuys }
            else { reviewAmount }
            if unchanged {
                Text(mode == .bankBalances ? "This balance is already saved." : "This quantity is already saved.")
                    .font(UpOnlyType.body).foregroundStyle(.secondary)
                Button("Done", action: back).buttonStyle(.upOnlySecondary)
            }
            if let error { Label(error, systemImage: "exclamationmark.circle").font(UpOnlyType.body).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            if working { HStack(spacing: 8) { ProgressView().controlSize(.small); Text(step == 2 ? "Saving…" : "Checking…").font(UpOnlyType.body).foregroundStyle(.secondary) } }
            // The amount and review pages end with their button at the foot of the page, as the saved page does.
            if step == 1 {
                Spacer(minLength: 0)
                primary("Review") {
                    if buys != nil { error = nil; step = 2 }
                    else { fillCostFromClose(); Task { await evaluate() } }
                }.disabled(buys != nil ? !buysReady : quantity.wrappedValue.isEmpty || working)
            } else if step == 2 {
                Spacer(minLength: 0)
                // No Return shortcut here, so a second Return after Review can't save unseen.
                primary("Save", shortcut: false) { Task { if buys != nil { await saveBuys() } else { await save() } } }
                    .disabled(working || (buys == nil && (review?.hasErrors != false || review?.added == 0)))
            }
        }
        // On the Add page, the amount and review pages fill the menu's height (Manage has its own header and scroll).
        .frame(minHeight: step > 0 && session.addingInMenu ? max(0, (session.dashboardHeight ?? 0) - 2 * UpOnlyLayout.inset) : nil, alignment: .top)
        }
        }
        .disabled(working || session.isBusy)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: step)
        .onChange(of: row.content) { _, _ in unchanged = false; error = nil }
        .onChange(of: step) { _, next in if next == 1, costFromClose { row.holding.paid = ""; costFromClose = false } }
        .onChange(of: step) { _, _ in unchanged = false }
        // Esc is Back when this form is the Add page (in Manage, Manage's own Back handles it).
        .onChange(of: session.backRequests) { if session.addingInMenu, !working { goBack() } }
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
            if row.bank.account.currency.isEmpty { row.bank.account.currency = "USD" }
            if mode == .bankBalances ? row.bank.account.existingID != nil : mode == .metals ? !row.holding.coin.isEmpty : !row.holding.resolvedCoinID.isEmpty { step = 1; preselected = true }
            #if UPONLY_FIXTURE
            if ProcessInfo.processInfo.environment["UPONLY_PREVIEW_ENTRY_STEP"] == "choose" { step = 0 }
            if ProcessInfo.processInfo.environment["UPONLY_PREVIEW_ENTRY_STEP"] == "account" { step = 0; newAccount = true; row.bank.account = ImportAccount() }
            if let day = ProcessInfo.processInfo.environment["UPONLY_PREVIEW_ENTRY_DATE"] { if mode == .bankBalances { row.bank.date = day } else { row.holding.date = day } }
            if ProcessInfo.processInfo.environment["UPONLY_PREVIEW_ENTRY_STEP"] == "review" { Task { await evaluate() } }
            #endif
        }
    }

    // MARK: Choosing

    /// Accounts, coins and metals are all chosen from a list of rows with their logos; something new is the last row.
    @ViewBuilder private var chooseAsset: some View {
        if choosingPortfolio { portfolioList }
        else if mode == .bankBalances {
            if newAccount { newAccountForm }
            else {
                let shown = activeAccounts.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
                if activeAccounts.count > 4 { UpOnlySearchField(placeholder: "Find an account", text: $search) }
                ManageCard {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                        // Each with its bank's logo, its latest balance and when that was.
                        let latest = session.document?.bankBalances.filter { $0.accountID == item.id }.max { $0.observedAt < $1.observedAt }
                        UpOnlyRow(title: item.name, caption: latest.map { "Updated " + UpOnlyManagement.when($0.observedAt) } ?? item.currency,
                                  value: latest.map { UpOnlyFormat.currencyMoney($0.amount.value, currency: item.currency) }, chevron: true, action: {
                            row.bank.account = ImportAccount(existingID: item.id, name: item.name, currency: item.currency); step = 1
                        }) {
                            UpOnlyBankBadge(name: item.name, size: 28)
                        }
                    }
                    UpOnlyRow(title: "New account", caption: "Name it and pick its currency", chevron: true, action: {
                        if row.bank.account.existingID != nil { row.bank.account.existingID = nil; row.bank.account.name = "" }
                        if row.bank.account.currency.isEmpty { row.bank.account.currency = "USD" }; newAccount = true
                    }) { addBadge }
                }
            }
        } else if mode == .metals {
            ManageCard {
                ForEach(Array(PreciousMetal.selectable.enumerated()), id: \.element) { index, metal in
                    UpOnlyRow(title: metal.name, caption: metal.rawValue, chevron: true, action: {
                        row.holding.coin = metal.rawValue; row.holding.assetName = metal.name; chose()
                    }) { UpOnlyEntryBadge(mode: .metals, symbol: metal.rawValue, size: 28) }
                }
            }
        } else if exactCoin {
            VStack(spacing: 16) {
                ManageCard {
                    UpOnlyFormRow(label: "CoinGecko ID") { formField("e.g. bitcoin", text: $row.holding.resolvedCoinID).accessibilityLabel("CoinGecko ID") }
                    UpOnlyFormRow(label: "Name") { formField("e.g. Bitcoin", text: $row.holding.assetName).accessibilityLabel("Display name") }
                }
                primary("Continue") { row.holding.coin = row.holding.resolvedCoinID; chose() }.disabled(row.holding.resolvedCoinID.isEmpty)
            }
        } else {
            let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
            UpOnlySearchField(placeholder: "Search coins", text: $search)
                .accessibilityLabel("Search coins").focused($searchFocused).onAppear { searchFocused = true }
                .task(id: query.lowercased()) {
                    if !query.isEmpty { try? await Task.sleep(for: .milliseconds(250)); await session.searchCatalog(search) }
                }
            // Before typing, offer the best-known coins rather than an empty list.
            let suggestions = query.isEmpty ? Array(ImportCoins.common.prefix(6)) : ImportCoins.suggestions(search, coins: coins)
            ManageCard {
                ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, coin in
                    UpOnlyRow(title: coin.name, caption: coin.symbol.uppercased(), chevron: true, action: {
                        row.holding.coin = coin.id; row.holding.resolvedCoinID = coin.id; row.holding.assetName = coin.name; chose()
                    }) {
                        UpOnlyAssetBadge(assetID: coin.id, symbol: coin.symbol, size: 28)
                    }
                    .help(coin.id).accessibilityIdentifier("ChooseCoin-" + coin.id)
                }
                // A coin the list doesn't know is found by its CoinGecko ID.
                if !query.isEmpty {
                    UpOnlyRow(title: "Another coin", caption: suggestions.isEmpty ? "No match here, so enter its CoinGecko ID" : "Enter its CoinGecko ID", chevron: true, action: {
                        row.holding.resolvedCoinID = query.lowercased().replacingOccurrences(of: " ", with: "-"); exactCoin = true
                    }) { addBadge }
                }
            }
        }
    }
    private var addBadge: some View { UpOnlySymbolBadge(symbol: "plus", tint: UpOnlyTint.brand, size: 28) }
    /// A new account: its bank's logo appears as the name is typed; the currency and owner are choices below it.
    private var newAccountForm: some View {
        VStack(spacing: 16) {
            UpOnlyBankBadge(name: row.bank.account.name, size: 44).frame(maxWidth: .infinity)
            ManageCard {
                UpOnlyFormRow(label: "Name") {
                    formField("Bank or account name", text: $row.bank.account.name).focused($searchFocused).accessibilityLabel("Account name")
                }
                // Banks matching what's typed, each with its logo; picking one fills in its name and usual currency.
                ForEach(nameSuggestions) { bank in
                    UpOnlyRow(title: bank.name, caption: bank.caption, action: { choose(bank) }) {
                        UpOnlyBankBadge(name: bank.name, size: 28)
                    }
                    .accessibilityIdentifier("BankSuggestion-" + bank.id)
                }
                UpOnlyFormRow(label: "Currency") {
                    UpOnlyCurrencyField(code: $row.bank.account.currency).textFieldStyle(.plain).multilineTextAlignment(.trailing).font(UpOnlyType.row.weight(.medium))
                }
                ownerRow($row.bank.account.ownerBusinessID)
            }
            primary("Continue") { step = 1 }.disabled(row.bank.account.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !CurrencyCodes.isValid(row.bank.account.currency))
        }.onAppear { searchFocused = true }
    }

    /// Up to four banks for the name being typed; none once it's a bank's name (or goes past one, as "Monzo Joint").
    private var nameSuggestions: [BankCatalogEntry] {
        let typed = row.bank.account.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return [] }
        let banks = BankCatalog.suggestions(typed, limit: 4)
        return banks.contains { BankCatalog.words($0.name) == BankCatalog.words(typed) } ? [] : banks
    }
    private func choose(_ bank: BankCatalogEntry) {
        row.bank.account.name = bank.name
        if let code = bank.currency { row.bank.account.currency = code }
    }

    // MARK: The amount

    /// The same page for a balance, a coin or a metal: the amount large under the logo, the details in one card.
    private var enterAmount: some View {
        VStack(spacing: 16) {
            if buys != nil { buysHero(review: false) } else { hero(editable: true) }
            ManageCard {
                if mode == .metals {
                    UpOnlyFormRow(label: "Unit") {
                        UpOnlyFormMenu(value: ((try? MetalWeightUnit.resolve(row.holding.unit)) ?? .grams).title, label: "Weight unit") {
                            ForEach(MetalWeightUnit.allCases, id: \.self) { unit in Button(unit.title) { row.holding.unit = unit.rawValue } }
                        }
                    }
                }
                if let buys {
                    // Several buys: each its amount and day, its cost from that day's average price.
                    ForEach(Array(buys.enumerated()), id: \.element.id) { index, _ in buyRow(index) }
                    UpOnlyRow(title: "Add another buy", action: { self.buys?.append(BuyLine()) }) { addBadge }
                } else {
                    UpOnlyFormRow(label: "Date") { UpOnlyDateButton(date: mode == .bankBalances ? date : holdingDate) }
                    if mode != .bankBalances {
                        // What it cost, if you like, so the app can show the gain since. Left empty with a past date,
                        // the cost is that day's average price times the amount, shown here until typed over.
                        UpOnlyFormRow(label: "Cost", note: estimatedCost == nil ? "optional" : closeDay + " price") {
                            UpOnlyValueField(estimatedCost.map { readBack($0, fraction: 2...2) } ?? "0.00", text: $row.holding.paid).textFieldStyle(.plain).multilineTextAlignment(.trailing)
                                .font(UpOnlyType.row.weight(.medium).monospacedDigit()).frame(maxWidth: 110).accessibilityLabel("Amount paid")
                            UpOnlyCurrencyField(code: $row.holding.paidCurrency, label: "Currency paid").textFieldStyle(.plain).font(UpOnlyType.row.weight(.medium))
                                .foregroundStyle(.secondary).frame(width: 32)
                        }
                    }
                }
            }
            if mode != .bankBalances {
                ManageCard { portfolioRows }
                if buys == nil {
                    // Bought in several goes: each buy with its day, costs filled in.
                    ManageCard {
                        UpOnlyRow(title: "Several buys", caption: "Each with its date; costs fill in from that day's price", chevron: true, action: startBuys) {
                            UpOnlySymbolBadge(symbol: "list.bullet", tint: mode == .metals ? UpOnlyTint.metals : UpOnlyTint.crypto, size: 28)
                        }
                    }
                }
            }
        }.task { amountFocused = true }
            .task(id: priceKey) { await fetchLivePrice() }
            .task(id: closeKey) { await fetchClosePrice() }
            .task(id: buyPriceKeys) { await fetchBuyPrices() }
    }
    /// Which portfolio it goes in: chosen, or a new one named here (with its owner when there are companies).
    @ViewBuilder private var portfolioRows: some View {
        UpOnlyFormRow(label: "Portfolio") {
            if portfolios.isEmpty {
                formField(mode == .metals ? "Home safe" : "Ledger or Coinbase", text: $row.holding.portfolioName).accessibilityLabel("Portfolio name")
            } else {
                UpOnlyFormMenu(value: row.holding.portfolioID == nil ? "New portfolio" : chosenPortfolioLabel, label: "Portfolio") {
                    ForEach(portfolios) { portfolio in Button(portfolioLabel(portfolio)) { row.holding.portfolioID = portfolio.id; row.holding.portfolioName = portfolio.name } }
                    Divider()
                    Button("New portfolio") { row.holding.portfolioID = nil; row.holding.portfolioName = "" }
                }
            }
        }
        if !portfolios.isEmpty, row.holding.portfolioID == nil {
            UpOnlyFormRow(label: "Name") {
                formField(mode == .metals ? "Home safe" : "Ledger or Coinbase", text: $row.holding.portfolioName).accessibilityLabel("Portfolio name")
            }
        }
        if row.holding.portfolioID == nil { ownerRow($row.holding.ownerBusinessID) }
    }

    // MARK: Choosing a portfolio

    /// After the coin or metal: which portfolio, when there's more than one and none was chosen already.
    private func chose() {
        if mode != .bankBalances, portfolios.count > 1, row.holding.portfolioID == nil { choosingPortfolio = true } else { step = 1 }
    }
    private var portfolioList: some View {
        ManageCard {
            ForEach(Array(portfolios.enumerated()), id: \.element.id) { index, portfolio in
                UpOnlyRow(title: portfolioLabel(portfolio), caption: portfolioCaption(portfolio), chevron: true, action: {
                    row.holding.portfolioID = portfolio.id; row.holding.portfolioName = portfolio.name; choosingPortfolio = false; step = 1
                }) { portfolioBadge }
            }
            UpOnlyRow(title: "New portfolio", caption: "Name it on the next page", chevron: true, action: {
                row.holding.portfolioID = nil; row.holding.portfolioName = ""; choosingPortfolio = false; step = 1
            }) { addBadge }
        }
    }
    @ViewBuilder private var portfolioBadge: some View {
        if mode == .metals { UpOnlyEntryBadge(mode: .metals, size: 28) } else { UpOnlyAssetBadge(assetID: "bitcoin", symbol: "BTC", size: 28) }
    }
    /// "Northwind · 3 holdings": whose it is, when a company's, and what's in it.
    private func portfolioCaption(_ portfolio: Portfolio) -> String {
        let count = session.document?.holdings.filter { $0.portfolioID == portfolio.id && $0.archivedAt == nil }.count ?? 0
        return [ownerName(portfolio), count == 1 ? "1 holding" : "\(count) holdings"].joined(separator: " · ")
    }
    /// Whose a portfolio is: a company's name, or Personal.
    private func ownerName(_ portfolio: Portfolio) -> String {
        session.document.map { AssetOwnership.ownerName(portfolio.ownerBusinessID, in: $0) } ?? "Personal"
    }
    /// A portfolio's name, with whose it is when another of the same kind has the same name ("Crypto · Northwind").
    private func portfolioLabel(_ portfolio: Portfolio) -> String {
        let clash = portfolios.contains { $0.id != portfolio.id && $0.name.caseInsensitiveCompare(portfolio.name) == .orderedSame }
        return clash ? portfolio.name + " · " + ownerName(portfolio) : portfolio.name
    }
    /// The chosen portfolio as the form and review name it; a new one by the name typed.
    private var chosenPortfolioLabel: String {
        portfolios.first { $0.id == row.holding.portfolioID }.map(portfolioLabel) ?? row.holding.portfolioName
    }

    // MARK: Several buys

    private func startBuys() {
        buys = [BuyLine(quantity: row.holding.quantity, date: holdingDate.wrappedValue), BuyLine()]
        row.holding.paid = ""; costFromClose = false
    }
    private func parsed(_ text: String) -> Decimal? { try? numberFormat.decimal(text, typed: true) }
    /// The buys' total, in the unit typed.
    private var buysTotal: Decimal { (buys ?? []).compactMap { parsed($0.quantity) }.filter { $0 > 0 }.reduce(0, +) }
    private func dayKey(_ day: Date) -> String { priceKey + "@" + ImportDateFormat.today(day) }
    /// Every past day a buy is on, for looking up prices.
    private var buyPriceKeys: String { Set((buys ?? []).filter { !isToday($0.date) }.map { dayKey($0.date) }).sorted().joined(separator: ",") }
    /// The price a buy is costed at: today's for one bought today, else that day's average.
    private func price(on day: Date) -> Decimal? { isToday(day) ? unitPrice : dayPrices[dayKey(day)] }
    /// A buy's cost in dollars: its amount (in grams for metal) at that day's price.
    private func buyCost(_ line: BuyLine) -> Decimal? {
        guard let amount = parsed(line.quantity), amount > 0, let price = price(on: line.date) else { return nil }
        let units = mode == .metals ? ((try? MetalWeightUnit.resolve(row.holding.unit).grams(amount)) ?? amount) : amount
        guard let cost = try? MoneyInput.multiply(units, price, allowingRounding: true) else { return nil }
        var raw = cost, rounded = Decimal(); NSDecimalRound(&rounded, &raw, 2, .plain); return rounded
    }
    private var buysCost: Decimal? {
        let lines = (buys ?? []).filter { (parsed($0.quantity) ?? 0) > 0 }
        let costs = lines.map(buyCost)
        return lines.isEmpty || costs.contains { $0 == nil } ? nil : costs.compactMap { $0 }.reduce(0, +)
    }
    private func fetchBuyPrices() async {
        guard let settings = session.document?.settings else { return }
        let asset = mode == .metals ? ((try? PreciousMetal.resolve(row.holding.coin))?.assetID.rawValue ?? "") : row.holding.resolvedCoinID
        guard !asset.isEmpty else { return }
        for day in Set((buys ?? []).map { UTCDay.start(of: $0.date) }) where !isToday(day) && dayPrices[dayKey(day)] == nil {
            guard !Task.isCancelled else { return }
            if let price = await PublicPrices.dayPrice(assetID: asset, symbol: coin?.symbol, day: day, today: unitPrice, key: settings.coinGeckoKey) { dayPrices[dayKey(day)] = price }
        }
    }
    private func buyRow(_ index: Int) -> some View {
        let quantity = Binding(get: { buys?.indices.contains(index) == true ? buys![index].quantity : "" }, set: { if buys?.indices.contains(index) == true { buys![index].quantity = $0 } })
        let day = Binding(get: { buys?.indices.contains(index) == true ? buys![index].date : UTCDay.today() }, set: { if buys?.indices.contains(index) == true { buys![index].date = $0 } })
        let line = buys?.indices.contains(index) == true ? buys![index] : BuyLine()
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                UpOnlyDateButton(date: day)
                Spacer(minLength: 8)
                UpOnlyValueField("0", text: quantity).textFieldStyle(.plain).multilineTextAlignment(.trailing)
                    .font(UpOnlyType.row.weight(.medium).monospacedDigit()).frame(maxWidth: 140).accessibilityLabel("Amount bought")
                Text(unitText).font(UpOnlyType.row.weight(.medium)).foregroundStyle(.secondary).fixedSize()
                if (buys?.count ?? 0) > 1 {
                    Button { withAnimation(.snappy(duration: 0.2)) { _ = buys?.remove(at: index) } } label: {
                        Image(systemName: "minus.circle.fill").font(.system(size: 14)).foregroundStyle(.tertiary)
                    }.buttonStyle(.plain).accessibilityLabel("Remove this buy")
                }
            }.frame(minHeight: 36)
            HStack {
                Spacer()
                if let cost = buyCost(line) {
                    UpOnlyPrivateText("≈ " + UpOnlyFormat.exactMoney(cost) + " at " + (isToday(line.date) ? "today's" : "that day's") + " price")
                } else if (parsed(line.quantity) ?? 0) > 0 {
                    Text(isToday(line.date) || dayPrices[dayKey(line.date)] == nil ? "Looking up the price…" : "No price for that day")
                }
            }.font(UpOnlyType.caption.monospacedDigit()).foregroundStyle(.secondary).padding(.bottom, 8)
        }
    }
    /// Several buys at a glance: their total, what it's worth now, and what it cost.
    private func buysHero(review: Bool) -> some View {
        let total = buysTotal
        let units = mode == .metals ? ((try? MetalWeightUnit.resolve(row.holding.unit).grams(total)) ?? total) : total
        let worth = unitPrice.flatMap { try? MoneyInput.multiply(units, $0, allowingRounding: true) }
        return VStack(spacing: 10) {
            badge
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                UpOnlyPrivateText(readBack(total, fraction: 0...18)).font(UpOnlyAmountEntry.font(readBack(total, fraction: 0...18).count)).lineLimit(1).minimumScaleFactor(0.6)
                Text(unitText).font(.system(size: 20, weight: .medium)).foregroundStyle(.secondary).fixedSize()
            }.frame(maxWidth: .infinity)
            UpOnlyPrivateText([worth.map { "≈ " + UpOnlyFormat.exactMoney($0) + " now" }, buysCost.map { "cost " + UpOnlyFormat.exactMoney($0) }].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
                              ?? "Total of \((buys ?? []).count) buys")
                .font(UpOnlyType.body.monospacedDigit()).foregroundStyle(.secondary)
            if review, let worth, let cost = buysCost, cost > 0 {
                HStack(spacing: 8) {
                    UpOnlyChangeBadge(fraction: (worth - cost) / cost)
                    UpOnlyPrivateText((worth < cost ? "−" : "+") + UpOnlyFormat.exactMoney(abs(worth - cost)) + " since you bought").font(UpOnlyType.body.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }.frame(maxWidth: .infinity).padding(.vertical, 4)
    }
    private var buysReady: Bool { buysTotal > 0 && (row.holding.portfolioID != nil || !row.holding.portfolioName.trimmingCharacters(in: .whitespaces).isEmpty) }
    /// Review for several buys: each buy, what it cost, and the portfolio; saved straight after.
    private var reviewBuys: some View {
        VStack(spacing: 16) {
            buysHero(review: true)
            ManageCard {
                ForEach(Array((buys ?? []).filter { (parsed($0.quantity) ?? 0) > 0 }.sorted { $0.date < $1.date }.enumerated()), id: \.element.id) { index, line in
                    UpOnlyFormRow(label: line.date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: UTCDay.timeZone))) {
                        formValue(readBack(parsed(line.quantity) ?? 0, fraction: 0...18) + " " + unitText + (buyCost(line).map { " · " + UpOnlyFormat.exactMoney($0) } ?? ""), isPrivate: true)
                    }
                }
                UpOnlyFormRow(label: "Portfolio") { formValue(chosenPortfolioLabel, badge: row.holding.portfolioID == nil ? "New" : nil) }
            }
            ManageCard {
                VStack(alignment: .leading, spacing: 10) {
                    note("Adds each buy to what you held that day, and to any total saved after it.", symbol: "checkmark.circle.fill", tint: UpOnlyTint.gain)
                    if buysCost == nil { note("A buy without a price for its day is saved without a cost.", symbol: "info.circle.fill", tint: .secondary) }
                }.padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    private func saveBuys() async {
        guard let buys else { return }
        working = true; error = nil
        let unit = (try? MetalWeightUnit.resolve(row.holding.unit)) ?? .grams
        let items: [UpOnlySession.Buy] = buys.compactMap { line in
            guard let amount = parsed(line.quantity), amount > 0 else { return nil }
            let quantity = mode == .metals ? ((try? unit.grams(amount)) ?? amount) : amount
            // Today is saved as now; an earlier day at its start, as a single entry is.
            let day = UTCDay.moment(for: line.date)
            return UpOnlySession.Buy(quantity: quantity, date: day, cost: buyCost(line))
        }
        let asset = mode == .metals ? ((try? PreciousMetal.resolve(row.holding.coin))?.assetID.rawValue ?? "") : row.holding.resolvedCoinID
        let token = session.sessionToken
        let total = buysTotal, cost = buysCost
        do {
            try await session.commitBuys(portfolioID: row.holding.portfolioID, portfolioName: row.holding.portfolioName, owner: row.holding.ownerBusinessID,
                                         assetID: asset, assetName: title, kind: mode.kind, buys: items)
            guard token == session.sessionToken else { return }
            let portfolio = session.document?.portfolios.first { $0.id == row.holding.portfolioID } ?? session.document?.portfolios.first { $0.name == row.holding.portfolioName && $0.kind == mode.kind && !$0.isArchived }
            saved(UpOnlySavedSummary(title: items.count == 1 ? "Buy saved" : "\(items.count) buys saved", amount: readBack(total, fraction: 0...18), unit: unitText,
                                     detail: [cost.map { "cost " + UpOnlyFormat.exactMoney($0) }, portfolio.map(portfolioLabel)].compactMap { $0 }.joined(separator: " · "),
                                     badge: .asset(mode, symbol: mode == .metals ? row.holding.coin : coin?.symbol.uppercased() ?? "", assetID: mode == .holdings ? row.holding.resolvedCoinID : nil),
                                     destination: portfolio.map { ("Open " + portfolioLabel($0), .portfolio($0.id)) }))
        } catch { if token == session.sessionToken { self.error = (error as? ImportFailure)?.text ?? error.localizedDescription; working = false } }
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
                             assetID: mode == .holdings ? row.holding.resolvedCoinID.nilIfEmpty ?? row.holding.coin : nil, size: 44)
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
        let price = unitPrice
        // A metal entered in ounces or kilos is kept in grams; say how many.
        let unit = (try? MetalWeightUnit.resolve(row.holding.unit)) ?? .grams
        let grams = mode == .metals && unit != .grams && !session.privacyMode ? entered.flatMap { try? unit.grams($0) }.map { readBack($0, fraction: 0...4) + " g" } : nil
        if worth != nil || grams != nil {
            UpOnlyPrivateText([worth.map { $0 > 0 && $0 < Decimal(string: "0.01")! ? "≈ <$0.01" : "≈ " + UpOnlyFormat.exactMoney($0) }, grams].compactMap { $0 }.joined(separator: " · "))
                .contentTransition(.numericText()).animation(.snappy(duration: 0.15), value: worth)
        } else if !review, let price, !(mode == .bankBalances && row.bank.account.currency.uppercased() == "USD") {
            // Before anything is typed, today's price, so the total that follows makes sense.
            Text("1 " + (mode == .metals ? "g" : unitText) + " = " + Self.priceText(price))
        } else if !review {
            Text(mode == .bankBalances ? "Balance" : mode == .metals ? "Pure metal weight" : "Total you hold")
        }
    }
    /// A market price at a useful precision: cents from a dollar up, four significant digits below (PEPE's $0.00001234).
    static func priceText(_ price: Decimal) -> String {
        price >= 1 ? UpOnlyFormat.exactMoney(price) : "$" + price.formatted(.number.precision(.significantDigits(1...4)).locale(Locale(identifier: "en_US")))
    }
    // MARK: Cost from the day's price

    /// The asset and day a price is wanted for: a holding dated before today whose cost is left empty.
    private var closeKey: String? {
        guard mode != .bankBalances, !isToday(holdingDate.wrappedValue) else { return nil }
        return priceKey + "@" + ImportDateFormat.today(holdingDate.wrappedValue)
    }
    /// "Mar 2", or "Mar 2, 2025" from another year: short enough to sit beside "Cost".
    private var closeDay: String {
        let day = holdingDate.wrappedValue
        return UTCDay.calendar.component(.year, from: day) == UTCDay.calendar.component(.year, from: UTCDay.today()) ? UpOnlyFormat.utcDay(day) : UpOnlyFormat.utcDate(day)
    }
    /// What the amount cost at that day's average price, while the cost is empty.
    private var estimatedCost: Decimal? {
        guard row.holding.paid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let key = closeKey, let close = closePrice, close.key == key,
              let amount = entered, amount > 0 else { return nil }
        let units = mode == .metals ? (try? MetalWeightUnit.resolve(row.holding.unit).grams(amount)) : amount
        guard let units, let cost = try? MoneyInput.multiply(units, close.price, allowingRounding: true) else { return nil }
        var raw = cost, rounded = Decimal()
        NSDecimalRound(&rounded, &raw, 2, .plain)
        return rounded
    }
    private func fetchClosePrice() async {
        guard let key = closeKey, closePrice?.key != key, let settings = session.document?.settings else { return }
        let asset = mode == .metals ? ((try? PreciousMetal.resolve(row.holding.coin))?.assetID.rawValue ?? "") : row.holding.resolvedCoinID
        guard !asset.isEmpty else { return }
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(4)) }
            guard !Task.isCancelled, key == closeKey else { return }
            let price = await PublicPrices.dayPrice(assetID: asset, symbol: coin?.symbol, day: holdingDate.wrappedValue, today: unitPrice, key: settings.coinGeckoKey)
            if let price, !Task.isCancelled, key == closeKey { closePrice = (key, price); return }
        }
        Logger(subsystem: "org.uponly", category: "entry").notice("no day price for \(key, privacy: .private)")
    }
    /// Pressing Review with the cost still empty records the estimate, in dollars, as what was paid.
    private func fillCostFromClose() {
        guard let cost = estimatedCost else { costFromClose = false; return }
        let text = NSDecimalNumber(decimal: cost).stringValue
        row.holding.paid = numberFormat == .comma ? text.replacingOccurrences(of: ".", with: ",") : text
        row.holding.paidCurrency = "USD"
        costFromClose = true
    }
    /// What `livePrice` is for right now: the coin, the metal, or the account's currency.
    private var priceKey: String {
        switch mode {
        case .bankBalances: return "fx:" + row.bank.account.currency.uppercased()
        case .metals: return "metal:" + row.holding.coin
        default: return "coin:" + row.holding.resolvedCoinID
        }
    }
    /// Today's fetched price if it's in, else the latest one saved in the vault.
    private var unitPrice: Decimal? {
        if let livePrice, livePrice.key == priceKey { return livePrice.price }
        guard let document = session.document else { return nil }
        switch mode {
        case .bankBalances:
            let currency = row.bank.account.currency.uppercased()
            if currency == "USD" { return 1 }
            return document.fx.filter { $0.sourceCurrency == currency && $0.targetCurrency == "USD" }.max { $0.providerTime < $1.providerTime }?.rate.value
        case .metals: return (try? PreciousMetal.resolve(row.holding.coin)).flatMap { latestPrice($0.assetID) }
        default: return latestPrice(CanonicalAssetID(rawValue: row.holding.resolvedCoinID))
        }
    }
    /// Fetches today's price once the coin, metal or currency is known, using the same requests as the app's own price
    /// updates: coins from CoinGecko's top-coins list, so it can't tell which you add.
    private func fetchLivePrice() async {
        let key = priceKey
        guard let settings = session.document?.settings, livePrice?.key != key else { return }
        // A lookup you asked for by choosing it: tried a few times, as a source may be busy (the dashboard's charts use
        // the same ones), with Binance as the coins' second source.
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(4)) }
            guard !Task.isCancelled, key == priceKey else { return }
            let price: Decimal?
            switch mode {
            case .bankBalances:
                let currency = row.bank.account.currency.uppercased()
                guard currency.count == 3, currency != "USD" else { return }
                price = try? await PublicPrices.currencyRate(currency).max { $0.providerTime < $1.providerTime }?.rate.value
            case .metals:
                guard let metal = try? PreciousMetal.resolve(row.holding.coin) else { return }
                price = try? await PublicPrices.metalSpot(metal, fetchedAt: Date()).priceUSD.value
            default:
                let id = row.holding.resolvedCoinID
                guard !id.isEmpty else { return }
                let listed = try? await PublicPrices.quotes(ids: [id], key: settings.coinGeckoKey).first?.priceUSD.value
                if let listed { price = listed } else if let symbol = coin?.symbol { price = await PublicPrices.binancePrice(symbol: symbol) } else { price = nil }
            }
            if let price, !Task.isCancelled, key == priceKey { livePrice = (key, price); return }
        }
        Logger(subsystem: "org.uponly", category: "entry").notice("no current price for \(key, privacy: .private)")
    }
    /// What the amount is worth now, as each digit is typed: today's price once fetched, else the latest saved one.
    private var approxUSD: Decimal? {
        guard let amount = entered, amount != 0, let price = unitPrice else { return nil }
        if mode == .metals {
            guard let grams = try? MetalWeightUnit.resolve(row.holding.unit).grams(amount) else { return nil }
            return try? MoneyInput.multiply(grams, price, allowingRounding: true)
        }
        return try? MoneyInput.multiply(amount, price, allowingRounding: true)
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
            // With a cost, what it's made since: the move as a pill and the gain in dollars.
            if let gain = gainSinceCost {
                HStack(spacing: 8) {
                    UpOnlyChangeBadge(fraction: gain.fraction)
                    UpOnlyPrivateText((gain.amount < 0 ? "−" : "+") + UpOnlyFormat.exactMoney(abs(gain.amount)) + " since " + closeDay)
                        .font(UpOnlyType.body.monospacedDigit()).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity)
            }
            ManageCard {
                if mode == .bankBalances {
                    UpOnlyFormRow(label: "Account") { formValue(row.bank.account.name, badge: row.bank.account.existingID == nil ? "New" : nil) }
                    UpOnlyFormRow(label: "Date") { formValue(asOf) }
                } else {
                    UpOnlyFormRow(label: "Portfolio") { formValue(chosenPortfolioLabel, badge: row.holding.portfolioID == nil ? "New" : nil) }
                    UpOnlyFormRow(label: "Date") { formValue(asOf) }
                    UpOnlyFormRow(label: "Cost", note: costFromClose ? closeDay + " price" : nil) {
                        formValue(paid.isEmpty ? "Not recorded" : paidValue + " " + row.holding.paidCurrency.uppercased(), muted: paid.isEmpty, isPrivate: !paid.isEmpty)
                    }
                }
            }
            // What saving will do, in a quiet card of its own.
            if mode != .bankBalances, !holdingNotes.isEmpty || review?.states[row.id] != nil {
                ManageCard {
                    VStack(alignment: .leading, spacing: 10) {
                        if let state = review?.states[row.id] { note(reviewSummary(state), symbol: "checkmark.circle.fill", tint: UpOnlyTint.gain) }
                        ForEach(holdingNotes, id: \.self) { note($0, symbol: "info.circle.fill", tint: .secondary) }
                    }.padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
    private func note(_ text: String, symbol: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(tint)
            Text(text).font(UpOnlyType.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    /// The holding's value now against what it cost, in dollars (a cost in another currency at the latest saved rate).
    private var gainSinceCost: (fraction: Decimal, amount: Decimal)? {
        guard mode != .bankBalances, !isToday(holdingDate.wrappedValue), let worth = approxUSD,
              let paid = try? numberFormat.decimal(row.holding.paid, typed: true), paid > 0 else { return nil }
        let currency = row.holding.paidCurrency.uppercased().nilIfEmpty ?? "USD"
        let rate: Decimal? = currency == "USD" ? 1 : session.document?.fx.filter { $0.sourceCurrency == currency && $0.targetCurrency == "USD" }.max { $0.providerTime < $1.providerTime }?.rate.value
        guard let rate, let cost = try? MoneyInput.multiply(paid, rate, allowingRounding: true), cost > 0 else { return nil }
        return ((worth - cost) / cost, worth - cost)
    }
    /// Turns the import engine's "previous → new Coin" state into a sentence.
    private func reviewSummary(_ state: ImportRowState) -> String {
        guard case .ready(let text) = state, let arrow = text.range(of: " → ") else { return state.displayText(privacy: session.privacyMode) }
        let previous = String(text[..<arrow.lowerBound])
        let name = mode == .metals ? ((try? PreciousMetal.resolve(row.holding.coin))?.name ?? "metal") : coin?.name ?? "holding"
        if session.privacyMode { return previous == "New" ? "Adds a new " + name + " holding to " + chosenPortfolioLabel + "." : "Replaces the current " + name + " total in " + chosenPortfolioLabel + "." }
        // Metal totals are kept in grams, whatever unit was typed.
        let total = Decimal(string: previous).map { mode == .metals ? readBack($0, fraction: 0...4) + " g" : readBack($0, fraction: 0...18) } ?? previous
        return previous == "New" ? "Adds a new " + name + " holding to " + chosenPortfolioLabel + "." : "Replaces the current " + name + " total of " + total + " in " + chosenPortfolioLabel + "."
    }
    // Say out loud what a past date or a cost without an increase will do before it is saved.
    private var holdingNotes: [String] {
        guard mode != .bankBalances, let document = session.document else { return [] }
        // Today is saved as now, so compare with now too; the note names the day picked.
        let day = holdingDate.wrappedValue, date = UTCDay.moment(for: day)
        var notes: [String] = []
        let when = day.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: UTCDay.timeZone))
        if let portfolio = portfolios.first(where: { $0.id == row.holding.portfolioID }), UTCDay.start(of: day) < UTCDay.start(of: portfolio.createdAt) {
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
            UpOnlyFormRow(label: "Owner") {
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
    private func primary(_ title: String, shortcut: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.system(size: 14, weight: .medium)).frame(maxWidth: .infinity).frame(height: 28) }
            .buttonStyle(.upOnlyPrimary).controlSize(.large).keyboardShortcut(shortcut ? KeyboardShortcut.defaultAction : nil)
    }
    /// One step back: from review to the amount, from the amount to the choice, and out when nothing would be lost.
    private func goBack() {
        if discard { discard = false }
        else if choosingPortfolio { choosingPortfolio = false }
        else if step == 2 || (step == 1 && !preselected) { step -= 1; error = nil; review = nil }
        else if step == 0 && mode == .bankBalances && newAccount && !activeAccounts.isEmpty && !addingAccount { newAccount = false }
        else if step == 0 && exactCoin { exactCoin = false }
        // Nothing typed, or the prefilled value left as it was, is nothing to lose.
        else if buys.map({ $0.allSatisfy { $0.quantity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }) ?? (quantity.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || row.content == initial) { back() }
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
    /// The confirmation's contents: the amount as saved, what it's worth, and the page it now shows on.
    private var savedSummary: UpOnlySavedSummary {
        let document = session.document
        let amount = entered.map { readBack($0, fraction: (mode == .bankBalances ? 2 : 0)...18) } ?? quantity.wrappedValue
        let worth = (mode == .bankBalances && row.bank.account.currency.uppercased() == "USD" ? nil : approxUSD).map { "≈ " + UpOnlyFormat.exactMoney($0) }
        if mode == .bankBalances {
            let name = row.bank.account.name
            let account = document?.accounts.first { $0.id == row.bank.account.existingID } ?? document?.accounts.first { $0.name == name && $0.isActive }
            let owner = account.flatMap { account in document.flatMap { AssetOwnership.businessID(for: account, in: $0) } }
            let page = owner.flatMap { id in document?.businessAccounting?.first { $0.id == id }?.name } ?? "Personal cash"
            return UpOnlySavedSummary(title: "Balance saved", amount: amount, unit: unitText, detail: [worth, name].compactMap { $0 }.joined(separator: " · "),
                                      badge: .bank(name), destination: ("Open " + page, .bankGroup(owner ?? "personal")))
        }
        let portfolio = document?.portfolios.first { $0.id == row.holding.portfolioID }
            ?? document?.portfolios.first { $0.name == row.holding.portfolioName && $0.kind == mode.kind && !$0.isArchived }
        return UpOnlySavedSummary(title: "Holding saved", amount: amount, unit: unitText,
                                  detail: [worth, portfolio.map(portfolioLabel) ?? row.holding.portfolioName].compactMap { $0 }.joined(separator: " · "),
                                  badge: .asset(mode, symbol: mode == .metals ? row.holding.coin : coin?.symbol.uppercased() ?? "",
                                                assetID: mode == .holdings ? row.holding.resolvedCoinID.nilIfEmpty ?? row.holding.coin : nil),
                                  destination: portfolio.map { ("Open " + portfolioLabel($0), .portfolio($0.id)) })
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
                saved(savedSummary)
            }
        } catch { if token == session.sessionToken { self.error = error.localizedDescription; working = false } }
    }
}

