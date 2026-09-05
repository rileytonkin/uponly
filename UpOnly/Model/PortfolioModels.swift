import Foundation

nonisolated struct CanonicalAssetID: Codable, Hashable, Sendable, RawRepresentable {
    var rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(_ raw: String) throws {
        self.rawValue = try MoneyInput.canonicalAssetID(raw)
    }
}

nonisolated struct Portfolio: Codable, Identifiable, Sendable, Equatable {
    var id: UUID
    var name: String
    var createdAt: Date
    var archivedAt: Date?

    var isArchived: Bool { archivedAt != nil }

    init(id: UUID = UUID(), name: String, createdAt: Date = Date(), archivedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.archivedAt = archivedAt
    }

    func isActive(at date: Date) -> Bool {
        guard date >= createdAt else { return false }
        if let archivedAt { return date < archivedAt }
        return true
    }
}

nonisolated struct Holding: Codable, Identifiable, Sendable, Equatable {
    var id: UUID
    var portfolioID: UUID
    var assetID: CanonicalAssetID
    var assetName: String
    var createdAt: Date
    var archivedAt: Date?

    init(
        id: UUID = UUID(),
        portfolioID: UUID,
        assetID: CanonicalAssetID,
        assetName: String,
        createdAt: Date = Date(),
        archivedAt: Date? = nil
    ) {
        self.id = id
        self.portfolioID = portfolioID
        self.assetID = assetID
        self.assetName = assetName
        self.createdAt = createdAt
        self.archivedAt = archivedAt
    }

    func isActive(at date: Date) -> Bool {
        guard date >= createdAt else { return false }
        if let archivedAt { return date < archivedAt }
        return true
    }
}

nonisolated struct QuantityObservation: Codable, Sendable, Equatable {
    var holdingID: UUID
    var quantity: PreciseDecimal
    var effectiveAt: Date
    var recordedAt: Date
    var ordinal: UInt64
    var signerID: UUID?
    var sequence: UInt64?

    static func ordering(_ lhs: QuantityObservation, _ rhs: QuantityObservation) -> Bool {
        if lhs.effectiveAt != rhs.effectiveAt { return lhs.effectiveAt < rhs.effectiveAt }
        if lhs.ordinal != rhs.ordinal { return lhs.ordinal < rhs.ordinal }
        return lhs.recordedAt < rhs.recordedAt
    }
}

nonisolated struct BankTrackingObservation: Codable, Sendable, Equatable {
    var accountID: UUID
    var tracked: Bool
    var effectiveAt: Date
    var ordinal: UInt64
}

nonisolated struct BankBalanceObservation: Codable, Identifiable, Sendable, Equatable {
    var id: UUID
    var accountID: UUID
    var amount: PreciseDecimal
    var currency: String
    var observedAt: Date
    var source: String
    var sourceIdentity: String
    var signerID: UUID?
    var sequence: UInt64?
    var originalBytes: Data?
}

nonisolated struct QuoteObservation: Codable, Sendable, Equatable {
    var assetID: CanonicalAssetID
    var priceUSD: PreciseDecimal
    var providerTime: Date
    var fetchedAt: Date
    var provider: String
    var signerID: UUID?
    var sequence: UInt64?
}

nonisolated struct FXObservation: Codable, Sendable, Equatable {
    var sourceCurrency: String
    var targetCurrency: String
    var rate: PreciseDecimal
    var providerTime: Date
    var fetchedAt: Date
    var provider: String
    var signerID: UUID?
    var sequence: UInt64?
}

nonisolated struct DailyValuation: Codable, Sendable, Equatable {
    var utcDay: Date
    var scope: ValuationScope
    var total: PreciseDecimal?
    var isComplete: Bool
    var components: [ValuationComponent]
    var computedAt: Date
    var includedAccountIDs: [UUID]
    var includedPortfolioIDs: [UUID]
}

nonisolated struct ValuationComponent: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case bank
        case holding
    }

    var id: UUID
    var kind: Kind
    var label: String
    var currency: String
    var nativeAmount: PreciseDecimal?
    var usdValue: PreciseDecimal?
    var quoteTime: Date?
    var fxTime: Date?
    var isStale: Bool
    var missing: String?
}

nonisolated struct SignerHighWater: Codable, Sendable, Equatable, Hashable {
    var source: CollectionSource
    var accountIdentity: String
    var sequence: UInt64
}

nonisolated struct TrustedSigner: Codable, Identifiable, Sendable, Equatable {
    var id: UUID
    var publicKeyX963: Data
    var role: SignerRole
    var highWater: [SignerHighWater]

    func sequence(for source: CollectionSource, accountIdentity: String) -> UInt64 {
        highWater.first { $0.source == source && $0.accountIdentity == accountIdentity }?.sequence ?? 0
    }

    mutating func raiseHighWater(source: CollectionSource, accountIdentity: String, sequence: UInt64) {
        if let index = highWater.firstIndex(where: { $0.source == source && $0.accountIdentity == accountIdentity }) {
            if sequence > highWater[index].sequence {
                highWater[index].sequence = sequence
            }
        } else {
            highWater.append(
                SignerHighWater(source: source, accountIdentity: accountIdentity, sequence: sequence)
            )
        }
    }
}

nonisolated enum BalanceChangeKind: String, Sendable {
    case change
}
