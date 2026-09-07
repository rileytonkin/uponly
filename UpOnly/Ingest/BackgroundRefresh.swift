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
    }
    private func path(_ root: URL, source: String) -> URL { root.appendingPathComponent("Background-" + source + ".schedule") }
    private func record(vaultID: UUID, root: URL, source: String) -> Record? {
        guard let data = try? Data(contentsOf: path(root, source: source)),
              let record = try? VaultJSON.decode(Record.self, from: data), record.vaultID == vaultID else { return nil }
        return record
    }
    func claim(vaultID: UUID, root: URL, source: String = "banks", now: Date = Date()) throws -> Bool {
        try Task.checkCancellation()
        if let last = record(vaultID: vaultID, root: root, source: source),
           now >= last.attemptedAt, now.timeIntervalSince(last.attemptedAt) < Self.interval(for: source) { return false }
        try finish(vaultID: vaultID, root: root, failed: false, source: source, now: now)
        return true
    }
    func finish(vaultID: UUID, root: URL, failed: Bool, source: String = "banks", now: Date = Date()) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try VaultJSON.encode(Record(vaultID: vaultID, attemptedAt: now, failed: failed)).write(to: path(root, source: source), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path(root, source: source).path)
    }
    func failed(vaultID: UUID, root: URL, source: String = "banks") -> Bool { record(vaultID: vaultID, root: root, source: source)?.failed == true }
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
        let url = path(packet.source, root: root)
        try bytes.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
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
    /// Separate envelopes preserve each source's last success if another fails.
    static func fetch(configuration: BackgroundConfiguration, root: URL) async -> [String] {
        var errors: [String] = []
        if configuration.pricesEnabled && !configuration.crypto.isEmpty {
            do {
                if try await BackgroundRefreshSchedule.shared.claim(vaultID: configuration.vaultID, root: root, source: "crypto") {
                    let quotes = try await PublicPrices.quotes(ids: configuration.crypto, key: configuration.coinGeckoKey)
                    try save(BackgroundPacket(source: "crypto", fetchedAt: Date(), prices: PriceUpdate(quotes: quotes)), configuration: configuration, root: root)
                    try await BackgroundRefreshSchedule.shared.finish(vaultID: configuration.vaultID, root: root, failed: false, source: "crypto")
                }
                if await BackgroundRefreshSchedule.shared.failed(vaultID: configuration.vaultID, root: root, source: "crypto") { errors.append("Crypto") }
            } catch {
                try? await BackgroundRefreshSchedule.shared.finish(vaultID: configuration.vaultID, root: root, failed: true, source: "crypto")
                errors.append("Crypto")
            }
        }
        if configuration.fxEnabled && !configuration.currencies.isEmpty {
            do {
                let update = try await PublicPrices.fx(currencies: Set(configuration.currencies))
                if !update.rates.isEmpty { try save(BackgroundPacket(source: "fx", fetchedAt: Date(), prices: update), configuration: configuration, root: root) }
                if !update.fxIssues.isEmpty { errors.append("Some exchange rates") }
            } catch { errors.append("Exchange rates") }
        }
        if configuration.metalsEnabled && !configuration.metals.isEmpty {
            do {
                if try await BackgroundRefreshSchedule.shared.claim(vaultID: configuration.vaultID, root: root, source: "metals") {
                var quotes: [QuoteObservation] = []
                for metal in configuration.metals {
                    try Task.checkCancellation()
                    let data = try await PublicPrices.request(host: "api.gold-api.com", path: "/price/" + metal.rawValue, query: [])
                    quotes.append(try PriceHistory.decodeMetal(data, metal: metal, fetchedAt: Date()))
                    try await Task.sleep(for: .seconds(1.1))
                }
                try save(BackgroundPacket(source: "metals", fetchedAt: Date(), prices: PriceUpdate(quotes: quotes)), configuration: configuration, root: root)
                try await BackgroundRefreshSchedule.shared.finish(vaultID: configuration.vaultID, root: root, failed: false, source: "metals")
                }
                if await BackgroundRefreshSchedule.shared.failed(vaultID: configuration.vaultID, root: root, source: "metals") { errors.append("Metals") }
            } catch {
                try? await BackgroundRefreshSchedule.shared.finish(vaultID: configuration.vaultID, root: root, failed: true, source: "metals")
                errors.append("Metals")
            }
        }
        #if UPONLY_PERSONAL
        if configuration.wiseEnabled {
            do {
                if try await BackgroundRefreshSchedule.shared.claim(vaultID: configuration.vaultID, root: root) {
                    do {
                        let snapshot = try await WiseAPI.fetch(WiseConnection.load())
                        let profiles = snapshot.profiles.map { BackgroundBankProfile(profile: $0.profile, balances: $0.balances, activities: $0.activities) }
                        try save(BackgroundPacket(source: "banks", fetchedAt: snapshot.fetchedAt, banks: profiles), configuration: configuration, root: root)
                        try await BackgroundRefreshSchedule.shared.finish(vaultID: configuration.vaultID, root: root, failed: false)
                    } catch {
                        try await BackgroundRefreshSchedule.shared.finish(vaultID: configuration.vaultID, root: root, failed: true)
                    }
                }
                if await BackgroundRefreshSchedule.shared.failed(vaultID: configuration.vaultID, root: root) { errors.append("Bank balances") }
            } catch { errors.append("Bank balances") }
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
