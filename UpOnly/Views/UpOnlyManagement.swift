import SwiftUI

struct UpOnlyManagement: View {
    @Environment(UpOnlySession.self) private var session
    var body: some View {
        UpOnlyManagementContent()
    }
}

// Pages share the menu's width and grow only as far as the available menu height.
// Longer forms scroll vertically; they never become a separate app window.
struct UpOnlyMenuScroll<Content: View>: View {
    @State private var contentHeight: CGFloat = 360
    var maxHeight: CGFloat = 540
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView {
            content().frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    if height.isFinite && height > 0 { contentHeight = ceil(height) }
                }
        }.scrollBounceBehavior(.basedOnSize)
            .frame(height: min(contentHeight, maxHeight))
    }
}

enum UpOnlyEditor: Identifiable {
    case portfolio, account, balance(Account), holding(UUID), quantity(Holding), move(Holding), entry, exchangeRate
    var id: String {
        switch self {
        case .portfolio: "portfolio"
        case .account: "account"
        case .balance(let a): "balance-" + a.id.uuidString
        case .holding(let id): "holding-" + id.uuidString
        case .quantity(let h): "quantity-" + h.id.uuidString
        case .move(let h): "move-" + h.id.uuidString
        case .entry: "entry"
        case .exchangeRate: "rate"
        }
    }
    var title: String {
        switch self {
        case .portfolio: "New portfolio"
        case .account: "Add bank account"
        case .balance: "Update balance"
        case .holding: "Add coin"
        case .quantity: "Update quantity"
        case .move: "Move coins"
        case .entry: "Add entry"
        case .exchangeRate: "Add exchange rate"
        }
    }
}

private struct UpOnlyManagementContent: View {
    @Environment(UpOnlySession.self) private var session
    @State private var sourceEditsPending = false
    @State private var discardSources = false
    @State private var editor: UpOnlyEditor?
    @State private var archive: Portfolio?
    @State private var entryToRemove: Entry?
    @State private var editingEntry: UUID?
    @State private var returnToReview = false
    @State private var entrySearch = ""
    @State private var entryMonth = ""
    @State private var entryProfile = ""
    @State private var entryLimit = 100
    private var hasGuidedHeader: Bool {
        guard editor == nil, session.managementSection == "Add your info", let draft = session.importDraft else { return false }
        return draft.mode != .statements && draft.rows.count <= 1 && draft.sources.allSatisfy { $0.grid.isEmpty } && !session.importTableMode
    }
    var body: some View {
        VStack(spacing: 0) {
            if !hasGuidedHeader {
            UpOnlyPageHeader(title: editor?.title ?? pageTitle,
                backLabel: editor != nil ? "Cancel editing" : ["Manage", "Needs attention"].contains(session.managementSection) ? "Back to overview" : returnToReview ? "Back to review data" : "Back to manage") {
                if discardSources { discardSources = false }
                else if archive != nil { archive = nil }
                else if entryToRemove != nil { entryToRemove = nil }
                else if session.managementSection == "Sources", sourceEditsPending { discardSources = true }
                else if editor != nil { finishEditing() }
                else if ["Manage", "Needs attention"].contains(session.managementSection) { session.managementInMenu = false }
                else if returnToReview { session.managementSection = "Needs attention" }
                else { session.managementSection = "Manage" }
            }.padding(UpOnlyLayout.inset)
            Divider()
            }
            if let portfolio = archive {
                UpOnlyConfirmation(title: "Archive " + portfolio.name + "?", detail: "Removes this portfolio from net worth. Keeps its history.", confirmTitle: "Archive portfolio",
                    confirm: { Task { await session.perform { doc in doc = try HoldingMutations.archivePortfolio(id: portfolio.id, at: Date(), document: doc) } }; archive = nil }, cancel: { archive = nil }).padding(16)
            } else if let entry = entryToRemove {
                UpOnlyConfirmation(title: "Remove this entry?", detail: entry.source == .csv ? "Your original statement stays saved." : "This removes the entry from your recorded monthly result.", confirmTitle: "Remove entry",
                    confirm: { Task { await session.perform { $0.entries.removeAll { $0.id == entry.id } } }; entryToRemove = nil }, cancel: { entryToRemove = nil }).padding(16)
            } else if let editor {
                UpOnlyMenuScroll {
                    UpOnlyEditSheet(editor: editor, compact: true, onCancel: finishEditing, onSave: finishEditing)
                        .padding(16)
                }
            } else if session.managementSection == "Add your info" {
                if session.importDraft == nil, !session.importTableMode { UpOnlyMenuScroll { UpOnlyEntryFlow(compact: true) } }
                else { UpOnlyImportView() }
            }
            else if session.managementSection == "Sources" {
                VStack(spacing: 0) {
                    if discardSources {
                        UpOnlyConfirmation(title: "Discard source changes?", confirmTitle: "Discard changes", cancelTitle: "Keep editing",
                            confirm: { sourceEditsPending = false; discardSources = false; session.managementSection = "Manage" }, cancel: { discardSources = false }).padding(16)
                    }
                    // Keep the editor mounted while confirming so Cancel preserves its draft.
                    UpOnlySources(pendingChanges: $sourceEditsPending)
                        .frame(height: discardSources ? 0 : nil).clipped()
                        .opacity(discardSources ? 0 : 1).allowsHitTesting(!discardSources).accessibilityHidden(discardSources)
                }
            }
            else {
                UpOnlyMenuScroll {
                    VStack(alignment: .leading, spacing: 16) {
                        switch session.managementSection {
                        case "Manage": navigation
                        case "Needs attention":
                            UpOnlyDataAttention(addEntry: { editor = .entry }, addRate: { editor = .exchangeRate })
                        case "Accounts":
                            if (session.document?.accounts.count ?? 0) > 1 {
                                Menu {
                                    Button("Add account") { session.startImport(.bankBalances) }
                                    Button("Update all balances") { session.startImport(.bankBalances, prefill: true) }
                                } label: { Label("Add or update", systemImage: "plus") }
                                    .modifier(UpOnlyPillMenu()).accessibilityLabel("Account actions")
                            } else {
                                Button { session.startImport(.bankBalances) } label: { Label("Add account", systemImage: "plus") }.buttonStyle(.glassProminent)
                            }
                            accounts
                        case "Portfolios":
                            Button { session.startImport(.holdings) } label: { Label("Add holding", systemImage: "plus") }.buttonStyle(.glassProminent)
                            portfolios
                        case "Precious metals": metals
                        case "Tracking": tracking
                        case "Entries":
                            entries
                        default: security
                        }
                        if let message = session.message { Text(message).fixedSize(horizontal: false, vertical: true).font(.system(size: 12)).foregroundStyle(.secondary) }
                    }.padding(16)
                }
            }
        }
        .buttonStyle(.bordered).buttonBorderShape(.capsule)
        .onAppear { entryMonth = session.entryMonthForManagement; if session.requestedRateCurrency != nil { editor = .exchangeRate } }
        .onChange(of: session.managementSection) { previous, next in
            if next == "Needs attention" || next == "Manage" { returnToReview = false }
            else if previous == "Needs attention" { returnToReview = true }
        }
        .onChange(of: session.entryMonthForManagement) { _, month in entryMonth = month; entryLimit = 100 }
        .onChange(of: session.requestedRateCurrency) { _, currency in if currency != nil { editor = .exchangeRate } }
    }
    private func shows(_ kind: TrackedKind) -> Bool { session.document?.shows(kind) == true }
    private var pageTitle: String {
        switch session.managementSection {
        case "Entries": "Transactions"
        case "Needs attention": "Review data"
        case "Portfolios": "Crypto"
        case "Add your info": session.importDraft?.mode.title ?? "Add your info"
        default: session.managementSection
        }
    }
    private func finishEditing() { editor = nil; session.requestedRateCurrency = nil }
    private var navigation: some View {
        VStack(spacing: 8) {
            navigationButton("Add your info", symbol: "plus", section: "Add your info")
            if shows(.banks) { navigationButton("Accounts", symbol: "building.columns", section: "Accounts") }
            if shows(.crypto) { navigationButton("Crypto", symbol: "bitcoinsign.circle", section: "Portfolios") }
            if shows(.metals) { navigationButton("Precious metals", symbol: "square.stack.3d.up", section: "Precious metals") }
            if shows(.cashFlow) { navigationButton("Transactions", symbol: "list.bullet.rectangle", section: "Entries") }
            Divider().padding(.vertical, 4)
            navigationButton("Tracking", symbol: "checklist", section: "Tracking")
            navigationButton("Sources", symbol: "arrow.triangle.2.circlepath", section: "Sources")
            navigationButton("Security", symbol: "lock.shield", section: "Security")

        }
    }
    private func navigationButton(_ title: String, symbol: String, section: String) -> some View {
        Button {
            if section == "Add your info", session.importDraft == nil { session.importTableMode = false }
            session.managementSection = section
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 18)
                Text(title)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }.font(.system(size: 13)).padding(10).contentShape(Rectangle())
        }.buttonStyle(UpOnlyCardButtonStyle(radius: 10)).accessibilityLabel(title)
    }
    private var tracking: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 0) {
                ForEach(TrackedKind.allCases, id: \.self) { kind in
                    HStack(spacing: 10) {
                        UpOnlySymbolBadge(symbol: kind.symbol, tint: kind.tint, size: 30)
                        Text(kind.title).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Toggle(kind.title, isOn: Binding(get: { shows(kind) }, set: { on in Task { await session.perform { $0.setTracked(kind, on) } } }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                            .disabled(session.isBusy || session.document?.hasData(kind) == true)
                            .help(session.document?.hasData(kind) == true ? "Types with saved data stay visible." : kind.title)
                    }.padding(.vertical, 10)
                    if kind != TrackedKind.allCases.last { Divider().opacity(0.5) }
                }
            }.padding(.horizontal, UpOnlyLayout.cardInset).modifier(UpOnlyContentSurface())
        }
    }
    private func setAccountOwner(_ account: Account, owner: String) {
        Task { await session.perform { doc in
            for index in doc.accounts.indices where doc.accounts[index].id == account.id || (account.externalProfileID != nil && doc.accounts[index].externalProfileID == account.externalProfileID) {
                doc.accounts[index].ownerBusinessID = owner
            }
        } }
    }
    private var accounts: some View {
        VStack(alignment: .leading, spacing: 16) {
            if session.document?.accounts.isEmpty == true {
                managementEmpty("Your accounts, together", detail: "Add a balance or import a statement to begin.", symbol: "building.columns")
            }
            ForEach(session.document?.accounts ?? []) { account in
                HStack(alignment: .top, spacing: 14) {
                    if account.profileImage != nil { UpOnlyProfileImage(data: account.profileImage, name: account.name, size: 30) }
                    else { UpOnlySymbolBadge(symbol: "building.columns.fill", size: 30) }
                    VStack(alignment: .leading, spacing: 7) {
                        Text(account.name).font(.system(size: 14, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                        if let observation = session.document?.bankBalances.filter({ $0.accountID == account.id }).max(by: { $0.observedAt < $1.observedAt }) {
                            UpOnlyPrivateText(UpOnlyFormat.currencyMoney(observation.amount.value, currency: account.currency))
                                .font(.system(size: 18, weight: .medium).monospacedDigit()).fixedSize(horizontal: false, vertical: true)
                            Text(observation.observedAt.formatted(date: .abbreviated, time: .omitted))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        } else { Text("Balance needed").font(.system(size: 12)).foregroundStyle(.secondary) }
                        if let document = session.document, let owner = AssetOwnership.businessID(for: account, in: document) {
                            Text("Owner: " + (document.businessAccounting?.first { $0.id == owner }?.name ?? "Company unavailable"))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        if session.document?.isBankTracked(account.id, at: Date()) == false {
                            Text("Outside net worth").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .trailing, spacing: 12) {
                        Menu {
                            Button("Update balance") { session.startImport(.bankBalances, prefill: true, accountID: account.id) }
                            Button("Import statement…") { session.startImport(.statements, accountID: account.id) }
                            Menu("Owner") {
                                Button("Personal") { setAccountOwner(account, owner: "") }
                                ForEach(session.document?.businessAccounting ?? []) { book in
                                    Button(book.name) { setAccountOwner(account, owner: book.id) }
                                }
                            }
                            Toggle("Include in net worth", isOn: Binding(get: { session.document?.isBankTracked(account.id, at: Date()) ?? false }, set: { tracked in
                                Task { await session.perform { $0.setBankTracked(account.id, tracked: tracked, at: Date()) } }
                            }))
                        } label: { Text("Edit") }.menuStyle(.borderedButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Options for " + account.name)
                    }
                }.padding(UpOnlyLayout.cardInset).modifier(UpOnlyContentSurface())
            }
        }
    }
    private func managementEmpty(_ title: String, detail: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            UpOnlySymbolBadge(symbol: symbol, size: 30)
            Text(title).font(.system(size: 18, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            Text(detail).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 20)
    }
    private var metals: some View {
        VStack(alignment: .leading, spacing: 16) {
            UpOnlyFlow {
                Button("Add metal") { session.startImport(.metals) }.buttonStyle(.glassProminent)
            }
            if let doc = session.document {
                ForEach(doc.portfolios.filter { !$0.isArchived && $0.kind == .metals }) { portfolio in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(portfolio.name).font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 12)
                            Menu {
                                Button("Update weights") { session.startImport(.metals, prefill: true, portfolioID: portfolio.id) }
                                Menu("Owner") {
                                    Button("Personal") { setPortfolioOwner(portfolio, owner: nil) }
                                    ForEach(doc.businessAccounting ?? []) { book in
                                        Button(book.name) { setPortfolioOwner(portfolio, owner: book.id) }
                                    }
                                }
                                Divider()
                                Button("Archive collection…", role: .destructive) { archive = portfolio }
                            } label: { Text("Edit") }
                                .menuStyle(.borderedButton).menuIndicator(.hidden).fixedSize()
                                .accessibilityLabel("Edit " + portfolio.name)
                        }
                        ForEach(doc.activeHoldings(in: portfolio.id, at: Date())) { holding in
                            Divider().opacity(0.5)
                            HStack {
                                Text(holding.assetName).fixedSize(horizontal: false, vertical: true)
                                Spacer()
                                UpOnlyPrivateText(UpOnlyFormat.quantity(doc.effectiveQuantity(holdingID: holding.id, at: Date()) ?? 0) + " g pure")
                                    .monospacedDigit().fixedSize(horizontal: false, vertical: true)
                            }.font(.system(size: 13))
                        }
                    }.padding(12).modifier(UpOnlyContentSurface())
                }
                ForEach(PreciousMetal.allCases.filter { metal in doc.holdings.contains { $0.assetID == metal.assetID && $0.isActive(at: Date()) && doc.portfolio(id: $0.portfolioID)?.isActive(at: Date()) == true } }, id: \.self) { metal in
                    DisclosureGroup(metal.name + " price history") {
                        UpOnlyMetalHistory(metal: metal, document: doc).padding(.top, 8)
                    }.font(.system(size: 12, weight: .medium))
                }
            }
        }
    }
    private func setPortfolioOwner(_ portfolio: Portfolio, owner: String?) {
        Task { await session.perform { doc in
            if let index = doc.portfolios.firstIndex(where: { $0.id == portfolio.id }) { doc.portfolios[index].ownerBusinessID = owner }
        } }
    }
    private var portfolios: some View {
        VStack(alignment: .leading, spacing: 16) {
            if session.document?.portfolios.contains(where: { !$0.isArchived && $0.kind == .crypto }) == false {
                managementEmpty("Your coins, wherever you keep them", detail: "Add a holding to start your portfolio.", symbol: "bitcoinsign.circle")
            }
            ForEach(session.document?.portfolios.filter { !$0.isArchived && $0.kind == .crypto } ?? []) { portfolio in
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text(portfolio.name).font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 12)
                        Menu {
                            Button("Add holding") { session.startImport(.holdings, portfolioID: portfolio.id) }
                            Button("Update quantities") { session.startImport(.holdings, prefill: true, portfolioID: portfolio.id) }
                            Menu("Owner") {
                                Button("Personal") { setPortfolioOwner(portfolio, owner: nil) }
                                ForEach(session.document?.businessAccounting ?? []) { book in
                                    Button(book.name) { setPortfolioOwner(portfolio, owner: book.id) }
                                }
                            }
                            Divider()
                            Button("Archive portfolio…", role: .destructive) { archive = portfolio }
                        } label: { Text("Edit") }
                            .menuStyle(.borderedButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Edit " + portfolio.name)
                    }
                    if let doc = session.document {
                        let holdings = doc.activeHoldings(in: portfolio.id, at: Date())
                        if holdings.isEmpty {
                            Button("Add a holding") { session.startImport(.holdings, portfolioID: portfolio.id) }.buttonStyle(.bordered)
                        }
                        ForEach(holdings) { holding in
                            HStack(spacing: 12) {
                                UpOnlySymbolBadge(symbol: holding.assetID.rawValue == "bitcoin" ? "bitcoinsign.circle.fill" : "circle.hexagongrid.fill", tint: UpOnlyTint.crypto, size: 32)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(holding.assetName).font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                                    UpOnlyPrivateText(UpOnlyFormat.quantity(doc.effectiveQuantity(holdingID: holding.id, at: Date()) ?? 0)).font(.system(size: 16).monospacedDigit()).fixedSize(horizontal: false, vertical: true)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                if (session.document?.portfolios.filter { !$0.isArchived && $0.kind == .crypto }.count ?? 0) > 1 {
                                    Menu {
                                        Button("Update quantity") { session.startImport(.holdings, prefill: true, holdingID: holding.id) }
                                        Button("Move") { editor = .move(holding) }
                                    } label: { Text("Edit") }
                                        .menuStyle(.borderedButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Edit " + holding.assetName)
                                } else {
                                    Button("Update") { session.startImport(.holdings, prefill: true, holdingID: holding.id) }
                                        .accessibilityLabel("Update " + holding.assetName)
                                }

                            }
                        }
                    }
                }.padding(UpOnlyLayout.cardInset).modifier(UpOnlyContentSurface())
            }
        }
    }
    private var entries: some View {
        let matching = filteredEntries
        let visible = Array(matching.prefix(entryLimit))
        let groups = Dictionary(grouping: visible, by: \.month)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search transactions", text: $entrySearch).textFieldStyle(.plain).accessibilityLabel("Search transactions")
                    .onChange(of: entrySearch) { entryLimit = 100 }
                if !entrySearch.isEmpty { Button { entrySearch = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.bordered).foregroundStyle(.secondary).accessibilityLabel("Clear search") }
                }.padding(10).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                Button { editor = .entry } label: { Label("Add", systemImage: "plus") }
                    .buttonStyle(.glassProminent).fixedSize().accessibilityLabel("Add entry")
            }
            UpOnlyFlow(spacing: 12) {
                Picker("Month", selection: $entryMonth) {
                    Text("All months").tag("")
                    ForEach(Array(Set((session.document?.entries ?? []).map(\.month) + (entryMonth.isEmpty ? [] : [entryMonth]))).sorted(by: >), id: \.self) { Text(MonthKey($0)?.title ?? $0).tag($0) }
                }.labelsHidden().fixedSize().accessibilityLabel("Filter transactions by month").onChange(of: entryMonth) { session.entryMonthForManagement = entryMonth; entryLimit = 100 }
                #if UPONLY_PERSONAL
                if session.wiseProfiles.contains(where: { profile in
                    session.document?.entries.contains(where: { $0.sourceRef?.hasPrefix("wise:" + String(profile.id) + ":") == true }) == true
                }) {
                    Picker("Profile", selection: $entryProfile) {
                        Text("All profiles").tag("")
                        ForEach(session.wiseProfiles) { Text($0.name).tag(String($0.id)) }
                    }.labelsHidden().fixedSize().accessibilityLabel("Filter transactions by profile").onChange(of: entryProfile) { entryLimit = 100 }
                }
                #endif
            }
            if matching.isEmpty {
                managementEmpty(entrySearch.isEmpty ? "No transactions here yet" : "No matching transactions", detail: entrySearch.isEmpty ? "Add an entry, import a statement, or choose another month." : "Try another description or clear your filters.", symbol: "list.bullet.rectangle")
                UpOnlyFlow {
                    if !entryMonth.isEmpty || !entryProfile.isEmpty || !entrySearch.isEmpty { Button("Clear filters") { entryMonth = ""; entryProfile = ""; entrySearch = "" }.buttonStyle(.bordered) }
                }
            } else {
                ForEach(groups.keys.sorted(by: >), id: \.self) { month in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(MonthKey(month)?.title ?? month).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                            .padding(.leading, 10).padding(.bottom, 6)
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(groups[month] ?? []) { entry in
                                transactionRow(entry)
                                if entry.id != groups[month]?.last?.id { Divider().opacity(0.5) }
                            }
                        }.padding(.horizontal, 10).padding(.vertical, 2)
                            .modifier(UpOnlyContentSurface())
                    }
                }
                if matching.count > entryLimit { Button("Show more transactions") { entryLimit += 100 }.buttonStyle(.bordered) }
            }
        }
    }
    private func transactionRow(_ entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.label).font(.system(size: 13, weight: .medium))
                        .lineLimit(2).help(entry.label)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    UpOnlyPrivateText((entry.kind == .expense ? "−" : entry.kind == .income ? "+" : "") + UpOnlyFormat.currencyMoney(entry.amount, currency: entry.currency))
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(entry.kind == .income ? UpOnlyTint.cashFlow : .primary)
                        .fixedSize(horizontal: false, vertical: true).layoutPriority(1)
                }
                HStack(spacing: 4) {
                    Text(entry.currency)
                    if entry.kind == .transfer { Text("· Transfer") }
                #if UPONLY_PERSONAL
                if entry.source == .wise, let profileID = entry.sourceRef?.split(separator: ":").dropFirst().first,
                   let profile = session.wiseProfiles.first(where: { String($0.id) == profileID }) {
                    Text("·")
                    Text(profile.name).lineLimit(1).help(profile.name)
                }
                #endif
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button {
                editingEntry = editingEntry == entry.id ? nil : entry.id
            } label: {
                Image(systemName: editingEntry == entry.id ? "checkmark" : "pencil")
                    .frame(width: 12, height: 16)
            }.buttonStyle(.bordered).controlSize(.small)
                .help(editingEntry == entry.id ? "Done editing" : "Edit transaction")
                .accessibilityLabel("Edit " + entry.label)
                .accessibilityValue(editingEntry == entry.id ? "Editing" : "")
        }
        if editingEntry == entry.id {
            Picker("Transaction type", selection: Binding(get: { entry.kind }, set: { reclassify(entry, as: $0) })) {
                Text("Income").tag(EntryKind.income)
                Text("Spending").tag(EntryKind.expense)
                Text("Transfer").tag(EntryKind.transfer)
            }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("Transaction type")
            if entry.source != .wise {
                Button("Remove entry…", role: .destructive) { entryToRemove = entry }
            }
        }
        }.padding(.vertical, 6)
    }
    private func reclassify(_ entry: Entry, as kind: EntryKind) {
        Task { await session.perform { doc in
            if let index = doc.entries.firstIndex(where: { $0.id == entry.id }) { doc.entries[index].kind = kind; doc.entries[index].kindIsUserEdited = true }
        } }
    }
    private var filteredEntries: [Entry] {
        (session.document?.entries ?? []).filter { entry in
            (entryMonth.isEmpty || entry.month == entryMonth)
                && (entrySearch.isEmpty || entry.label.localizedCaseInsensitiveContains(entrySearch))
                && (entryProfile.isEmpty || entry.sourceRef?.hasPrefix("wise:" + entryProfile + ":") == true)
        }.sorted { $0.month == $1.month ? $0.id.uuidString < $1.id.uuidString : $0.month > $1.month }
    }
    private var security: some View {
        VStack(alignment: .leading, spacing: 16) {
            UpOnlySettingsCard(title: "App lock", subtitle: "", symbol: "lock.shield.fill") {
                Label("Unlock with Touch ID or your Mac password", systemImage: "touchid")
                    .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                Text("Locks after five minutes of inactivity, or when your Mac locks or sleeps.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button { session.lockAndAuthenticate() } label: { Label("Lock now", systemImage: "lock") }
            }
            UpOnlySettingsCard(title: "Backup and recovery", subtitle: "", symbol: "externaldrive.fill", tint: UpOnlyTint.cashFlow) {
                Text("Keep your recovery code separately. You’ll need it to restore a backup.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button { Task { await session.exportBackup() } } label: { Label("Export encrypted backup…", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.glassProminent)
            }
        }
    }
}

private struct UpOnlyDataAttention: View {
    @Environment(UpOnlySession.self) private var session
    var addEntry: () -> Void
    var addRate: () -> Void
    @State private var reviewMonth = ""
    private var report: DataAttention {
        guard let document = session.document else { return DataAttention() }
        return session.monthModel?.attention(in: document, includePerformance: session.attentionIncludesPerformance || session.destination == 0) ?? DataAttention()
    }
    private var month: MonthKey {
        MonthKey(reviewMonth) ?? report.spendingMonths.last ?? session.monthModel?.month ?? .current()
    }
    private var hasBankStatus: Bool {
        #if UPONLY_PERSONAL
        return session.document?.settings.automaticWise == true && (session.wiseError != nil || session.backgroundIssues.contains("Bank balances"))
        #else
        return false
        #endif
    }
    private var hasAccountingStatus: Bool {
        #if UPONLY_PERSONAL
        return session.accountingError != nil || session.backgroundIssues.contains { $0 == "Accounting" || $0.hasSuffix(" accounting") }
        #else
        return false
        #endif
    }
    private var hasPriceStatus: Bool {
        session.backgroundIssues.contains { $0 != "Bank balances" && $0 != "Accounting" && !$0.hasSuffix(" accounting") }
    }
    var body: some View {
        let attention = report
        VStack(alignment: .leading, spacing: 16) {
            Group {
                #if UPONLY_PERSONAL
                if hasBankStatus {
                    attentionCard("Wise", symbol: "arrow.triangle.2.circlepath") {
                        note(session.wiseError ?? "Wise could not refresh. Your saved balances and transactions are still available.")
                        Button("Retry Wise") { Task { await session.refreshWise() } }.disabled(session.isBusy || session.wiseRefreshing)
                    }
                }
                if hasAccountingStatus {
                    attentionCard("Accounting", symbol: "doc.text") {
                        note(session.accountingError ?? "Accounting could not refresh. Your saved results are still available.")
                        Button("Retry accounting") { Task { await session.refreshAccounting() } }.disabled(session.isBusy || session.accountingRefreshing)
                    }
                }
                #endif
                if attention.count == 0 && !hasBankStatus && !hasAccountingStatus && !hasPriceStatus {
                    Label("Nothing to review", systemImage: "checkmark.circle").font(.headline)
                }
                if !attention.spendingMonths.isEmpty {
                    attentionCard("Income & spending", symbol: "checklist") {
                        spendingReview
                    }
                }
                if !attention.balances.isEmpty {
                    attentionCard("Balances needed", symbol: "building.columns") {
                        ForEach(attention.balances) { account in
                            Button { session.startImport(.bankBalances, prefill: true, accountID: account.id) } label: {
                                Label(account.name, systemImage: "plus").fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                if !attention.quantities.isEmpty {
                    attentionCard("Holdings need quantities", symbol: "square.stack.3d.up") {
                        ForEach(attention.quantities) { holding in
                            Button(holding.assetName) {
                                let metals = session.document?.portfolio(id: holding.portfolioID)?.kind == .metals
                                session.startImport(metals ? .metals : .holdings, prefill: true, holdingID: holding.id)
                            }
                        }
                    }
                }
                if attention.pricesNeeded || !attention.accountingNames.isEmpty || hasPriceStatus {
                    attentionCard("Sources need attention", symbol: "arrow.triangle.2.circlepath") {
                        if hasPriceStatus { note("A background source could not refresh. Your saved values are still available.") }
                        if attention.pricesNeeded { note("Some prices or exchange rates are missing.") }
                        if !attention.accountingNames.isEmpty { note(attention.accountingNames.joined(separator: ", ") + ": accounting is incomplete for this period.") }
                        Button("Review sources") { session.managementSection = "Sources" }
                    }
                }
            }
        }.controlSize(.regular)
            .onAppear {
                if reviewMonth.isEmpty {
                    reviewMonth = attention.spendingMonths.first { $0.description == session.entryMonthForManagement }?.description
                        ?? (attention.spendingMonths.last ?? session.monthModel?.month ?? .current()).description
                }
            }
            .onChange(of: reviewMonth) { session.entryMonthForManagement = month.description }
    }
    private var spendingReview: some View {
        VStack(alignment: .leading, spacing: 14) {
            if report.spendingMonths.count > 1 {
                Menu(month.title) {
                    ForEach(report.spendingMonths.reversed(), id: \.self) { item in
                        Button(item.title) { reviewMonth = item.description }
                    }
                }.modifier(UpOnlyPillMenu()).fixedSize().accessibilityLabel("Month to review")
            } else { Text(month.title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary) }
            if let doc = session.document, let totals = MonthlyLedger.personal(month, document: doc).totals {
                HStack(spacing: 16) {
                    reviewTotal("Income", value: totals.moneyIn)
                    reviewTotal("Spending", value: totals.moneyOut)
                }
            }
            HStack(spacing: 8) {
                Button("Transactions") { session.entryMonthForManagement = month.description; session.managementSection = "Entries" }
                Menu("Add missing") {
                    Button("Import statements…") { session.startImport(.statements) }
                    Button("Add entry") { session.entryMonthForManagement = month.description; addEntry() }
                }.menuStyle(.borderedButton).fixedSize()
            }
            if let doc = session.document {
                let state = MonthlyLedger.personal(month, document: doc)
                if case .exchangeRates(let currencies)? = state.unavailable {
                    note("A dated " + currencies.joined(separator: ", ") + " exchange rate is also needed.")
                    Menu("Exchange rates") {
                        Button("Get exchange rates") {
                            Task { await session.repairExchangeRates(month: month, currencies: currencies) }
                        }.disabled(session.refreshing || session.isBusy)
                        Button("Add exchange rate") {
                            session.entryMonthForManagement = month.description
                            session.requestedRateCurrency = currencies.first
                            addRate()
                        }
                    }.menuStyle(.borderedButton).fixedSize()

                }
                if month == .current() { note("Review this month after it ends.") }
                else if state.totals == nil { note("Add the missing entries or rates before marking this month complete.") }
                else if doc.reviewedMonths.contains(month.description) {
                    Label("Month reviewed", systemImage: "checkmark.circle").font(.headline)
                } else {
                    note("All personal accounts included?")
                    Button("Mark month complete") {
                        let selected = month.description
                        Task {
                            await session.perform { doc in
                                if !doc.reviewedMonths.contains(selected) { doc.reviewedMonths.append(selected) }
                            }
                            if session.document?.reviewedMonths.contains(selected) == true, let next = report.spendingMonths.last {
                                reviewMonth = next.description
                            }
                        }
                    }.buttonStyle(.glassProminent).disabled(session.isBusy)
                }
            }
        }
    }
    private func reviewTotal(_ title: String, value: Decimal) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            UpOnlyPrivateText(UpOnlyFormat.exactMoney(value)).font(.system(size: 14, weight: .medium)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    private func attentionCard<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.headline)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct UpOnlyEditSheet: View {
    @Environment(UpOnlySession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let editor: UpOnlyEditor
    var compact = false
    var onCancel: (() -> Void)?
    var onSave: (() -> Void)?
    @State private var ownerBusinessID: String?
    @State private var name = ""
    @State private var currency = "USD"
    @State private var amount = ""
    @State private var date = Date()
    @State private var asset = ""
    @State private var destination: UUID?
    @State private var entryMonth = MonthKey.current().description
    @State private var kind = "expense"
    @State private var bucket = "personal"
    @State private var error: String?
    @State private var saving = false
    private var actionTitle: String {
        switch editor {
        case .entry: "Save entry"
        case .exchangeRate: "Save rate"
        case .move: "Move holding"
        case .portfolio: "Create portfolio"
        case .account, .balance: "Save balance"
        case .holding, .quantity: "Save holding"
        }
    }
    private var editingMonth: Binding<MonthKey> { Binding(get: { MonthKey(entryMonth) ?? .current() }, set: { entryMonth = $0.description }) }
    private func field(_ title: String, text: Binding<String>, placeholder: String = "") -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            TextField(placeholder.isEmpty ? title : placeholder, text: text, axis: .vertical).textFieldStyle(.plain).font(.system(size: 15))
                .accessibilityLabel(title).padding(.vertical, 8)
                .overlay(alignment: .bottom) { Rectangle().fill(.primary.opacity(0.14)).frame(height: 1) }
        }
    }
    private var amountField: some View {
        UpOnlyValueField("0.00", text: $amount).textFieldStyle(.plain)
            .font(.system(size: 34, weight: .medium).monospacedDigit()).accessibilityLabel("Amount")
            .padding(.vertical, 6)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if !session.managementInMenu { HStack { Text(editor.title).font(.system(size: 20, weight: .semibold)).fixedSize(horizontal: false, vertical: true); Spacer() } }
            VStack(alignment: .leading, spacing: 16) {
                switch editor {
                case .portfolio:
                    field("Portfolio name", text: $name, placeholder: "Ledger or Coinbase")
                    UpOnlyOwnerPicker(owner: $ownerBusinessID)
                case .account:
                    field("Account name", text: $name)
                    field("Currency", text: $currency)
                    amountField
                    HStack { Text("As of").foregroundStyle(.secondary); Spacer(); UpOnlyDateButton(date: $date) }
                case .balance(let account):
                    Text(account.name).font(.headline).fixedSize(horizontal: false, vertical: true)
                    Text(account.currency).font(.caption).foregroundStyle(.secondary)
                    amountField
                    HStack { Text("As of").foregroundStyle(.secondary); Spacer(); UpOnlyDateButton(date: $date) }
                case .holding:
                    field("CoinGecko ID", text: $asset, placeholder: "bitcoin")
                    field("Display name", text: $name, placeholder: "Bitcoin")
                    amountField
                case .quantity(let holding):
                    Text(holding.assetName).font(.headline).fixedSize(horizontal: false, vertical: true)
                    Text("New total quantity").font(.caption).foregroundStyle(.secondary)
                    amountField
                case .move(let holding):
                    Text(holding.assetName).font(.headline).fixedSize(horizontal: false, vertical: true)
                    UpOnlyPrivateText("Available: " + UpOnlyFormat.quantity(session.document?.effectiveQuantity(holdingID: holding.id, at: Date()) ?? 0)).font(.system(size: 12)).foregroundStyle(.secondary)
                    amountField
                    let choices = session.document?.portfolios.filter { !$0.isArchived && $0.id != holding.portfolioID && $0.kind == .crypto } ?? []
                    if choices.isEmpty {
                        Text("Create another portfolio before moving this holding.").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Picker("Move to", selection: $destination) {
                            Text("Choose portfolio").tag(Optional<UUID>.none)
                            ForEach(choices) { Text($0.name).tag(Optional($0.id)) }
                        }.accessibilityLabel("Destination portfolio")
                    }
                case .exchangeRate:
                    field("From currency", text: $currency, placeholder: "GBP")
                    Text("USD for 1 " + currency.uppercased()).font(.system(size: 12)).foregroundStyle(.secondary)
                    amountField
                    HStack { Text("Rate date").foregroundStyle(.secondary); Spacer(); UpOnlyDateButton(date: $date) }
                case .entry:
                    Picker("Type", selection: $kind) { Text("Spending").tag("expense"); Text("Income").tag("income"); Text("Transfer").tag("transfer") }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("Entry type")
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        amountField
                        TextField("USD", text: $currency).textFieldStyle(.plain).font(.system(size: 14, weight: .medium)).frame(width: 50).accessibilityLabel("Currency")
                    }
                    field("Description", text: $name, placeholder: "What was it for?")
                    UpOnlyMonthPicker(month: editingMonth)
                    Picker("Category", selection: $bucket) { Text("Personal").tag("personal"); Text("Business").tag("otherBusiness"); Text("Business cost").tag("businessCost") }
                }
            }.disabled(saving || session.isBusy)
            if let error { Label(error, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 12) {
                if !session.managementInMenu || !compact || session.managementSection == "Add your info" {
                    Button("Cancel") { if let onCancel { onCancel() } else { dismiss() } }.keyboardShortcut(.cancelAction).disabled(saving || session.isBusy)
                }
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button(saving ? "Saving…" : actionTitle) { Task { await save() } }
                    .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction).disabled(saving || session.isBusy)
            }.buttonBorderShape(.capsule).controlSize(.large)
        }.padding(compact ? 0 : 28).frame(width: compact ? nil : 420).fixedSize(horizontal: false, vertical: true)
            .background(Color(nsColor: .windowBackgroundColor))
            .interactiveDismissDisabled(saving || session.isBusy)
        .onAppear {
            if case .quantity(let h) = editor { amount = session.document?.effectiveQuantity(holdingID: h.id, at: Date()).map(UpOnlyFormat.quantity) ?? "" }
            if case .entry = editor, session.managementInMenu, !session.entryMonthForManagement.isEmpty { entryMonth = session.entryMonthForManagement }
            if case .exchangeRate = editor {
                currency = session.requestedRateCurrency ?? "GBP"
                if let start = try? ImportDateFormat.iso.date(session.entryMonthForManagement + "-01") {
                    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = UTCDay.timeZone
                    if let end = calendar.date(byAdding: .month, value: 1, to: start) { date = min(Date(), end.addingTimeInterval(-1)) }
                }
            }
        }
    }
    private func validName(_ value: String, title: String) throws -> String {
        do { return try UpOnlySession.name(value) } catch { throw ImportFailure("Enter a \(title.lowercased()) of 1–100 characters.") }
    }
    private func validAmount(nonnegative: Bool = true, positive: Bool = false) throws -> Decimal {
        guard let value = try? MoneyInput.parseExact(amount) else { throw ImportFailure("Enter a number without a currency symbol, such as 125.50.") }
        if positive && value <= 0 { throw ImportFailure("Enter a rate greater than zero.") }
        if nonnegative && value < 0 { throw ImportFailure("Enter zero or a positive amount.") }
        return value
    }
    private func validCurrency() throws -> String {
        guard let value = try? MoneyInput.normalizeCurrency(currency) else { throw ImportFailure("Enter a three-letter currency code, such as GBP.") }
        return value
    }
    private func save() async {
        saving = true; error = nil
        defer { saving = false }
        do {
            switch editor {
            case .portfolio:
                let clean = try validName(name, title: "portfolio name")
                guard session.document?.portfolios.contains(where: { !$0.isArchived && $0.name.caseInsensitiveCompare(clean) == .orderedSame }) != true else { throw ImportFailure("A portfolio with this name already exists. Choose another name.") }
                try await session.addPortfolio(name: clean, ownerBusinessID: ownerBusinessID)
            case .account:
                _ = try validName(name, title: "account name"); _ = try validCurrency(); _ = try validAmount(nonnegative: false)
                try await session.addAccount(name: name, currency: currency, balance: amount, date: date)
            case .balance(let account):
                _ = try validAmount(nonnegative: false)
                try await session.updateBalance(account: account, text: amount, date: date)
            case .holding(let portfolio):
                let quantity = try validAmount()
                let canonical = try CanonicalAssetID(asset)
                let title = try UpOnlySession.name(name.isEmpty ? asset : name)
                try await session.mutate { doc in doc = try HoldingMutations.addHolding(portfolioID: portfolio, assetID: canonical, assetName: title, quantity: quantity, at: Date(), document: doc) }
            case .quantity(let holding):
                let quantity = try validAmount()
                try await session.mutate { doc in doc = try HoldingMutations.setQuantity(holdingID: holding.id, quantity: quantity, at: Date(), document: doc) }
            case .move(let holding):
                guard let destination else { throw ImportFailure("Choose a destination portfolio.") }
                let quantity = try validAmount()
                guard quantity > 0, quantity <= (session.document?.effectiveQuantity(holdingID: holding.id, at: Date()) ?? 0) else { throw ImportFailure("Enter an amount greater than zero and no more than your available quantity.") }
                try await session.mutate { doc in doc = try HoldingMutations.moveHolding(assetID: holding.assetID, quantity: quantity, from: holding.portfolioID, to: destination, at: Date(), document: doc) }
            case .exchangeRate:
                let code = try validCurrency()
                guard code != "USD" else { throw ImportFailure("Choose the currency you’re converting to USD, such as GBP.") }
                let value = try validAmount(positive: true)
                try await session.mutate { $0.fx.append(FXObservation(sourceCurrency: code, targetCurrency: "USD", rate: PreciseDecimal(value), providerTime: date, fetchedAt: Date(), provider: "Manual")) }
            case .entry:
                let label = try validName(name, title: "description")
                guard let month = MonthKey(entryMonth), month <= .current(), month.year >= 1900,
                      let entryKind = EntryKind(rawValue: kind), let entryBucket = Bucket(rawValue: bucket) else { throw VaultError.invalidAmount }
                let value = try validAmount()
                let code = try validCurrency()
                try await session.mutate { doc in doc.entries.append(Entry(month: month, bucket: entryBucket, kind: entryKind, amount: value, currency: code, label: label, source: .manual)); doc.track(.cashFlow) }
            }
            if let onSave { onSave() } else { dismiss() }
        } catch { self.error = (error as? ImportFailure)?.text ?? (error as? VaultError)?.errorDescription ?? "Couldn’t save this change. Your previous data is safe. Try again." }
    }
}

private struct UpOnlyMetalHistory: View {
    var metal: PreciousMetal
    var document: VaultDocument
    @State private var days = 90
    private var observations: [QuoteObservation] { document.quotes.filter { $0.assetID == metal.assetID }.sorted { $0.providerTime < $1.providerTime } }
    private var points: [UpOnlyChartPoint] {
        guard let first = observations.first else { return [] }
        let end = UTCDay.start(of: Date())
        let start = max(UTCDay.start(of: first.providerTime), days == 0 ? UTCDay.start(of: first.providerTime) : end.addingTimeInterval(-Double(days - 1) * 86400))
        let daily = Dictionary(grouping: observations, by: { UTCDay.start(of: $0.providerTime) })
        return stride(from: start.timeIntervalSince1970, through: end.timeIntervalSince1970, by: 86400).map { timestamp in
            let date = Date(timeIntervalSince1970: timestamp), label = ImportDateFormat.today(date)
            let quote = daily[date]?.last
            let value = quote.flatMap { try? MoneyInput.multiply($0.priceUSD.value, PreciousMetal.gramsPerTroyOunce) }
            return UpOnlyChartPoint(id: label, label: label, value: value)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("USD per troy ounce").font(.system(size: 11)).foregroundStyle(.secondary)
            Picker("Period", selection: $days) { Text("1 month").tag(30); Text("3 months").tag(90); Text("1 year").tag(365); Text("All").tag(0) }
                .pickerStyle(.segmented).labelsHidden().accessibilityLabel("Metal chart period")
            if let quote = observations.last, let price = try? MoneyInput.multiply(quote.priceUSD.value, PreciousMetal.gramsPerTroyOunce) {
                UpOnlyPrivateText(UpOnlyFormat.money(price)).font(.system(size: 24, weight: .medium).monospacedDigit()).fixedSize(horizontal: false, vertical: true)
                Text(quote.provider + " · " + quote.providerTime.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if points.contains(where: { $0.value != nil }) {
                UpOnlyChart(points: points, tint: UpOnlyTint.metals)
            } else {
                Text("Price history will appear here after the first update.").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct UpOnlyOwnerPicker: View {
    @Environment(UpOnlySession.self) private var session
    @Binding var owner: String?
    var body: some View {
        if !(session.document?.businessAccounting ?? []).isEmpty || owner != nil {
            Picker("Owner", selection: $owner) {
                Text("Personal").tag(Optional<String>.none)
                ForEach(session.document?.businessAccounting ?? []) { book in Text(book.name).tag(Optional(book.id)) }
                if let owner, !(session.document?.businessAccounting ?? []).contains(where: { $0.id == owner }) {
                    Text("Company unavailable").tag(Optional(owner))
                }
            }.pickerStyle(.menu).font(.system(size: 12)).accessibilityLabel("Asset owner")
        }
    }
}
