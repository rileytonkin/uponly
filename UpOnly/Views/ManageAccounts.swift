import SwiftUI

/// Manage → Accounts: manual accounts and connected profiles, their balances, owners and net-worth switch.
extension UpOnlyManagement {
    var accounts: some View {
        let all = session.document?.accounts ?? []
        // Synced Wise currencies fold into one card per profile; manual accounts keep their own card.
        var order: [String] = [], groups: [String: [Account]] = [:]
        for account in all {
            let key = account.externalProfileID.map { "wise:" + $0 } ?? account.id.uuidString
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(account)
        }
        var latest: [UUID: BankBalanceObservation] = [:]
        for observation in session.document?.bankBalances ?? [] where latest[observation.accountID].map({ $0.observedAt < observation.observedAt }) ?? true {
            latest[observation.accountID] = observation
        }
        return VStack(alignment: .leading, spacing: 12) {
            if all.isEmpty {
                ManageEmptyState(title: "No accounts yet", detail: "Add a balance or import a statement to begin.", symbol: TrackedKind.banks.symbol, actionTitle: "Add account") {
                    session.startImport(.bankBalances, newAccount: true)
                }
            } else {
                // One list: a manual account's row updates its balance; a synced profile's row opens its currencies.
                ManageCard {
                    ForEach(Array(order.enumerated()), id: \.element) { index, key in
                        if let members = groups[key], let first = members.first {
                            if members.count == 1 && first.externalProfileID == nil { accountRow(first, latest: latest[first.id], divided: index > 0) }
                            else { profileRows(first, members: members, latest: latest, divided: index > 0) }
                        }
                    }
                }
            }
        }
    }
    /// "Synced today · Studio · Outside net worth": when the balance is from, who owns it (unless the name already
    /// says), and whether it counts.
    func accountCaption(_ members: [Account], date: Date?, synced: Bool = false, name: String = "") -> String {
        var parts: [String] = []
        if let date { parts.append((synced ? "Synced " : "Updated ") + Self.when(date)) }
        else { parts.append(synced ? "Not synced yet" : "Balance needed") }
        if let document = session.document, let first = members.first {
            if let owner = AssetOwnership.businessID(for: first, in: document) {
                let company = document.businessAccounting?.first { $0.id == owner }?.name ?? "Company unavailable"
                if company.caseInsensitiveCompare(name) != .orderedSame { parts.append(company) }
            }
            let outside = members.filter { !document.isBankTracked($0.id, at: Date()) }.count
            if outside > 0 { parts.append(outside == members.count ? "Outside net worth" : "Partly outside net worth") }
        }
        return parts.joined(separator: " · ")
    }
    /// "today", "yesterday", "Sep 9", or "Sep 9, 2025" from another year.
    static func when(_ date: Date) -> String {
        let calendar = UTCDay.calendar, today = UTCDay.start(of: Date())
        if calendar.isDate(date, inSameDayAs: today) { return "today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), calendar.isDate(date, inSameDayAs: yesterday) { return "yesterday" }
        return calendar.component(.year, from: date) == calendar.component(.year, from: today) ? UpOnlyFormat.utcDay(date) : UpOnlyFormat.utcDate(date)
    }
    /// A balance in dollars at the latest saved rate, for the right-hand column every row shares.
    func usd(_ amount: Decimal, currency: String) -> Decimal? {
        if currency == "USD" || amount == 0 { return amount }
        guard let rate = session.document?.fx.filter({ $0.sourceCurrency == currency && $0.targetCurrency == "USD" }).max(by: { $0.providerTime < $1.providerTime })?.rate.value else { return nil }
        return try? MoneyInput.multiply(amount, rate, allowingRounding: true)
    }
    /// A manual bank account: its dollar value with its own balance under it, and when it's from. The row updates it.
    func accountRow(_ account: Account, latest: BankBalanceObservation?, divided: Bool) -> some View {
        let native = latest.map { UpOnlyFormat.currencyMoney($0.amount.value, currency: account.currency) }
        let dollars = latest.flatMap { usd($0.amount.value, currency: account.currency) }.map(UpOnlyFormat.exactMoney)
        return ManageRow(title: account.name, caption: accountCaption([account], date: latest?.observedAt, name: account.name),
                         value: account.currency == "USD" ? native ?? "Add balance" : dollars ?? native ?? "Add balance",
                         valueDetail: account.currency == "USD" || dollars == nil ? nil : native, divided: divided,
                         action: { session.startImport(.bankBalances, prefill: true, accountID: account.id) }) {
            UpOnlyBankBadge(name: account.name, size: 28)
        } menu: {
            ManageRowMenu(label: "More options for " + account.name) {
                Button("Update balance…") { session.startImport(.bankBalances, prefill: true, accountID: account.id) }
                Button("Rename…") { editor = .renameAccount(account) }
                Button("Import statement…") { session.startImport(.statements, accountID: account.id) }
                ownerMenu(current: session.document.flatMap { AssetOwnership.businessID(for: account, in: $0) }) { setAccountOwner(account, owner: $0) }
                trackingToggle([account])
            }
        }
    }
    /// A synced profile is one row like any account: its total in dollars, with how many currencies hold money.
    /// Clicking it lists them. Balances come from the sync, so there's nothing to update by hand.
    @ViewBuilder func profileRows(_ first: Account, members: [Account], latest: [UUID: BankBalanceObservation], divided: Bool) -> some View {
        let name = AssetOwnership.profileName(first).caseInsensitiveCompare("Personal") == .orderedSame ? "Wise" : AssetOwnership.profileName(first)
        let key = first.externalProfileID ?? first.id.uuidString
        // Jars merge into their currency: one figure per currency for the whole profile.
        let byCurrency: [String: (Account, Decimal, Date?)] = members.reduce(into: [:]) { result, account in
            let observation = latest[account.id]
            let amount = observation?.amount.value ?? 0
            if let existing = result[account.currency] {
                result[account.currency] = (existing.0, existing.1 + amount, [existing.2, observation?.observedAt].compactMap { $0 }.max())
            } else { result[account.currency] = (account, amount, observation?.observedAt) }
        }
        // Less than a cent is nothing, not "€0.00".
        let funded = byCurrency.values.filter { abs($0.1) >= Decimal(string: "0.005")! }
            .sorted { (usd($0.1, currency: $0.0.currency) ?? 0) > (usd($1.1, currency: $1.0.currency) ?? 0) }
        let dollars = funded.map { usd($0.1, currency: $0.0.currency) }
        let total = dollars.contains { $0 == nil } ? nil : dollars.compactMap { $0 }.reduce(Decimal(0), +)
        let open = expandedProfiles.contains(key)
        ManageRow(title: name, caption: accountCaption(members, date: byCurrency.values.compactMap { $0.2 }.max(), synced: true, name: name),
                  value: total.map(UpOnlyFormat.exactMoney) ?? (funded.isEmpty ? "No money" : "Rate needed"),
                  valueDetail: funded.count > 1 ? "\(funded.count) currencies" : funded.first.flatMap { $0.0.currency == "USD" ? nil : UpOnlyFormat.currencyMoney($0.1, currency: $0.0.currency) },
                  divided: divided, action: funded.count > 1 ? {
                      withAnimation(.snappy(duration: 0.2)) { if open { expandedProfiles.remove(key) } else { expandedProfiles.insert(key) } }
                  } : nil) {
            // Your own profile is "Wise", with Wise's logo; a company's profile keeps its own.
            if name == "Wise" { UpOnlyBankBadge(name: name, synced: true, size: 28) }
            else { UpOnlyProfileImage(data: first.profileImage, name: name, size: 28) }
        } menu: {
            ManageRowMenu(label: "More options for " + name) {
                ownerMenu(current: session.document.flatMap { AssetOwnership.businessID(for: first, in: $0) }) { setAccountOwner(first, owner: $0) }
                trackingToggle(members)
            }
        }
        if open {
            VStack(spacing: 4) {
                ForEach(funded, id: \.0.currency) { account, amount, _ in
                    HStack(spacing: 8) {
                        Text(account.currency).font(UpOnlyType.caption.weight(.medium)).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        UpOnlyPrivateText(UpOnlyFormat.currencyMoney(amount, currency: account.currency)).font(UpOnlyType.body.monospacedDigit())
                    }.accessibilityElement(children: .combine)
                }
            }.padding(.leading, 38).padding(.trailing, 28).padding(.bottom, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}
