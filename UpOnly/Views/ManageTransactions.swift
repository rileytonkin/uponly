import SwiftUI

/// Manage → Transactions: search, month and account filters, and each transaction's options.
extension UpOnlyManagement {
    var entries: some View {
        let matching = filteredEntries
        let visible = Array(matching.prefix(entryLimit))
        let groups = Dictionary(grouping: visible, by: \.month)
        let imported = importedEntryAccounts
        // Rows name their account only when statements came from more than one.
        let accountNames: [UUID: String] = imported.count > 1 ? Dictionary(uniqueKeysWithValues: imported.map { ($0.id, $0.name) }) : [:]
        let searching = !entrySearch.isEmpty || !entryProfile.isEmpty || !entryAccount.isEmpty
        return VStack(alignment: .leading, spacing: 12) {
            // Adding is the + beside the title; search sits alone, like a list's own search field.
            UpOnlySearchField(placeholder: "Search transactions", text: $entrySearch).onChange(of: entrySearch) { entryLimit = 100 }
            UpOnlyFlow(spacing: 12) {
                Picker("Month", selection: $entryMonth) {
                    Text("All months").tag("")
                    ForEach(Array(Set((session.document?.entries ?? []).map(\.month) + (entryMonth.isEmpty ? [] : [entryMonth]))).sorted(by: >), id: \.self) { Text(MonthKey($0)?.title ?? $0).tag($0) }
                }.labelsHidden().fixedSize().accessibilityLabel("Filter transactions by month").onChange(of: entryMonth) { session.entryMonthForManagement = entryMonth; entryLimit = 100 }
                if imported.count > 1 {
                    Picker("Account", selection: $entryAccount) {
                        Text("All accounts").tag("")
                        ForEach(imported) { Text($0.name).tag($0.id.uuidString) }
                    }.labelsHidden().fixedSize().accessibilityLabel("Filter transactions by account").onChange(of: entryAccount) { entryLimit = 100 }
                }
                #if UPONLY_PERSONAL
                if session.wiseProfiles.contains(where: { profile in
                    session.document?.entries.contains(where: { $0.sourceRef?.hasPrefix("wise:" + String(profile.id) + ":") == true }) == true
                }) {
                    Picker("Profile", selection: $entryProfile) {
                        Text("All profiles").tag("")
                        ForEach(session.wiseProfiles) { Text($0.name).tag(String($0.id)) }
                    }.labelsHidden().fixedSize().accessibilityLabel("Filter transactions by profile").onChange(of: entryProfile) { entryLimit = 100 }
                }
                #endif
            }
            if matching.isEmpty {
                if searching {
                    ManageEmptyState(title: "No matching transactions", detail: "Try another description or clear your filters.", symbol: "list.bullet.rectangle.fill", tint: UpOnlyTint.cashFlow, actionTitle: "Clear filters") {
                        entryMonth = ""; entryProfile = ""; entryAccount = ""; entrySearch = ""
                    }
                } else {
                    ManageEmptyState(title: MonthKey(entryMonth).map { "Nothing in " + $0.title } ?? "No transactions yet",
                                     detail: entryMonth.isEmpty ? "Add a transaction or import a statement." : "Add a transaction, import a statement, or choose All months.",
                                     symbol: "list.bullet.rectangle.fill", tint: UpOnlyTint.cashFlow, actionTitle: "Add a transaction") { editor = .entry }
                }
            } else {
                ForEach(groups.keys.sorted(by: >), id: \.self) { month in
                    let rows = groups[month] ?? []
                    VStack(alignment: .leading, spacing: 6) {
                        Text(MonthKey(month)?.title ?? month).font(UpOnlyType.section)
                        ManageCard {
                            ForEach(rows) { entry in
                                transactionRow(entry, accountNames: accountNames)
                            }
                        }
                    }
                }
                if matching.count > entryLimit { Button("Show more transactions") { entryLimit += 100 }.buttonStyle(.upOnlySecondary) }
            }
        }
    }
    /// A transaction: what it was, when and in what, and the amount. Clicking it opens its options underneath.
    func transactionRow(_ entry: Entry, accountNames: [UUID: String]) -> some View {
        let editing = editingEntry == entry.id
        return VStack(alignment: .leading, spacing: 8) {
            Button { editingEntry = editing ? nil : entry.id } label: {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(entry.label).font(UpOnlyType.row.weight(.medium))
                            .lineLimit(2).help(entry.label)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        UpOnlyPrivateText(kindSign(entry.kind) + UpOnlyFormat.currencyMoney(entry.amount, currency: entry.currency))
                            .font(UpOnlyType.row.weight(.medium).monospacedDigit())
                            .foregroundStyle(entry.kind == .income ? UpOnlyTint.gain : .primary)
                            .fixedSize(horizontal: false, vertical: true).layoutPriority(1)
                    }
                    let details = captionParts(entry, accountNames: accountNames)
                    if !details.isEmpty {
                        Text(details.joined(separator: " · ")).lineLimit(1).help(details.joined(separator: " · "))
                            .font(UpOnlyType.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(editing ? 90 : 0)).padding(.top, 4)
            }.padding(.vertical, 8).contentShape(Rectangle())
            }.buttonStyle(UpOnlyRowButtonStyle())
                .help(editing ? "Close options" : "Change type, who paid, or remove")
                .accessibilityLabel(entry.label).accessibilityHint(editing ? "Closes options" : "Opens options")
                .accessibilityAddTraits(editing ? .isSelected : [])
            if editing { transactionOptions(entry).padding(.bottom, 10) }
        }
    }
    /// The caption, then the account and (for Wise) the profile it came through, whichever are known.
    func captionParts(_ entry: Entry, accountNames: [UUID: String]) -> [String] {
        var parts = [caption(entry)].filter { !$0.isEmpty }
        if let id = entry.accountID, let name = accountNames[id] { parts.append(name) }
        #if UPONLY_PERSONAL
        if entry.source == .wise, let profileID = entry.sourceRef?.split(separator: ":").dropFirst().first,
           let profile = session.wiseProfiles.first(where: { String($0.id) == profileID }) { parts.append(profile.name) }
        #endif
        return parts
    }
    /// "Aug 12 · Refund": the day when the source gave one, then anything unusual about the row. The amount already
    /// says its currency ("£40.00").
    func caption(_ entry: Entry) -> String {
        var parts: [String] = []
        if let day = entry.day.flatMap({ ManageFormat.day($0) }) { parts.append(day) }
        if entry.kind == .transfer || entry.kind == .refund { parts.append(kindTitle(entry.kind)) }
        if entry.bucket == .businessCost { parts.append("Paid for " + businessName(entry.businessID)) } else if entry.bucket == .otherBusiness { parts.append("Business") }
        return parts.joined(separator: " · ")
    }
    @ViewBuilder func transactionOptions(_ entry: Entry) -> some View {
        Picker("Transaction type", selection: Binding(get: { entry.kind }, set: { TransactionEdits.reclassify(entry, as: $0, in: session) })) {
            ForEach(entryKinds, id: \.self) { Text(kindTitle($0)).tag($0) }
        }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("Transaction type")
        if entry.kind == .expense, entry.bucket == .personal || entry.bucket == .businessCost {
            Picker("Paid for", selection: Binding(get: { entry.bucket == .businessCost ? "business:" + (entry.businessID ?? "") : "me" }, set: { choice in
                let business = String(choice.dropFirst("business:".count))
                if choice == "me" { TransactionEdits.reassign(entry, to: .personal, business: nil, in: session) }
                else { TransactionEdits.reassign(entry, to: .businessCost, business: business.isEmpty ? nil : business, in: session) }
            })) {
                Text("Me").tag("me")
                let books = session.document?.businessAccounting ?? []
                if books.isEmpty { Text("The business").tag("business:") }
                ForEach(books) { Text($0.name).tag("business:" + $0.id) }
            }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("Paid for")
            if entry.bucket == .businessCost {
                Text("Left out of personal spending. The company's accounting is unchanged.").font(UpOnlyType.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        if entry.source != .manual, entry.bucket == .personal, let doc = session.document {
            let always = OwnerPayments.isPersonalTransferCounterparty(entry.label, document: doc)
            Toggle(isOn: Binding(get: { always }, set: { TransactionEdits.setTransferCounterparty(entry.label, enabled: $0, in: session) })) {
                Text(always ? "Payments to “\(entry.label)” are always transfers" : "Always treat “\(entry.label)” as a transfer")
                    .font(UpOnlyType.body).fixedSize(horizontal: false, vertical: true)
            }.toggleStyle(.switch).controlSize(.small).accessibilityLabel("Always treat " + entry.label + " as a transfer")
            Text("Use this for money moved to your own company or another account you own. Imports and syncs apply it automatically.")
                .font(UpOnlyType.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        UpOnlyFlow(spacing: 8) {
            if entry.source == .manual { Button("Edit details…") { editor = .editEntry(entry) } }
            if entry.source != .wise { Button("Remove transaction…", role: .destructive) { entryToRemove = entry } }
        }
    }
    func businessName(_ id: String?) -> String {
        session.document?.businessAccounting?.first { $0.id == id }?.name ?? "the business"
    }
    /// Newest month first; within a month, newest day first (rows without a day last), then by description.
    var filteredEntries: [Entry] {
        (session.document?.entries ?? []).filter { entry in
            (entryMonth.isEmpty || entry.month == entryMonth)
                && (entrySearch.isEmpty || entry.label.localizedCaseInsensitiveContains(entrySearch))
                && (entryProfile.isEmpty || entry.sourceRef?.hasPrefix("wise:" + entryProfile + ":") == true)
                && (entryAccount.isEmpty || entry.accountID?.uuidString == entryAccount)
        }.sorted { a, b in
            if a.month != b.month { return a.month > b.month }
            if a.day != b.day { return (a.day ?? "") > (b.day ?? "") }
            let order = a.label.localizedStandardCompare(b.label)
            return order == .orderedSame ? a.id.uuidString < b.id.uuidString : order == .orderedAscending
        }
    }
    /// Bank accounts that statements have been imported into. The account filter only appears when there is more than one.
    var importedEntryAccounts: [Account] {
        guard let doc = session.document else { return [] }
        let used = Set(doc.entries.compactMap(\.accountID))
        return doc.accounts.filter { used.contains($0.id) }
    }
}
