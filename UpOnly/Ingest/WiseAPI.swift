#if UPONLY_PERSONAL
import Foundation
import Security


// Compiled exclusively into the owner's local build. Credentials and profile IDs are never bundled.
nonisolated struct WiseConfiguredProfile: Codable, Sendable, Identifiable {
    var id: Int64
    var name: String
    var bucket: Bucket
    var image: Data?
}
nonisolated struct WiseConnection: Codable, Sendable {
    var token: String
    var profiles: [WiseConfiguredProfile]
    static let keychainService = "org.uponly.personal.wise"
    /// Kept in the data-protection Keychain, on this Mac only; one provisioned into the login keychain is moved there
    /// (`KeychainItem.provisioned`). Reading never asks for authentication, so background work can't prompt.
    static func load(from keychain: KeychainItemStore = KeychainItem(service: WiseConnection.keychainService, account: "connection", label: "Up Only Wise connection")) throws -> WiseConnection {
        guard let data = try? KeychainItem.provisioned(from: keychain) else {
            throw ImportFailure("Your private Wise connection is not available in this Mac’s Keychain.")
        }
        let connection = try JSONDecoder().decode(WiseConnection.self, from: data)
        guard !connection.token.isEmpty, !connection.profiles.isEmpty, connection.profiles.count <= 10,
              Set(connection.profiles.map(\.id)).count == connection.profiles.count else { throw ImportFailure("Check the private Wise connection configuration.") }
        return connection
    }
}
nonisolated struct WiseAmount: Codable, Sendable { var value: Decimal; var currency: String }
nonisolated struct WiseBalance: Codable, Sendable {
    var id: Int64
    var currency: String
    var amount: WiseAmount
    /// "STANDARD" for the main balance, "SAVINGS" for a jar. Optional so older fixtures decode.
    var type: String?
    /// A jar's name; the main balance has none.
    var name: String?
}
nonisolated struct WiseActivity: Codable, Sendable {
    struct Resource: Codable, Sendable { var type: String; var id: String }
    var id: String
    var type: String
    var resource: Resource?
    var title: String?
    var description: String?
    var primaryAmount: String?
    var secondaryAmount: String?
    var status: String
    var createdOn: String
}
nonisolated struct WiseActivityPage: Decodable, Sendable { var cursor: String?; var activities: [WiseActivity] }
nonisolated struct WiseProfileSnapshot: Sendable {
    var profile: WiseConfiguredProfile
    var balances: [WiseBalance]
    var activities: [WiseActivity]
}
nonisolated struct WiseSnapshot: Sendable { var profiles: [WiseProfileSnapshot]; var fetchedAt: Date }
nonisolated enum WiseAPI {
    static func request(path: String, query: [URLQueryItem] = [], token: String) async throws -> Data {
        guard path.hasPrefix("/v"), !path.contains(".."), token.utf8.count <= 4096,
              !token.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw ImportFailure("Invalid Wise request.") }
        var url = URLComponents(); url.scheme = "https"; url.host = "api.wise.com"; url.path = path; url.queryItems = query
        guard let endpoint = url.url else { throw ImportFailure("Invalid Wise request.") }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil; config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 25; config.timeoutIntervalForResource = 45
        let session = URLSession(configuration: config, delegate: NoPriceRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: endpoint); request.httpMethod = "GET"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization"); request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw ImportFailure("Wise returned an unreadable response.") }
        if response.statusCode == 429 { throw ImportFailure("Wise is limiting requests. Your saved records are unchanged; try again later.") }
        if [401, 403].contains(response.statusCode) { throw ImportFailure("Wise access needs attention. Check the read-only token or account authorization.") }
        guard response.statusCode == 200, response.expectedContentLength <= 4 * 1024 * 1024 else { throw ImportFailure("Wise could not refresh. Your saved records are unchanged.") }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 4 * 1024 * 1024 else { throw ImportFailure("Wise returned too much data in one response.") }
            data.append(byte)
        }
        return data
    }
    /// Wise's USD rate for a currency: the latest, or one a day over `start..<end`.
    static func rates(_ currency: String, start: Date?, end: Date?, token: String) async throws -> [FXObservation] {
        let code = try MoneyInput.normalizeCurrency(currency)
        var query = [URLQueryItem(name: "source", value: code), URLQueryItem(name: "target", value: "USD")]
        if let start, let end {
            query += [URLQueryItem(name: "from", value: ImportDateFormat.today(start) + "T00:00"), URLQueryItem(name: "to", value: ImportDateFormat.today(end) + "T00:00"),
                      URLQueryItem(name: "group", value: "day")]
        }
        let data = try await request(path: "/v1/rates", query: query, token: token)
        return try PublicPrices.decodeWiseRates(data, currency: code, fetchedAt: Date(), daily: start != nil, start: start, end: end)
    }
    static func fetch(_ connection: WiseConnection) async throws -> WiseSnapshot {
        var profiles: [WiseProfileSnapshot] = []
        for profile in connection.profiles {
            try Task.checkCancellation()
            // Jars (SAVINGS) hold money too; leaving them out understates the company's cash.
            let balanceData = try await request(path: "/v4/profiles/\(profile.id)/balances", query: [URLQueryItem(name: "types", value: "STANDARD,SAVINGS")], token: connection.token)
            let balances = try JSONDecoder().decode([WiseBalance].self, from: balanceData)
            var activities: [WiseActivity] = [], cursor: String?, cursors = Set<String>(), complete = false
            for _ in 0..<200 {
                var query = [URLQueryItem(name: "size", value: "100")]
                if let cursor { query.append(URLQueryItem(name: "nextCursor", value: cursor)) }
                let data = try await request(path: "/v1/profiles/\(profile.id)/activities", query: query, token: connection.token)
                let page = try JSONDecoder().decode(WiseActivityPage.self, from: data)
                activities += page.activities
                guard activities.count <= 20000 else { throw ImportFailure("Wise history exceeds this sync’s limit. Saved records are unchanged.") }
                guard let next = page.cursor, !next.isEmpty else { complete = true; break }
                guard cursors.insert(next).inserted else { throw ImportFailure("Wise repeated a history page. Try syncing again.") }
                cursor = next
            }
            guard complete else { throw ImportFailure("Wise history is incomplete. Saved records are unchanged.") }
            profiles.append(WiseProfileSnapshot(profile: profile, balances: balances, activities: activities))
        }
        return WiseSnapshot(profiles: profiles, fetchedAt: Date())
    }
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func amount(_ text: String?) throws -> (value: Decimal, currency: String, incoming: Bool)? {
        let clean = plain(text ?? "").replacingOccurrences(of: "−", with: "-")
        guard !clean.isEmpty else { return nil }
        let regex = try NSRegularExpression(pattern: "^([+-]?)\\s*([0-9,]+(?:\\.[0-9]+)?)\\s*([A-Z]{3})$")
        guard let match = regex.firstMatch(in: clean, range: NSRange(clean.startIndex..., in: clean)) else { throw ImportFailure("A Wise activity amount could not be read exactly. Saved records are unchanged.") }
        func group(_ index: Int) -> String { Range(match.range(at: index), in: clean).map { String(clean[$0]) } ?? "" }
        return (try ImportNumberFormat.point.decimal(group(2)), try MoneyInput.normalizeCurrency(group(3)), group(1) == "+")
    }
    static func apply(_ snapshot: WiseSnapshot, to document: VaultDocument) throws -> VaultDocument {
        var next = document
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainFormatter = ISO8601DateFormatter()
        var sharedTransfers: [String: Set<Int64>] = [:]
        for item in snapshot.profiles {
            for activity in item.activities where activity.type == "TRANSFER" && activity.status == "COMPLETED" {
                if let resource = activity.resource { sharedTransfers[resource.id, default: []].insert(item.profile.id) }
            }
        }
        for item in snapshot.profiles {
            let profileID = String(item.profile.id)
            for balance in item.balances {
                let currency = try MoneyInput.normalizeCurrency(balance.currency)
                guard balance.amount.currency == currency else { throw ImportFailure("Wise returned mismatched balance currencies.") }
                try MoneyInput.requireFinite(balance.amount.value)
                let externalBalance = String(balance.id)
                let accountID: UUID
                if let index = next.accounts.firstIndex(where: { $0.externalProfileID == profileID && $0.externalBalanceID == externalBalance }) {
                    accountID = next.accounts[index].id; next.accounts[index].profileImage = item.profile.image
                } else {
                    let jar = balance.type == "SAVINGS" ? (balance.name ?? "Jar") : nil
                    var account = Account(name: item.profile.name + " · " + currency + (jar.map { " · " + $0 } ?? ""), currency: currency)
                    account.ownerBusinessID = next.accounts.first { $0.externalProfileID == profileID }?.ownerBusinessID
                    account.externalProfileID = profileID; account.externalBalanceID = externalBalance; account.profileImage = item.profile.image
                    next.accounts.append(account); accountID = account.id
                    next.setBankTracked(accountID, tracked: true, at: snapshot.fetchedAt)
                }
                if !next.bankBalances.contains(where: { $0.accountID == accountID && $0.observedAt == snapshot.fetchedAt }) {
                    next.bankBalances.append(BankBalanceObservation(id: UUID(), accountID: accountID, amount: PreciseDecimal(balance.amount.value), currency: currency, observedAt: snapshot.fetchedAt, source: "Wise", sourceIdentity: profileID + ":" + externalBalance))
                }
            }
            for activity in item.activities {
                try Task.checkCancellation()
                let reference = "wise:" + profileID + ":" + activity.id
                if ["CANCELLED", "CANCELED", "REVERSED", "FAILED"].contains(activity.status) {
                    next.entries.removeAll { $0.source == .wise && $0.sourceRef == reference }; continue
                }
                guard activity.status == "COMPLETED", activity.type != "CARD_CHECK" else { continue }
                guard let primary = try amount(activity.primaryAmount) else { continue }
                let secondaryText = plain(activity.secondaryAmount ?? "")
                let secondary = secondaryText.contains(where: \.isNumber) ? try amount(secondaryText) : nil
                let income = primary.incoming || ["DEPOSIT", "RECEIVED", "REFUND", "INTEREST", "CASHBACK"].contains { activity.type.contains($0) }
                // Outgoing activity's secondary amount is the amount debited from the source balance.
                // Incoming activity uses the credited primary currency. Currency-list subtitles are not amounts.
                let recorded = !income ? secondary ?? primary : primary
                let amount = recorded.value
                if amount == 0 { continue }
                guard let date = formatter.date(from: activity.createdOn) ?? plainFormatter.date(from: activity.createdOn), date <= snapshot.fetchedAt.addingTimeInterval(300) else { throw ImportFailure("A Wise transaction date is invalid.") }
                // Wise gives the moment; the transaction's day and month are the date it was on this Mac.
                let dayText = ImportDateFormat.today(UTCDay.today(now: date)), monthText = String(dayText.prefix(7))
                guard let month = MonthKey(monthText) else { throw ImportFailure("A Wise transaction month is invalid.") }
                let ownTransfer = activity.type == "INTERBALANCE" || activity.resource.map { (sharedTransfers[$0.id]?.count ?? 0) > 1 } == true
                // Cleaned like an imported statement's: no control characters or marks that reorder how it reads.
                let label = ImportBatchProcessor.cleanLabel(plain(activity.title ?? activity.description ?? "Wise transaction"))
                guard label.count <= 500, !activity.id.isEmpty else { throw ImportFailure("A Wise activity has invalid details.") }
                let existing = next.entries.firstIndex { $0.source == .wise && $0.sourceRef == reference }
                let refund = income && ["REFUND", "CASHBACK"].contains { activity.type.contains($0) }
                var kind: EntryKind = ownTransfer ? .transfer : refund ? .refund : income ? .income : .expense
                if item.profile.bucket == .personal { kind = OwnerPayments.classify(kind, label: label, month: month.description, document: next) }
                if let index = existing {
                    // Retain explicit user classification while refreshing provider amounts/status. A saved day and month
                    // stay: earlier versions dated by UTC, and moving those now would reopen months already confirmed.
                    next.entries[index].amount = amount; next.entries[index].currency = recorded.currency
                    if next.entries[index].day == nil { next.entries[index].month = month.description; next.entries[index].day = dayText }
                    next.entries[index].label = label; next.entries[index].outflow = !income
                    if next.entries[index].kindIsUserEdited != true { next.entries[index].kind = kind }
                } else {
                    var entry = Entry(month: month, bucket: item.profile.bucket, kind: kind, amount: amount, currency: recorded.currency, label: label.isEmpty ? "Wise transaction" : label, source: .wise, sourceRef: reference)
                    entry.day = dayText; entry.outflow = !income
                    next.entries.append(entry)
                }
            }
        }
        next.track(.banks); if next.entries.contains(where: { $0.source == .wise }) { next.track(.cashFlow) }
        // Synced balances anchor a day-by-day history rebuilt from the activity list.
        _ = BalanceReconstruction.apply(accountIDs: Set(next.accounts.filter { $0.externalProfileID != nil }.map(\.id)), to: &next, now: snapshot.fetchedAt)
        return next
    }
}
#endif
