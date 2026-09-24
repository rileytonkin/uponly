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
                // One list: a manual account's row updates its balance; a synced profile lists its currencies under it.
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
    /// "Sep 24 · Studio · Outside net worth": when the balance is from, who owns it, and whether it counts.
    func accountCaption(_ members: [Account], date: Date?, synced: Bool = false) -> String {
        var parts: [String] = []
        if let date { parts.append((synced ? "Synced " : "") + date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: UTCDay.timeZone))) }
        else { parts.append(synced ? "Not synced yet" : "Balance needed") }
        if let document = session.document, let first = members.first {
            if let owner = AssetOwnership.businessID(for: first, in: document) {
                parts.append(document.businessAccounting?.first { $0.id == owner }?.name ?? "Company unavailable")
            }
            let outside = members.filter { !document.isBankTracked($0.id, at: Date()) }.count
            if outside > 0 { parts.append(outside == members.count ? "Outside net worth" : "Partly outside net worth") }
        }
        return parts.joined(separator: " · ")
    }
    /// A manual bank account: its balance and when it's from. The row updates the balance.
    func accountRow(_ account: Account, latest: BankBalanceObservation?, divided: Bool) -> some View {
        ManageRow(title: account.name, caption: accountCaption([account], date: latest?.observedAt),
                  value: latest.map { UpOnlyFormat.currencyMoney($0.amount.value, currency: account.currency) } ?? "Add balance", divided: divided,
                  action: { session.startImport(.bankBalances, prefill: true, accountID: account.id) }) {
            UpOnlySymbolBadge(symbol: TrackedKind.banks.symbol, size: 24)
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
    /// A synced profile: its row, then a line per currency with money in it and one for the empty ones.
    /// Balances come from the sync, so the options apply to the whole profile and there's nothing to update by hand.
    @ViewBuilder func profileRows(_ first: Account, members: [Account], latest: [UUID: BankBalanceObservation], divided: Bool) -> some View {
        let name = AssetOwnership.profileName(first).caseInsensitiveCompare("Personal") == .orderedSame ? "Wise" : AssetOwnership.profileName(first)
        // Jars merge into their currency: one figure per currency for the whole profile.
        let byCurrency: [String: (Account, Decimal, Date?)] = members.reduce(into: [:]) { result, account in
            let observation = latest[account.id]
            let amount = observation?.amount.value ?? 0
            if let existing = result[account.currency] {
                result[account.currency] = (existing.0, existing.1 + amount, [existing.2, observation?.observedAt].compactMap { $0 }.max())
            } else { result[account.currency] = (account, amount, observation?.observedAt) }
        }
        let funded = byCurrency.values.filter { $0.1 != 0 }.sorted { $0.1 > $1.1 }
        let empty = byCurrency.values.filter { $0.1 == 0 }.map(\.0.currency).sorted()
        ManageRow(title: name, caption: accountCaption(members, date: byCurrency.values.compactMap { $0.2 }.max(), synced: true), divided: divided) {
            UpOnlyProfileImage(data: first.profileImage, name: name, size: 24)
        } menu: {
            ManageRowMenu(label: "More options for " + name) {
                ownerMenu(current: session.document.flatMap { AssetOwnership.businessID(for: first, in: $0) }) { setAccountOwner(first, owner: $0) }
                trackingToggle(members)
            }
        }
        ForEach(funded, id: \.0.currency) { account, amount, _ in
            HStack(spacing: 8) {
                Text(account.currency).font(UpOnlyType.body.weight(.medium)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                UpOnlyPrivateText(UpOnlyFormat.currencyMoney(amount, currency: account.currency)).font(UpOnlyType.row.monospacedDigit())
            }.padding(.leading, 34).padding(.trailing, 28).padding(.bottom, 6)
                .accessibilityElement(children: .combine)
        }
        if !empty.isEmpty {
            // Which currencies hold nothing is itself an amount, so it hides with the others.
            UpOnlyPrivateText((funded.isEmpty ? "No money in " : "Empty: ") + empty.joined(separator: ", "))
                .font(UpOnlyType.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 34).padding(.bottom, 8)
        }
    }
}
