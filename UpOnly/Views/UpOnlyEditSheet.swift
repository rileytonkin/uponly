import SwiftUI

struct UpOnlyEditSheet: View {
    @Environment(UpOnlySession.self) private var session
    /// The room Manage gives its pages, so the form can fill it with its button at the foot.
    @Environment(\.upOnlyScrollHeight) private var pageHeight
    let editor: UpOnlyEditor
    let onCancel: () -> Void
    let onSave: () -> Void
    /// The Add page's confirmation, for a new transaction; given, it's called instead of `onSave`.
    var onSaved: ((UpOnlySavedSummary) -> Void)? = nil
    @State private var name = ""
    @State private var currency = "USD"
    @State private var amount = ""
    /// A saved day (its UTC midnight), today on this Mac to start with.
    @State private var date = UTCDay.today()
    @State private var destination: UUID?
    @State private var entryMonth = MonthKey.current().description
    @State private var kind = "expense"
    @State private var bucket = "personal"
    @State private var error: String?
    @State private var saving = false
    @State private var lotQuantity = ""
    @State private var lotToRemove: PurchaseLot?
    /// A transaction's company, when it was paid for one; and whether its day is known (manual ones used to record
    /// only the month, and one opened for a past month starts with just that month).
    @State private var businessID: String?
    @State private var dayKnown = true
    @FocusState private var amountFocused: Bool
    /// Set up once: the menu keeps this view when it closes, and reopening mustn't put back the starting values.
    @State private var configured = false
    private var actionTitle: String {
        switch editor {
        case .entry: "Save transaction"
        case .editEntry: "Save changes"
        case .exchangeRate: "Save rate"
        case .move: "Move coins"
        case .renameAccount, .renamePortfolio: "Save name"
        case .purchases: "Add purchase"
        }
    }
    // In Manage, Back lives top-left like every other page; the Add flow's own form keeps its header.
    private var showsOwnHeader: Bool { !session.managementInMenu || session.entryEditorInMenu }
    /// How tall the form stands: Manage's scrolling room less its bottom margin, or the Add page's height less its
    /// margins. Nil before the dashboard has been measured.
    private var fillHeight: CGFloat? {
        guard let height = session.dashboardHeight else { return nil }
        return max(0, showsOwnHeader ? height - 2 * UpOnlyLayout.inset : pageHeight - UpOnlyLayout.inset)
    }
    /// The latest a manual rate can be dated and still price the month it was opened for. Nil when no month was given.
    private var rateCutoff: Date? {
        guard let month = MonthKey(session.entryMonthForManagement) else { return nil }
        return UTCDay.calendar.date(from: DateComponents(year: month.next.year, month: month.next.month, day: 1)).map { min(Date(), $0.addingTimeInterval(-1)) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if showsOwnHeader {
                UpOnlyPageHeader(title: editor.title, backLabel: "Cancel", back: onCancel).disabled(saving)
            }
            if let lot = lotToRemove {
                UpOnlyConfirmation(title: "Remove this purchase?", detail: "Your quantity stays the same. Only the record of what you paid is removed.", confirmTitle: "Remove purchase",
                                   confirm: { remove(lot) }, cancel: { lotToRemove = nil })
            } else {
                VStack(alignment: .leading, spacing: 16) { form }.disabled(saving)
                if let error { UpOnlyNotice(error) }
                // The button sits at the foot of the page, as on every other form, not wherever the form ends.
                Spacer(minLength: 0)
                Button { Task { await save() } } label: {
                    Text(saving ? "Saving…" : actionTitle).frame(maxWidth: .infinity).frame(minHeight: 24)
                }.buttonStyle(.upOnlyPrimary).controlSize(.large).keyboardShortcut(.defaultAction).disabled(saving)
            }
        }.frame(minHeight: fillHeight, alignment: .top)
        .onAppear {
            guard !configured else { return }
            configured = true
            switch editor {
            case .renameAccount(let account): name = account.name
            case .renamePortfolio(let portfolio): name = portfolio.name
            case .entry:
                // Opened to fill in a past month: that month, with no day until one is picked.
                if session.managementInMenu, let month = MonthKey(session.entryMonthForManagement), month < .current() {
                    entryMonth = month.description; dayKnown = false; date = Self.lastDay(of: month)
                }
                amountFocused = true
            case .editEntry(let entry):
                kind = entry.kind.rawValue; bucket = entry.bucket.rawValue; amount = UpOnlyFormat.quantity(entry.amount)
                currency = entry.currency; name = entry.label; entryMonth = entry.month; businessID = entry.businessID
                if let day = entry.day, let parsed = try? ImportDateFormat.iso.date(day) { date = parsed }
                else { dayKnown = false; date = MonthKey(entry.month).map(Self.lastDay) ?? UTCDay.today() }
            case .exchangeRate:
                currency = session.requestedRateCurrency ?? "GBP"
                if let month = MonthKey(session.entryMonthForManagement) { date = Self.lastDay(of: month) }
                amountFocused = true
            case .move: amountFocused = true
            case .purchases: break
            }
        }
    }
    @ViewBuilder private var form: some View {
        switch editor {
        case .move(let holding):
            moveForm(holding)
        case .purchases(let holding):
            purchasesForm(holding)
        case .renameAccount:
            renameForm(badge: AnyView(UpOnlyBankBadge(name: name, size: 44)), placeholder: "Account name")
        case .renamePortfolio(let portfolio):
            renameForm(badge: AnyView(UpOnlySymbolBadge(symbol: portfolio.kind == .metals ? TrackedKind.metals.symbol : TrackedKind.crypto.symbol,
                                                         tint: portfolio.kind == .metals ? UpOnlyTint.metals : UpOnlyTint.crypto, size: 44)), placeholder: "Portfolio name")
        case .exchangeRate:
            rateForm
        case .entry, .editEntry:
            transactionForm
        }
    }
    // MARK: Transaction

    /// The amount first, signed the way the money moved, with one line on how it counts; then the details in one
    /// card, as every add form has.
    private var transactionForm: some View {
        let entryKind = EntryKind(rawValue: kind) ?? .expense
        let books = session.document?.businessAccounting ?? []
        return VStack(spacing: 16) {
            VStack(spacing: 10) {
                UpOnlySymbolBadge(symbol: Self.kindBadge(entryKind).symbol, tint: Self.kindBadge(entryKind).tint, size: 44)
                UpOnlyAmountEntry(text: $amount, unit: currency.uppercased().nilIfEmpty ?? "USD", sign: kindSign(entryKind),
                                  tint: entryKind == .income || entryKind == .refund ? UpOnlyTint.gain : .primary, label: "Amount", focused: $amountFocused)
                Text(meaning(entryKind, books: books)).font(UpOnlyType.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity).padding(.vertical, 4)
            ManageCard {
                UpOnlyFormRow(label: "Type") {
                    UpOnlyFormMenu(value: kindTitle(entryKind), label: "Transaction type") {
                        ForEach(entryKinds, id: \.self) { choice in Button(kindTitle(choice)) { kind = choice.rawValue } }
                    }
                }
                UpOnlyFormRow(label: "Description") {
                    TextField("What was it for?", text: $name).textFieldStyle(.plain).multilineTextAlignment(.trailing).font(UpOnlyType.row.weight(.medium))
                        .accessibilityLabel("Description")
                }
                UpOnlyFormRow(label: "Date") {
                    UpOnlyDateButton(date: Binding(get: { date }, set: { date = $0; dayKnown = true }), title: dayKnown ? nil : MonthKey(entryMonth)?.title)
                }
                UpOnlyFormRow(label: "Currency") {
                    UpOnlyCurrencyField(code: $currency).textFieldStyle(.plain).multilineTextAlignment(.trailing).font(UpOnlyType.row.weight(.medium))
                }
                // Only when there's a company it could have been for (or it already isn't yours).
                if !books.isEmpty || bucket != Bucket.personal.rawValue {
                    UpOnlyFormRow(label: "For") {
                        UpOnlyFormMenu(value: forTitle(books), label: "Who it was for") {
                            Button("Me") { bucket = Bucket.personal.rawValue; businessID = nil }
                            ForEach(books) { book in Button(book.name) { bucket = Bucket.businessCost.rawValue; businessID = book.id } }
                            if books.isEmpty { Button("A business") { bucket = Bucket.businessCost.rawValue; businessID = nil } }
                        }
                    }
                }
            }
        }
    }
    /// Which way the money moved, as an arrow: out for spending, in for income, back for a refund, across for a transfer.
    static func kindBadge(_ kind: EntryKind) -> (symbol: String, tint: Color) {
        switch kind {
        case .income: ("arrow.down.left", UpOnlyTint.gain)
        case .refund: ("arrow.uturn.backward", UpOnlyTint.gain)
        case .transfer: ("arrow.left.arrow.right", Color.secondary)
        case .expense: ("arrow.up.right", UpOnlyTint.cashFlow)
        }
    }
    /// How the transaction will count, in a sentence, so the type and "for" choices explain themselves.
    private func meaning(_ kind: EntryKind, books: [BusinessBook]) -> String {
        let month = dayKnown ? MonthKey(day: date).title : MonthKey(entryMonth)?.title ?? "this month"
        if bucket != Bucket.personal.rawValue { return "Paid for " + (books.first { $0.id == businessID }?.name ?? "a business") + ", so it’s left out of your own spending" }
        switch kind {
        case .expense: return "Counts as spending in " + month
        case .income: return "Counts as income in " + month
        case .refund: return "Money back: lowers " + month + "’s spending"
        case .transfer: return "Between your own accounts, so it isn’t counted"
        }
    }
    private func forTitle(_ books: [BusinessBook]) -> String {
        switch Bucket(rawValue: bucket) ?? .personal {
        case .personal: return "Me"
        case .businessCost: return books.first { $0.id == businessID }?.name ?? "A business"
        case .otherBusiness, .reserve: return "A business account"
        }
    }
    /// A month's last day, or today while it's this month.
    private static func lastDay(of month: MonthKey) -> Date {
        let start = UTCDay.calendar.date(from: DateComponents(year: month.next.year, month: month.next.month, day: 1)) ?? UTCDay.today()
        return min(UTCDay.today(), start.addingTimeInterval(-86400))
    }
    // MARK: Other forms

    /// A coin's symbol, or grams for metal: the unit its quantities are typed in.
    private func unit(_ holding: Holding) -> String {
        if PreciousMetal.asset(holding.assetID) != nil { return "g" }
        let id = holding.assetID.rawValue
        return (session.catalog.first { $0.id == id } ?? ImportCoins.common.first { $0.id == id })?.symbol.uppercased() ?? holding.assetName
    }
    private func assetBadge(_ holding: Holding) -> some View {
        UpOnlyEntryBadge(mode: PreciousMetal.asset(holding.assetID) != nil ? .metals : .holdings, symbol: PreciousMetal.asset(holding.assetID)?.rawValue ?? unit(holding),
                         assetID: holding.assetID.rawValue, size: 44)
    }
    /// Moving coins: how many, large, with what's there to move under it; then from where to where.
    private func moveForm(_ holding: Holding) -> some View {
        let available = session.document?.effectiveQuantity(holdingID: holding.id, at: Date()) ?? 0
        let choices = session.document?.portfolios.filter { !$0.isArchived && $0.id != holding.portfolioID && $0.kind == .crypto } ?? []
        let from = session.document?.portfolio(id: holding.portfolioID)?.name ?? "This portfolio"
        return VStack(spacing: 16) {
            VStack(spacing: 10) {
                assetBadge(holding)
                UpOnlyAmountEntry(text: $amount, unit: unit(holding), label: "Quantity to move", focused: $amountFocused)
                // Exact, so moving everything is typing the figure shown (or clicking it).
                Button { amount = UpOnlyFormat.quantity(available) } label: {
                    UpOnlyPrivateText(UpOnlyFormat.quantity(available) + " " + unit(holding) + " available").font(UpOnlyType.body.monospacedDigit()).foregroundStyle(.secondary)
                }.buttonStyle(.plain).help("Move all of it")
            }.frame(maxWidth: .infinity).padding(.vertical, 4)
            ManageCard {
                UpOnlyFormRow(label: "From") { Text(from).font(UpOnlyType.row.weight(.medium)).lineLimit(1) }
                UpOnlyFormRow(label: "To") {
                    if choices.isEmpty {
                        Text("No other portfolio yet").font(UpOnlyType.row).foregroundStyle(.tertiary)
                    } else {
                        UpOnlyFormMenu(value: choices.first { $0.id == destination }?.name ?? "Choose", label: "Destination portfolio") {
                            ForEach(choices) { portfolio in Button(portfolio.name) { destination = portfolio.id } }
                        }
                    }
                }
            }
        }
    }
    /// What was paid for a holding: the purchases so far as a list, then one card to add another.
    private func purchasesForm(_ holding: Holding) -> some View {
        let lots = (session.document?.purchases ?? []).filter { $0.holdingID == holding.id }.sorted { $0.at < $1.at }
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                assetBadge(holding)
                Text(lots.isEmpty ? "No purchases recorded yet. Add one to see your gain against what you paid." : "Removing a purchase never changes your quantity.")
                    .font(UpOnlyType.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !lots.isEmpty {
                ManageCard {
                    ForEach(Array(lots.enumerated()), id: \.element.id) { index, lot in
                        UpOnlyRow(title: lot.at.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: UTCDay.timeZone)),
                                  caption: ManageFormat.amount(lot.quantity.value, of: holding, catalog: session.catalog), captionIsPrivate: true,
                                  value: UpOnlyFormat.currencyMoney(lot.paid.value, currency: lot.currency)) {
                            UpOnlySymbolBadge(symbol: "cart.fill", tint: UpOnlyTint.crypto, size: 32)
                        } menu: {
                            ManageRowMenu(label: "Options for this purchase") { Button("Remove purchase…", role: .destructive) { lotToRemove = lot } }
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Add a purchase").font(UpOnlyType.section)
                ManageCard {
                    UpOnlyFormRow(label: "Bought") {
                        UpOnlyValueField("0", text: $lotQuantity).textFieldStyle(.plain).multilineTextAlignment(.trailing)
                            .font(UpOnlyType.row.weight(.medium).monospacedDigit()).frame(maxWidth: 140).accessibilityLabel(PreciousMetal.asset(holding.assetID) != nil ? "Pure metal bought, in grams" : "Quantity bought")
                        Text(unit(holding)).font(UpOnlyType.row.weight(.medium)).foregroundStyle(.secondary)
                    }
                    UpOnlyFormRow(label: "Paid") {
                        UpOnlyValueField("0.00", text: $amount).textFieldStyle(.plain).multilineTextAlignment(.trailing)
                            .font(UpOnlyType.row.weight(.medium).monospacedDigit()).frame(maxWidth: 140).accessibilityLabel("Total paid")
                        // The currency is typed after the amount, as the Add form's cost is.
                        UpOnlyCurrencyField(code: $currency, label: "Currency paid").textFieldStyle(.plain).font(UpOnlyType.row.weight(.medium))
                            .foregroundStyle(.secondary).frame(width: 32)
                    }
                    UpOnlyFormRow(label: "Date") { UpOnlyDateButton(date: $date) }
                }
            }
        }
    }
    /// A new name, with the logo it will show (for an account, its bank's) above it.
    private func renameForm(badge: AnyView, placeholder: String) -> some View {
        VStack(spacing: 16) {
            badge.frame(maxWidth: .infinity)
            ManageCard {
                UpOnlyFormRow(label: "Name") {
                    TextField(placeholder, text: $name).textFieldStyle(.plain).multilineTextAlignment(.trailing).font(UpOnlyType.row.weight(.medium))
                        .accessibilityLabel(placeholder)
                }
            }
        }
    }
    /// A rate, typed as dollars for one unit of the currency, and the day it's for.
    private var rateForm: some View {
        let code = currency.uppercased().nilIfEmpty ?? "GBP"
        return VStack(spacing: 16) {
            VStack(spacing: 10) {
                UpOnlySymbolBadge(symbol: "arrow.left.arrow.right", tint: UpOnlyTint.netWorth, size: 44)
                UpOnlyAmountEntry(text: $amount, unit: "USD", label: "US dollars for one " + code, focused: $amountFocused)
                Text("for 1 " + code).font(UpOnlyType.body).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity).padding(.vertical, 4)
            ManageCard {
                // A rate is for a currency other than USD, so an empty field means GBP, the form's own default.
                UpOnlyFormRow(label: "Currency") {
                    UpOnlyCurrencyField(code: $currency, fallback: "GBP").textFieldStyle(.plain).multilineTextAlignment(.trailing).font(UpOnlyType.row.weight(.medium))
                }
                UpOnlyFormRow(label: "Date") { UpOnlyDateButton(date: $date) }
            }
            // Only a rate from the month's last seven days prices it (MonthlyLedger.rate).
            if let month = MonthKey(session.entryMonthForManagement), let cutoff = rateCutoff, date > cutoff || cutoff.timeIntervalSince(date) > 7 * 86400 {
                UpOnlyNotice("This rate won’t count for " + month.title + ". Choose a date in the last 7 days of the month.")
            }
        }
    }
    private func remove(_ lot: PurchaseLot) {
        lotToRemove = nil
        Task { await session.perform { $0.purchases?.removeAll { $0.id == lot.id } } }
    }
    private func validName(_ value: String, what: String) throws -> String {
        do { return try UpOnlySession.name(value) } catch { throw ImportFailure("Enter " + what + " of 1–100 characters.") }
    }
    private func validAmount(nonnegative: Bool = true, positive: Bool = false) throws -> Decimal {
        guard let value = try? MoneyInput.parseExact(amount) else { throw ImportFailure("Enter a number without a currency symbol, such as 125.50.") }
        if positive && value <= 0 { throw ImportFailure("Enter a rate greater than zero.") }
        if nonnegative && value < 0 { throw ImportFailure("Enter zero or a positive amount.") }
        return value
    }
    private func validCurrency() throws -> String {
        guard let value = try? MoneyInput.normalizeCurrency(currency) else { throw ImportFailure("Enter a three-letter currency code, such as GBP.") }
        return value
    }
    /// The transaction form's fields, checked. Adding and editing share them.
    private func validEntry() throws -> Entry {
        let label = try validName(name, what: "a description")
        // A picked day sets the month; otherwise the month it was opened with stands.
        let month: MonthKey? = dayKnown ? MonthKey(day: date) : MonthKey(entryMonth)
        guard let month, month <= .current(), month.year >= 1900,
              let entryKind = EntryKind(rawValue: kind), let entryBucket = Bucket(rawValue: bucket) else { throw VaultError.invalidAmount }
        let value = try validAmount()
        let code = try validCurrency()
        var entry = Entry(month: month, bucket: entryBucket, kind: entryKind, amount: value, currency: code, label: label, source: .manual)
        entry.day = dayKnown ? ImportDateFormat.today(date) : nil
        entry.businessID = entryBucket == .businessCost ? businessID : nil
        return entry
    }
    private func save() async {
        saving = true; error = nil
        defer { saving = false }
        do {
            switch editor {
            case .move(let holding):
                guard let destination else { throw ImportFailure("Choose a destination portfolio.") }
                let quantity = try validAmount()
                guard quantity > 0, quantity <= (session.document?.effectiveQuantity(holdingID: holding.id, at: Date()) ?? 0) else { throw ImportFailure("Enter an amount greater than zero and no more than your available quantity.") }
                // Dated today on this Mac, like an entry, so the move and the cost it carries file under today.
                let at = UTCDay.moment(for: UTCDay.today())
                try await session.mutate { doc in doc = try HoldingMutations.moveHolding(assetID: holding.assetID, quantity: quantity, from: holding.portfolioID, to: destination, at: at, document: doc) }
            case .purchases(let holding):
                guard let bought = try? MoneyInput.parseExact(lotQuantity), MoneyInput.isFinite(bought), bought > 0 else { throw ImportFailure("Enter the quantity bought, greater than zero.") }
                let paid = try validAmount()
                let code = try validCurrency()
                guard date <= UTCDay.today() else { throw ImportFailure("Choose today or an earlier date.") }
                // Today's purchase at now, after anything else today; an earlier day at its start.
                let at = UTCDay.moment(for: date)
                try await session.mutate { doc in
                    doc.purchases = (doc.purchases ?? []) + [PurchaseLot(holdingID: holding.id, quantity: PreciseDecimal(bought), paid: PreciseDecimal(paid), currency: code, at: at)]
                }
                lotQuantity = ""; amount = ""; return
            case .renameAccount(let account):
                let clean = try validName(name, what: "an account name")
                try await session.mutate { doc in
                    for index in doc.accounts.indices where doc.accounts[index].id == account.id { doc.accounts[index].name = clean }
                }
            case .renamePortfolio(let portfolio):
                let clean = try validName(name, what: "a portfolio name")
                let owner = (portfolio.ownerBusinessID ?? "").nilIfEmpty
                guard session.document?.portfolios.contains(where: { !$0.isArchived && $0.id != portfolio.id && ($0.ownerBusinessID ?? "").nilIfEmpty == owner && $0.name.caseInsensitiveCompare(clean) == .orderedSame }) != true else { throw ImportFailure("A portfolio with this name already exists here. Choose another name.") }
                try await session.mutate { doc in
                    if let index = doc.portfolios.firstIndex(where: { $0.id == portfolio.id }) { doc.portfolios[index].name = clean }
                }
            case .exchangeRate:
                let code = try validCurrency()
                guard code != "USD" else { throw ImportFailure("Choose the currency you’re converting to USD, such as GBP.") }
                let value = try validAmount(positive: true)
                try await session.mutate { $0.fx.append(FXObservation(sourceCurrency: code, targetCurrency: "USD", rate: PreciseDecimal(value), providerTime: date, fetchedAt: Date(), provider: "Manual")) }
            case .entry:
                let entry = try validEntry()
                try await session.mutate { doc in doc.entries.append(entry); doc.track(.cashFlow) }
                if let onSaved {
                    let badge = Self.kindBadge(entry.kind)
                    let when = dayKnown ? date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: UTCDay.timeZone)) : MonthKey(entry.month)?.title ?? entry.month
                    onSaved(UpOnlySavedSummary(title: "Transaction saved", amount: kindSign(entry.kind) + readBack(entry.amount, fraction: 2...2), unit: entry.currency,
                                               detail: entry.label + " · " + when, badge: .symbol(badge.symbol, badge.tint), destination: ("Open Income & spending", .cashFlow)))
                    return
                }
            case .editEntry(let original):
                let edited = try validEntry()
                // Replaced in place: same identity and position, so filters and the review keep pointing at it.
                try await session.mutate { doc in
                    guard let index = doc.entries.firstIndex(where: { $0.id == original.id }) else { throw ImportFailure("This transaction no longer exists.") }
                    doc.entries[index].month = edited.month; doc.entries[index].kind = edited.kind; doc.entries[index].bucket = edited.bucket
                    doc.entries[index].amount = edited.amount; doc.entries[index].currency = edited.currency; doc.entries[index].label = edited.label
                    doc.entries[index].businessID = edited.businessID
                    // A day left untouched on an entry that never had one stays unknown.
                    if dayKnown { doc.entries[index].day = edited.day }
                }
            }
            onSave()
        } catch { self.error = (error as? ImportFailure)?.text ?? (error as? VaultError)?.errorDescription ?? "Couldn’t save this change. Your previous data is safe. Try again." }
    }
}
