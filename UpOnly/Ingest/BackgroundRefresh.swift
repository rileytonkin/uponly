import Foundation
import Security

/// Provider configuration and a signing key can refresh sources while locked.
/// The vault's decryption key and inbox private key are never stored here.
nonisolated struct BackgroundConfiguration: Codable, Sendable, Equatable {
    var vaultID: UUID
    var inboxPublicKey: Data
    var signingPrivateKey: Data
    var signingPublicKey: Data
    var crypto: [String]
    var currencies: [String]
    var metals: [PreciousMetal]
    var pricesEnabled: Bool
    var fxEnabled: Bool
    var metalsEnabled: Bool
    var coinGeckoKey: String
    var wiseEnabled: Bool = false
    var accountingEnabled: Bool = false
    static var service: String { (Bundle.main.bundleIdentifier ?? "org.uponly") + ".background" }
    static func load() throws -> Self? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "sources", kSecReturnData as String: true, kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw ImportFailure("Background source configuration is unavailable.") }
        return try JSONDecoder().decode(Self.self, from: data)
    }
    func save() throws {
        let match: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service, kSecAttrAccount as String: "sources"]
        let data = try JSONEncoder().encode(self)
        let status = SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = match; item[kSecValueData as String] = data; item[kSecAttrLabel as String] = "Up Only background sources"
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw ImportFailure("Background sources could not be saved.") }
        } else if status != errSecSuccess { throw ImportFailure("Background sources could not be updated.") }
    }
}
#if UPONLY_PERSONAL
nonisolated struct BackgroundBankProfile: Codable, Sendable {
    var profile: WiseConfiguredProfile
    var balances: [WiseBalance]
    var activities: [WiseActivity]?
}
#endif
/// Persist the automatic attempt so menu openings, relaunches and reconnects
/// cannot bypass each source’s refresh interval.
actor BackgroundRefreshSchedule {
    static let shared = BackgroundRefreshSchedule()
    nonisolated static func interval(for source: String) -> TimeInterval {
        source == "banks" ? 12 * 60 * 60 : ["crypto", "metals", "history"].contains(source) ? 60 * 60 : 15 * 60
    }
    nonisolated private struct Record: Codable {
        var vaultID: UUID
        var attemptedAt: Date
        var failed: Bool
        /// Consecutive failures; each doubles the retry delay.
        var failures: Int?
    }
    private func path(_ root: URL, source: String) -> URL { root.appendingPathComponent("Background-" + source + ".schedule") }
    private func record(vaultID: UUID, root: URL, source: String) -> Record? {
        guard let data = try? Data(contentsOf: path(root, source: source)),
              let record = try? VaultJSON.decode(Record.self, from: data), record.vaultID == vaultID else { return nil }
        return record
    }
    func claim(vaultID: UUID, root: URL, source: String = "banks", now: Date = Date()) throws -> Bool {
        try Task.checkCancellation()
        let last = record(vaultID: vaultID, root: root, source: source)
        if let last, now >= last.attemptedAt {
            // A failure is retried after a twelfth of the interval (five minutes for hourly sources), doubling up to the interval.
            let interval = Self.interval(for: source)
            let wait = last.failed ? min(interval, interval / 12 * Double(1 << min(max((last.failures ?? 1) - 1, 0), 12))) : interval
            if now.timeIntervalSince(last.attemptedAt) < wait { return false }
        }
        try write(Record(vaultID: vaultID, attemptedAt: now, failed: false, failures: last?.failures), root: root, source: source)
        return true
    }
    func finish(vaultID: UUID, root: URL, failed: Bool, source: String = "banks", now: Date = Date()) throws {
        let failures = failed ? (record(vaultID: vaultID, root: root, source: source)?.failures ?? 0) + 1 : nil
        try write(Record(vaultID: vaultID, attemptedAt: now, failed: failed, failures: failures), root: root, source: source)
    }
    private func write(_ record: Record, root: URL, source: String) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try DiskFileIO().write(VaultJSON.encode(record), to: path(root, source: source), sync: false)
    }
    func failed(vaultID: UUID, root: URL, source: String = "banks") -> Bool { record(vaultID: vaultID, root: root, source: source)?.failed == true }
    /// Forgets the last attempt so a changed key, a newly enabled source or an attempt cut short by going offline is tried straight away.
    func reset(vaultID: UUID, root: URL, sources: [String]) {
        for source in sources where record(vaultID: vaultID, root: root, source: source) != nil {
            try? FileManager.default.removeItem(at: path(root, source: source))
        }
    }
}
nonisolated struct BackgroundPacket: Codable, Sendable {
    var source: String
    var fetchedAt: Date
    var prices: PriceUpdate?
    var books: [BusinessBook]?
    #if UPONLY_PERSONAL
    var banks: [BackgroundBankProfile]?
    #endif
}
nonisolated struct BackgroundEnvelope: Codable, Sendable {
    var vaultID: UUID
    var wrappedKey: Data
    var nonce: Data
    var ciphertext: Data
    var tag: Data
    var signature: Data
    private var signedBytes: Data { vaultID.uuidString.data(using: .utf8)! + wrappedKey + nonce + ciphertext + tag }
    static func seal(_ packet: BackgroundPacket, configuration: BackgroundConfiguration) throws -> Self {
        let key = VaultCrypto.randomKey()
        let sealed = try VaultCrypto.seal(try VaultJSON.encode(packet), key: key, schema: 901, vaultID: configuration.vaultID, generation: 1)
        var envelope = Self(vaultID: configuration.vaultID, wrappedKey: try VaultCrypto.wrapAESKey(VaultCrypto.keyData(key), inboxPublicX963: configuration.inboxPublicKey), nonce: sealed.nonce, ciphertext: sealed.ciphertext, tag: sealed.tag, signature: Data())
        envelope.signature = try VaultCrypto.sign(envelope.signedBytes, privateKeyX963: configuration.signingPrivateKey)
        return envelope
    }
    func open(document: VaultDocument) throws -> BackgroundPacket {
        guard vaultID == document.vaultID, let publicKey = document.backgroundSignerPublicKey else { throw VaultError.invalidSignature }
        try VaultCrypto.verify(signedBytes, signature: signature, publicKeyX963: publicKey)
        let key = try VaultCrypto.key(from: VaultCrypto.unwrapAESKey(wrappedKey, inboxPrivateX963: document.inboxPrivateKeyX963))
        let packet = try VaultJSON.decode(BackgroundPacket.self, from: VaultCrypto.open(nonce: nonce, ciphertext: ciphertext, tag: tag, key: key, schema: 901, vaultID: vaultID, generation: 1))
        guard BackgroundRefresh.sources.contains(packet.source), packet.fetchedAt <= Date().addingTimeInterval(300) else { throw VaultError.corrupt }
        return packet
    }
}
nonisolated enum BackgroundRefresh {
    static let interval: TimeInterval = 15 * 60
    static let sources = ["crypto", "fx", "metals", "banks", "accounting"]
    static func path(_ source: String, root: URL) -> URL { root.appendingPathComponent("Background-" + source + ".sealed") }
    static func save(_ packet: BackgroundPacket, configuration: BackgroundConfiguration, root: URL) throws {
        try Task.checkCancellation()
        let bytes = try VaultJSON.encode(BackgroundEnvelope.seal(packet, configuration: configuration))
        guard bytes.count <= 8 * 1024 * 1024 else { throw VaultError.oversizedInbox }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try DiskFileIO().write(bytes, to: path(packet.source, root: root), sync: false)
    }
    // File IO, signature verification, decryption and decoding must never run
    // on the UI executor while the newly unlocked menu is trying to appear.
    static func cachedPackets(document: VaultDocument, root: URL) -> (packets: [BackgroundPacket], issues: [String]) {
        var packets: [BackgroundPacket] = [], issues: [String] = []
        for source in sources {
            if Task.isCancelled { return ([], []) }
            let url = path(source, root: root)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 8 * 1024 * 1024 else { continue }
                let envelope = try VaultJSON.decode(BackgroundEnvelope.self, from: Data(contentsOf: url))
                let packet = try envelope.open(document: document)
                guard packet.source == source else { throw VaultError.corrupt }
                if packet.fetchedAt > (document.backgroundAppliedAt?[source] ?? .distantPast) { packets.append(packet) }
            } catch { issues.append(source.capitalized + " cached data") }
        }
        return Task.isCancelled ? ([], []) : (packets, issues)
    }
    /// Claims the source's slot, fetches and seals its packet, and records the outcome. Returns false if the
    /// source is failing. Going offline or being cancelled isn't a failed attempt: the slot is freed for the reconnect.
    static func scheduled(_ source: String, configuration: BackgroundConfiguration, root: URL, schedule: BackgroundRefreshSchedule = .shared,
                          fetch: () async throws -> BackgroundPacket) async -> Bool {
        let vaultID = configuration.vaultID
        do {
            guard try await schedule.claim(vaultID: vaultID, root: root, source: source) else {
                return await !schedule.failed(vaultID: vaultID, root: root, source: source)
            }
        } catch { return false }
        do {
            try save(try await fetch(), configuration: configuration, root: root)
            try await schedule.finish(vaultID: vaultID, root: root, failed: false, source: source)
            return true
        } catch {
            if PublicPrices.isOffline(error) { await schedule.reset(vaultID: vaultID, root: root, sources: [source]) }
            else { try? await schedule.finish(vaultID: vaultID, root: root, failed: true, source: source) }
            return false
        }
    }
    /// Separate envelopes preserve each source's last success if another fails.
    static func fetch(configuration: BackgroundConfiguration, root: URL) async -> [String] {
        var errors: [String] = []
        if configuration.pricesEnabled && !configuration.crypto.isEmpty {
            let ok = await scheduled("crypto", configuration: configuration, root: root) {
                let quotes = try await PublicPrices.quotes(ids: configuration.crypto, key: configuration.coinGeckoKey)
                return BackgroundPacket(source: "crypto", fetchedAt: Date(), prices: PriceUpdate(quotes: quotes))
            }
            if !ok { errors.append("Crypto") }
        }
        if configuration.fxEnabled && !configuration.currencies.isEmpty {
            do {
                let update = try await PublicPrices.fx(currencies: Set(configuration.currencies))
                if !update.rates.isEmpty { try save(BackgroundPacket(source: "fx", fetchedAt: Date(), prices: update), configuration: configuration, root: root) }
                if !update.fxIssues.isEmpty { errors.append("Some exchange rates") }
            } catch { errors.append("Exchange rates") }
        }
        if configuration.metalsEnabled && !configuration.metals.isEmpty {
            let ok = await scheduled("metals", configuration: configuration, root: root) {
                var quotes: [QuoteObservation] = []
                for metal in configuration.metals {
                    try Task.checkCancellation()
                    let data = try await PublicPrices.request(host: "api.gold-api.com", path: "/price/" + metal.rawValue, query: [])
                    quotes.append(try PriceHistory.decodeMetal(data, metal: metal, fetchedAt: Date()))
                    try await Task.sleep(for: .seconds(1.1))
                }
                return BackgroundPacket(source: "metals", fetchedAt: Date(), prices: PriceUpdate(quotes: quotes))
            }
            if !ok { errors.append("Metals") }
        }
        #if UPONLY_PERSONAL
        if configuration.wiseEnabled {
            let ok = await scheduled("banks", configuration: configuration, root: root) {
                let snapshot = try await WiseAPI.fetch(WiseConnection.load())
                let profiles = snapshot.profiles.map { BackgroundBankProfile(profile: $0.profile, balances: $0.balances, activities: $0.activities) }
                return BackgroundPacket(source: "banks", fetchedAt: snapshot.fetchedAt, banks: profiles)
            }
            if !ok { errors.append("Bank balances") }
        }
        if configuration.accountingEnabled {
            do {
                let result = try await AccountingAPI.fetchResult(AccountingConnection.load())
                if !result.failedSources.isEmpty { errors.append(contentsOf: result.failedSources.map { $0 + " accounting" }) }
                try save(BackgroundPacket(source: "accounting", fetchedAt: Date(), books: result.books), configuration: configuration, root: root)
            } catch { errors.append("Accounting") }
        }
        #endif
        return errors
    }
    static func applying(_ packet: BackgroundPacket, to document: VaultDocument) throws -> VaultDocument {
        var next = document
        guard packet.fetchedAt > (document.backgroundAppliedAt?[packet.source] ?? .distantPast) else { return next }
        switch packet.source {
        case "crypto", "fx", "metals":
            let enabled = packet.source == "crypto" ? document.settings.automaticPrices : packet.source == "fx" ? document.settings.automaticFX : document.settings.automaticMetals
            guard enabled, let prices = packet.prices else { return next }
            next = try PriceHistory.applying(prices, to: next, now: Date())
        case "accounting":
            if let books = packet.books {
                next.businessAccounting = AccountingHistory.merging(books, into: document.businessAccounting ?? [])
                OwnerPayments.reconcile(in: &next)
                next.track(.cashFlow)
            }
        #if UPONLY_PERSONAL
        case "banks":
            guard document.settings.automaticWise, let banks = packet.banks else { return next }
            next = try WiseAPI.apply(WiseSnapshot(profiles: banks.map { WiseProfileSnapshot(profile: $0.profile, balances: $0.balances, activities: $0.activities ?? []) }, fetchedAt: packet.fetchedAt), to: next)
        #endif
        default: return next
        }
        var applied = next.backgroundAppliedAt ?? [:]; applied[packet.source] = packet.fetchedAt; next.backgroundAppliedAt = applied
        return next
    }
}
