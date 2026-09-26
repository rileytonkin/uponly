import SwiftUI
import AppKit

// Editors for one import file's account and for one row, used by the statement and spreadsheet review.
struct ImportField<Content: View>: View {
    var title: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct ImportAccountEditor: View {
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
                            Button(accountTitle(item.name, item.currency)) { account = ImportAccount(existingID: item.id, name: item.name, currency: item.currency) }
                        }
                    } label: { Label(account.existingID == nil ? "Choose existing" : "Change", systemImage: "chevron.down").font(.system(size: 11)) }
                        .menuStyle(.borderedButton).menuIndicator(.hidden).fixedSize().disabled(accounts.isEmpty && account.existingID == nil)
                }
            }
            ImportField(title: "Currency") {
                UpOnlyCurrencyField(code: $account.currency, label: "Account currency").textFieldStyle(.roundedBorder).disabled(account.existingID != nil)
            }.frame(width: 76)
            if account.existingID == nil { UpOnlyOwnerPicker(owner: $account.ownerBusinessID) }
        }
    }
}
struct ImportRowEditor: View {
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
    var selectable: Bool = true
    /// Updating an existing account's balance: one line in a list, not a card of fields.
    var compact = false
    var select: () -> Void
    var remove: () -> Void
    @State private var search = ""
    @State private var choosingCoin = false
    private var matches: [CatalogCoin] { ImportCoins.suggestions(search, coins: coins) }
    /// Gold and silver, plus platinum or palladium when a file names them, so the picker is never blank.
    private var metalChoices: [PreciousMetal] {
        let current = try? PreciousMetal.resolve(row.holding.coin)
        return PreciousMetal.allCases.filter { PreciousMetal.selectable.contains($0) || $0 == current }
    }
    var body: some View {
        if compact { compactBankRow } else { card }
    }
    /// An existing account's new balance, as a home-style row: logo, name and date, and the balance to type.
    private var compactBankRow: some View {
        let account = accounts.first { $0.id == row.bank.account.existingID }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                UpOnlyBankBadge(name: row.bank.account.name, synced: account?.externalProfileID != nil, image: account?.profileImage, size: 28)
                // The date is shared, above the list; each row is its name, then its new balance in its currency. The
                // field says the currency, so a Wise name's own " · USD" isn't repeated.
                let currency = row.bank.account.currency, suffix = " · " + row.bank.account.currency
                Text(row.bank.account.name.hasSuffix(suffix) ? String(row.bank.account.name.dropLast(suffix.count)) : row.bank.account.name)
                    .font(UpOnlyType.row.weight(.semibold)).lineLimit(2).frame(minWidth: 80, alignment: .leading)
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    UpOnlyValueField("0.00", text: $row.bank.balance).textFieldStyle(.plain).multilineTextAlignment(.trailing)
                        .font(UpOnlyType.row.monospacedDigit()).frame(width: 76)
                        .accessibilityLabel("Balance for " + row.bank.account.name + " in " + currency)
                    Text(currency).font(UpOnlyType.caption).foregroundStyle(.secondary).fixedSize()
                }.padding(.horizontal, 8).padding(.vertical, 5).background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8)).fixedSize()
            }
            if let state {
                Label(state.displayText(privacy: session.privacyMode), systemImage: state.blocksSave ? "exclamationmark.circle" : "checkmark.circle")
                    .font(UpOnlyType.caption).foregroundStyle(state.blocksSave ? Color.orange : UpOnlyTint.cashFlow).padding(.leading, 38)
            }
        }.padding(.vertical, 8).opacity(row.included ? 1 : 0.5)
            .contextMenu { Button("Leave out of this update", role: .destructive, action: remove) }
    }
    private var card: some View {
        VStack(alignment: .leading, spacing: mode == .statements ? 10 : 18) {
            HStack {
                if selectable && (mode == .statements || !manual) {
                    Button(action: select) { Image(systemName: selected ? "checkmark.square.fill" : "square") }.buttonStyle(.bordered).accessibilityLabel("Select row \(row.line)")
                }
                Text(manual ? (mode == .bankBalances ? "Bank balance" : mode == .metals ? "Metal holding" : mode == .holdings ? "Crypto holding" : "Transaction") : "Row \(row.line)" + (sourceName.isEmpty ? "" : " · " + sourceName))
                    .lineLimit(1).truncationMode(.middle).help(sourceName).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
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
                if state == .possibleDuplicate {
                    HStack(spacing: 8) {
                        Button("This is a separate payment") { row.duplicateApproved = true }
                        Button("Skip it") { row.included = false }
                    }.font(.caption)
                }
            }
            if row.duplicateApproved { Label("Confirmed as a separate payment", systemImage: "checkmark").fixedSize(horizontal: false, vertical: true).font(.caption).foregroundStyle(.secondary) }
            if let issue = row.parseError {
                Text(issue).fixedSize(horizontal: false, vertical: true).font(.caption).foregroundStyle(.orange)
                Button("I’ve corrected this row’s fields") { row.parseError = nil }.font(.caption)
            }
        }.padding(mode == .statements ? 14 : 20).modifier(UpOnlyContentSurface())
            .overlay { if selected { RoundedRectangle(cornerRadius: UpOnlyLayout.radius, style: .continuous).strokeBorder(mode.kind.tint) } }
            .textFieldStyle(.roundedBorder)
    }
    private var statementFields: some View {
        VStack(spacing: 8) {
            TextField("Description", text: $row.statement.label, axis: .vertical)
            HStack {
                TextField("Date", text: $row.statement.date, axis: .vertical)
                UpOnlyCurrencyField(code: $row.statement.currency, label: "Currency").frame(width: 60)
            }
            VStack(alignment: .leading, spacing: 8) {
                if usesDebitCredit {
                    UpOnlyValueField("Money out", text: $row.statement.debit)
                    UpOnlyValueField("Money in", text: $row.statement.credit)
                } else { UpOnlyValueField("Amount", text: $row.statement.amount) }
                HStack(spacing: 8) {
                    Picker("Type", selection: Binding(get: { row.statement.kind }, set: { row.statement.kind = $0; row.statement.kindIsUserEdited = true })) {
                        Text("Income").fixedSize(horizontal: false, vertical: true).tag(EntryKind.income); Text("Expense").fixedSize(horizontal: false, vertical: true).tag(EntryKind.expense); Text("Refund").fixedSize(horizontal: false, vertical: true).tag(EntryKind.refund); Text("Transfer").fixedSize(horizontal: false, vertical: true).tag(EntryKind.transfer)
                    }.frame(width: 155)
                    // A chosen type also sets the direction; a transfer keeps the file's sign.
                    if row.statement.kindIsUserEdited && row.statement.kind != .transfer {
                        Text(row.statement.kind == .expense ? "Money out" : "Money in").font(.caption).foregroundStyle(.secondary)
                    }
                }
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
                        UpOnlyDateButton(date: Binding(get: { (try? ImportDateFormat.iso.date(row.bank.date)) ?? UTCDay.today() }, set: { row.bank.date = ImportDateFormat.today($0) }))
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
                        ForEach(metalChoices, id: \.self) { Text($0.name).tag($0.rawValue) }
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
                .task(id: search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
                    if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { try? await Task.sleep(for: .milliseconds(250)); await session.searchCatalog(search) }
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
            }.scrollEdgeEffectStyle(.soft, for: .vertical).frame(height: min(280, CGFloat(max(matches.count, 1)) * 64))
            }
            Text("Select the exact asset; tickers can be shared.").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(18).frame(width: 310)
    }
}
