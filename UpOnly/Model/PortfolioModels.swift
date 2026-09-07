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

    var ownerBusinessID: String?
    var assetKind: TrackedKind?
    var kind: TrackedKind { assetKind == .metals ? .metals : .crypto }
    var isArchived: Bool { archivedAt != nil }

    init(id: UUID = UUID(), name: String, createdAt: Date = Date(), archivedAt: Date? = nil, kind: TrackedKind = .crypto, ownerBusinessID: String? = nil) {
        self.ownerBusinessID = ownerBusinessID
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.archivedAt = archivedAt
        self.assetKind = kind == .metals ? .metals : nil
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

// Physical metal quantities use fine grams, never a token that represents gold.
nonisolated enum PreciousMetal: String, Codable, CaseIterable, Sendable {
    case gold = "XAU", silver = "XAG", platinum = "XPT", palladium = "XPD"
    static let selectable: [PreciousMetal] = [.gold, .silver]
    var name: String { switch self { case .gold: "Gold"; case .silver: "Silver"; case .platinum: "Platinum"; case .palladium: "Palladium" } }
    var assetID: CanonicalAssetID { CanonicalAssetID(rawValue: "metal-" + name.lowercased() + "-gram") }
    static let gramsPerTroyOunce = Decimal(string: "31.1034768")!
    static func asset(_ id: CanonicalAssetID) -> PreciousMetal? { allCases.first { $0.assetID == id } }
    static func resolve(_ text: String) throws -> PreciousMetal {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let metal = allCases.first(where: { $0.rawValue.lowercased() == clean || $0.name.lowercased() == clean || $0.assetID.rawValue == clean }) else {
            throw ImportFailure("Choose Gold or Silver. Tokenized gold belongs in Crypto holdings.")
        }
        return metal
    }
}
nonisolated enum MetalWeightUnit: String, CaseIterable, Sendable {
    case grams = "g", troyOunces = "ozt", kilograms = "kg"
    var title: String { switch self { case .grams: "Grams"; case .troyOunces: "Troy ounces"; case .kilograms: "Kilograms" } }
    static func resolve(_ raw: String) throws -> MetalWeightUnit {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "g", "gram", "grams": return .grams
        case "ozt", "troy oz", "troy ounce", "troy ounces": return .troyOunces
        case "kg", "kilogram", "kilograms": return .kilograms
        default: throw ImportFailure("Specify g, kg or ozt (troy ounces). Plain oz is ambiguous.")
        }
    }
    func grams(_ value: Decimal) throws -> Decimal {
        try MoneyInput.requireNonNegativeFinite(value)
        return try MoneyInput.multiply(value, self == .grams ? 1 : self == .kilograms ? 1000 : PreciousMetal.gramsPerTroyOunce)
    }
}
