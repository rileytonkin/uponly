import SwiftUI

struct UpOnlyEditSheet: View {
    @Environment(UpOnlySession.self) private var session
    let editor: UpOnlyEditor
    /// Unused: the editor always lives inside the menu. Kept so existing call sites that pass it still compile.
    var compact = true
    let onCancel: () -> Void
    let onSave: () -> Void
    @State private var name = ""
    @State private var currency = "USD"
    @State private var amount = ""
    @State private var date = Date()
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
    @State private var customCurrency = false
    @FocusState private var amountFocused: Bool
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
    /// The latest a manual rate can be dated and still price the month it was opened for. Nil when no month was given.
    private var rateCutoff: Date? {
        guard let month = MonthKey(session.entryMonthForManagement) else { return nil }
        return UTCDay.calendar.date(from: DateComponents(year: month.next.year, month: month.next.month, day: 1)).map { min(Date(), $0.addingTimeInterval(-1)) }
    }
    private func field(_ title: String, text: Binding<String>, placeholder: String = "", hidesValue: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(UpOnlyType.caption.weight(.medium)).foregroundStyle(.secondary)
            Group {
                if hidesValue { UpOnlyValueField(placeholder.isEmpty ? title : placeholder, text: text) }
                else { TextField(placeholder.isEmpty ? title : placeholder, text: text, axis: .vertical) }
            }.textFieldStyle(.plain).font(.system(size: 15))
                .accessibilityLabel(title).padding(.vertical, 8)
                .overlay(alignment: .bottom) { Rectangle().fill(.primary.opacity(0.14)).frame(height: 1) }
        }
    }
    private var amountField: some View {
        UpOnlyValueField("0.00", text: $amount).textFieldStyle(.plain)
            .font(.system(size: 34, weight: .medium).monospacedDigit()).accessibilityLabel("Amount")
            .padding(.vertical, 6)
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
                Button { Task { await save() } } label: {
                    Text(saving ? "Saving…" : actionTitle).frame(maxWidth: .infinity).frame(minHeight: 24)
                }.buttonStyle(.glassProminent).buttonBorderShape(.capsule).controlSize(.large).keyboardShortcut(.defaultAction).disabled(saving)
            }
        }.fixedSize(horizontal: false, vertical: true)
        .onAppear {
            switch editor {
            case .renameAccount(let account): name = account.name
            case .renamePortfolio(let portfolio): name = portfolio.name
            case .entry:
                currency = defaultCurrency
                // Opened to fill in a past month: that month, with no day until one is picked.
                if session.managementInMenu, let month = MonthKey(session.entryMonthForManagement), month < .current() {
                    entryMonth = month.description; dayKnown = false; date = Self.lastDay(of: month)
                }
                amountFocused = true
            case .editEntry(let entry):
                kind = entry.kind.rawValue; bucket = entry.bucket.rawValue; amount = UpOnlyFormat.quantity(entry.amount)
                currency = entry.currency; name = entry.label; entryMonth = entry.month; businessID = entry.businessID
                if let day = entry.day, let parsed = try? ImportDateFormat.iso.date(day) { date = parsed }
                else { dayKnown = false; date = MonthKey(entry.month).map(Self.lastDay) ?? Date() }
                customCurrency = !currencyChoices.contains(currency)
            case .exchangeRate:
                currency = session.requestedRateCurrency ?? "GBP"
                if let cutoff = rateCutoff { date = cutoff }
            case .move, .purchases: break
            }
        }
    }
    @ViewBuilder private var form: some View {
        switch editor {
        case .move(let holding):
            Text(holding.assetName).font(UpOnlyType.section).fixedSize(horizontal: false, vertical: true)
            // Exact, so typing the figure shown moves everything.
            UpOnlyPrivateText("Available: " + UpOnlyFormat.quantity(session.document?.effectiveQuantity(holdingID: holding.id, at: Date()) ?? 0))
                .font(UpOnlyType.body).foregroundStyle(.secondary)
            amountField
            let choices = session.document?.portfolios.filter { !$0.isArchived && $0.id != holding.portfolioID && $0.kind == .crypto } ?? []
            if choices.isEmpty {
                Text("Create another portfolio before moving this holding.").font(UpOnlyType.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("Move to", selection: $destination) {
                    Text("Choose portfolio").tag(Optional<UUID>.none)
                    ForEach(choices) { Text($0.name).tag(Optional($0.id)) }
                }.accessibilityLabel("Destination portfolio")
            }
        case .purchases(let holding):
            purchasesList(holding)
            Text("Add a purchase").font(UpOnlyType.section)
            field(PreciousMetal.asset(holding.assetID) != nil ? "Pure metal bought, in grams" : "Quantity bought", text: $lotQuantity, placeholder: "0", hidesValue: true)
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Total paid").font(UpOnlyType.caption.weight(.medium)).foregroundStyle(.secondary)
                    amountField
                }
                TextField("USD", text: $currency).textFieldStyle(.plain).font(.system(size: 14, weight: .medium)).frame(width: 50).accessibilityLabel("Currency paid")
            }
            HStack { Text("Bought on").foregroundStyle(.secondary); Spacer(); UpOnlyDateButton(date: $date) }
        case .renameAccount:
            field("Account name", text: $name)
        case .renamePortfolio:
            field("Portfolio name", text: $name)
        case .exchangeRate:
            field("From currency", text: $currency, placeholder: "GBP")
            Text("USD for 1 " + currency.uppercased()).font(UpOnlyType.body).foregroundStyle(.secondary)
            amountField
            HStack { Text("Rate date").foregroundStyle(.secondary); Spacer(); UpOnlyDateButton(date: $date) }
            // Only a rate from the month's last seven days prices it (MonthlyLedger.rate).
            if let month = MonthKey(session.entryMonthForManagement), let cutoff = rateCutoff, date > cutoff || cutoff.timeIntervalSince(date) > 7 * 86400 {
                UpOnlyNotice("This rate won’t count for " + month.title + ". Choose a date in the last 7 days of the month.")
            }
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
                UpOnlySymbolBadge(symbol: entryKind == .income ? "arrow.down.left" : entryKind == .refund ? "arrow.uturn.backward" : entryKind == .transfer ? "arrow.left.arrow.right" : "arrow.up.right",
                                  tint: entryKind == .income || entryKind == .refund ? UpOnlyTint.gain : entryKind == .transfer ? .secondary : UpOnlyTint.cashFlow, size: 44)
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
                UpOnlyFormRow(label: "Description", divided: true) {
                    TextField("What was it for?", text: $name).textFieldStyle(.plain).multilineTextAlignment(.trailing).font(UpOnlyType.row.weight(.medium))
                        .accessibilityLabel("Description")
                }
                UpOnlyFormRow(label: "Date", divided: true) {
                    UpOnlyDateButton(date: Binding(get: { date }, set: { date = $0; dayKnown = true }), title: dayKnown ? nil : MonthKey(entryMonth)?.title)
                }
                UpOnlyFormRow(label: "Currency", divided: true) {
                    UpOnlyFormMenu(value: customCurrency ? "Other" : currency.uppercased(), label: "Currency") {
                        ForEach(currencyChoices, id: \.self) { code in Button(code) { currency = code; customCurrency = false } }
                        Divider()
                        Button("Other…") { customCurrency = true; currency = "" }
                    }
                }
                if customCurrency {
                    UpOnlyFormRow(label: "Code", divided: true) {
                        TextField("e.g. CHF", text: $currency).textFieldStyle(.plain).multilineTextAlignment(.trailing).font(UpOnlyType.row.weight(.medium))
                            .accessibilityLabel("Currency code")
                    }
                }
                // Only when there's a company it could have been for (or it already isn't yours).
                if !books.isEmpty || bucket != Bucket.personal.rawValue {
                    UpOnlyFormRow(label: "For", divided: true) {
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
    /// How the transaction will count, in a sentence, so the type and "for" choices explain themselves.
    private func meaning(_ kind: EntryKind, books: [BusinessBook]) -> String {
        let month = dayKnown ? (MonthKey.current(now: date)).title : MonthKey(entryMonth)?.title ?? "this month"
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
    /// The currency last typed in by hand, else this Mac's, else dollars.
    private var defaultCurrency: String {
        session.document?.entries.last { $0.source == .manual }?.currency ?? Locale.current.currency?.identifier ?? "USD"
    }
    /// Common currencies and the ones your accounts use, most likely first.
    private var currencyChoices: [String] {
        var seen = Set<String>()
        return ([defaultCurrency] + (session.document?.accounts.map(\.currency) ?? []) + ["USD", "EUR", "GBP"])
            .map { $0.uppercased() }.filter { $0.count == 3 && seen.insert($0).inserted }
    }
    private static func lastDay(of month: MonthKey) -> Date {
        let start = UTCDay.calendar.date(from: DateComponents(year: month.next.year, month: month.next.month, day: 1)) ?? Date()
        return min(Date(), start.addingTimeInterval(-86400))
    }
    // Recorded lots for one holding, each removable. Removing a lot never changes quantities.
    private func purchasesList(_ holding: Holding) -> some View {
        let lots = (session.document?.purchases ?? []).filter { $0.holdingID == holding.id }.sorted { $0.at < $1.at }
        return VStack(alignment: .leading, spacing: 8) {
            if lots.isEmpty {
                Text("No purchases recorded. Add one to see gain against what you paid.").font(UpOnlyType.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(lots) { lot in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(lot.at.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: UTCDay.timeZone))).font(UpOnlyType.body.weight(.medium))
                        UpOnlyPrivateText(ManageFormat.amount(lot.quantity.value, of: holding, catalog: session.catalog) + " for " + UpOnlyFormat.currencyMoney(lot.paid.value, currency: lot.currency) + " " + lot.currency)
                            .font(UpOnlyType.body).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) { lotToRemove = lot } label: { Image(systemName: "trash") }.controlSize(.small).accessibilityLabel("Remove purchase")
                }
                Divider().opacity(0.5)
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
        let month: MonthKey? = dayKnown ? MonthKey.current(now: date) : MonthKey(entryMonth)
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
                try await session.mutate { doc in doc = try HoldingMutations.moveHolding(assetID: holding.assetID, quantity: quantity, from: holding.portfolioID, to: destination, at: Date(), document: doc) }
            case .purchases(let holding):
                guard let bought = try? MoneyInput.parseExact(lotQuantity), MoneyInput.isFinite(bought), bought > 0 else { throw ImportFailure("Enter the quantity bought, greater than zero.") }
                let paid = try validAmount()
                let code = try validCurrency()
                guard date <= Date() else { throw ImportFailure("Choose today or an earlier date.") }
                try await session.mutate { doc in
                    doc.purchases = (doc.purchases ?? []) + [PurchaseLot(holdingID: holding.id, quantity: PreciseDecimal(bought), paid: PreciseDecimal(paid), currency: code, at: date)]
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
