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
                // Each account card has its own Update, so this button only adds.
                UpOnlyFlow {
                    Button { session.startImport(.bankBalances, newAccount: true) } label: { Label("Add account", systemImage: "plus") }.buttonStyle(.glassProminent)
                    if all.count > 1 { Button("Update all balances") { session.startImport(.bankBalances, prefill: true) } }
                }
            }
            ForEach(order, id: \.self) { key in
                if let members = groups[key], let first = members.first {
                    if members.count == 1 && first.externalProfileID == nil { accountCard(first, latest: latest[first.id]) }
                    else { profileCard(first, members: members, latest: latest) }
                }
            }
        }
    }
    func accountMenu(_ account: Account) -> some View {
        Menu {
            Button("Rename…") { editor = .renameAccount(account) }
            Button("Import statement…") { session.startImport(.statements, accountID: account.id) }
            ownerMenu(current: session.document.flatMap { AssetOwnership.businessID(for: account, in: $0) }) { setAccountOwner(account, owner: $0) }
            trackingToggle([account])
        } label: { Image(systemName: "ellipsis") }.modifier(UpOnlyRowMenu()).accessibilityLabel("More options for " + account.name)
    }
    @ViewBuilder func ownerLine(_ members: [Account]) -> some View {
        if let document = session.document, let first = members.first {
            if let owner = AssetOwnership.businessID(for: first, in: document) {
                Text("Owner: " + (document.businessAccounting?.first { $0.id == owner }?.name ?? "Company unavailable")).font(UpOnlyType.caption).foregroundStyle(.secondary)
            }
            let outside = members.filter { !document.isBankTracked($0.id, at: Date()) }.count
            if outside > 0 {
                Text(outside == members.count ? "Outside net worth" : "Partly outside net worth").font(UpOnlyType.caption).foregroundStyle(.secondary)
            }
        }
    }
    /// A manual bank account: one balance, one date.
    func accountCard(_ account: Account, latest: BankBalanceObservation?) -> some View {
        HStack(alignment: .center, spacing: 10) {
            UpOnlySymbolBadge(symbol: TrackedKind.banks.symbol, size: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(account.name).font(UpOnlyType.row.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                if let observation = latest {
                    HStack(spacing: 6) {
                        UpOnlyPrivateText(UpOnlyFormat.currencyMoney(observation.amount.value, currency: account.currency)).font(UpOnlyType.row.monospacedDigit())
                        Text(observation.observedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: UTCDay.timeZone))).font(UpOnlyType.caption).foregroundStyle(.secondary)
                    }
                } else { Text("Balance needed").font(UpOnlyType.caption).foregroundStyle(.secondary) }
                ownerLine([account])
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button("Update") { session.startImport(.bankBalances, prefill: true, accountID: account.id) }
                .controlSize(.small).accessibilityLabel("Update balance for " + account.name)
            accountMenu(account)
        }.padding(UpOnlyLayout.cardInset).modifier(UpOnlyContentSurface())
    }
    /// A synced profile: currencies with money listed, empty ones summarised in one line.
    /// Its options apply to the whole profile; balances come from the sync, so there is no Update, Rename or Import.
    func profileCard(_ first: Account, members: [Account], latest: [UUID: BankBalanceObservation]) -> some View {
        let name = AssetOwnership.profileName(first).caseInsensitiveCompare("Personal") == .orderedSame ? "Wise" : AssetOwnership.profileName(first)
        // Jars merge into their currency: one figure per currency for the whole profile.
        var byCurrency: [String: (Account, Decimal, Date?)] = [:]
        for account in members {
            let observation = latest[account.id]
            let amount = observation?.amount.value ?? 0
            if let existing = byCurrency[account.currency] {
                byCurrency[account.currency] = (existing.0, existing.1 + amount, [existing.2, observation?.observedAt].compactMap { $0 }.max())
            } else { byCurrency[account.currency] = (account, amount, observation?.observedAt) }
        }
        let rows = byCurrency.values.map { ($0.0, $0.1) }
        let funded = rows.filter { $0.1 != 0 }.sorted { $0.1 > $1.1 }
        let empty = rows.filter { $0.1 == 0 }
        let synced = byCurrency.values.compactMap { $0.2 }.max()
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                UpOnlyProfileImage(data: first.profileImage, name: name, size: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(UpOnlyType.row.weight(.medium))
                    Text(synced.map { "Synced " + $0.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: UTCDay.timeZone)) } ?? "Not synced yet").font(UpOnlyType.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Menu {
                    ownerMenu(current: session.document.flatMap { AssetOwnership.businessID(for: first, in: $0) }) { setAccountOwner(first, owner: $0) }
                    trackingToggle(members)
                } label: { Image(systemName: "ellipsis") }.modifier(UpOnlyRowMenu()).accessibilityLabel("More options for " + name)
            }
            ownerLine(members)
            VStack(spacing: 0) {
                ForEach(funded, id: \.0.currency) { account, amount in
                    Divider().opacity(0.4)
                    HStack(spacing: 8) {
                        Text(account.currency).font(UpOnlyType.body.weight(.medium))
                        Spacer(minLength: 8)
                        UpOnlyPrivateText(UpOnlyFormat.currencyMoney(amount, currency: account.currency)).font(UpOnlyType.row.monospacedDigit())
                    }.padding(.vertical, 6)
                }
                if !empty.isEmpty {
                    Divider().opacity(0.4)
                    // Which currencies hold nothing is itself an amount, so it hides with the others.
                    UpOnlyPrivateText((funded.isEmpty ? "No money in " : "Empty: ") + empty.map(\.0.currency).sorted().joined(separator: ", "))
                        .font(UpOnlyType.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.padding(UpOnlyLayout.cardInset).modifier(UpOnlyContentSurface())
    }
}
