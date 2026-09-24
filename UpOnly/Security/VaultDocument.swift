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

    func signer(id: UUID) -> TrustedSigner? {
        trustedSigners.first { $0.id == id }
    }

    mutating func replaceSigner(_ signer: TrustedSigner) {
        if let index = trustedSigners.firstIndex(where: { $0.id == signer.id }) {
            trustedSigners[index] = signer
        } else {
            trustedSigners.append(signer)
        }
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

    /// Every scope a daily value is stored for.
    var valuationScopes: [ValuationScope] { [.allTracked, .banks] + portfolios.map { .portfolio($0.id) } }

    func storedValuation(day: Date, scope: ValuationScope) -> DailyValuation? {
        let start = UTCDay.start(of: day)
        return dailyValuations.last { UTCDay.start(of: $0.utcDay) == start && $0.scope == scope }
    }

    /// Something the user added. Restoring a backup over a vault that has any asks first.
    var hasRecords: Bool { !accounts.isEmpty || !entries.isEmpty || !holdings.isEmpty || !portfolios.isEmpty }
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
}

struct RecoveryWrapperFile: Codable, Sendable {
    var format: Int
    var vaultID: UUID
    var nonce: Data
    var ciphertext: Data
    var tag: Data
}

struct VaultLayout: Sendable, Equatable {
    var root: URL

    var current: URL { root.appendingPathComponent("vault.uponly") }
    var previous: URL { root.appendingPathComponent("vault.uponly.prev") }
    var recovery: URL { root.appendingPathComponent("recovery.wrapper") }
    var lockFile: URL { root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + ".writer.lock") }
    var inbox: URL { root.appendingPathComponent("Inbox", isDirectory: true) }
    var journal: URL { root.appendingPathComponent("cutover.journal") }
    var formatActive: URL { root.appendingPathComponent("encrypted.format") }
    var writerDisabled: URL { root.appendingPathComponent("plaintext-writer.disabled") }
    var backupTemp: URL { root.appendingPathComponent("backup.tmp", isDirectory: true) }

    func ensureDirectories(_ io: VaultFileIO) throws {
        try io.createDirectory(at: root)
        try io.createDirectory(at: inbox)
    }

    /// The folder a vault replaced by a restored backup is moved to, beside it: “Vault (replaced 2026-09-24 1432)”.
    func replacedName(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return root.lastPathComponent + " (replaced " + formatter.string(from: date) + ")"
    }

    /// `replacedName`, numbered when a folder of that name already exists.
    func replacedRoot(at date: Date, io: VaultFileIO) -> URL {
        let parent = root.deletingLastPathComponent(), name = replacedName(at: date)
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
