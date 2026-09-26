import Foundation
import Security

nonisolated struct PendingHistoryRebuild: Codable, Sendable, Equatable {
    var from: Date
    var cursor: Date
}
struct VaultDocument: Codable, Sendable, Equatable {
    var schema: Int
    var vaultID: UUID
    var generation: UInt64
    var createdAt: Date
    var entries: [Entry]
    var accounts: [Account]
    var dormant: [DormantMark]
    var trackedBankAccountIDs: [UUID]
    var portfolios: [Portfolio]
    var holdings: [Holding]
    var quantities: [QuantityObservation]
    var bankBalances: [BankBalanceObservation]
    var quotes: [QuoteObservation]
    var fx: [FXObservation]
    var dailyValuations: [DailyValuation]
    /// Left from the retired signed inbox and no longer used; kept so older vaults still decode.
    var acceptedBatchIDs: [UUID]
    var trustedSigners: [TrustedSigner]
    var inboxPrivateKeyX963: Data
    var inboxPublicKeyX963: Data
    var statementArchive: Data?
    var nextOrdinal: UInt64
    var bankTracking: [BankTrackingObservation]
    var settings: AppSettings = AppSettings()
    var importedStatements: [ImportedStatement] = []
    var reviewedMonths: [String] = []
    var priceHistoryCoverage: [PriceHistoryCoverage]?
    var businessAccounting: [BusinessBook]?
    var backgroundSignerPublicKey: Data?
    var backgroundAppliedAt: [String: Date]?
    var purchases: [PurchaseLot]?
    /// Payees whose personal transactions are always transfers (money moved to your own company or accounts).
    var transferCounterparties: [String]?
    /// A history rebuild still in progress: days from `from` up to `cursor` have yet to be recomputed.
    /// Kept in the vault so a relaunch resumes instead of leaving old days valued without newer assets.
    var pendingHistoryRebuild: PendingHistoryRebuild?
    /// `VaultSchema.revision` of the build that saved it: which fields it knew. Absent from documents saved earlier.
    var writerRevision: Int?

    static func empty(
        vaultID: UUID = UUID(),
        createdAt: Date = Date(),
        inboxPrivateKeyX963: Data,
        inboxPublicKeyX963: Data
    ) -> VaultDocument {
        VaultDocument(
            schema: VaultSchema.document,
            vaultID: vaultID,
            generation: 1,
            createdAt: createdAt,
            entries: [],
            accounts: [],
            dormant: [],
            trackedBankAccountIDs: [],
            portfolios: [],
            holdings: [],
            quantities: [],
            bankBalances: [],
            quotes: [],
            fx: [],
            dailyValuations: [],
            acceptedBatchIDs: [],
            trustedSigners: [],
            inboxPrivateKeyX963: inboxPrivateKeyX963,
            inboxPublicKeyX963: inboxPublicKeyX963,
            statementArchive: nil,
            nextOrdinal: 1,
            bankTracking: []
        )
    }

    func portfolio(id: UUID) -> Portfolio? {
        portfolios.first { $0.id == id }
    }

    func activeHoldings(in portfolioID: UUID, at date: Date) -> [Holding] {
        holdings.filter { $0.portfolioID == portfolioID && $0.isActive(at: date) }
    }

    func effectiveQuantity(holdingID: UUID, at date: Date) -> Decimal? {
        quantities.lazy
            .filter { $0.holdingID == holdingID && $0.effectiveAt <= date }
            .latest(by: QuantityObservation.ordering)
            .map(\.quantity.value)
    }

    func isBankTracked(_ accountID: UUID, at date: Date) -> Bool {
        if let last = bankTracking.lazy.filter({ $0.accountID == accountID && $0.effectiveAt <= date })
            .latest(by: { ($0.effectiveAt, $0.ordinal) < ($1.effectiveAt, $1.ordinal) }) { return last.tracked }
        if bankTracking.contains(where: { $0.accountID == accountID }) { return false }
        return trackedBankAccountIDs.contains(accountID)
    }

    /// Tracking starts at an account's first observation, so a balance dated before its first tracked day
    /// moves that start back, unless the account was explicitly left out in between. Returns whether it moved.
    @discardableResult mutating func backdateBankTracking(_ accountID: UUID, to date: Date) -> Bool {
        guard !isBankTracked(accountID, at: date),
              let first = bankTracking.lazy.filter({ $0.accountID == accountID && $0.tracked }).min(by: { $0.effectiveAt < $1.effectiveAt }),
              date < first.effectiveAt,
              !bankTracking.contains(where: { $0.accountID == accountID && !$0.tracked && $0.effectiveAt >= date && $0.effectiveAt <= first.effectiveAt })
        else { return false }
        setBankTracked(accountID, tracked: true, at: date)
        return true
    }

    mutating func setBankTracked(_ accountID: UUID, tracked: Bool, at date: Date) {
        let ordinal = nextOrdinal
        nextOrdinal += 1
        bankTracking.append(
            BankTrackingObservation(accountID: accountID, tracked: tracked, effectiveAt: date, ordinal: ordinal)
        )
        if tracked {
            if !trackedBankAccountIDs.contains(accountID) { trackedBankAccountIDs.append(accountID) }
        } else {
            trackedBankAccountIDs.removeAll { $0 == accountID }
        }
    }

    /// Every scope a daily value is stored for. Bank balances alone aren't shown anywhere, so they aren't stored.
    var valuationScopes: [ValuationScope] { [.allTracked] + portfolios.map { .portfolio($0.id) } }
    /// Drops saved daily values for scopes no longer stored (bank balances alone, from older versions). They are
    /// derived, never shown, and roughly doubled the vault's history; the next rebuild or price update clears them.
    mutating func dropUnstoredValuations() {
        if dailyValuations.contains(where: { $0.scope == .banks }) { dailyValuations.removeAll { $0.scope == .banks } }
    }

    func storedValuation(day: Date, scope: ValuationScope) -> DailyValuation? {
        let start = UTCDay.start(of: day)
        return dailyValuations.last { UTCDay.start(of: $0.utcDay) == start && $0.scope == scope }
    }

    /// Something the user added. Restoring a backup over a vault that has any asks first.
    var hasRecords: Bool { !accounts.isEmpty || !entries.isEmpty || !holdings.isEmpty || !portfolios.isEmpty }
}

// In an extension, so the memberwise initializer stays.
extension VaultDocument {
    /// Written out so a field added later can't make earlier vaults unreadable: every field with a default is optional
    /// on the way in. Encoding stays synthesized, so saved bytes don't change. A new stored property must be read here
    /// too, or the next save would drop it; a test counts them.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(Int.self, forKey: .schema)
        vaultID = try c.decode(UUID.self, forKey: .vaultID)
        generation = try c.decode(UInt64.self, forKey: .generation)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        entries = try c.decode([Entry].self, forKey: .entries)
        accounts = try c.decode([Account].self, forKey: .accounts)
        dormant = try c.decode([DormantMark].self, forKey: .dormant)
        trackedBankAccountIDs = try c.decode([UUID].self, forKey: .trackedBankAccountIDs)
        portfolios = try c.decode([Portfolio].self, forKey: .portfolios)
        holdings = try c.decode([Holding].self, forKey: .holdings)
        quantities = try c.decode([QuantityObservation].self, forKey: .quantities)
        bankBalances = try c.decode([BankBalanceObservation].self, forKey: .bankBalances)
        quotes = try c.decode([QuoteObservation].self, forKey: .quotes)
        fx = try c.decode([FXObservation].self, forKey: .fx)
        dailyValuations = try c.decode([DailyValuation].self, forKey: .dailyValuations)
        acceptedBatchIDs = try c.decode([UUID].self, forKey: .acceptedBatchIDs)
        trustedSigners = try c.decode([TrustedSigner].self, forKey: .trustedSigners)
        inboxPrivateKeyX963 = try c.decode(Data.self, forKey: .inboxPrivateKeyX963)
        inboxPublicKeyX963 = try c.decode(Data.self, forKey: .inboxPublicKeyX963)
        statementArchive = try c.decodeIfPresent(Data.self, forKey: .statementArchive)
        nextOrdinal = try c.decode(UInt64.self, forKey: .nextOrdinal)
        bankTracking = try c.decode([BankTrackingObservation].self, forKey: .bankTracking)
        settings = try c.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
        importedStatements = try c.decodeIfPresent([ImportedStatement].self, forKey: .importedStatements) ?? []
        reviewedMonths = try c.decodeIfPresent([String].self, forKey: .reviewedMonths) ?? []
        priceHistoryCoverage = try c.decodeIfPresent([PriceHistoryCoverage].self, forKey: .priceHistoryCoverage)
        businessAccounting = try c.decodeIfPresent([BusinessBook].self, forKey: .businessAccounting)
        backgroundSignerPublicKey = try c.decodeIfPresent(Data.self, forKey: .backgroundSignerPublicKey)
        backgroundAppliedAt = try c.decodeIfPresent([String: Date].self, forKey: .backgroundAppliedAt)
        purchases = try c.decodeIfPresent([PurchaseLot].self, forKey: .purchases)
        transferCounterparties = try c.decodeIfPresent([String].self, forKey: .transferCounterparties)
        pendingHistoryRebuild = try c.decodeIfPresent(PendingHistoryRebuild.self, forKey: .pendingHistoryRebuild)
        writerRevision = try c.decodeIfPresent(Int.self, forKey: .writerRevision)
    }
}

struct VaultSession: Sendable {
    let sessionID: UUID
    let document: VaultDocument
    let fenceTicket: UInt64
}

struct PersistedVaultFile: Codable, Sendable {
    var format: Int
    var vaultID: UUID
    var generation: UInt64
    var nonce: Data
    var ciphertext: Data
    var tag: Data
    /// The document schema in plain text, written only above 1 so schema-1 files stay byte-for-byte as before (and
    /// earlier builds ignore it). A build that raises the schema must write it, so older builds that read it refuse the
    /// file as newer instead of treating it as damage and reopening the previous copy.
    var schema: Int? = nil
}

struct RecoveryWrapperFile: Codable, Sendable {
    var format: Int
    var vaultID: UUID
    var nonce: Data
    var ciphertext: Data
    var tag: Data
    /// `VaultCrypto.keyID` of the key inside, set by a recovery-code change so an unlock can tell whether a waiting
    /// wrapper belongs to the key it has. Earlier wrappers have none, and earlier builds ignore it.
    var keyID: Data? = nil
}

struct VaultLayout: Sendable, Equatable {
    var root: URL

    var current: URL { root.appendingPathComponent("vault.uponly") }
    var previous: URL { root.appendingPathComponent("vault.uponly.prev") }
    var recovery: URL { root.appendingPathComponent("recovery.wrapper") }
    /// The new code's wrapper while a recovery-code change finishes (`VaultStore.rotateRecovery`).
    var pendingRecovery: URL { root.appendingPathComponent("recovery.wrapper.next") }
    var lockFile: URL { root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + ".writer.lock") }
    var inbox: URL { root.appendingPathComponent("Inbox", isDirectory: true) }
    /// Beside the folder while a restore replaces it (`VaultStore.replace`), naming where the vault was moved.
    var restoreJournal: URL { root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + ".restore.journal") }

    func ensureDirectories(_ io: VaultFileIO) throws {
        try io.createDirectory(at: root)
        try io.createDirectory(at: inbox)
    }

    /// Any of a vault's own files means a vault is here, even without its main file: it must never look like a fresh start.
    /// So does a restore that stopped partway, which may have left the vault in the folder beside this one.
    func holdsVault(_ io: VaultFileIO) -> Bool {
        [current, previous, recovery, pendingRecovery, restoreJournal].contains { io.fileExists(at: $0) }
    }

    /// Whether the folder holds its recovery wrapper and provably no vault data: nothing else but an empty Inbox, Finder's
    /// `.DS_Store` and a half-written wrapper. It's what setup leaves if it stops between saving the wrapper and the vault.
    func holdsOnlyWrapper(_ io: VaultFileIO) -> Bool {
        guard io.fileExists(at: recovery), !io.fileExists(at: restoreJournal),
              let names = try? io.contentsOfDirectory(at: root).map(\.lastPathComponent) else { return false }
        // `DiskFileIO.write` names its temporary file "." + name + "." + a UUID.
        let wrapperTemp = "." + recovery.lastPathComponent + "."
        return names.allSatisfy { name in
            name == recovery.lastPathComponent || name == ".DS_Store"
                || (name.hasPrefix(wrapperTemp) && UUID(uuidString: String(name.dropFirst(wrapperTemp.count))) != nil)
                || (name == inbox.lastPathComponent && inboxIsEmpty(io))
        }
    }

    /// Whether the Inbox holds no pending import: nothing, or only hidden files such as Finder's `.DS_Store`.
    func inboxIsEmpty(_ io: VaultFileIO) -> Bool {
        (try? io.contentsOfDirectory(at: inbox))?.allSatisfy { $0.lastPathComponent.hasPrefix(".") } == true
    }

    /// Where Start over moves a wrapper left without a vault: beside the folder, “Vault recovery.wrapper.unused”,
    /// numbered while earlier ones are still there.
    func unusedWrapper(_ io: VaultFileIO) -> URL {
        let parent = root.deletingLastPathComponent(), name = root.lastPathComponent + " recovery.wrapper.unused"
        var candidate = parent.appendingPathComponent(name), number = 2
        while io.fileExists(at: candidate) {
            candidate = parent.appendingPathComponent(name + " \(number)")
            number += 1
        }
        return candidate
    }

    /// Where a damaged main file is moved aside: `vault.uponly.damaged`, numbered while earlier ones are still there.
    func damagedCopy(_ io: VaultFileIO) -> URL {
        var candidate = root.appendingPathComponent("vault.uponly.damaged"), number = 2
        while io.fileExists(at: candidate) {
            candidate = root.appendingPathComponent("vault.uponly.damaged \(number)")
            number += 1
        }
        return candidate
    }

    /// The folder a vault replaced by a restored backup is moved to, beside it: “Vault (replaced 2026-09-24 1432)”.
    func replacedName(at date: Date) -> String {
        besideName("replaced", at: date)
    }

    /// `replacedName`, numbered when a folder of that name already exists.
    func replacedRoot(at date: Date, io: VaultFileIO) -> URL {
        besideRoot(besideName("replaced", at: date), io: io)
    }

    /// Where a welcome-screen restore moves a folder holding hidden leftovers, such as a crash's temporary file, beside it:
    /// “Vault (set aside 2026-09-24 1432)”, numbered like `replacedRoot`.
    func setAsideRoot(at date: Date, io: VaultFileIO) -> URL {
        besideRoot(besideName("set aside", at: date), io: io)
    }

    private func besideName(_ label: String, at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return root.lastPathComponent + " (" + label + " " + formatter.string(from: date) + ")"
    }

    private func besideRoot(_ name: String, io: VaultFileIO) -> URL {
        let parent = root.deletingLastPathComponent()
        var candidate = parent.appendingPathComponent(name, isDirectory: true), number = 2
        while io.fileExists(at: candidate) {
            candidate = parent.appendingPathComponent(String(name.dropLast()) + " \(number))", isDirectory: true)
            number += 1
        }
        return candidate
    }
}

struct RecoveryCode: Equatable, Sendable {
    let secret: Data

    init(secret: Data) throws {
        guard secret.count == 32 else { throw VaultError.wrongRecoveryCode }
        self.secret = secret
    }

    static func random() -> RecoveryCode {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return try! RecoveryCode(secret: Data(bytes))
    }

    var canonical: String {
        let hex = secret.map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: hex.count, by: 8).map { start in
            let i = hex.index(hex.startIndex, offsetBy: start)
            let j = hex.index(i, offsetBy: 8)
            return String(hex[i..<j])
        }.joined(separator: "-")
    }

    init(canonical: String) throws {
        let stripped = canonical.uppercased().filter { $0.isHexDigit }
        guard stripped.count == 64, let data = Self.hexData(stripped), data.count == 32 else {
            throw VaultError.wrongRecoveryCode
        }
        try self.init(secret: data)
    }

    func matches(_ other: String) -> Bool {
        (try? RecoveryCode(canonical: other))?.secret == secret
    }

    private static func hexData(_ hex: String) -> Data? {
        var data = Data()
        let chars = Array(hex)
        guard chars.count.isMultiple(of: 2) else { return nil }
        for i in stride(from: 0, to: chars.count, by: 2) {
            let byte = String(chars[i...i + 1])
            guard let value = UInt8(byte, radix: 16) else { return nil }
            data.append(value)
        }
        return data
    }
}
