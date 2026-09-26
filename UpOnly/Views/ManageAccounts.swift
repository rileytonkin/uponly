import SwiftUI

/// Manage → Accounts: manual accounts and connected profiles, their balances, owners and net-worth switch.
extension UpOnlyManagement {
    /// Bank accounts by whose they are: Personal first, then each company, each with its total. A manual account's
    /// row updates its balance; a synced profile's row opens its currencies.
    var accounts: some View {
        let document = session.document
        let all = document?.accounts ?? []
        // Synced Wise currencies fold into one row per profile; manual accounts keep their own row.
        var order: [String] = [], groups: [String: [Account]] = [:]
        for account in all {
            let key = account.externalProfileID.map { "wise:" + $0 } ?? account.id.uuidString
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(account)
        }
        var latest: [UUID: BankBalanceObservation] = [:]
        for observation in document?.bankBalances ?? [] where latest[observation.accountID].map({ $0.observedAt < observation.observedAt }) ?? true {
            latest[observation.accountID] = observation
        }
        let ownerOf: [String: String?] = Dictionary(uniqueKeysWithValues: order.map { key in
            (key, groups[key]?.first.flatMap { account in document.flatMap { AssetOwnership.businessID(for: account, in: $0) } })
        })
        var owners: [String?] = []
        for key in order where !owners.contains(ownerOf[key] ?? nil) { owners.append(ownerOf[key] ?? nil) }
        let ownerName = { (owner: String?) in document.map { AssetOwnership.ownerName(owner, in: $0) } ?? "" }
        owners.sort { a, b in a == nil ? b != nil : b == nil ? false : ownerName(a) < ownerName(b) }
        return VStack(alignment: .leading, spacing: 14) {
            if all.isEmpty {
                ManageEmptyState(title: "No bank accounts yet", detail: "Add a balance or import a statement to begin.", symbol: TrackedKind.banks.symbol, actionTitle: "Add a bank account") {
                    session.startImport(.bankBalances, newAccount: true)
                }
            } else if let document {
                ForEach(owners, id: \.self) { owner in
                    let keys = order.filter { (ownerOf[$0] ?? nil) == owner }
                    let totals = keys.map { usdTotal(groups[$0] ?? [], latest: latest) }
                    let synced = keys.filter { $0.hasPrefix("wise:") }.count
                    VStack(alignment: .leading, spacing: 6) {
                        manageSubheader(AssetOwnership.ownerName(owner, in: document), total: totals.contains { $0 == nil } ? nil : totals.compactMap { $0 }.reduce(0, +))
                        ManageCard {
                            ForEach(Array(keys.enumerated()), id: \.element) { index, key in
                                if let members = groups[key], let first = members.first {
                                    if members.count == 1 && first.externalProfileID == nil { accountRow(first, latest: latest[first.id]) }
                                    // The heading says whose it is, so a lone Wise profile is just "Wise".
                                    else { profileRows(first, members: members, latest: latest, title: synced == 1 ? "Wise" : nil) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    /// What an account or profile holds in dollars at the latest rates; nil while a rate is missing.
    func usdTotal(_ members: [Account], latest: [UUID: BankBalanceObservation]) -> Decimal? {
        var total = Decimal(0)
        for account in members {
            guard let observation = latest[account.id] else { continue }
            guard let dollars = usd(observation.amount.value, currency: account.currency) else { return nil }
            total += dollars
        }
        return total
    }
    /// A dashboard page, leaving Manage for it.
    func showOnDashboard(_ selection: UpOnlySession.DashboardSelection) {
        session.showDashboard(selection)
        leaveManage()
    }
    /// "Synced today · Studio · Outside net worth": when the balance is from, who owns it (unless the name already
    /// says), and whether it counts.
    func accountCaption(_ members: [Account], date: Date?, synced: Bool = false, name: String = "", showsOwner: Bool = false) -> String {
        var parts: [String] = []
        if let date { parts.append((synced ? "Synced " : "Updated ") + Self.when(date, synced: synced)) }
        else { parts.append(synced ? "Not synced yet" : "Balance needed") }
        if let document = session.document, let first = members.first {
            if showsOwner, let owner = AssetOwnership.businessID(for: first, in: document) {
                let company = document.businessAccounting?.first { $0.id == owner }?.name ?? "Company unavailable"
                if company.caseInsensitiveCompare(name) != .orderedSame { parts.append(company) }
            }
            let outside = members.filter { !document.isBankTracked($0.id, at: Date()) }.count
            if outside > 0 { parts.append(outside == members.count ? "Outside net worth" : "Partly outside net worth") }
        }
        return parts.joined(separator: " · ")
    }
    /// "today", "yesterday", "Sep 9", or "Sep 9, 2025" from another year, with today as it is on this Mac: the saved day
    /// a balance is for, or for a sync (a moment), the date it happened here.
    static func when(_ date: Date, synced: Bool = false) -> String {
        let calendar = UTCDay.calendar, day = synced ? UTCDay.today(now: date) : UTCDay.day(of: date), today = UTCDay.today()
        if day == today { return "today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), day == yesterday { return "yesterday" }
        return calendar.component(.year, from: day) == calendar.component(.year, from: today) ? UpOnlyFormat.utcDay(day) : UpOnlyFormat.utcDate(day)
    }
    /// A balance in dollars at the latest saved rate, for the right-hand column every row shares.
    func usd(_ amount: Decimal, currency: String) -> Decimal? {
        if currency == "USD" || amount == 0 { return amount }
        guard let rate = session.latestRate(currency) else { return nil }
        return try? MoneyInput.multiply(amount, rate, allowingRounding: true)
    }
    /// A manual bank account: its dollar value with its own balance under it, and when it's from. The row updates it.
    func accountRow(_ account: Account, latest: BankBalanceObservation?) -> some View {
        let native = latest.map { UpOnlyFormat.currencyMoney($0.amount.value, currency: account.currency) }
        let dollars = latest.flatMap { usd($0.amount.value, currency: account.currency) }.map(UpOnlyFormat.exactMoney)
        return UpOnlyRow(title: account.name, caption: accountCaption([account], date: latest?.observedAt, name: account.name),
                         value: account.currency == "USD" ? native ?? "Add balance" : dollars ?? native ?? "Add balance",
                         valueDetail: account.currency == "USD" || dollars == nil ? nil : native,
                         action: { session.startImport(.bankBalances, prefill: true, accountID: account.id) }) {
            UpOnlyBankBadge(name: account.name, size: 32)
        } menu: {
            let owner = session.document.flatMap { AssetOwnership.businessID(for: account, in: $0) }
            ManageRowMenu(label: "More options for " + account.name) {
                Button("Update balance…") { session.startImport(.bankBalances, prefill: true, accountID: account.id) }
                Button("Import statement…") { session.startImport(.statements, accountID: account.id) }
                Button("Rename…") { editor = .renameAccount(account) }
                ownerMenu(current: owner) { setAccountOwner(account, owner: $0) }
                Button("Show on dashboard") { showOnDashboard(.bankGroup(owner ?? "personal")) }
                Divider()
                netWorthButton([account])
            }
        }
    }
    /// A synced profile is one row like any account: its total in dollars, with how many currencies hold money.
    /// Clicking it lists them. Balances come from the sync, so there's nothing to update by hand.
    @ViewBuilder func profileRows(_ first: Account, members: [Account], latest: [UUID: BankBalanceObservation], title: String? = nil) -> some View {
        let name = title ?? (AssetOwnership.profileName(first).caseInsensitiveCompare("Personal") == .orderedSame ? "Wise" : AssetOwnership.profileName(first))
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
        // Several currencies are named under the total ("USD · EUR"), and the row opens their balances.
        let codes = funded.map(\.0.currency)
        let currencies = codes.count > 3 ? codes.prefix(2).joined(separator: " · ") + " +\(codes.count - 2)" : codes.joined(separator: " · ")
        UpOnlyRow(title: name, caption: accountCaption(members, date: byCurrency.values.compactMap { $0.2 }.max(), synced: true, name: name),
                  value: total.map(UpOnlyFormat.exactMoney) ?? (funded.isEmpty ? "No money" : "Rate needed"),
                  valueDetail: funded.count > 1 ? currencies : funded.first.flatMap { $0.0.currency == "USD" ? nil : UpOnlyFormat.currencyMoney($0.1, currency: $0.0.currency) }, action: funded.count > 1 ? {
                      withAnimation(.snappy(duration: 0.2)) { if open { expandedProfiles.remove(key) } else { expandedProfiles.insert(key) } }
                  } : nil) {
            // Your own profile is "Wise", with Wise's logo; a company's profile keeps its own.
            if name == "Wise" { UpOnlyBankBadge(name: name, synced: true, size: 32) }
            else { UpOnlyProfileImage(data: first.profileImage, name: name, size: 32) }
        } menu: {
            let owner = session.document.flatMap { AssetOwnership.businessID(for: first, in: $0) }
            ManageRowMenu(label: "More options for " + name) {
                #if UPONLY_PERSONAL
                Button("Sync now") { Task { await session.refreshWise() } }.disabled(session.wiseRefreshing)
                #endif
                ownerMenu(current: owner) { setAccountOwner(first, owner: $0) }
                Button("Show on dashboard") { showOnDashboard(.bankGroup(owner ?? "personal")) }
                Divider()
                netWorthButton(members)
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
