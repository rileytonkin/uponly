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
                    if let change { changeLine(change).padding(.top, 2) }
                } else if allParts.isEmpty {
                    Text("Balance needed").font(UpOnlyType.title)
                    Text("Add a balance to value this account.").font(UpOnlyType.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else { Text("Needs a price or rate").font(UpOnlyType.title) }
            }
            if partOwner, let share, companyFocus == .all, focusTotal != nil {
                UpOnlyValueRow(label: "Your share of assets" + (ownership.map { " · " + $0.label } ?? ""), value: UpOnlyFormat.exactMoney(share))
            }
            // One chart. Assets shows the selected account, portfolio or everything; Profit / loss shows the accounting months.
            if hasAssetChart || companyID != nil {
                VStack(alignment: .leading, spacing: 8) {
                    rangeControl
                    if companyID != nil {
                        Picker("Chart", selection: Binding(get: { companyChart }, set: { companyChart = $0 })) {
                            Text("Assets").tag(CompanyChart.balance)
                            Text("Profit / loss").tag(CompanyChart.profit)
                        }.pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize().accessibilityLabel("Company chart")
                    }
                    if !showProfit, focusOptions.count > 2 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(focusOptions, id: \.focus) { option in
                                    Button(option.label) { companyFocus = option.focus }
                                        .buttonStyle(.plain).font(.system(size: 11, weight: companyFocus == option.focus ? .semibold : .regular))
                                        .padding(.horizontal, 9).padding(.vertical, 4)
                                        .background(companyFocus == option.focus ? UpOnlyTint.netWorth.opacity(0.16) : Color.primary.opacity(0.06), in: Capsule())
                                        .foregroundStyle(companyFocus == option.focus ? .primary : .secondary)
                                        .accessibilityAddTraits(companyFocus == option.focus ? [.isSelected] : [])
                                }
                            }
                        }
                    }
                    if showProfit {
                        // The accounting figures belong with their chart, not above the assets.
                        if let book {
                            let totals = rangeTotals(book)
                            HStack(alignment: .top, spacing: 12) {
                                companyFigure("Net revenue", totals.revenue)
                                companyFigure("Expenses", totals.expenses.map { -$0 })
                                companyFigure(partOwner ? "Your profit" : "Profit / loss", partOwner ? totals.share : totals.profit, signed: true)
                            }.padding(.top, 4)
                            UpOnlyChart(points: rangeMonthPoints(book), includesZero: true, showsAllMarkers: true, tint: UpOnlyTint.cashFlow)
                            // Which months the figures cover, when some are missing.
                            if let caption = totals.caption { Text(caption).font(UpOnlyType.caption).foregroundStyle(.secondary) }
                        } else { Text("Accounting unavailable for this period").font(UpOnlyType.body).foregroundStyle(.secondary) }
                    } else if hasAssetChart {
                        UpOnlyChart(points: series, tint: trendTint(series), bridgesGaps: true)
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
                    assetList(portfolios.map { portfolio -> AssetRow in
                        let parts = holdingValues.filter { component in document?.holdings.first { $0.id == component.id }?.portfolioID == portfolio.id }
                        return AssetRow(id: portfolio.id.uuidString, name: portfolio.name, detail: parts.isEmpty ? nil : parts.map(\.label).joined(separator: ", "),
                                        value: AssetOwnership.sum(parts).map(UpOnlyFormat.exactMoney) ?? (parts.isEmpty ? "No holdings" : "Price needed"),
                                        // Crypto always wears Bitcoin's logo; metals their largest holding's.
                                        logo: portfolio.kind == .crypto ? "bitcoin" : parts.max { ($0.usdValue?.value ?? 0) < ($1.usdValue?.value ?? 0) }.flatMap { part in document?.holdings.first { $0.id == part.id }?.assetID.rawValue },
                                        symbol: portfolio.kind == .metals ? TrackedKind.metals.symbol : TrackedKind.crypto.symbol,
                                        tint: portfolio.kind == .metals ? UpOnlyTint.metals : UpOnlyTint.crypto, selected: companyFocus == .portfolio(portfolio.id),
                                        trailing: .button(symbol: "chevron.right", label: "Open " + portfolio.name, action: {
                                            select(.portfolio(portfolio.id), .drill)
                                        })) {
                            companyFocus = companyFocus == .portfolio(portfolio.id) ? .all : .portfolio(portfolio.id)
                        }
                    })
                }
            }
            if let book {
                // The sheet's own basis and warnings; the figures above already cover the selected range.
                DisclosureGroup("Accounting details") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(book.basis)
                        if let warning = book.warning { Text(warning) }
                        if let url = URL(string: book.sourceURL), url.scheme == "https" { Link("Open accounting sheet", destination: url).buttonStyle(.bordered) }
                    }.font(UpOnlyType.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
                }.font(UpOnlyType.body)
            }
        }
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
                        selected: companyFocus == .bank(ids), trailing: .none, options: options) {
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
            return estimates.total(parts, day: day, at: moment).map { ($0.total, $0.estimated.isEmpty ? nil : "Estimated: " + $0.estimated.joined(separator: "; ")) }
        }
        if let fine = intradaySeries(scope: .allTracked, interval: interval, samples: samples, liveComponents: liveComponents, live: live, { figure($0, day: $1, at: $1) }) {
            return fine
        }
        if worthRange.hourly { return hourlySeries(scope: .allTracked, interval: interval, live: live) { figure($0, day: $1, at: $1) } }
        return dailySeries(samples, interval: interval, live: live) { figure($0.components, day: $0.utcDay, at: nil) }
    }
}
