import SwiftUI

/// Cash flow: income minus spending by month, year or all time, and the Personal and company detail pages.
extension UpOnlyUnlockedPanel {
    var monthContent: some View {
        let gaps = personalRateGaps
        return VStack(alignment: .leading, spacing: 0) {
            if detail == "personal" {
                personalContent(gaps)
            } else if let row = selectedBusiness {
                headline(eyebrow("Company profit / loss"))
                if let profit = row.observation?.profitUSD {
                    UpOnlyAmount(value: profit, signed: true, tint: UpOnlyTint.signed(profit)).padding(.top, 10)
                }
                businessDetails(row).padding(.top, 14)
            } else {
            // With no companies the tab title already says Cash flow, so the eyebrow says what the figure is.
            if model.books.isEmpty { headline(eyebrow(performanceBasis)) } else { headline(performanceScopeSelector) }
            if let totals = model.availableTotals {
                UpOnlyAmount(value: totals.net, signed: true, tint: UpOnlyTint.signed(totals.net)).padding(.top, 10)
                if let caption = performanceCaption { Text(caption).font(UpOnlyType.body).foregroundStyle(.secondary).padding(.top, 6) }
            } else if case .exchangeRates(let currencies)? = model.state.unavailable {
                nativeMonthContent(gaps.first ?? (model.month, currencies)).padding(.top, 16)
            } else {
                let nothing = model.state.unavailable == .noEntries && gaps.isEmpty
                VStack(alignment: .leading, spacing: 7) {
                    Text(model.state.unavailable == .invalidAmount ? "Check your amounts" : nothing ? "Nothing recorded" : !gaps.isEmpty ? "Exchange rates needed" : "Not reported yet")
                        .font(UpOnlyType.title)
                    Text(nothing ? "Add a transaction or import a bank statement." : !gaps.isEmpty ? "Some months can’t be shown in USD until their rates are added." : "The selected period has no recorded result.")
                        .font(UpOnlyType.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if nothing {
                        Button("Add") { session.addingInMenu = true }.buttonStyle(.glassProminent).padding(.top, 4)
                    }
                }.padding(.top, 18)
            }
            if let gap = gaps.first {
                if case .exchangeRates? = model.state.unavailable {
                    if model.availableTotals != nil { exchangeRateAction(gap.1, month: gap.0).padding(.top, 12) }
                } else { exchangeRateAction(gap.1, month: gap.0).padding(.top, 12) }
            }
            if model.period == .monthly, !model.pendingAccounting.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.pendingAccounting.joined(separator: ", ") + " · " + model.month.title + " not reported yet")
                        .font(UpOnlyType.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let latest = model.latestAccountingMonth, latest != model.month {
                        Button("View " + latest.title) { model.select(latest) }.buttonStyle(.bordered).controlSize(.small)
                    }
                }.padding(.top, 8)
            }
                let points = monthPoints(model.chartHistory)
                if gaps.isEmpty || points.contains(where: { $0.value != nil }) {
                UpOnlyChart(points: points, includesZero: true, showsAllMarkers: true, selected: model.period == .monthly ? model.month.description : nil, tint: UpOnlyTint.cashFlow) { id in
                    if let month = MonthKey(id) { model.drillInto(month) }
                }.padding(.top, 20)
                }
                if case .business = model.scope {
                    if let row = model.state.businesses.first {
                        VStack(spacing: 6) { accountingRows(row) }.padding(.top, 10)
                        assetList([AssetRow(id: row.id, name: shareLabel(row), value: shareValue(row), symbol: "building.2.fill", tint: UpOnlyTint.cashFlow) { detail = "business:" + row.id }])
                            .padding(.top, 8)
                    }
                } else {
                    assetList(cashFlowRows).padding(.top, 10)
                }
            }
        }
        .onChange(of: model.scope) { detail = nil }
    }
    var cashFlowRows: [AssetRow] {
        var rows = [AssetRow(id: "personal", name: "Personal", value: model.personalState.totals.map { UpOnlyFormat.exactMoney($0.net) } ?? "Not recorded",
                             symbol: "person.fill", tint: UpOnlyTint.cashFlow) { detail = "personal" }]
        for row in model.state.businesses {
            rows.append(AssetRow(id: row.id, name: row.book.name, value: shareValue(row), symbol: "building.2.fill", tint: UpOnlyTint.cashFlow) { detail = "business:" + row.id })
        }
        return rows
    }
    var performanceBasis: String {
        if case .business = model.scope { return "Company profit / loss" }
        return "Income minus spending"
    }
    /// Partial only when months are missing or a company hasn't reported. An open or unreviewed month is normal.
    var performanceCaption: String? {
        let missing = model.state.missingMonths
        let partial: String? = missing > 0 ? "\(missing) month\(missing == 1 ? "" : "s") not recorded"
            : model.state.totals == nil && model.availableTotals != nil ? "Partial" : nil
        if model.books.isEmpty { return partial }
        return performanceBasis + (partial.map { " · " + $0 } ?? "")
    }
    func shareLabel(_ row: BusinessContribution) -> String {
        row.ownershipLabel == "Historical ownership" ? "Your share" : "Your share · " + row.ownershipLabel
    }
    func shareValue(_ row: BusinessContribution) -> String {
        row.share.map(UpOnlyFormat.exactMoney) ?? (row.book.months.isEmpty ? "Needs refresh" : "Not reported")
    }
    @ViewBuilder func accountingRows(_ row: BusinessContribution) -> some View {
        if let revenue = row.observation?.revenueUSD { UpOnlyValueRow(label: "Net revenue", value: UpOnlyFormat.exactMoney(revenue)) }
        if let expenses = row.observation?.expensesUSD { UpOnlyValueRow(label: "Expenses", value: UpOnlyFormat.exactMoney(-expenses)) }
    }
    func businessDetails(_ row: BusinessContribution) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            accountingRows(row)
            if row.observation == nil { Text("Not reported for this period").font(UpOnlyType.body).foregroundStyle(.secondary) }
            UpOnlyValueRow(label: shareLabel(row), value: shareValue(row))
        }
    }
    func companyFigure(_ title: String, _ value: Decimal?, signed: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(UpOnlyType.caption).foregroundStyle(.secondary).lineLimit(1)
            UpOnlyPrivateText(value.map(UpOnlyFormat.exactMoney) ?? "—").font(.system(size: 14, weight: .medium).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.8)
                // Hidden values stay neutral: a red "••••" would still say it's a loss.
                .foregroundStyle(signed && !session.privacyMode ? value.map(UpOnlyTint.signed) ?? Color.primary : Color.primary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    /// Revenue, expenses, profit and your share summed over the months in the selected range, with a caption saying
    /// which months that covers.
    func rangeTotals(_ book: BusinessBook) -> (revenue: Decimal?, expenses: Decimal?, profit: Decimal?, share: Decimal?, caption: String) {
        let months = rangeMonths
        let rows = months.compactMap { key in book.months.first { $0.month == key.description } }
        guard let firstRow = rows.first, let lastRow = rows.last else { return (nil, nil, nil, nil, "No accounting" + worthRange.within + ".") }
        let profit = rows.reduce(Decimal(0)) { $0 + $1.profitUSD }
        let revenue = rows.allSatisfy { $0.revenueUSD != nil } ? rows.reduce(Decimal(0)) { $0 + ($1.revenueUSD ?? 0) } : nil
        let expenses = rows.allSatisfy { $0.expensesUSD != nil } ? rows.reduce(Decimal(0)) { $0 + ($1.expensesUSD ?? 0) } : nil
        let share = rows.reduce(Decimal?.some(0)) { sum, row in
            guard let sum, let portion = book.ownership(at: row.month).flatMap({ try? $0.portion(row.profitUSD) }) else { return nil }
            return sum + portion
        }
        let missing = months.count - rows.count
        let first = MonthKey(firstRow.month)?.title ?? firstRow.month, last = MonthKey(lastRow.month)?.title ?? lastRow.month
        var caption = rows.count == 1 ? first : first + " to " + last
        if missing > 0 { caption += " · \(missing) month\(missing == 1 ? "" : "s") without accounting" }
        if rows.contains(where: \.estimated) { caption += " · current month is provisional" }
        return (revenue, expenses, profit, share, caption)
    }
    /// The whole months the net worth range covers, ending with the current one. All reaches back to the first
    /// reported accounting month (at most ten years).
    var rangeMonths: [MonthKey] {
        let count = worthRange.months ?? {
            guard let first = model.books.flatMap(\.months).compactMap({ MonthKey($0.month) }).min() else { return 1 }
            var n = 1, cursor = MonthKey.current()
            while cursor > first && n < 120 { cursor = cursor.previous; n += 1 }
            return n
        }()
        var months: [MonthKey] = [.current()]
        while months.count < count { months.insert(months[0].previous, at: 0) }
        return months
    }
    /// Monthly profit for the months inside the net worth range, so both company charts cover the same span.
    func rangeMonthPoints(_ book: BusinessBook?) -> [UpOnlyChartPoint] {
        let months = rangeMonths
        let showYear = months.first?.year != months.last?.year
        return months.map { key -> UpOnlyChartPoint in
            let row = model.history.first { $0.month == key } ?? (key, nil, false)
            // Say where the figure came from, so it can be checked against the sheet. The chart hides it in privacy mode.
            let sheet = book?.months.first { $0.month == key.description }
            let parts = [sheet?.revenueUSD.map { "Net revenue " + UpOnlyFormat.money($0) }, sheet?.expensesUSD.map { "expenses " + UpOnlyFormat.money($0) }].compactMap { $0 }
            let note = sheet.map { (parts.isEmpty ? "" : parts.joined(separator: " − ") + " · ") + $0.sourceRange + ($0.estimated ? " · provisional" : "") }
            return UpOnlyChartPoint(id: key.description, label: UpOnlyFormat.monthName(key) + (showYear ? " " + String(key.year).suffix(2) : ""), value: row.net, provisional: !row.settled, detailLabel: key.title, note: note)
        }
    }
    func monthPoints(_ history: [(month: MonthKey, net: Decimal?, settled: Bool)]) -> [UpOnlyChartPoint] {
        history.map {
            UpOnlyChartPoint(id: $0.month.description, label: UpOnlyFormat.monthName($0.month) + (model.period == .allTime ? " " + String($0.month.year).suffix(2) : ""),
                             value: $0.net, provisional: !$0.settled, detailLabel: $0.month.title)
        }
    }
    var selectedBusiness: BusinessContribution? {
        guard let detail else { return nil }
        if let row = model.state.businesses.first(where: { "business:" + $0.id == detail }) { return row }
        guard let book = model.books.first(where: { "business:" + $0.id == detail }) else { return nil }
        return BusinessContribution(book: book, observation: nil, share: nil, ownershipLabel: "Historical ownership")
    }
    func personalContent(_ gaps: [(MonthKey, [String])]) -> some View {
        let state = model.personalState
        let entries = model.personalEntries
        let sources = personalSources(entries)
        // The latest few, inline: the page itself scrolls, and "See all" opens the full list.
        let latest = Array(entries.sorted { ($0.month, $0.day ?? "") > ($1.month, $1.day ?? "") }.prefix(6))
        let points = monthPoints(model.personalChartHistory)
        return VStack(alignment: .leading, spacing: 14) {
            headline(eyebrow("Income minus spending"))
            if let totals = state.totals {
                UpOnlyAmount(value: totals.net, signed: true, tint: UpOnlyTint.signed(totals.net))
                    .help(state.isEstimated ? "Based on recorded transactions; this period isn’t complete yet." : "Income minus spending")
                HStack(spacing: 20) {
                    personalSubtotal("Income", value: totals.personalIncome)
                    personalSubtotal("Spending", value: -totals.personalSpend)
                }
                if sources.count > 1 { personalAccountBreakdown(sources) }
            } else if entries.isEmpty {
                Text("No personal transactions for this period").font(UpOnlyType.section).fixedSize(horizontal: false, vertical: true)
            }
            if let gap = gaps.first { exchangeRateAction(gap.1, month: gap.0) }
            if points.contains(where: { $0.value != nil }) {
                UpOnlyChart(points: points, includesZero: true, showsAllMarkers: true, selected: model.period == .monthly ? model.month.description : nil, tint: UpOnlyTint.cashFlow) { id in
                    if let month = MonthKey(id) { model.drillInto(month) }
                }
            }
            HStack {
                Text("Transactions").font(UpOnlyType.section)
                Spacer()
                if entries.isEmpty {
                    Button("Add") { session.addingInMenu = true }.buttonStyle(.bordered).accessibilityLabel("Add a transaction")
                } else {
                    Button("See all") { manage("Entries") }.buttonStyle(.bordered).accessibilityLabel("See all personal transactions")
                }
            }
            if !latest.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    let byMonth = Dictionary(grouping: latest, by: \.month)
                    ForEach(byMonth.keys.sorted(by: >), id: \.self) { month in
                        VStack(alignment: .leading, spacing: 6) {
                            if model.period != .monthly {
                                Text(MonthKey(month)?.title ?? month).font(UpOnlyType.caption.weight(.medium)).foregroundStyle(.secondary)
                            }
                            ForEach(byMonth[month] ?? []) { entry in
                                UpOnlyValueRow(label: entry.label, value: personalEntryAmount(entry))
                            }
                        }
                    }
                    if entries.count > latest.count {
                        Button("See all \(entries.count) transactions") { manage("Entries") }
                            .buttonStyle(.plain).font(UpOnlyType.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }.padding(.top, 8)
    }
    /// Where the visible personal transactions came from, named as Needs attention names them: each bank account in
    /// the order it was added, then Wise, with transactions added by hand last.
    func personalSources(_ entries: [Entry]) -> [PersonalAccountGroup] {
        let accounts = session.document?.accounts ?? []
        var names: [String: String] = [:]
        let grouped = Dictionary(grouping: entries) { entry in
            let source = MonthEvidence.sourceName(for: entry, accounts: accounts)
            names[source.id] = source.name
            return source.id
        }
        let order = Dictionary(accounts.enumerated().map { ($1.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
        return grouped.keys.sorted { a, b in
            let rank = { (id: String) -> Int in id == "manual" ? Int.max : order[id] ?? Int.max - 1 }
            return rank(a) != rank(b) ? rank(a) < rank(b) : (names[a] ?? a) < (names[b] ?? b)
        }.map { PersonalAccountGroup(id: $0, name: names[$0] ?? $0, entries: grouped[$0] ?? []) }
    }
    func personalAccountBreakdown(_ sources: [PersonalAccountGroup]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("By account").font(UpOnlyType.caption).foregroundStyle(.secondary)
            ForEach(sources) { source in
                let usd = source.entries.reduce(Decimal?.some(0)) { sum, entry in
                    guard let sum, let value = personalEntryUSD(entry) else { return nil }
                    return (try? MoneyInput.add(sum, value)) ?? nil
                }
                UpOnlyValueRow(label: source.name, value: usd.map { UpOnlyFormat.exactMoney($0) } ?? "Rate needed")
            }
        }
    }
    func personalSubtotal(_ title: String, value: Decimal) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(UpOnlyType.caption).foregroundStyle(.secondary)
            UpOnlyPrivateText(UpOnlyFormat.exactMoney(value)).font(.system(size: 14, weight: .medium)).monospacedDigit().fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore).accessibilityLabel(title)
            .accessibilityValue(session.privacyMode ? "Hidden value" : UpOnlyFormat.exactMoney(value))
    }
    func personalEntryUSD(_ entry: Entry) -> Decimal? {
        let signed = entry.kind == .expense ? -entry.amount : entry.amount
        guard let doc = session.document, let month = MonthKey(entry.month), let rate = MonthlyLedger.rate(currency: entry.currency, month: month, document: doc) else { return nil }
        return try? MoneyInput.multiply(signed, rate)
    }
    func personalEntryAmount(_ entry: Entry) -> String {
        guard let usd = personalEntryUSD(entry) else {
            let signed = entry.kind == .expense ? -entry.amount : entry.amount
            return UpOnlyFormat.currencyMoney(signed, currency: entry.currency) + " " + entry.currency
        }
        return UpOnlyFormat.exactMoney(usd)
    }

}
