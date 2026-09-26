import CryptoKit
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
    /// 32 random bytes that name the sealed and schedule files and seal the schedules (`BackgroundFiles`), so the folder
    /// doesn't show which sources are on. Nil in a configuration an earlier build saved: nothing is fetched or read under
    /// it until the next unlock adds one.
    var fileKey: Data? = nil
    static var service: String { (Bundle.main.bundleIdentifier ?? "org.uponly") + ".background" }
    /// Read only from the data-protection Keychain. Earlier builds kept it in the login keychain, where any process
    /// running as you could have put one, so an item there is never read, only deleted: the next unlock saves the
    /// configuration again. An item that can't be read now is never taken for none: loading fails and tries again next time.
    static func load(from keychain: KeychainItemStore = KeychainItem.backgroundSources) throws -> Self? {
        keychain.deleteLegacy()
        guard let data = try keychain.read(legacy: false) else { return nil }
        return try JSONDecoder().decode(Self.self, from: data)
    }
    /// The saved configuration, only when it belongs to the vault in `layout`: the folder holds a vault, and its file's
    /// plain-text header, or its previous copy's, names the configuration's vault. One left by a vault that was deleted,
    /// started over or replaced fetches nothing.
    static func load(for layout: VaultLayout, keychain: KeychainItemStore = KeychainItem.backgroundSources) throws -> Self? {
        guard layout.holdsVault(DiskFileIO()), let stored = layout.storedVaultID(), let saved = try load(from: keychain), saved.vaultID == stored else { return nil }
        return saved
    }
    func save(to keychain: KeychainItemStore = KeychainItem.backgroundSources) throws {
        try keychain.save(JSONEncoder().encode(self))
    }
    /// This configuration's files in `root`, or nil when it has no file key.
    func files(root: URL) -> BackgroundFiles? { fileKey.map { BackgroundFiles(root: root, key: $0) } }
    /// The saved configuration's files, only when it's `vaultID`'s and has a file key. None saved yet, or none readable
    /// now, is nil: what they hold is only a cache and a timer, so the unlocked app goes without them.
    static func files(for vaultID: UUID, root: URL, keychain: KeychainItemStore = KeychainItem.backgroundSources) -> BackgroundFiles? {
        guard let saved = try? load(from: keychain), saved.vaultID == vaultID else { return nil }
        return saved.files(root: root)
    }
}
/// The background files' names, and the key their schedule records are sealed with, from the configuration's file key.
/// A name is a keyed hash of its kind and source, `Background-<first 16 bytes of HMAC-SHA256(key, "sealed:crypto"), hex>.sealed`,
/// so listing the folder shows how many sources are on but not which, and no two file keys give the same names. A
/// schedule record (vault ID, attempt time, failures) is AES-GCM sealed under a key derived from the file key and bound
/// to its source, so the file shows neither the vault nor when the source was tried. Earlier builds named the files by
/// source (`Background-banks.sealed`); `BackgroundRefresh.deleteFiles` removes those when a file key is first saved.
nonisolated struct BackgroundFiles: Sendable {
    let root: URL
    let key: Data
    /// A new file key: 32 random bytes.
    static func newKey() -> Data { VaultCrypto.keyData(VaultCrypto.randomKey()) }
    private func url(_ kind: String, _ source: String) -> URL {
        let code = HMAC<SHA256>.authenticationCode(for: Data((kind + ":" + source).utf8), using: SymmetricKey(data: key))
        return root.appendingPathComponent("Background-" + Data(code).prefix(16).map { String(format: "%02x", $0) }.joined() + "." + kind)
    }
    func sealed(_ source: String) -> URL { url("sealed", source) }
    func schedule(_ source: String) -> URL { url("schedule", source) }
    private var scheduleKey: SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: key), info: Data("Up Only background schedule".utf8), outputByteCount: 32)
    }
    /// Nonce, ciphertext and tag, with `schedule:<source>` authenticated, so a record can't pass for another source's.
    func sealSchedule(_ record: Data, source: String) throws -> Data {
        guard let combined = try AES.GCM.seal(record, using: scheduleKey, authenticating: Data(("schedule:" + source).utf8)).combined else { throw VaultError.corrupt }
        return combined
    }
    func openSchedule(_ data: Data, source: String) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: scheduleKey, authenticating: Data(("schedule:" + source).utf8))
    }
}
/// A Keychain item the app keeps in the data-protection Keychain, and the login keychain's item of the same service and
/// account that came before it: the Keychain in the app, a stand-in in tests.
protocol KeychainItemStore: Sendable {
    /// The saved bytes, or nil if there are none. Throws when there may be some that can't be read now.
    nonisolated func read(legacy: Bool) throws -> Data?
    /// Saves to the data-protection item, replacing what's there.
    nonisolated func save(_ data: Data) throws
    /// Deletes the data-protection item; none there is nothing to do.
    nonisolated func delete() throws
    /// Deletes the login keychain's item.
    nonisolated func deleteLegacy()
}
nonisolated struct KeychainItem: KeychainItemStore {
    var service: String
    var account: String
    var label: String
    /// The background sources' configuration.
    static var backgroundSources: Self { Self(service: BackgroundConfiguration.service, account: "sources", label: "Up Only background sources") }
    /// In the data-protection Keychain, like the vault key, in the app's default access group (the first of its
    /// keychain-access-groups), on this Mac only. Readable from the Mac's first unlock, so refreshes run while the vault is locked.
    var item: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: kCFBooleanFalse as Any, kSecUseDataProtectionKeychain as String: true]
    }
    /// The login keychain's item with the same service and account.
    var legacyItem: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecUseDataProtectionKeychain as String: false]
    }
    /// A new item's attributes: the item, its label and its protection class.
    func addition(_ data: Data) -> [String: Any] {
        var add = item
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = label
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return add
    }
    func read(legacy: Bool) throws -> Data? {
        var query = legacy ? legacyItem : item
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw ImportFailure(label + " can’t be read from the Keychain now.") }
        return data
    }
    func save(_ data: Data) throws {
        let status = SecItemUpdate(item as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(addition(data) as CFDictionary, nil) == errSecSuccess else { throw ImportFailure(label + " could not be saved.") }
        } else if status != errSecSuccess { throw ImportFailure(label + " could not be updated.") }
    }
    func delete() throws {
        let status = SecItemDelete(item as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ImportFailure(label + " could not be deleted.") }
    }
    func deleteLegacy() {
        var query = legacyItem
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        _ = SecItemDelete(query as CFDictionary)
    }
    /// A credential set up outside the app (the Wise and accounting connections), which writes it to the login keychain,
    /// where any process running as you can ask for it. It's moved: saved to the data-protection item, and the login item
    /// deleted only once that's saved. A newly provisioned login item always wins and is moved the same way; with none,
    /// the data-protection item is read. A login item that can't be read now doesn't hide one already moved.
    static func provisioned(from store: KeychainItemStore) throws -> Data? {
        let provisioned: Data?
        do { provisioned = try store.read(legacy: true) }
        catch {
            if let moved = try store.read(legacy: false) { return moved }
            throw error
        }
        guard let provisioned else { return try store.read(legacy: false) }
        if (try? store.save(provisioned)) != nil { store.deleteLegacy() }
        return provisioned
    }
}
extension VaultLayout {
    /// The vault ID in the plain-text header of the vault file, or of its previous copy when that can't be read: only
    /// the header's ID is decoded, no key is needed, and the file is read within the vault's size limit.
    nonisolated func storedVaultID() -> UUID? {
        struct Header: Decodable { var vaultID: UUID }
        for url in [current, previous] {
            if let data = try? BoundedFile.read(url, limit: VaultLimits.maxVaultFileBytes), let header = try? JSONDecoder().decode(Header.self, from: data) { return header.vaultID }
        }
        return nil
    }
}
// In an extension, so the memberwise initializer stays.
extension BackgroundConfiguration {
    /// Switches added later are read as off when missing, and a missing file key as none, so a saved configuration from
    /// an earlier build still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vaultID = try c.decode(UUID.self, forKey: .vaultID)
        inboxPublicKey = try c.decode(Data.self, forKey: .inboxPublicKey)
        signingPrivateKey = try c.decode(Data.self, forKey: .signingPrivateKey)
        signingPublicKey = try c.decode(Data.self, forKey: .signingPublicKey)
        crypto = try c.decode([String].self, forKey: .crypto)
        currencies = try c.decode([String].self, forKey: .currencies)
        metals = try c.decode([PreciousMetal].self, forKey: .metals)
        pricesEnabled = try c.decode(Bool.self, forKey: .pricesEnabled)
        fxEnabled = try c.decode(Bool.self, forKey: .fxEnabled)
        metalsEnabled = try c.decode(Bool.self, forKey: .metalsEnabled)
        coinGeckoKey = try c.decode(String.self, forKey: .coinGeckoKey)
        wiseEnabled = try c.decodeIfPresent(Bool.self, forKey: .wiseEnabled) ?? false
        accountingEnabled = try c.decodeIfPresent(Bool.self, forKey: .accountingEnabled) ?? false
        fileKey = try c.decodeIfPresent(Data.self, forKey: .fileKey)
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
        source == "banks" ? 12 * 60 * 60 : ["crypto", "metals", "history", "accounting"].contains(source) ? 60 * 60 : 15 * 60
    }
    nonisolated private struct Record: Codable {
        var vaultID: UUID
        var attemptedAt: Date
        var failed: Bool
        /// Consecutive failures; each doubles the retry delay.
        var failures: Int?
    }
    private func record(vaultID: UUID, files: BackgroundFiles, source: String) -> Record? {
        // A record is a few dozen bytes, sealed (`BackgroundFiles`); anything bigger, not a plain file, or that doesn't
        // open under this file key and source is no record: the worst that does is an early attempt.
        guard let data = try? BoundedFile.read(files.schedule(source), limit: 4096), let opened = try? files.openSchedule(data, source: source),
              var record = try? VaultJSON.decode(Record.self, from: opened), record.vaultID == vaultID else { return nil }
        // Its key sits in the Keychain configuration, readable without the vault: an edited count still mustn't
        // overflow the back-off arithmetic and crash the app.
        record.failures = record.failures.map { min(max($0, 0), 64) }
        return record
    }
    func claim(vaultID: UUID, files: BackgroundFiles, source: String = "banks", now: Date = Date()) throws -> Bool {
        try Task.checkCancellation()
        let last = record(vaultID: vaultID, files: files, source: source)
        if let last, now >= last.attemptedAt {
            // A failure is retried after a twelfth of the interval (five minutes for hourly sources), doubling up to the interval.
            let interval = Self.interval(for: source)
            let wait = last.failed ? min(interval, interval / 12 * Double(1 << min(max((last.failures ?? 1) - 1, 0), 12))) : interval
            if now.timeIntervalSince(last.attemptedAt) < wait { return false }
        }
        try write(Record(vaultID: vaultID, attemptedAt: now, failed: false, failures: last?.failures), files: files, source: source)
        return true
    }
    func finish(vaultID: UUID, files: BackgroundFiles, failed: Bool, source: String = "banks", now: Date = Date()) throws {
        let failures = failed ? (record(vaultID: vaultID, files: files, source: source)?.failures ?? 0) + 1 : nil
        try write(Record(vaultID: vaultID, attemptedAt: now, failed: failed, failures: failures), files: files, source: source)
    }
    private func write(_ record: Record, files: BackgroundFiles, source: String) throws {
        try FileManager.default.createDirectory(at: files.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try DiskFileIO().write(files.sealSchedule(VaultJSON.encode(record), source: source), to: files.schedule(source), sync: false)
    }
    func failed(vaultID: UUID, files: BackgroundFiles, source: String = "banks") -> Bool { record(vaultID: vaultID, files: files, source: source)?.failed == true }
    /// Forgets the last attempt so a changed key, a newly enabled source or an attempt cut short by going offline is tried straight away.
    func reset(vaultID: UUID, files: BackgroundFiles, sources: [String]) {
        for source in sources where record(vaultID: vaultID, files: files, source: source) != nil {
            try? FileManager.default.removeItem(at: files.schedule(source))
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
    /// Saved under the configuration's opaque name (`BackgroundFiles`); one with no file key saves nothing.
    static func save(_ packet: BackgroundPacket, configuration: BackgroundConfiguration, root: URL) throws {
        try Task.checkCancellation()
        guard let files = configuration.files(root: root) else { throw VaultError.unavailable }
        let bytes = try VaultJSON.encode(BackgroundEnvelope.seal(packet, configuration: configuration))
        guard bytes.count <= 8 * 1024 * 1024 else { throw VaultError.oversizedInbox }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try DiskFileIO().write(bytes, to: files.sealed(packet.source), sync: false)
    }
    // File IO, signature verification, decryption and decoding must never run
    // on the UI executor while the newly unlocked menu is trying to appear.
    /// The packets under `files`' names (the saved configuration's: `BackgroundConfiguration.files(for:root:)`). With no
    /// file key nothing is read: they're only a cache, and the next refresh fetches them again.
    static func cachedPackets(document: VaultDocument, files: BackgroundFiles?) -> (packets: [BackgroundPacket], issues: [String]) {
        guard let files else { return ([], []) }
        var packets: [BackgroundPacket] = [], issues: [String] = []
        for source in sources {
            if Task.isCancelled { return ([], []) }
            do {
                // Within the size a packet is saved at, and only a plain file: never through a link or from a pipe.
                let envelope = try VaultJSON.decode(BackgroundEnvelope.self, from: BoundedFile.read(files.sealed(source), limit: 8 * 1024 * 1024))
                let packet = try envelope.open(document: document)
                guard packet.source == source else { throw VaultError.corrupt }
                if packet.fetchedAt > (document.backgroundAppliedAt?[source] ?? .distantPast) { packets.append(packet) }
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile { continue }
            catch { issues.append(source.capitalized + " cached data") }
        }
        return Task.isCancelled ? ([], []) : (packets, issues)
    }
    /// Deletes the background configuration, with the packets and schedule it left, unless it belongs to `vaultID` (nil
    /// when no vault is left): a vault that was started over or replaced by another keeps no sources fetched, and no coin
    /// IDs or keys saved, on this Mac. One that can't be read is deleted too; the next unlock saves it again. Returns
    /// whether it deleted it.
    @discardableResult static func forget(unless vaultID: UUID?, root: URL, keychain: KeychainItemStore = KeychainItem.backgroundSources) -> Bool {
        if let vaultID, (try? BackgroundConfiguration.load(from: keychain))?.vaultID == vaultID { return false }
        try? keychain.delete()
        deleteFiles(root: root)
        return true
    }
    /// Deletes every sealed packet: after a new signing key or vault they could never be opened. Found by listing the
    /// folder, so none is missed whatever key named it, and no configuration is needed.
    static func deleteSealed(root: URL) { delete(root: root, suffix: ".sealed") }
    /// Deletes every sealed packet and schedule record, under any file key or none: after a new file key they'd never be
    /// found again, yet would still count as sources on. It's also how the source-named files earlier builds left
    /// (`Background-crypto.sealed`, `Background-history.schedule`) go, the first time a file key is saved; losing them
    /// only means each source is fetched again straight away.
    static func deleteFiles(root: URL) {
        delete(root: root, suffix: ".sealed"); delete(root: root, suffix: ".schedule")
    }
    private static func delete(root: URL, suffix: String) {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] where name.hasPrefix("Background-") && name.hasSuffix(suffix) {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
        }
    }
    /// Claims the source's slot, fetches and seals its packet, and records the outcome. Returns false if the
    /// source is failing. Going offline or being cancelled isn't a failed attempt: the slot is freed for the reconnect.
    /// A packet saved with a part missing (`incomplete`) counts as failing, so it's retried and reported as a failure is.
    static func scheduled(_ source: String, configuration: BackgroundConfiguration, root: URL, schedule: BackgroundRefreshSchedule = .shared,
                          incomplete: (BackgroundPacket) -> Bool = { _ in false }, fetch: () async throws -> BackgroundPacket) async -> Bool {
        let vaultID = configuration.vaultID
        guard let files = configuration.files(root: root) else { return false }
        do {
            guard try await schedule.claim(vaultID: vaultID, files: files, source: source) else {
                return await !schedule.failed(vaultID: vaultID, files: files, source: source)
            }
        } catch { return false }
        do {
            let packet = try await fetch()
            try save(packet, configuration: configuration, root: root)
            let failed = incomplete(packet)
            try await schedule.finish(vaultID: vaultID, files: files, failed: failed, source: source)
            return !failed
        } catch {
            if PublicPrices.isOffline(error) { await schedule.reset(vaultID: vaultID, files: files, sources: [source]) }
            else { try? await schedule.finish(vaultID: vaultID, files: files, failed: true, source: source) }
            return false
        }
    }
    /// Separate envelopes preserve each source's last success if another fails.
    static func fetch(configuration: BackgroundConfiguration, root: URL) async -> [String] {
        // Saved by an earlier build, with no file key: nothing is fetched until the next unlock adds one, so no file is
        // named after its source again.
        guard configuration.fileKey != nil else { return [] }
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
                #if UPONLY_PERSONAL
                let wiseToken = configuration.wiseEnabled ? (try? WiseConnection.load())?.token : nil
                #else
                let wiseToken: String? = nil
                #endif
                let update = try await PublicPrices.fx(currencies: Set(configuration.currencies)) { try await PublicPrices.rates($0, wiseToken: wiseToken) }
                if !update.rates.isEmpty { try save(BackgroundPacket(source: "fx", fetchedAt: Date(), prices: update), configuration: configuration, root: root) }
                if !update.fxIssues.isEmpty { errors.append("Some exchange rates") }
            } catch { errors.append("Exchange rates") }
        }
        if configuration.metalsEnabled && !configuration.metals.isEmpty {
            let ok = await scheduled("metals", configuration: configuration, root: root) {
                var quotes: [QuoteObservation] = []
                for metal in configuration.metals {
                    try Task.checkCancellation()
                    quotes.append(try await PublicPrices.metalSpot(metal, fetchedAt: Date()))
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
            // Hourly, like prices. A company that couldn't refresh (kept with no fetch time, `AccountingAPI.collect`) is
            // reported only as "Accounting", so no company's name reaches the lock screen; the others' results are saved.
            let ok = await scheduled("accounting", configuration: configuration, root: root, incomplete: { $0.books?.contains { $0.fetchedAt == .distantPast } == true }) {
                let result = try await AccountingAPI.fetchResult(AccountingConnection.load())
                return BackgroundPacket(source: "accounting", fetchedAt: Date(), books: result.books)
            }
            if !ok { errors.append("Accounting") }
        }
        #endif
        return errors
    }
    static func applying(_ packet: BackgroundPacket, to document: VaultDocument, now: Date = Date()) throws -> VaultDocument {
        var next = document
        guard packet.fetchedAt > (document.backgroundAppliedAt?[packet.source] ?? .distantPast) else { return next }
        switch packet.source {
        case "crypto", "fx", "metals":
            let enabled = packet.source == "crypto" ? document.settings.automaticPrices : packet.source == "fx" ? document.settings.automaticFX : document.settings.automaticMetals
            guard enabled, let prices = packet.prices else { return next }
            try validate(packet, now: now)
            next = try PriceHistory.applying(prices, to: next, now: now)
        // Company accounting and bank balances come only from the private build's connections; the public build
        // ignores such a packet.
        #if UPONLY_PERSONAL
        case "accounting":
            try validate(packet, now: now)
            if let books = packet.books {
                next.businessAccounting = AccountingHistory.merging(books, into: document.businessAccounting ?? [])
                OwnerPayments.reconcile(in: &next)
                next.track(.cashFlow)
            }
        case "banks":
            guard document.settings.automaticWise, let banks = packet.banks else { return next }
            try validate(packet, now: now)
            next = try WiseAPI.apply(WiseSnapshot(profiles: banks.map { WiseProfileSnapshot(profile: $0.profile, balances: $0.balances, activities: $0.activities ?? []) }, fetchedAt: packet.fetchedAt), to: next)
        #endif
        default: return next
        }
        var applied = next.backgroundAppliedAt ?? [:]; applied[packet.source] = packet.fetchedAt; next.backgroundAppliedAt = applied
        return next
    }
    /// A sealed packet is checked again as it's applied, as its fetch checked it: the key that signs it sits in the
    /// Keychain configuration, readable without the vault, so nothing in it is taken on trust. Prices and rates must be
    /// positive, asset IDs and currencies well formed, times no earlier than 2009 and no more than five minutes ahead, and
    /// covered ranges within those days. Anything else rejects the whole packet.
    static func validate(_ packet: BackgroundPacket, now: Date) throws {
        let earliest = Date(timeIntervalSince1970: 1_230_768_000), latest = now.addingTimeInterval(300)
        func check(_ time: Date) throws { guard time >= earliest, time <= latest else { throw VaultError.corrupt } }
        try check(packet.fetchedAt)
        if let prices = packet.prices {
            for quote in prices.quotes {
                guard (try? MoneyInput.canonicalAssetID(quote.assetID.rawValue)) == quote.assetID.rawValue else { throw VaultError.corrupt }
                try MoneyInput.requirePositiveFinite(quote.priceUSD.value)
                try check(quote.providerTime); try check(quote.fetchedAt)
            }
            for rate in prices.rates {
                guard (try? MoneyInput.normalizeCurrency(rate.sourceCurrency)) == rate.sourceCurrency, rate.sourceCurrency != "USD", rate.targetCurrency == "USD" else { throw VaultError.corrupt }
                try MoneyInput.requirePositiveFinite(rate.rate.value)
                try check(rate.providerTime); try check(rate.fetchedAt)
            }
            for range in prices.coverage {
                guard range.start < range.end, range.start >= earliest, range.end <= UTCDay.start(of: now).addingTimeInterval(86400) else { throw VaultError.corrupt }
                try check(range.checkedAt)
            }
        }
        // A company that couldn't refresh is kept with no fetch time (`AccountingAPI.collect`).
        for book in packet.books ?? [] {
            guard book.fetchedAt <= latest, MonthKey(book.firstMonth) != nil,
                  book.ownership.allSatisfy({ MonthKey($0.fromMonth) != nil && $0.numerator >= 0 && $0.denominator > 0 && $0.numerator <= $0.denominator }),
                  book.months.allSatisfy({ MonthKey($0.month) != nil && MoneyInput.isFinite($0.profitUSD) && ($0.revenueUSD.map(MoneyInput.isFinite) ?? true) && ($0.expensesUSD.map(MoneyInput.isFinite) ?? true) }) else { throw VaultError.corrupt }
        }
    }
}
