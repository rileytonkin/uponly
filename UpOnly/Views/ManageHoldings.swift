import SwiftUI

/// Manage → Crypto and Metals: portfolios, holdings, owners and archived portfolios.
extension UpOnlyManagement {
    func setPortfolioOwner(_ portfolio: Portfolio, owner: String?) {
        Task { await session.perform { doc in
            if let index = doc.portfolios.firstIndex(where: { $0.id == portfolio.id }) { doc.portfolios[index].ownerBusinessID = owner }
        } }
    }
    /// Crypto and Metals share one layout: a card per portfolio, a row per holding.
    func holdings(_ kind: TrackedKind) -> some View {
        let metals = kind == .metals
        let mode: ImportMode = metals ? .metals : .holdings
        let addTitle = metals ? "Add gold or silver" : "Add a coin"
        let now = Date()
        let active = session.document?.portfolios.filter { !$0.isArchived && $0.kind == kind } ?? []
        let canMove = !metals && active.count > 1
        return VStack(alignment: .leading, spacing: 16) {
            // Adding is the + beside the title.
            if active.isEmpty {
                ManageEmptyState(title: metals ? "No gold or silver yet" : "No crypto yet",
                                 detail: metals ? "Add bars or coins by weight to see what they’re worth." : "Add a coin to see what your crypto is worth.",
                                 symbol: kind.symbol, tint: kind.tint, actionTitle: addTitle) { session.startImport(mode) }
            }
            if let doc = session.document {
                ForEach(active) { portfolio in portfolioCard(portfolio, mode: mode, document: doc, now: now, canMove: canMove) }
                if metals {
                    ForEach(PreciousMetal.allCases.filter { metal in doc.holdings.contains { $0.assetID == metal.assetID && $0.isActive(at: now) && doc.portfolio(id: $0.portfolioID)?.isActive(at: now) == true } }, id: \.self) { metal in
                        DisclosureGroup(metal.name + " price history") {
                            UpOnlyMetalHistory(metal: metal, document: doc).padding(.top, 8)
                        }.font(UpOnlyType.body.weight(.medium))
                    }
                }
            }
            archivedPortfolios(kind)
        }
    }
    /// A portfolio: its name and options above one card of its holdings, as the dashboard lists them.
    func portfolioCard(_ portfolio: Portfolio, mode: ImportMode, document doc: VaultDocument, now: Date, canMove: Bool) -> some View {
        let holdings = doc.activeHoldings(in: portfolio.id, at: now)
        // One valuation per portfolio; each row reads its own value from it.
        let values = NetWorthCalculator.value(at: now, scope: .portfolio(portfolio.id), document: doc).components
        let addTitle = mode == .metals ? "Add gold or silver" : "Add a coin"
        let owner = portfolio.ownerBusinessID?.nilIfEmpty.flatMap { id in doc.businessAccounting?.first { $0.id == id }?.name }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(portfolio.name + (owner.map { " · " + $0 } ?? "")).font(UpOnlyType.section).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                ManageRowMenu(label: "More options for " + portfolio.name) {
                    Button(addTitle + "…") { session.startImport(mode, portfolioID: portfolio.id) }
                    if holdings.count > 1 { Button(mode == .metals ? "Update all weights…" : "Update all holdings…") { session.startImport(mode, prefill: true, portfolioID: portfolio.id) } }
                    Button("Rename…") { editor = .renamePortfolio(portfolio) }
                    ownerMenu(current: portfolio.ownerBusinessID?.nilIfEmpty) { setPortfolioOwner(portfolio, owner: $0) }
                    Divider()
                    Button("Archive portfolio…", role: .destructive) { archive = portfolio }
                }
            }
            ManageCard {
                if holdings.isEmpty {
                    ManageRow(title: addTitle, caption: "Nothing in this portfolio yet", action: { session.startImport(mode, portfolioID: portfolio.id) }) {
                        UpOnlySymbolBadge(symbol: "plus", tint: .accentColor, size: 24)
                    } menu: { EmptyView() }
                }
                ForEach(Array(holdings.enumerated()), id: \.element.id) { index, holding in
                    holdingRow(holding, mode: mode, value: values.first { $0.id == holding.id }?.usdValue?.value, document: doc, now: now, canMove: canMove, divided: index > 0)
                }
            }
        }
    }
    /// A holding: its logo, name, quantity and what's known of its cost, and its value. The row updates it.
    func holdingRow(_ holding: Holding, mode: ImportMode, value: Decimal?, document doc: VaultDocument, now: Date, canMove: Bool, divided: Bool) -> some View {
        let quantity = ManageFormat.amount(doc.effectiveQuantity(holdingID: holding.id, at: now) ?? 0, of: holding, catalog: session.catalog)
        let performance = UpOnlyFormat.performance(HoldingPerformance.summary(holdingID: holding.id, valueUSD: value, document: doc), metal: mode == .metals)
        return ManageRow(title: holding.assetName, caption: [quantity, performance].compactMap { $0 }.joined(separator: " · "), captionIsPrivate: true,
                         value: value.map(UpOnlyFormat.exactMoney) ?? "Price needed", divided: divided,
                         action: { session.startImport(mode, prefill: true, holdingID: holding.id) }) {
            UpOnlyAssetBadge(assetID: holding.assetID.rawValue, symbol: quantity.split(separator: " ").last.map(String.init) ?? holding.assetName, size: 24)
        } menu: {
            ManageRowMenu(label: "More options for " + holding.assetName) {
                Button(mode == .metals ? "Update weight…" : "Update quantity…") { session.startImport(mode, prefill: true, holdingID: holding.id) }
                Button("Purchases…") { editor = .purchases(holding) }
                if canMove { Button("Move coins…") { editor = .move(holding) } }
            }
        }
    }
    /// Archived portfolios stay out of net worth and the list above until restored.
    @ViewBuilder func archivedPortfolios(_ kind: TrackedKind) -> some View {
        let all = session.document?.portfolios ?? []
        let archived = all.filter { $0.isArchived && $0.kind == kind }
        if !archived.isEmpty {
            DisclosureGroup("Archived (\(archived.count))") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(archived) { portfolio in
                        // Active names are unique per owner, so a portfolio now using this name has to be renamed first.
                        let owner = portfolio.ownerBusinessID?.nilIfEmpty
                        let clash = all.contains { !$0.isArchived && $0.ownerBusinessID?.nilIfEmpty == owner && $0.name.caseInsensitiveCompare(portfolio.name) == .orderedSame }
                        let archivedOn = portfolio.archivedAt.map { $0.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: UTCDay.timeZone)) } ?? ""
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(portfolio.name).font(UpOnlyType.row)
                                Text(clash ? "Rename the other “\(portfolio.name)” to restore this one." : "Archived \(archivedOn)")
                                    .font(UpOnlyType.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Button("Restore") { restore(portfolio) }.controlSize(.small).disabled(clash).accessibilityLabel("Restore " + portfolio.name)
                        }.padding(.vertical, 6)
                    }
                }.padding(.top, 6)
            }.font(UpOnlyType.body)
        }
    }
    func restore(_ portfolio: Portfolio) {
        Task { await session.perform { doc in
            if let index = doc.portfolios.firstIndex(where: { $0.id == portfolio.id }) { doc.portfolios[index].archivedAt = nil }
        } }
    }
}
