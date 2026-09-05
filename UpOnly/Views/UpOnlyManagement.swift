import SwiftUI

struct UpOnlyManagement: View {
    @Environment(UpOnlySession.self) private var session
    var body: some View {
        Group {
            if session.state == .unlocked {
                if session.document?.settings.setupComplete != true { UpOnlySetup().id(session.sessionToken) }
                else { UpOnlyManagementContent().id(session.sessionToken) }
            }
            else { UpOnlyLockView().frame(maxWidth: 344) }
        }.frame(minWidth: 620, idealWidth: 680, minHeight: 460, idealHeight: 520)
            .onAppear { session.surfaceOpened() }.onDisappear { session.surfaceClosed() }
    }
}

private enum UpOnlyEditor: Identifiable {
    case portfolio, account, balance(Account), holding(UUID), quantity(Holding), move(Holding), entry, exchangeRate
    var id: String {
        switch self {
        case .portfolio: "portfolio"
        case .account: "account"
        case .balance(let a): "balance-" + a.id.uuidString
        case .holding(let id): "holding-" + id.uuidString
        case .quantity(let h): "quantity-" + h.id.uuidString
        case .move(let h): "move-" + h.id.uuidString
        case .entry: "entry"
        case .exchangeRate: "rate"
        }
    }
    var title: String {
        switch self {
        case .portfolio: "New portfolio"
        case .account: "Add bank account"
        case .balance: "Update balance"
        case .holding: "Add coin"
        case .quantity: "Update quantity"
        case .move: "Move coins"
        case .entry: "Add entry"
        case .exchangeRate: "Add exchange rate"
        }
    }
}

private struct UpOnlyManagementContent: View {
    @Environment(UpOnlySession.self) private var session
    @State private var editor: UpOnlyEditor?
    @State private var archive: Portfolio?
    @State private var entryToRemove: Entry?
    var body: some View {
        @Bindable var session = session
        NavigationSplitView {
            List(selection: $session.managementSection) {
                Label("Accounts", systemImage: "building.columns").tag("Accounts")
                Label("Portfolios", systemImage: "square.stack.3d.up").tag("Portfolios")
                Label("Entries", systemImage: "list.bullet.rectangle").tag("Entries")
                Label("Sources", systemImage: "arrow.triangle.2.circlepath").tag("Sources")
                Label("Security", systemImage: "lock.shield").tag("Security")
            }.navigationSplitViewColumnWidth(160)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Text(session.managementSection).font(.system(size: 24, weight: .semibold))
                        Spacer()
                        if session.managementSection == "Accounts" {
                            Menu { Button("Bank account") { editor = .account }; Button("Monthly entry") { editor = .entry } } label: { Image(systemName: "plus") }
                        } else if session.managementSection == "Entries" {
                            Menu { Button("Monthly entry") { editor = .entry }; Button("Exchange rate") { editor = .exchangeRate } } label: { Image(systemName: "plus") }
                        } else if session.managementSection == "Portfolios" {
                            Button { editor = .portfolio } label: { Image(systemName: "plus") }.help("New portfolio")
                        }
                    }
                    switch session.managementSection {
                    case "Accounts": accounts
                    case "Portfolios": portfolios
                    case "Sources": UpOnlySources()
                    case "Entries": entries
                    default: security
                    }
                    if let message = session.message { Text(message).font(.system(size: 12)).foregroundStyle(.secondary) }
                }.padding(24)
            }
        }
        .sheet(isPresented: Binding(get: { session.choosingStatementAccount }, set: { session.choosingStatementAccount = $0 })) { StatementAccountChooser() }
        .sheet(item: $editor) { item in UpOnlyEditSheet(editor: item) }
        .sheet(item: Binding(get: { session.pendingStatement }, set: { session.pendingStatement = $0 })) { StatementReview(draft: $0) }
        .confirmationDialog("Archive \(archive?.name ?? "portfolio")?", isPresented: Binding(get: { archive != nil }, set: { if !$0 { archive = nil } })) {
            if let p = archive {
                Button("Archive portfolio", role: .destructive) {
                    Task { await session.perform { doc in doc = try HoldingMutations.archivePortfolio(id: p.id, at: Date(), document: doc) } }
                    archive = nil
                }
            }
        } message: { Text("It will leave your current total. Its recorded history will stay in your vault.") }
    }
    private var accounts: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Dated balances make up your net worth. Statements track what came in and went out.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            if session.document?.accounts.isEmpty == true {
                Button("Add your first bank account") { editor = .account }.buttonStyle(.borderedProminent)
            }
            ForEach(session.document?.accounts ?? []) { account in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(account.name).font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Button("Update") { editor = .balance(account) }.controlSize(.small)
                    }
                    if let observation = session.document?.bankBalances.filter({ $0.accountID == account.id }).max(by: { $0.observedAt < $1.observedAt }) {
                        Text(UpOnlyFormat.quantity(observation.amount.value) + " " + account.currency)
                            .font(.system(size: 18, weight: .medium).monospacedDigit())
                        Text("As of " + observation.observedAt.formatted(date: .abbreviated, time: .omitted))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    } else { Text("No balance yet").font(.system(size: 12)).foregroundStyle(.secondary) }
                    Toggle("Include in net worth", isOn: Binding(get: { session.document?.isBankTracked(account.id, at: Date()) ?? false }, set: { tracked in
                        Task { await session.perform { $0.setBankTracked(account.id, tracked: tracked, at: Date()) } }
                    })).toggleStyle(.checkbox).font(.system(size: 12))
                    Button("Import statement for this account…") {
                        Task { await session.chooseStatements(accountID: account.id) }
                    }.buttonStyle(.plain).font(.system(size: 12))
                }
                Divider()
            }
            Button { Task { await session.chooseStatements() } } label: { Label("Import statements…", systemImage: "arrow.down.doc") }
            Text("Bank balances are entered manually. Each balance is shown with its observation date.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
    private var portfolios: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Separate stacks, one clear total. Enter your coins and quantities here; public prices update automatically once the price source is enabled.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            if session.document?.portfolios.isEmpty == true {
                Button("Create your first portfolio") { editor = .portfolio }.buttonStyle(.borderedProminent)
            }
            ForEach(session.document?.portfolios.filter { !$0.isArchived } ?? []) { portfolio in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(portfolio.name).font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Menu {
                            Button("Add coin") { editor = .holding(portfolio.id) }
                            Button("Archive portfolio…", role: .destructive) { archive = portfolio }
                        } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                    }
                    if let doc = session.document {
                        ForEach(doc.activeHoldings(in: portfolio.id, at: Date())) { holding in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(holding.assetName).font(.system(size: 13))
                                    Text(UpOnlyFormat.quantity(doc.effectiveQuantity(holdingID: holding.id, at: Date()) ?? 0))
                                        .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Edit") { editor = .quantity(holding) }.controlSize(.small)
                                Button("Move") { editor = .move(holding) }.controlSize(.small)
                            }.padding(.vertical, 4)
                        }
                    }
                    Button("Add coin") { editor = .holding(portfolio.id) }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Divider()
            }
            Text("Wallets and exchanges are never connected. Quantities and portfolio names stay inside your encrypted vault.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
    private var entries: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Income and spending are separate from your account balances. Transfers are excluded from monthly results.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Add monthly entry") { editor = .entry }
            ForEach((session.document?.entries ?? []).sorted { $0.month > $1.month }) { entry in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.label).font(.system(size: 13))
                        Text(entry.month + " · " + entry.kind.rawValue).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(UpOnlyFormat.quantity(entry.amount) + " " + entry.currency).monospacedDigit()
                    Button("Remove", role: .destructive) { entryToRemove = entry }
                }.padding(.vertical, 5)
                Divider()
            }
            Button("Add a dated USD exchange rate") { editor = .exchangeRate }
        }
        .confirmationDialog("Remove this entry?", isPresented: Binding(get: { entryToRemove != nil }, set: { if !$0 { entryToRemove = nil } })) {
            Button("Remove entry", role: .destructive) {
                if let id = entryToRemove?.id { Task { await session.perform { $0.entries.removeAll { $0.id == id } } } }
                entryToRemove = nil
            }
        } message: { Text("The original imported statement, if any, stays encrypted in your vault.") }
    }
    private var security: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Encrypted on this Mac", systemImage: "lock.shield").font(.system(size: 15, weight: .medium))
            Text("Your vault uses authenticated encryption. Its key stays in this Mac’s Keychain, protected by Touch ID or your Mac password.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            Text("Up Only locks when the last finance window closes, when the Mac sleeps or locks, and after five minutes without interaction.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            Divider()
            Button("Save encrypted backup…") { Task { await session.exportBackup() } }
            Text("Keep backups and your recovery code separately. Your recovery code is not saved by Up Only.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Button("Lock now") { session.lock() }
        }
    }
}

private struct UpOnlyEditSheet: View {
    @Environment(UpOnlySession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let editor: UpOnlyEditor
    @State private var name = ""
    @State private var currency = "USD"
    @State private var amount = ""
    @State private var date = Date()
    @State private var asset = ""
    @State private var search = ""
    @State private var destination: UUID?
    @State private var entryMonth = MonthKey.current().description
    @State private var kind = "expense"
    @State private var bucket = "personal"
    @State private var error: String?
    @State private var saving = false
    private var coins: [CatalogCoin] {
        Array(session.catalog.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.symbol.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search) }.prefix(100))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(editor.title).font(.system(size: 20, weight: .semibold))
            Form {
                switch editor {
                case .portfolio: TextField("Name", text: $name)
                case .account:
                    TextField("Account name", text: $name)
                    TextField("Currency", text: $currency)
                    TextField("Closing balance", text: $amount)
                    DatePicker("Observed on", selection: $date, in: ...Date(), displayedComponents: .date)
                case .balance(let account):
                    Text(account.name).font(.headline)
                    TextField("Balance in " + account.currency, text: $amount)
                    DatePicker("Observed on", selection: $date, in: ...Date(), displayedComponents: .date)
                case .holding:
                    TextField("Search coin name or symbol", text: $search)
                    if !coins.isEmpty {
                        Picker("Coin", selection: $asset) {
                            Text("Choose a coin").tag("")
                            ForEach(coins) { coin in Text(coin.name + " · " + coin.symbol.uppercased() + " · " + coin.id).tag(coin.id) }
                        }
                    }
                    TextField("CoinGecko coin ID", text: $asset)
                    TextField("Display name", text: $name)
                    Text("Use the exact CoinGecko ID, not a ticker or wallet address.").font(.caption).foregroundStyle(.secondary)
                    TextField("Quantity", text: $amount)
                    Text("This quantity takes effect now.").font(.system(size: 11)).foregroundStyle(.secondary)
                case .quantity(let holding):
                    Text(holding.assetName).font(.headline)
                    TextField("New total quantity", text: $amount)
                    Text("Changes take effect now. Past observations stay unchanged. Enter zero to close this holding.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                case .move(let holding):
                    Text(holding.assetName).font(.headline)
                    TextField("Quantity to move", text: $amount)
                    Picker("To portfolio", selection: $destination) {
                        Text("Choose portfolio").tag(nil as UUID?)
                        ForEach(session.document?.portfolios.filter { !$0.isArchived && $0.id != holding.portfolioID } ?? []) { p in Text(p.name).tag(Optional(p.id)) }
                    }
                    Text("Moves keep your total quantity unchanged.").font(.system(size: 11)).foregroundStyle(.secondary)
                case .exchangeRate:
                    TextField("From currency", text: $currency)
                    TextField("USD for one unit", text: $amount)
                    DatePicker("Rate date", selection: $date, in: ...Date(), displayedComponents: .date)
                case .entry:
                    TextField("Description", text: $name)
                    TextField("Month (YYYY-MM)", text: $entryMonth)
                    Picker("Type", selection: $kind) { Text("Spent").tag("expense"); Text("Paid in").tag("income"); Text("Transfer").tag("transfer") }
                    Picker("Category", selection: $bucket) { Text("Personal").tag("personal"); Text("Business").tag("otherBusiness"); Text("Business cost").tag("businessCost") }
                    TextField("Amount", text: $amount)
                    TextField("Currency", text: $currency)
                }
            }.formStyle(.grouped)
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saving ? "Saving…" : "Save") { Task { await save() } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(saving || session.isBusy)
            }
        }.padding(24).frame(width: 420)
        .task { if case .holding = editor { await session.loadCatalog() } }
        .onChange(of: asset) { _, id in if let coin = session.catalog.first(where: { $0.id == id }) { name = coin.name } }
        .onAppear {
            if case .quantity(let h) = editor { amount = session.document?.effectiveQuantity(holdingID: h.id, at: Date()).map(UpOnlyFormat.quantity) ?? "" }
        }
    }
    private func save() async {
        saving = true; error = nil
        defer { saving = false }
        do {
            switch editor {
            case .portfolio: try await session.addPortfolio(name: name)
            case .account: try await session.addAccount(name: name, currency: currency, balance: amount, date: date)
            case .balance(let account): try await session.updateBalance(account: account, text: amount, date: date)
            case .holding(let portfolio):
                let quantity = try MoneyInput.parseExact(amount)
                let canonical = try CanonicalAssetID(asset)
                let title = try UpOnlySession.name(name.isEmpty ? asset : name)
                try await session.mutate { doc in doc = try HoldingMutations.addHolding(portfolioID: portfolio, assetID: canonical, assetName: title, quantity: quantity, at: Date(), document: doc) }
            case .quantity(let holding):
                let quantity = try MoneyInput.parseExact(amount)
                try await session.mutate { doc in doc = try HoldingMutations.setQuantity(holdingID: holding.id, quantity: quantity, at: Date(), document: doc) }
            case .move(let holding):
                guard let destination else { throw VaultError.unknownPortfolio }
                let quantity = try MoneyInput.parseExact(amount)
                try await session.mutate { doc in doc = try HoldingMutations.moveHolding(assetID: holding.assetID, quantity: quantity, from: holding.portfolioID, to: destination, at: Date(), document: doc) }
            case .exchangeRate:
                let code = try MoneyInput.normalizeCurrency(currency)
                let value = try MoneyInput.parseExact(amount)
                try MoneyInput.requirePositiveFinite(value)
                try await session.mutate { $0.fx.append(FXObservation(sourceCurrency: code, targetCurrency: "USD", rate: PreciseDecimal(value), providerTime: date, fetchedAt: Date(), provider: "Manual")) }
            case .entry:
                let label = try UpOnlySession.name(name)
                guard let month = MonthKey(entryMonth), month <= .current(), month.year >= 1900,
                      let entryKind = EntryKind(rawValue: kind), let entryBucket = Bucket(rawValue: bucket) else { throw VaultError.invalidAmount }
                let value = try MoneyInput.parseExact(amount)
                try MoneyInput.requireNonNegativeFinite(value)
                let code = try MoneyInput.normalizeCurrency(currency)
                try await session.mutate { doc in doc.entries.append(Entry(month: month, bucket: entryBucket, kind: entryKind, amount: value, currency: code, label: label, source: .manual)) }
            }
            dismiss()
        } catch { self.error = "Check the fields and try again. Your saved data has not changed." }
    }
}
