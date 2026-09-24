import SwiftUI

/// A bank group or company page: its assets, accounting figures, chart focus and accounts.
extension UpOnlyUnlockedPanel {
    struct CompanySelection {
        var group: BankBalanceGroup
        var previousScope: PerformanceScope
    }
    func openCompany(_ group: BankBalanceGroup) {
        companyFocus = .all
        companySelection = CompanySelection(group: group, previousScope: model.scope)
        model.selectScope(group.businessID.map(PerformanceScope.business) ?? .personal)
    }
    func companyContent(_ selection: CompanySelection) -> some View {
        let document = session.document
        let interval = selectedInterval
        let raw = document.map { NetWorthCalculator.value(at: interval.end, scope: .allTracked, document: $0) }
        let companyID = selection.group.businessID
        let bankValues = (raw?.components ?? []).filter { component in
            guard component.kind == .bank, let document else { return false }
            if let companyID { return AssetOwnership.businessID(for: component, in: document) == companyID }
            return selection.group.components.contains { $0.id == component.id }
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
        let series = companySeries(selection, interval: interval)
        let focusOptions = companyFocusOptions(bankValues: bankValues, portfolios: portfolios)
        let delta = change(from: series.baseline, to: focusTotal, interval: interval)
        let hasAssetChart = series.points.contains { $0.value != nil }
        let showProfit = companyChart == .profit && companyID != nil
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                // The page title already says "Bank balances"; the eyebrow only names a focused account or a company's total.
                if let title = companyFocusTitle(focusOptions) ?? (companyID == nil ? nil : "Total assets") {
                    eyebrow(title).frame(minHeight: 22, alignment: .leading)
                }
                if let focusTotal {
                    UpOnlyAmount(value: focusTotal)
                    if let delta { Text(delta.text).font(UpOnlyType.body.weight(.medium).monospacedDigit()).foregroundStyle(delta.tint).padding(.top, 2) }
                } else if allParts.isEmpty {
                    Text("Balance needed").font(UpOnlyType.title)
                    Text("Add a balance to value this account.").font(UpOnlyType.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else { Text("Needs a price or rate").font(UpOnlyType.title) }
            }
            if partOwner, let share, companyFocus == .all, focusTotal != nil {
                UpOnlyValueRow(label: "Your share" + (ownership.map { " · " + $0.label } ?? ""), value: UpOnlyFormat.exactMoney(share))
            }
            if companyID != nil, let book {
                let totals = rangeTotals(book)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 12) {
                        companyFigure("Net revenue", totals.revenue)
                        companyFigure("Expenses", totals.expenses.map { -$0 })
                        companyFigure(partOwner ? "Your share" : "Profit / loss", partOwner ? totals.share : totals.profit, signed: true)
                    }
                    // Say which months the figures cover: missing months would otherwise pass for a full range.
                    Text(totals.caption).font(UpOnlyType.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else if companyID != nil { Text("Accounting unavailable for this period").font(UpOnlyType.body).foregroundStyle(.secondary) }
            // One chart. Assets shows the selected account, portfolio or everything; Profit / loss shows the accounting months.
            if hasAssetChart || companyID != nil {
                VStack(alignment: .leading, spacing: 8) {
                    rangeControl
                    if companyID != nil {
                        Picker("Chart", selection: $companyChart) {
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
                        UpOnlyChart(points: rangeMonthPoints(book), includesZero: true, showsAllMarkers: true, tint: UpOnlyTint.cashFlow)
                    } else if hasAssetChart {
                        UpOnlyChart(points: series.points, tint: trendTint(series.points), spansRange: true)
                    } else { Text("No history yet for this selection.").font(UpOnlyType.caption).foregroundStyle(.secondary) }
                }.padding(.top, 6)
            }
            // Breakdown: one USD line per bank. Choosing a row focuses the chart and headline on it; the pencil on a
            // manual account updates its balance. Currency detail stays on Manage → Bank accounts.
            let banks = document.map { BankBalanceGroup.banks(bankValues, document: $0) } ?? []
            if !banks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Bank accounts").font(UpOnlyType.section)
                    assetList(banks.map { bank in companyBankRow(bank, document: document) })
                }
            }
            if !portfolios.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Set(portfolios.map(\.kind)).count > 1 ? "Crypto, gold & silver" : portfolios[0].kind == .metals ? "Gold & silver" : "Crypto").font(UpOnlyType.section)
                    assetList(portfolios.map { portfolio -> AssetRow in
                        let parts = holdingValues.filter { component in document?.holdings.first { $0.id == component.id }?.portfolioID == portfolio.id }
                        return AssetRow(id: portfolio.id.uuidString, name: portfolio.name, detail: parts.isEmpty ? nil : parts.map(\.label).joined(separator: ", "),
                                        value: AssetOwnership.sum(parts).map(UpOnlyFormat.exactMoney) ?? (parts.isEmpty ? "No holdings" : "Price needed"),
                                        symbol: portfolio.kind == .metals ? TrackedKind.metals.symbol : TrackedKind.crypto.symbol,
                                        tint: portfolio.kind == .metals ? UpOnlyTint.metals : UpOnlyTint.crypto, selected: companyFocus == .portfolio(portfolio.id),
                                        trailing: .button(symbol: "chevron.right", label: "Open " + portfolio.name, action: {
                                            companySelection = nil; model.selectScope(selection.previousScope)
                                            portfolioReturn = selection; scope = .portfolio(portfolio.id)
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
        // Every row keeps the same trailing slot, so the amounts line up.
        var trailing = AssetRow.Trailing.space
        if manual, let component = single {
            trailing = .button(symbol: "square.and.pencil", label: "Update " + component.label + " balance", action: {
                showImport(session.startImport(.bankBalances, prefill: true, accountID: component.id))
            })
        }
        return AssetRow(id: bank.id, name: bank.name, detail: native, detailIsAmount: true,
                        value: bank.total.map(UpOnlyFormat.exactMoney) ?? (bank.components.contains { $0.missing == "fx" } ? "Rate needed" : "Add balance"),
                        image: bank.image, symbol: "building.columns.fill", tint: UpOnlyTint.netWorth, selected: companyFocus == .bank(ids), trailing: trailing) {
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
    /// The selected account, portfolio or whole company over time, from the saved daily values of everything tracked.
    /// A day with an unpriced part is an estimate.
    func companySeries(_ selection: CompanySelection, interval: DateInterval) -> (points: [UpOnlyChartPoint], baseline: Baseline?) {
        guard let document = session.document else { return ([], nil) }
        let ids = Set(selection.group.components.map(\.id))
        let companyID = selection.group.businessID
        let samples = DashboardPeriod.samples(in: interval, scope: .allTracked, document: document)
        return dailySeries(samples, interval: interval) { sample in
            let banks = sample.components.filter { component in
                guard component.kind == .bank else { return false }
                if let companyID { return AssetOwnership.businessID(for: component, in: document) == companyID }
                return ids.contains(component.id)
            }
            let parts = focusedParts(banks + companyHoldings(sample.components, companyID: companyID))
            guard !parts.isEmpty else { return nil }
            let valued = parts.filter { $0.usdValue != nil && $0.missing == nil }
            guard let total = AssetOwnership.sum(valued), !valued.isEmpty else { return nil }
            if valued.count == parts.count { return (total, nil) }
            return (total, "Excludes " + parts.filter { $0.usdValue == nil || $0.missing != nil }.map(\.label).joined(separator: ", ") + " (no price that day)")
        }
    }
}
