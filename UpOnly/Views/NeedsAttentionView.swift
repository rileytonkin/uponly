import SwiftUI

struct UpOnlyDataAttention: View {
    @Environment(UpOnlySession.self) private var session
    let report: DataAttention
    /// Closed months still to check, oldest first. `month` is the one shown.
    let months: [MonthKey]
    let month: MonthKey?
    @Binding var selection: String
    var addEntry: () -> Void
    var addRate: () -> Void
    private var hasBankStatus: Bool {
        #if UPONLY_PERSONAL
        return session.document?.settings.automaticWise == true && (session.wiseError != nil || session.backgroundIssues.contains("Bank balances"))
        #else
        return false
        #endif
    }
    private var hasAccountingStatus: Bool {
        #if UPONLY_PERSONAL
        return session.accountingError != nil || session.backgroundIssues.contains { $0 == "Accounting" || $0.hasSuffix(" accounting") }
        #else
        return false
        #endif
    }
    private var priceIssues: [String] { session.backgroundIssues.filter { $0 != "Bank balances" && $0 != "Accounting" && !$0.hasSuffix(" accounting") } }
    var body: some View {
        let caughtUp = months.isEmpty && report.balances.isEmpty && report.quantities.isEmpty && !report.pricesNeeded && report.accountingNames.isEmpty
            && !hasBankStatus && !hasAccountingStatus && priceIssues.isEmpty
        VStack(alignment: .leading, spacing: 16) {
            #if UPONLY_PERSONAL
            if hasBankStatus {
                attentionCard("Wise", symbol: "arrow.triangle.2.circlepath") {
                    note(session.wiseError ?? "Wise could not refresh. Your saved balances and transactions are still available.")
                    Button("Retry Wise") { Task { await session.refreshWise() } }.disabled(session.isBusy || session.wiseRefreshing)
                }
            }
            if hasAccountingStatus {
                attentionCard("Accounting", symbol: "doc.text") {
                    note(session.accountingError ?? "Accounting could not refresh. Your saved results are still available.")
                    Button("Retry accounting") { Task { await session.refreshAccounting() } }.disabled(session.isBusy || session.accountingRefreshing)
                }
            }
            #endif
            if caughtUp {
                ManageEmptyState(title: "You’re all caught up", detail: "Nothing needs checking right now.", symbol: "checkmark.circle.fill", tint: UpOnlyTint.gain)
            }
            if let month {
                // The page header names the month; this starts straight at the figures.
                spendingReview(month).frame(maxWidth: .infinity, alignment: .leading)
            }
            // What's missing is a list of rows, each opening the form that fills it in.
            if !report.balances.isEmpty {
                section("Balances needed") {
                    ForEach(Array(report.balances.enumerated()), id: \.element.id) { index, account in
                        UpOnlyRow(title: account.name, caption: "Add its balance", chevron: true, action: {
                            session.startImport(.bankBalances, prefill: true, accountID: account.id)
                        }) {
                            if let image = account.profileImage { UpOnlyProfileImage(data: image, name: account.name, size: 28) }
                            else { UpOnlyBankBadge(name: account.name, size: 28) }
                        }
                    }
                }
            }
            if !report.quantities.isEmpty {
                section("Holdings need quantities") {
                    ForEach(Array(report.quantities.enumerated()), id: \.element.id) { index, holding in
                        let metals = session.document?.portfolio(id: holding.portfolioID)?.kind == .metals
                        UpOnlyRow(title: holding.assetName, caption: metals ? "Add its weight" : "Add its quantity", chevron: true, action: {
                            session.startImport(metals ? .metals : .holdings, prefill: true, holdingID: holding.id)
                        }) {
                            if let metal = PreciousMetal.asset(holding.assetID) { UpOnlyEntryBadge(mode: .metals, symbol: metal.rawValue, size: 28) }
                            else { UpOnlyAssetBadge(assetID: holding.assetID.rawValue, symbol: holding.assetName, size: 28) }
                        }
                    }
                }
            }
            if report.pricesNeeded || !report.accountingNames.isEmpty || !priceIssues.isEmpty {
                section("Data sources") {
                    VStack(alignment: .leading, spacing: 8) {
                        if !priceIssues.isEmpty { note(priceIssues.joined(separator: ", ") + " could not refresh in the background. Saved values are still shown.") }
                        if report.pricesNeeded { note("No price or rate for today: " + report.missingPriceLabels.joined(separator: ", ") + ". Check the source is on, has its key, and has updated.") }
                        if !report.accountingNames.isEmpty { note(report.accountingNames.joined(separator: ", ") + ": accounting is incomplete for this period.") }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
                    UpOnlyRow(title: "Open Settings", chevron: true, action: { session.managementSection = "Sources" }) {
                        UpOnlySymbolBadge(symbol: "arrow.triangle.2.circlepath", tint: UpOnlyTint.netWorth, size: 28)
                    }
                }
            }
        }.controlSize(.regular)
    }
    @ViewBuilder private func spendingReview(_ month: MonthKey) -> some View {
        if let doc = session.document {
            let state = MonthlyLedger.personal(month, document: doc)
            VStack(alignment: .leading, spacing: 14) {
                if let totals = state.totals {
                    HStack(spacing: 16) {
                        reviewTotal("Income", value: totals.moneyIn)
                        reviewTotal("Spending", value: totals.moneyOut)
                    }
                }
                reviewEvidence(MonthEvidence.build(month, document: doc), document: doc)
                // Fixing the month is a short list, like everywhere else: see them all, or add what's missing.
                ManageCard {
                    UpOnlyRow(title: "All of " + month.title + "’s transactions", chevron: true, action: {
                        session.entryMonthForManagement = month.description; session.managementSection = "Entries"
                    }) { UpOnlySymbolBadge(symbol: "list.bullet", tint: UpOnlyTint.cashFlow, size: 28) }
                    UpOnlyRow(title: "Import a statement", caption: "Transactions from a CSV file", chevron: true, action: {
                        session.startImport(.statements)
                    }) { UpOnlySymbolBadge(symbol: "doc.text.fill", tint: UpOnlyTint.cashFlow, size: 28) }
                    UpOnlyRow(title: "Add a transaction", chevron: true, action: {
                        session.entryMonthForManagement = month.description; addEntry()
                    }) { UpOnlySymbolBadge(symbol: "plus", tint: .accentColor, size: 28) }
                }
                if case .exchangeRates(let currencies)? = state.unavailable {
                    note("A dated " + currencies.joined(separator: ", ") + " exchange rate is also needed.")
                    Menu("Exchange rates") {
                        Button("Get exchange rates") {
                            Task { await session.repairExchangeRates(month: month, currencies: currencies) }
                        }.disabled(session.refreshing || session.isBusy)
                        Button("Add exchange rate") {
                            session.entryMonthForManagement = month.description
                            session.requestedRateCurrency = currencies.first
                            addRate()
                        }
                    }.menuStyle(.borderedButton).fixedSize()
                } else if state.unavailable == .noEntries {
                    note("No transactions are recorded for " + month.title + ". If there was nothing to record, say so and it won’t be asked again.")
                    Button("Nothing to record this month") { confirm(month) }.buttonStyle(.glassProminent)
                } else if state.totals != nil {
                    note("Is all of your income and spending for " + month.title + " recorded?")
                    Button("Yes, it’s complete") { confirm(month) }.buttonStyle(.glassProminent)
                } else {
                    note("Add the missing transactions or rates first.")
                }
            }
        }
    }
    /// Marks the month reviewed, then moves on to the next month still to check, else the latest one left.
    private func confirm(_ month: MonthKey) {
        let selected = month.description
        let remaining = months.filter { $0 != month }
        Task {
            await session.perform { doc in
                if !doc.reviewedMonths.contains(selected) { doc.reviewedMonths.append(selected) }
            }
            if session.document?.reviewedMonths.contains(selected) == true {
                selection = (remaining.first(where: { $0 > month }) ?? remaining.last)?.description ?? ""
            }
        }
    }
    /// Shows what the totals were built from: one USD line per source and the biggest movements, each editable in place.
    private func reviewEvidence(_ evidence: MonthEvidence, document: VaultDocument) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !evidence.sources.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(evidence.sources) { source in
                        HStack(alignment: .center, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.name).font(UpOnlyType.body.weight(.medium)).lineLimit(1)
                                Text("\(source.count) transaction\(source.count == 1 ? "" : "s")").font(UpOnlyType.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 2) {
                                UpOnlyPrivateText(source.moneyIn.map { "+" + UpOnlyFormat.exactMoney($0) } ?? "Rate needed")
                                    .font(UpOnlyType.body.weight(.medium).monospacedDigit()).foregroundStyle(UpOnlyTint.gain)
                                UpOnlyPrivateText(source.moneyOut.map { "−" + UpOnlyFormat.exactMoney($0) } ?? "Rate needed")
                                    .font(UpOnlyType.body.weight(.medium).monospacedDigit())
                            }
                        }.padding(.vertical, 6).accessibilityElement(children: .combine)
                    }
                }
            }
            if !evidence.largest.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Transactions, biggest first").font(UpOnlyType.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 4)
                    // The scroll extends to the panel edge so its bar sits outside the rows.
                    UpOnlyMenuScroll(maxHeight: 280) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(evidence.largest) { item in
                                evidenceRow(item, document: document)
                            }
                        }.padding(.trailing, UpOnlyLayout.inset)
                    }.padding(.trailing, -UpOnlyLayout.inset)
                }
            }
            ForEach(evidence.silent, id: \.self) { name in
                UpOnlyNotice(name + ": nothing this month. Import its statement if you used it.")
            }
        }
    }
    /// Full label with the type and source beneath, amount on the right. Clicking anywhere opens the type menu.
    private func evidenceRow(_ item: MonthEvidence.Item, document: VaultDocument) -> some View {
        let entry = item.entry
        let sign = kindSign(entry.kind)
        let amount = item.usd.map { UpOnlyFormat.exactMoney($0) } ?? UpOnlyFormat.currencyMoney(entry.amount, currency: entry.currency) + " " + entry.currency
        let source = MonthEvidence.sourceName(for: entry, accounts: document.accounts).name
        let alwaysTransfer = OwnerPayments.isPersonalTransferCounterparty(entry.label, document: document)
        return Menu {
            ForEach(entryKinds, id: \.self) { kind in
                Toggle(kindTitle(kind), isOn: Binding(get: { entry.kind == kind }, set: { if $0 { TransactionEdits.reclassify(entry, as: kind, in: session) } }))
            }
            if entry.source != .manual, entry.bucket == .personal, !alwaysTransfer {
                Divider()
                Button("Always a transfer: " + entry.label) { TransactionEdits.setTransferCounterparty(entry.label, enabled: true, in: session) }
            }
            if entry.kind == .expense {
                Divider()
                let books = document.businessAccounting ?? []
                if books.isEmpty { Button("Paid for the business, not me") { TransactionEdits.reassign(entry, to: .businessCost, business: nil, in: session) } }
                else if books.count == 1, let book = books.first { Button("Paid for " + book.name + ", not me") { TransactionEdits.reassign(entry, to: .businessCost, business: book.id, in: session) } }
                else {
                    Menu("Paid for a business, not me") {
                        ForEach(books) { book in Button(book.name) { TransactionEdits.reassign(entry, to: .businessCost, business: book.id, in: session) } }
                    }
                }
            }
        } label: {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.label).font(UpOnlyType.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(entry.kind == .transfer ? .secondary : .primary)
                    Text(kindTitle(entry.kind) + (alwaysTransfer ? " (always)" : "") + " · " + source).font(UpOnlyType.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                UpOnlyPrivateText(sign + amount).font(UpOnlyType.body.weight(.medium).monospacedDigit()).lineLimit(1)
                    .foregroundStyle(entry.kind == .income ? UpOnlyTint.gain : entry.kind == .transfer ? .secondary : .primary)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
            }.padding(.vertical, 6).contentShape(Rectangle())
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .help("Change the type of " + entry.label)
            .accessibilityLabel(entry.label + ", " + kindTitle(entry.kind) + ", " + (session.privacyMode ? "Hidden value" : sign + amount))
    }
    private func reviewTotal(_ title: String, value: Decimal) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(UpOnlyType.caption).foregroundStyle(.secondary)
            UpOnlyPrivateText(UpOnlyFormat.exactMoney(value)).font(UpOnlyType.row.weight(.medium)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func note(_ text: String) -> some View {
        Text(text).font(UpOnlyType.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    /// A titled list, as the dashboard's sections are.
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        let rows = content()
        return VStack(alignment: .leading, spacing: 6) {
            Text(title).font(UpOnlyType.section)
            ManageCard { rows }
        }
    }
    private func attentionCard<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(UpOnlyType.section)
            content()
        }.padding(UpOnlyLayout.cardInset).frame(maxWidth: .infinity, alignment: .leading).modifier(UpOnlyContentSurface())
    }
}

