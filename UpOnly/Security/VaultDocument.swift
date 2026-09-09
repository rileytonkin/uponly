import Foundation
import Security

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

    func holding(id: UUID) -> Holding? {
        holdings.first { $0.id == id }
    }

    func activeHoldings(in portfolioID: UUID, at date: Date) -> [Holding] {
        holdings.filter { $0.portfolioID == portfolioID && $0.isActive(at: date) }
    }

    func effectiveQuantity(holdingID: UUID, at date: Date) -> Decimal? {
        quantities
            .filter { $0.holdingID == holdingID && $0.effectiveAt <= date }
            .sorted(by: QuantityObservation.ordering)
            .last
            .map(\.quantity.value)
    }

    func isBankTracked(_ accountID: UUID, at date: Date) -> Bool {
        let relevant = bankTracking
            .filter { $0.accountID == accountID && $0.effectiveAt <= date }
            .sorted { lhs, rhs in
                if lhs.effectiveAt != rhs.effectiveAt { return lhs.effectiveAt < rhs.effectiveAt }
                return lhs.ordinal < rhs.ordinal
            }
        if let last = relevant.last { return last.tracked }
        if bankTracking.contains(where: { $0.accountID == accountID }) { return false }
        return trackedBankAccountIDs.contains(accountID)
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

    func storedValuation(day: Date, scope: ValuationScope) -> DailyValuation? {
        let start = UTCDay.start(of: day)
        return dailyValuations.last { UTCDay.start(of: $0.utcDay) == start && $0.scope == scope }
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
        var chars = Array(hex)
        guard chars.count.isMultiple(of: 2) else { return nil }
        for i in stride(from: 0, to: chars.count, by: 2) {
            let byte = String(chars[i...i + 1])
            guard let value = UInt8(byte, radix: 16) else { return nil }
            data.append(value)
        }
        return data
    }
}
