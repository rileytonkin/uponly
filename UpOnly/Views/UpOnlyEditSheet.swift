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
    private var editingMonth: Binding<MonthKey> { Binding(get: { MonthKey(entryMonth) ?? .current() }, set: { entryMonth = $0.description }) }
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
                if session.managementInMenu, !session.entryMonthForManagement.isEmpty { entryMonth = session.entryMonthForManagement }
            case .editEntry(let entry):
                kind = entry.kind.rawValue; bucket = entry.bucket.rawValue; amount = UpOnlyFormat.quantity(entry.amount)
                currency = entry.currency; name = entry.label; entryMonth = entry.month
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
            Picker("Type", selection: $kind) { ForEach(entryKinds, id: \.self) { Text(kindTitle($0)).tag($0.rawValue) } }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("Transaction type")
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                amountField
                TextField("USD", text: $currency).textFieldStyle(.plain).font(.system(size: 14, weight: .medium)).frame(width: 50).accessibilityLabel("Currency")
            }
            field("Description", text: $name, placeholder: "What was it for?")
            UpOnlyMonthPicker(month: editingMonth)
            Picker("Category", selection: $bucket) { Text("Personal").tag("personal"); Text("Business").tag("otherBusiness"); Text("Business cost").tag("businessCost") }
        }
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
        guard let month = MonthKey(entryMonth), month <= .current(), month.year >= 1900,
              let entryKind = EntryKind(rawValue: kind), let entryBucket = Bucket(rawValue: bucket) else { throw VaultError.invalidAmount }
        let value = try validAmount()
        let code = try validCurrency()
        return Entry(month: month, bucket: entryBucket, kind: entryKind, amount: value, currency: code, label: label, source: .manual)
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
                    if edited.bucket != .businessCost { doc.entries[index].businessID = nil }
                }
            }
            onSave()
        } catch { self.error = (error as? ImportFailure)?.text ?? (error as? VaultError)?.errorDescription ?? "Couldn’t save this change. Your previous data is safe. Try again." }
    }
}
