import SwiftUI

/// A bank group or company page: its assets, accounting figures, chart focus and accounts.
extension UpOnlyUnlockedPanel {
    /// `groupID` is "personal" or a company's id.
    func companyContent(_ groupID: String) -> some View {
        let document = session.document
        let interval = selectedInterval
        let raw = document.map { NetWorthCalculator.value(at: interval.end, scope: .allTracked, document: $0) }
        let companyID = groupID == "personal" ? nil : groupID
        let bankValues = (raw?.components ?? []).filter { component in
            guard component.kind == .bank, let document else { return false }
            return (AssetOwnership.businessID(for: component, in: document) ?? "personal") == groupID
        }
        // Personal portfolios already appear on the overview; only a company's own holdings belong here.
        let portfolios = companyID == nil ? [] : document?.portfolios.filter { $0.isActive(at: interval.end) && $0.ownerBusinessID == companyID } ?? []
        let book = model.books.first { $0.id == companyID }
        let ownership = book?.ownership(at: AssetOwnership.month(at: interval.end).description)
        let partOwner = ownership.map { $0.numerator != $0.denominator } ?? false
        // Everything the company holds today: bank accounts plus the holdings in portfolios it owns.
        let holdingValues = companyHoldings(raw?.components ?? [], companyID: companyID)
        let allParts = bankValues + holdingValues
        let focusParts = focusedParts(allParts)
        let focusTotal = focusParts.isEmpty ? nil : AssetOwnership.sum(focusParts)
        let share = document.flatMap { doc in allParts.isEmpty ? nil : AssetOwnership.personalTotal(allParts, at: interval.end, document: doc) }
        let series = companySeries(groupID, interval: interval, live: focusTotal, liveComponents: raw?.components ?? [])
        let focusOptions = companyFocusOptions(bankValues: bankValues, portfolios: portfolios)
        // The same measure as the overview: today's figure against the chart's first, over whatever the page is focused on.
        let change = periodChange(series, now: focusTotal)
        let hasAssetChart = series.contains { $0.value != nil }
        let showProfit = companyChart == .profit && companyID != nil
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                // The title already names the page; the eyebrow only names a focused account or portfolio.
                if let title = companyFocusTitle(focusOptions) {
                    eyebrow(title).frame(minHeight: 22, alignment: .leading)
                }
                if let focusTotal {
                    UpOnlyAmount(value: focusTotal, cents: true)
                    // A portfolio in focus moves with its market, so it keeps its percentage; cash doesn't.
                    let market = if case .portfolio = companyFocus { true } else { false }
                    let assets = change.map { changeStat($0, percent: market) }
                    if let book, companyID != nil {
                        // Part owners: the whole company above, your share of it on one quiet line.
                        if partOwner, companyFocus == .all, let share {
                            UpOnlyPrivateText("Your share" + (ownership.map { " · " + $0.label } ?? "") + " · " + UpOnlyFormat.exactMoney(share))
                                .font(UpOnlyType.caption).foregroundStyle(.secondary)
                        }
                        // The two figures are also what the chart shows: choosing one switches it.
                        let totals = rangeTotals(book)
                        let profit = partOwner ? totals.share : totals.profit
                        HStack(spacing: 8) {
                            metricTile(title: "Assets", value: assets?.value ?? "—", detail: assets?.detail, tint: assets?.tint ?? .secondary,
                                       caption: worthRange.spokenTitle, selected: !showProfit) { companyChart = .balance }
                            metricTile(title: partOwner ? "Your profit" : "Profit", value: profit.map { UpOnlyFormat.movement($0, fraction: nil, cents: true) } ?? "—", private: true,
                                       tint: profit.map(UpOnlyTint.signed) ?? .secondary, caption: worthRange.spokenTitle + (totals.missing > 0 ? " · \(totals.missing) month\(totals.missing == 1 ? "" : "s") missing" : ""),
                                       selected: showProfit) { companyChart = .profit }
                        }.padding(.top, 8)
                    } else {
                        // The change over the range, beside your share of a part-owned company.
                        let yourShare = partOwner && companyFocus == .all ? share.map { share -> HeadlineStat in
                            let shown = session.privacyMode ? session.standInFactor.map { UpOnlyFormat.exactMoney(share * $0) } ?? "••••" : UpOnlyFormat.exactMoney(share)
                            return HeadlineStat(label: "Your share" + (ownership.map { " · " + $0.label } ?? ""), value: shown, tint: .primary, spoken: shown)
                        } : nil
                        let stats = [assets, yourShare].compactMap { $0 }
                        if !stats.isEmpty { headlineStats(stats).padding(.top, 4) }
                    }
                } else if allParts.isEmpty {
                    Text("Balance needed").font(UpOnlyType.title)
                    Text("Add a balance to value this account.").font(UpOnlyType.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else { Text("Needs a price or rate").font(UpOnlyType.title) }
            }
            // One chart. Assets shows the selected account, portfolio or everything; Profit / loss shows the accounting months.
            if hasAssetChart || companyID != nil {
                VStack(alignment: .leading, spacing: 8) {
                    rangeControl
                    if showProfit {
                        if let book {
                            let totals = rangeTotals(book)
                            UpOnlyChart(points: rangeMonthPoints(book), includesZero: true, showsAllMarkers: true, tint: UpOnlyTint.cashFlow, plotHeight: chartPlotHeight)
                            // What the profit is made of, when the sheet says.
                            let parts = [totals.revenue.map { "Net revenue " + UpOnlyFormat.exactMoney($0) }, totals.expenses.map { "expenses " + UpOnlyFormat.exactMoney($0) }].compactMap { $0 }
                            if !parts.isEmpty { UpOnlyPrivateText(parts.joined(separator: " − ")).font(UpOnlyType.caption).foregroundStyle(.secondary) }
                        } else { Text("Accounting unavailable for this period").font(UpOnlyType.body).foregroundStyle(.secondary) }
                    } else if hasAssetChart {
                        UpOnlyChart(points: series, tint: trendTint(series), plotHeight: chartPlotHeight, bridgesGaps: true)
                    } else { Text("No history yet for this selection.").font(UpOnlyType.caption).foregroundStyle(.secondary) }
                }.padding(.top, 6)
            }
            // Breakdown: one USD line per bank, with its logo. Choosing a row focuses the chart and headline on it; a
            // typed-in balance updates from a right-click or the + above. Currency detail stays on Manage → Accounts.
            let banks = document.map { BankBalanceGroup.banks(bankValues, document: $0) } ?? []
            if !banks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Bank accounts").font(UpOnlyType.section)
                    assetList(banks.map { bank in companyBankRow(bank, document: document) })
                }
            }
            if !portfolios.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Set(portfolios.map(\.kind)).count > 1 ? "Crypto & metals" : portfolios[0].kind == .metals ? "Metals" : "Crypto").font(UpOnlyType.section)
                    // Every holding on its own row, biggest first, as a portfolio page lists them; each opens its own page.
                    assetList(holdingValues.sorted { ($0.usdValue?.value ?? 0) > ($1.usdValue?.value ?? 0) }.compactMap { part -> AssetRow? in
                        guard let holding = document?.holdings.first(where: { $0.id == part.id }), let portfolio = portfolios.first(where: { $0.id == holding.portfolioID }) else { return nil }
                        let metal = portfolio.kind == .metals
                        return AssetRow(id: part.id.uuidString, name: part.label,
                                        detail: part.nativeAmount.map { ManageFormat.amount($0.value, of: holding, catalog: session.catalog) }, detailIsAmount: true,
                                        value: part.usdValue.map { UpOnlyFormat.exactMoney($0.value) } ?? "Price needed",
                                        logo: holding.assetID.rawValue, symbol: metal ? TrackedKind.metals.symbol : TrackedKind.crypto.symbol,
                                        tint: metal ? UpOnlyTint.metals : UpOnlyTint.crypto) {
                            select(.holding(holding.id), .drill)
                        }
                    })
                }
            }
            // Only a problem with the accounting is worth a line here; how profit is measured stays with the sheet.
            if let warning = book?.warning {
                Label(warning, systemImage: "exclamationmark.triangle").font(UpOnlyType.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    /// A figure that is also a choice of chart: its name, its change over the range and the range. The chosen one is
    /// raised on a light card; the other stays flat.
    func metricTile(title: String, value: String, detail: String? = nil, private isPrivate: Bool = false, tint: Color, caption: String,
                    selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(UpOnlyType.caption.weight(.medium)).foregroundStyle(selected ? .primary : .secondary)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Group { if isPrivate { UpOnlyPrivateText(value) } else { Text(value) } }
                        .font(UpOnlyType.body.weight(.semibold).monospacedDigit())
                        // Dots stay neutral; a red "••••" would still say it's a loss.
                        .foregroundStyle(session.privacyMode && session.standInFactor == nil ? Color.primary : tint)
                    if let detail { Text(detail).font(UpOnlyType.caption.monospacedDigit()).foregroundStyle(.secondary) }
                }.lineLimit(1).minimumScaleFactor(0.8)
                Text(caption).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 8)
                // The card fill every tile has, a shade deeper for the one on the chart.
                .background(selected ? Color.primary.opacity(0.11) : UpOnlyContentSurface.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : []).help("Show " + title.lowercased() + " on the chart")
    }
    func companyBankRow(_ bank: BankBalanceGroup, document: VaultDocument?) -> AssetRow {
        let ids = Set(bank.components.map(\.id))
        let single = bank.components.count == 1 ? bank.components.first : nil
        let manual = single.flatMap { component in document?.accounts.first { $0.id == component.id } }.map { $0.externalProfileID == nil } ?? false
        let native = single.flatMap { component in manual && component.currency != "USD" ? component.nativeAmount.map { UpOnlyFormat.currencyMoney($0.value, currency: component.currency) } : nil }
        // Clicking a bank focuses the chart on it; updating a typed-in balance is a right-click (or the + above).
        let synced = single.flatMap { component in document?.accounts.first { $0.id == component.id } }.map { $0.externalProfileID != nil } ?? (single == nil)
        var options: [(title: String, action: () -> Void)] = []
        if manual, let component = single {
            options.append(("Update balance…", { showImport(session.startImport(.bankBalances, prefill: true, accountID: component.id)) }))
        }
        // A foreign balance sits under its dollar value, as a coin's quantity does, so the name stays on one line.
        return AssetRow(id: bank.id, name: bank.name,
                        value: bank.total.map(UpOnlyFormat.exactMoney) ?? (bank.components.contains { $0.missing == "fx" } ? "Rate needed" : "Add balance"), valueDetail: native,
                        image: bank.image, bank: bank.name, synced: synced, symbol: "building.columns.fill", tint: UpOnlyTint.netWorth,
                        selected: companyFocus == .bank(ids), chevron: false, options: options) {
            companyFocus = companyFocus == .bank(ids) ? .all : .bank(ids)
        }
    }
    /// `.bank` holds every account of one bank (a Wise profile's currencies together), valued as one USD figure.
    enum CompanyFocus: Hashable { case all, bank(Set<UUID>), portfolio(UUID) }
    /// Holdings in the portfolios a company owns, from a set of valuation components.
    func companyHoldings(_ components: [ValuationComponent], companyID: String?) -> [ValuationComponent] {
        guard let companyID, let document = session.document else { return [] }
        let owned = Set(document.portfolios.filter { $0.ownerBusinessID == companyID }.map(\.id))
        return components.filter { component in
            component.kind == .holding && document.holdings.first { $0.id == component.id }.map { owned.contains($0.portfolioID) } == true
        }
    }
    func focusedParts(_ parts: [ValuationComponent]) -> [ValuationComponent] {
        switch companyFocus {
        case .all: return parts
        case .bank(let ids): return parts.filter { ids.contains($0.id) }
        case .portfolio(let portfolioID): return parts.filter { component in session.document?.holdings.first { $0.id == component.id }?.portfolioID == portfolioID }
        }
    }
    func companyFocusOptions(bankValues: [ValuationComponent], portfolios: [Portfolio]) -> [(focus: CompanyFocus, label: String)] {
        guard let document = session.document else { return [] }
        var options: [(CompanyFocus, String)] = [(.all, "All")]
        for bank in BankBalanceGroup.banks(bankValues, document: document) where (bank.total ?? 0) != 0 {
            options.append((.bank(Set(bank.components.map(\.id))), bank.name))
        }
        for portfolio in portfolios { options.append((.portfolio(portfolio.id), portfolio.name)) }
        return options.map { (focus: $0.0, label: $0.1) }
    }
    func companyFocusTitle(_ options: [(focus: CompanyFocus, label: String)]) -> String? {
        guard companyFocus != .all else { return nil }
        return options.first { $0.focus == companyFocus }?.label
    }
    /// The selected account, portfolio or whole group over time, from the saved daily values of everything tracked.
    /// Missing prices, rates and balances are estimated as on the net worth chart; the line ends at `live`.
    func companySeries(_ groupID: String, interval: DateInterval, live: Decimal?, liveComponents: [ValuationComponent]) -> [UpOnlyChartPoint] {
        guard let document = session.document else { return [] }
        let companyID = groupID == "personal" ? nil : groupID
        let samples = DashboardPeriod.samples(in: interval, scope: .allTracked, document: document)
        let estimates = session.chartEstimates() ?? ChartEstimates(document: document)
        func figure(_ components: [ValuationComponent], day: Date, at moment: Date?) -> (Decimal, String?)? {
            let banks = components.filter { component in
                component.kind == .bank && (AssetOwnership.businessID(for: component, in: document) ?? "personal") == groupID
            }
            let parts = focusedParts(banks + companyHoldings(components, companyID: companyID))
            guard !parts.isEmpty else { return nil }
            return estimates.total(parts, day: day, at: moment).map { ($0.total, nil) }
        }
        if let fine = intradaySeries(scope: .allTracked, interval: interval, samples: samples, liveComponents: liveComponents, live: live, { figure($0, day: $1, at: $1) }) {
            return fine
        }
        if worthRange.hourly { return hourlySeries(scope: .allTracked, interval: interval, live: live) { figure($0, day: $1, at: $1) } }
        return dailySeries(samples, interval: interval, live: live) { figure($0.components, day: $0.utcDay, at: nil) }
    }
}
