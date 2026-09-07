import Foundation

nonisolated enum VaultSchema {
    static let document = 1
    static let envelope = 1
    static let persistedFile = 1
    static let recoveryWrapper = 1
    static let backupPackage = 1
}

nonisolated enum VaultLimits {
    static let maxBatchBytes = 8 * 1024 * 1024
    static let maxPendingInboxBytes = 100 * 1024 * 1024
    static let maxObservationSkew: TimeInterval = 5 * 60
    static let quoteStaleAfter: TimeInterval = 60 * 60
    static let fxStaleAfter: TimeInterval = 4 * 24 * 60 * 60
    static let maxVaultFileBytes = 128 * 1024 * 1024
    static let maxBackupBytes = 384 * 1024 * 1024
    static let maxManifestBytes = 1024 * 1024
    static let bankStaleAfter: TimeInterval = 36 * 60 * 60
}

nonisolated enum SignerRole: String, Codable, Sendable, Equatable {
    case businessBridge
    case personalCollector
}

nonisolated enum CollectionSource: String, Codable, Sendable, Equatable {
    case business
    case bank
    case quote
    case fx
}

nonisolated enum VaultError: LocalizedError, Equatable, Sendable {
    case cancelled
    case locked
    case alreadyOpen
    case alreadyExists
    case notFound
    case needsRecovery
    case keychainUnavailable(Int32)
    case corrupt
    case wrongKey
    case wrongRecoveryCode
    case staleGeneration
    case staleSession
    case invalidGeneration
    case barrierHeld
    case diskWriteFailed
    case missingRecoveryWrapper
    case inboxNotCommitted
    case oversizedVault
    case oversizedBatch
    case oversizedInbox
    case malformedEnvelope
    case invalidSignature
    case wrongVault
    case unknownSchema
    case unauthorizedRole
    case staleSequence
    case observationInFuture
    case invalidAmount
    case invalidCurrency
    case invalidAssetID
    case insufficientQuantity
    case samePortfolio
    case unknownHolding
    case unknownPortfolio
    case confirmationMismatch
    case backupIncoherent
    case pauseFailed
    case malformedLegacy
    case verificationFailed
    case cleanupFailed
    case formatNotActive
    case unsafeFilename
    case unavailable
    case overflow
    var errorDescription: String? {
        switch self {
        case .cancelled: "The action was cancelled."
        case .locked, .staleSession: "Up is locked. Unlock it, then try again."
        case .invalidAmount, .overflow: "Enter a valid amount within the supported range."
        case .invalidCurrency: "Enter a three-letter currency code, such as USD or GBP."
        case .invalidAssetID: "Choose a coin from search or enter its exact CoinGecko ID."
        case .observationInFuture: "Choose today or an earlier date."
        case .insufficientQuantity: "You can’t move more than the quantity you hold."
        case .samePortfolio: "Choose a different destination portfolio."
        case .unknownHolding, .unknownPortfolio: "This holding or portfolio is no longer available. Choose an active one."
        case .alreadyExists: "A vault already exists here. Unlock it to continue."
        case .notFound: "The file could not be found. Choose it again."
        case .wrongRecoveryCode, .confirmationMismatch: "The recovery code doesn’t match. Check every group and try again."
        case .needsRecovery, .keychainUnavailable, .wrongKey: "Your vault could not be unlocked. Try your Mac password or saved recovery code."
        case .diskWriteFailed: "The change couldn’t be saved. Check available disk space and try again."
        case .oversizedVault: "Your vault has reached its 128 MB limit. Export a backup from Security; new imports cannot be saved."
        case .oversizedBatch, .oversizedInbox: "This import is too large. Split it into smaller files and try again."
        case .unknownSchema, .formatNotActive: "This file needs a compatible version of Up Only. Check for an app update."
        case .staleGeneration, .invalidGeneration, .alreadyOpen, .barrierHeld, .pauseFailed: "Another change is still finishing. Wait a moment, then try again."
        case .missingRecoveryWrapper: "This backup is missing recovery information. Choose another backup."
        case .corrupt, .backupIncoherent, .malformedEnvelope, .invalidSignature, .wrongVault, .unauthorizedRole, .staleSequence, .malformedLegacy, .verificationFailed, .unsafeFilename: "This file could not be verified. Choose an original, unmodified Up Only file."
        case .inboxNotCommitted, .cleanupFailed, .unavailable: "The action couldn’t finish. Your last saved data is unchanged; try again."
        }
    }

}

nonisolated enum ValuationScope: Codable, Hashable, Sendable, Equatable {
    case allTracked
    case banks
    case portfolio(UUID)
}

nonisolated enum UTCDay {
    static let timeZone = TimeZone(secondsFromGMT: 0)!

    static func start(of date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.startOfDay(for: date)
    }

    static func isSameDay(_ lhs: Date, _ rhs: Date) -> Bool {
        start(of: lhs) == start(of: rhs)
    }
}

nonisolated enum MoneyInput {
    static func isFinite(_ value: Decimal) -> Bool {
        !value.isNaN
    }

    static func requireFinite(_ value: Decimal) throws {
        guard isFinite(value) else { throw VaultError.invalidAmount }
    }

    static func requirePositiveFinite(_ value: Decimal) throws {
        try requireFinite(value)
        guard value > 0 else { throw VaultError.invalidAmount }
    }

    static func requireNonNegativeFinite(_ value: Decimal) throws {
        try requireFinite(value)
        guard value >= 0 else { throw VaultError.invalidAmount }
    }

    static func parseExact(_ text: String) throws -> Decimal {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 160 else { throw VaultError.invalidAmount }
        let allowed = CharacterSet(charactersIn: "0123456789.-")
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw VaultError.invalidAmount
        }
        guard trimmed.filter({ $0 == "." }).count <= 1,
              trimmed.filter({ $0 == "-" }).count <= 1,
              !trimmed.hasPrefix("."),
              trimmed != "-",
              trimmed != "-." else {
            throw VaultError.invalidAmount
        }
        if let minus = trimmed.firstIndex(of: "-"), minus != trimmed.startIndex {
            throw VaultError.invalidAmount
        }
        guard let parsed = Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX")),
              isFinite(parsed) else {
            throw VaultError.invalidAmount
        }
        func normalized(_ raw: String) -> String {
            let negative = raw.hasPrefix("-")
            let parts = raw.drop(while: { $0 == "-" }).split(separator: ".", omittingEmptySubsequences: false)
            let whole = String(parts[0].drop(while: { $0 == "0" }))
            let fraction = parts.count > 1 ? String(parts[1].reversed().drop(while: { $0 == "0" }).reversed()) : ""
            let result = (whole.isEmpty ? "0" : whole) + (fraction.isEmpty ? "" : "." + fraction)
            return negative && result != "0" ? "-" + result : result
        }
        guard normalized(NSDecimalNumber(decimal: parsed).stringValue) == normalized(trimmed) else { throw VaultError.invalidAmount }
        return parsed
    }

    static func add(_ lhs: Decimal, _ rhs: Decimal) throws -> Decimal {
        var a = lhs, b = rhs, result = Decimal()
        let status = NSDecimalAdd(&result, &a, &b, .plain)
        guard status == .noError, isFinite(result) else { throw VaultError.overflow }
        return result
    }

    static func multiply(_ lhs: Decimal, _ rhs: Decimal) throws -> Decimal {
        var a = lhs, b = rhs, result = Decimal()
        let status = NSDecimalMultiply(&result, &a, &b, .plain)
        guard status == .noError, isFinite(result) else { throw VaultError.overflow }
        return result
    }

    static func normalizeCurrency(_ raw: String) throws -> String {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.count == 3,
              code.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ").contains($0) }),
              Locale.commonISOCurrencyCodes.contains(code) else {
            throw VaultError.invalidCurrency
        }
        return code
    }

    static func canonicalAssetID(_ raw: String) throws -> String {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !id.isEmpty, id.count <= 150,
              id.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-").contains($0) }) else {
            throw VaultError.invalidAssetID
        }
        return id
    }
}

nonisolated struct PreciseDecimal: Codable, Sendable, Hashable, Comparable {
    var value: Decimal

    init(_ value: Decimal) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            do {
                value = try MoneyInput.parseExact(text)
            } catch {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an exact decimal")
            }
            return
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Decimal must be a string")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(NSDecimalNumber(decimal: value).stringValue)
    }

    static func < (lhs: PreciseDecimal, rhs: PreciseDecimal) -> Bool {
        lhs.value < rhs.value
    }
}

nonisolated enum SafeFileName {
    static func require(_ name: String) throws -> String {
        guard !name.isEmpty, name != ".", name != ".." else { throw VaultError.unsafeFilename }
        guard name == (name as NSString).lastPathComponent else { throw VaultError.unsafeFilename }
        guard !name.contains("/"), !name.contains("\\"), !name.contains("\0") else {
            throw VaultError.unsafeFilename
        }
        guard !name.contains(":") else { throw VaultError.unsafeFilename }
        return name
    }

    static func requireUnique(_ names: [String]) throws -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for name in names {
            let safe = try require(name)
            guard seen.insert(safe).inserted else { throw VaultError.unsafeFilename }
            result.append(safe)
        }
        return result
    }
}

// JSON strategies are Sendable. Each coder owns these formatters, and locking
// also makes explicit reuse of one coder across tasks safe for date conversion.
nonisolated private final class VaultTimestampFormatter: @unchecked Sendable {
    private let lock = NSLock()
    private let formatter = ISO8601DateFormatter()
    init(fractional: Bool) {
        formatter.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
    }
    func string(from date: Date) -> String {
        lock.lock(); defer { lock.unlock() }
        return formatter.string(from: date)
    }
    func date(from text: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return formatter.date(from: text)
    }
}

nonisolated enum VaultJSON {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Keep the existing signed/serialized representation, but construct its
        // formatter once per encoding operation, not once per saved date.
        let formatter = VaultTimestampFormatter(fractional: true)
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        let fractional = VaultTimestampFormatter(fractional: true)
        let fallback = VaultTimestampFormatter(fractional: false)
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            // Our encoder writes UTC timestamps with exactly three fractional
            // digits. Foundation's value-type parser avoids ICU formatter setup
            // and parsing overhead for this common path. Normalize via Unix
            // milliseconds to match ISO8601DateFormatter's Date representation.
            if text.utf8.count == 24, text.hasSuffix("Z"),
               let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) {
                return Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
            }
            if let date = fractional.date(from: text) { return date }
            if let date = fallback.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Not an ISO-8601 timestamp: \(text)"
            )
        }
        return decoder
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder().encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder().decode(type, from: data)
    }
}
