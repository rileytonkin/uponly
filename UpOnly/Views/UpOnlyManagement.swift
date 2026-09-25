import SwiftUI

// Pages share the menu's width and grow only as far as the available menu height.
// Longer forms scroll vertically; they never become a separate app window.
struct UpOnlyMenuScroll<Content: View>: View {
    @State var contentHeight: CGFloat = 360
    /// The tallest it grows before scrolling: given, else the page's room (Manage pages share the dashboard's height).
    var maxHeight: CGFloat? = nil
    @ViewBuilder var content: () -> Content
    @Environment(\.upOnlyScrollHeight) private var pageHeight
    var body: some View {
        let maxHeight = self.maxHeight ?? pageHeight
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

extension EnvironmentValues {
    /// How tall a page's scrolling area may grow: set by the menu so Manage pages match the dashboard's height.
    @Entry var upOnlyScrollHeight: CGFloat = 540
}

enum UpOnlyEditor: Identifiable {
    case move(Holding), entry, editEntry(Entry), exchangeRate
    case renameAccount(Account), renamePortfolio(Portfolio), purchases(Holding)
    var id: String {
        switch self {
        case .purchases(let h): "purchases-" + h.id.uuidString
        case .renameAccount(let a): "rename-account-" + a.id.uuidString
        case .renamePortfolio(let p): "rename-portfolio-" + p.id.uuidString
        case .move(let h): "move-" + h.id.uuidString
        case .entry: "entry"
        case .editEntry(let e): "edit-entry-" + e.id.uuidString
        case .exchangeRate: "rate"
        }
    }
    var title: String {
        switch self {
        case .move: "Move coins"
        case .entry: "New transaction"
        case .editEntry: "Edit transaction"
        case .exchangeRate: "Add exchange rate"
        case .renameAccount: "Rename account"
        case .renamePortfolio: "Rename portfolio"
        case .purchases(let h): h.assetName + " purchases"
        }
    }
}

struct UpOnlyManagement: View {
    @Environment(UpOnlySession.self) var session
    /// Synced profiles opened to show their currencies on Manage → Accounts.
    @State var expandedProfiles: Set<String> = []
    @State var sourceEditsPending = false
    @State var discardSources = false
    @State var discardingImport = false
    /// The import's rows when it opened, so Back only asks before throwing away something the user entered.
    @State var importBaseline: [ImportRowContent] = []
    @State var editor: UpOnlyEditor?
    /// The editor was opened by a link from the overview, so finishing it goes straight back there.
    @State var editorReturnsHome = false
    @State var archive: Portfolio?
    @State var entryToRemove: Entry?
    @State var editingEntry: UUID?
    @State var returnToReview = false
    /// The section Manage opened on. Links from the overview land on a section; Back from it returns to the overview.
    @State var origin = ""
    @State var configured = false
    @State var reviewSelection = ""
    @State var entrySearch = ""
    @State var entryMonth = ""
    @State var entryProfile = ""
    @State var entryAccount = ""
    @State var diagnosticsMessage: String?
    @State var entryLimit = 100
    /// A page opened from Backup & security; Back returns to it.
    @State var securityPage: SecurityPage?
    /// The new code survives Back, so stepping back and forward never silently swaps it.
    @State var newRecoveryCode: RecoveryCode?
    @State var savedNewCode = false
    @State var restoreCode = ""
    @State var confirmingRestore = false
    enum SecurityPage {
        case recoveryCode, restore
        var title: String { self == .recoveryCode ? "New recovery code" : "Restore from a backup" }
    }
    var hasGuidedHeader: Bool {
        guard editor == nil, session.managementSection == "Add your info" else { return false }
        if session.entryEditorInMenu { return true }
        guard let draft = session.importDraft else { return false }
        return draft.mode != .statements && draft.rows.count <= 1 && draft.sources.allSatisfy { $0.grid.isEmpty } && !session.importTableMode
    }
    var body: some View {
        let review = attention
        let month = review.flatMap { selectedMonth($0.months) }
        VStack(spacing: 0) {
            if !hasGuidedHeader {
                UpOnlyPageHeader(title: editor?.title ?? pageTitle(month), backLabel: backLabel, backTitle: backTitle, back: back,
                                 subtitle: editor == nil && month != nil ? "Is this month complete?" : nil,
                                 trailing: editor == nil ? monthMenu(review?.months ?? [], current: month) ?? sectionActions : nil)
                    .padding(.horizontal, UpOnlyLayout.inset).padding(.top, 14).padding(.bottom, 12)
            }
            if let portfolio = archive {
                UpOnlyConfirmation(title: "Archive " + portfolio.name + "?", detail: "It leaves net worth and this page, and its history is kept. You can restore it from Archived at the bottom of the page.", confirmTitle: "Archive portfolio",
                    confirm: { Task { await session.perform { doc in doc = try HoldingMutations.archivePortfolio(id: portfolio.id, at: Date(), document: doc) } }; archive = nil }, cancel: { archive = nil }).padding(UpOnlyLayout.inset)
            } else if let entry = entryToRemove {
                UpOnlyConfirmation(title: "Remove this transaction?", detail: entry.source == .csv ? "This can’t be undone. Importing the same statement again won’t bring it back." : "This can’t be undone.", confirmTitle: "Remove transaction",
                    confirm: { Task { await session.perform { $0.entries.removeAll { $0.id == entry.id } } }; entryToRemove = nil }, cancel: { entryToRemove = nil }).padding(UpOnlyLayout.inset)
            } else if confirmingRestore {
                UpOnlyConfirmation(title: "Replace everything in Up Only with this backup?",
                                   detail: "Your current vault is moved to a folder named “\(session.layout.replacedName(at: Date()))” next to it, not deleted.",
                                   confirmTitle: "Replace with backup",
                    confirm: { Task { await restoreFromBackup(confirmed: true) } }, cancel: { cancelRestore() }).padding(UpOnlyLayout.inset)
            } else if let editor {
                UpOnlyMenuScroll {
                    UpOnlyEditSheet(editor: editor, onCancel: finishEditing, onSave: finishEditing).id(editor.id)
                        .padding(.horizontal, UpOnlyLayout.inset).padding(.bottom, UpOnlyLayout.inset)
                }
            } else if session.managementSection == "Add your info" {
                VStack(spacing: 0) {
                    if discardingImport {
                        UpOnlyConfirmation(title: "Discard this import?", detail: "Nothing from it has been saved yet.", confirmTitle: "Discard import", cancelTitle: "Keep editing",
                            confirm: { leaveImport(confirmed: true) }, cancel: { discardingImport = false }).padding(UpOnlyLayout.inset)
                    }
                    Group {
                        if session.importDraft == nil, !session.importTableMode { UpOnlyMenuScroll { UpOnlyEntryFlow() } }
                        else { UpOnlyImportView() }
                    }.modifier(UpOnlyHiddenWhile(hidden: discardingImport))
                }
            }
            else if session.managementSection == "Sources" {
                VStack(spacing: 0) {
                    if discardSources {
                        UpOnlyConfirmation(title: "Discard source changes?", confirmTitle: "Discard changes", cancelTitle: "Keep editing",
                            confirm: { sourceEditsPending = false; discardSources = false; leaveSection() }, cancel: { discardSources = false }).padding(UpOnlyLayout.inset)
                    }
                    // Keep the editor mounted while confirming so Cancel preserves its draft.
                    UpOnlySources(pendingChanges: $sourceEditsPending).modifier(UpOnlyHiddenWhile(hidden: discardSources))
                }
            }
            else {
                UpOnlyMenuScroll {
                    VStack(alignment: .leading, spacing: 16) {
                        if let message = session.message { Text(message).fixedSize(horizontal: false, vertical: true).font(UpOnlyType.body).foregroundStyle(.secondary) }
                        if session.historyRebuilding {
                            Label("Updating past values…", systemImage: "clock.arrow.circlepath").font(UpOnlyType.caption).foregroundStyle(.secondary)
                        }
                        switch session.managementSection {
                        case "Manage": navigation
                        case "Needs attention":
                            if let review {
                                UpOnlyDataAttention(report: review.report, months: review.months, month: month, selection: $reviewSelection,
                                                    addEntry: { editor = .entry }, addRate: { editor = .exchangeRate })
                            }
                        case "Accounts": accounts
                        case "Portfolios": holdings(.crypto)
                        case "Precious metals": holdings(.metals)
                        case "Entries": entries
                        default: security
                        }
                    }.padding(.horizontal, UpOnlyLayout.inset).padding(.bottom, UpOnlyLayout.inset)
                }
            }
        }
        .buttonStyle(.bordered).buttonBorderShape(.capsule)
        .onAppear {
            // Reopening the menu shows this page again without recreating it; keep where it came from and the import's baseline.
            guard !configured else { return }
            configured = true
            origin = session.managementSection
            session.message = nil
            importBaseline = session.importDraft?.rows.map(\.content) ?? []
            if origin == "Entries" { entryMonth = session.entryMonthForManagement }
            if session.requestedRateCurrency != nil { editor = .exchangeRate; editorReturnsHome = true }
            #if UPONLY_FIXTURE
            // Opens one of the smaller editors directly, for checking its layout.
            if let doc = session.document, let crypto = doc.holdings.first(where: { PreciousMetal.asset($0.assetID) == nil }) {
                switch ProcessInfo.processInfo.environment["UPONLY_PREVIEW_EDITOR"] {
                case "move": editor = .move(crypto)
                case "purchases": editor = .purchases(crypto)
                case "rate": editor = .exchangeRate
                case "rename-account": if let account = doc.accounts.first { editor = .renameAccount(account) }
                case "rename-portfolio": if let portfolio = doc.portfolios.first { editor = .renamePortfolio(portfolio) }
                default: break
                }
            }
            #endif
        }
        .onChange(of: session.managementSection) { previous, next in
            // A message belongs to the page it was shown on. Leaving for the overview keeps it (an import that returns home).
            if session.managementInMenu { session.message = nil }
            if securityPage != nil { closeSecurityPage() }
            if next == "Needs attention" || next == "Manage" { returnToReview = false }
            else if previous == "Needs attention" { returnToReview = true }
            // Arriving on Transactions shows the month a link or Edit all asked for, else the last one chosen there.
            if next == "Entries" { entryMonth = session.entryMonthForManagement; entryLimit = 100 }
        }
        .onChange(of: session.importDraft?.id) { importBaseline = session.importDraft?.rows.map(\.content) ?? [] }
        // Esc is Back here, a step at a time.
        .onChange(of: session.backRequests) { if session.managementInMenu { back() } }
        .onChange(of: session.requestedRateCurrency) { _, currency in if currency != nil { editor = .exchangeRate } }
    }
    /// Needs attention's report and the closed months still to check, oldest first.
    var attention: (report: DataAttention, months: [MonthKey])? {
        guard session.managementSection == "Needs attention", let document = session.document, let model = session.monthModel else { return nil }
        let report = model.attention(in: document)
        let current = MonthKey.current(), reviewed = Set(document.reviewedMonths)
        // The open month is checked once it ends. A month confirmed as having nothing to record is done.
        let months = report.spendingMonths.filter { month in
            month < current && !(reviewed.contains(month.description) && MonthlyLedger.personal(month, document: document).unavailable == .noEntries)
        }
        return (report, months)
    }
    /// The month chosen in the header menu, else the latest one still to check.
    func selectedMonth(_ months: [MonthKey]) -> MonthKey? { months.first { $0.description == reviewSelection } ?? months.last }
    func monthMenu(_ months: [MonthKey], current: MonthKey?) -> AnyView? {
        guard months.count > 1, let current else { return nil }
        return AnyView(Menu {
            ForEach(months.reversed(), id: \.self) { item in
                Toggle(item.title, isOn: Binding(get: { item == current }, set: { _ in reviewSelection = item.description }))
            }
        } label: {
            Text("\(months.count) months").font(UpOnlyType.caption.weight(.semibold))
        }.modifier(UpOnlyPillMenu()).fixedSize().accessibilityLabel("Choose a month to check"))
    }
    func pageTitle(_ month: MonthKey?) -> String {
        if let month { return month.title }
        if session.managementSection == "Add your info", let mode = session.importDraft?.mode { return mode.isHolding ? mode.kind.title : mode.title }
        if session.managementSection == "Security", let securityPage { return securityPage.title }
        return sectionTitle(session.managementSection)
    }
    func sectionTitle(_ section: String) -> String {
        switch section {
        case "Entries": "Transactions"
        case "Portfolios": "Crypto"
        case "Precious metals": "Metals"
        case "Sources": "Data sources"
        case "Security": "Backup & security"
        case "Add your info": "Add"
        default: section
        }
    }
    var backTitle: String {
        if case .purchases? = editor { return "Done" }
        return editor == nil ? "Back" : "Cancel"
    }
    var backLabel: String {
        if editor != nil { return backTitle }
        if securityPage != nil { return "Back to Backup & security" }
        let section = session.managementSection
        if section == "Add your info" {
            if session.importReturnsHome || origin == section { return "Back to overview" }
            return session.importDraft == nil ? "Back to Manage" : "Back to " + sectionTitle(session.importReturnSection)
        }
        if section == "Manage" || section == "Needs attention" || section == origin { return "Back to overview" }
        return returnToReview ? "Back to Needs attention" : "Back to Manage"
    }
    func back() {
        if discardSources { discardSources = false }
        else if discardingImport { discardingImport = false }
        else if archive != nil { archive = nil }
        else if entryToRemove != nil { entryToRemove = nil }
        else if confirmingRestore { cancelRestore() }
        else if securityPage != nil { session.message = nil; closeSecurityPage() }
        else if editor != nil { finishEditing() }
        else if session.managementSection == "Sources", sourceEditsPending { discardSources = true }
        else if session.managementSection == "Add your info" { leaveImport() }
        else { leaveSection() }
    }
    /// Back from an import discards it, asking first if anything was entered, and returns to where it started.
    func leaveImport(confirmed: Bool = false) {
        if !confirmed, let draft = session.importDraft, draft.rows.map(\.content) != importBaseline { discardingImport = true; return }
        discardingImport = false
        let hadDraft = session.importDraft != nil, home = session.importReturnsHome || origin == "Add your info"
        session.discardImport()
        if home { leaveManage() } else if !hadDraft { session.managementSection = "Manage" }
    }
    func leaveSection() {
        let section = session.managementSection
        if section == "Manage" || section == "Needs attention" || section == origin { leaveManage() }
        else { session.managementSection = returnToReview ? "Needs attention" : "Manage" }
    }
    func leaveManage() {
        session.entryMonthForManagement = ""; session.message = nil; session.managementInMenu = false
    }
    func finishEditing() {
        editor = nil; session.requestedRateCurrency = nil
        if editorReturnsHome { editorReturnsHome = false; leaveManage() }
    }
    /// Manage's first page, in the home list's style: what you've recorded in one card, how it's kept in another,
    /// each row saying what's inside.
    var navigation: some View {
        let doc = session.document
        let crypto = hasData(.crypto) || hasArchived(.crypto), metals = hasData(.metals) || hasArchived(.metals)
        var records: [(title: String, caption: String, symbol: String, tint: Color, section: String)] = []
        if hasData(.banks) { records.append(("Accounts", count(doc?.accounts.count ?? 0, "account"), TrackedKind.banks.symbol, UpOnlyTint.netWorth, "Accounts")) }
        if crypto { records.append(("Crypto", holdingsSummary(.crypto), TrackedKind.crypto.symbol, UpOnlyTint.crypto, "Portfolios")) }
        if metals { records.append(("Metals", holdingsSummary(.metals), TrackedKind.metals.symbol, UpOnlyTint.metals, "Precious metals")) }
        if hasData(.cashFlow) { records.append(("Transactions", count(doc?.entries.count ?? 0, "transaction"), "list.bullet.rectangle.fill", UpOnlyTint.cashFlow, "Entries")) }
        return VStack(alignment: .leading, spacing: 14) {
            if records.isEmpty {
                Text("Accounts, crypto, gold and silver, and transactions appear here once you add them with the plus button.")
                    .font(UpOnlyType.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                ManageCard {
                    ForEach(Array(records.enumerated()), id: \.element.section) { index, record in
                        UpOnlyRow(title: record.title, caption: record.caption, divided: index > 0, chevron: true, action: { session.managementSection = record.section }) {
                            UpOnlySymbolBadge(symbol: record.symbol, tint: record.tint, size: 24)
                        }
                    }
                }
            }
            ManageCard {
                UpOnlyRow(title: "Data sources", caption: sourcesSummary, chevron: true, action: { session.managementSection = "Sources" }) {
                    UpOnlySymbolBadge(symbol: "arrow.triangle.2.circlepath", tint: UpOnlyTint.netWorth, size: 24)
                }
                UpOnlyRow(title: "Backup & security", caption: "Touch ID, recovery code and backups", divided: true, chevron: true, action: { session.managementSection = "Security" }) {
                    UpOnlySymbolBadge(symbol: "lock.shield.fill", tint: UpOnlyTint.netWorth, size: 24)
                }
            }
        }
    }
    func count(_ number: Int, _ noun: String) -> String { "\(number) " + noun + (number == 1 ? "" : "s") }
    /// "2 portfolios · 3 coins", "1 safe · gold": what a Crypto or Metals row holds.
    func holdingsSummary(_ kind: TrackedKind) -> String {
        guard let doc = session.document else { return "" }
        let now = Date()
        let portfolios = doc.portfolios.filter { !$0.isArchived && $0.kind == kind }
        let holdings = doc.holdings.filter { holding in holding.isActive(at: now) && portfolios.contains { $0.id == holding.portfolioID } }
        guard !portfolios.isEmpty else { return "Archived only" }
        let noun = kind == .metals ? (holdings.count == 1 ? " metal" : " metals") : (holdings.count == 1 ? " coin" : " coins")
        return count(portfolios.count, kind == .metals ? "place" : "portfolio") + " · " + String(holdings.count) + noun
    }
    /// "Crypto & metals and exchange rates on", or what's off.
    var sourcesSummary: String {
        guard let settings = session.document?.settings else { return "" }
        var on: [String] = []
        #if UPONLY_PERSONAL
        if settings.automaticWise { on.append("Wise") }
        #endif
        if settings.automaticPrices { on.append("crypto") }
        if settings.automaticMetals { on.append("metals") }
        if settings.automaticFX { on.append("exchange rates") }
        guard !on.isEmpty else { return "Prices and rates are off" }
        let list = on.count == 1 ? on[0] : on.dropLast().joined(separator: ", ") + " and " + on.last!
        return list.prefix(1).uppercased() + list.dropFirst() + " on"
    }
    /// A section's own actions, beside its title: Add, and for accounts, updating every balance at once.
    var sectionActions: AnyView? {
        switch session.managementSection {
        case "Accounts":
            let many = (session.document?.accounts.filter { $0.externalProfileID == nil }.count ?? 0) > 1
            return AnyView(HStack(spacing: 8) {
                if many { ManageRowMenu(label: "More account options") { Button("Update all balances…") { session.startImport(.bankBalances, prefill: true) } } }
                ManageAddButton(label: "Add account") { session.startImport(.bankBalances, newAccount: true) }
            })
        case "Portfolios": return AnyView(ManageAddButton(label: "Add a coin") { session.startImport(.holdings) })
        case "Precious metals": return AnyView(ManageAddButton(label: "Add gold or silver") { session.startImport(.metals) })
        case "Entries": return AnyView(ManageAddButton(label: "Add a transaction") { editor = .entry })
        case "Add your info":
            // A table of balances or holdings: paste, files and the template live in the header, not above the rows.
            guard let draft = session.importDraft, draft.mode != .statements, session.importTableMode || draft.rows.count > 1 else { return nil }
            return AnyView(ManageRowMenu(label: "Import options") {
                Button("Paste from spreadsheet") { session.importRequest = .paste }
                Button("Choose CSV files…") { session.importRequest = .chooseFiles }
                Button("Download CSV template…") { session.importRequest = .template }
                if !draft.rows.isEmpty {
                    Divider()
                    Button("Discard draft…", role: .destructive) { session.importRequest = .discard }
                }
            })
        default: return nil
        }
    }
    func hasData(_ kind: TrackedKind) -> Bool { session.document?.hasData(kind) == true }
    func hasArchived(_ kind: TrackedKind) -> Bool { session.document?.portfolios.contains { $0.isArchived && $0.kind == kind } == true }
    /// Owner choices, shown when there is a company to choose, or when the current owner is a company that's gone
    /// (so it can be set back to Personal). The current owner is ticked.
    @ViewBuilder func ownerMenu(current: String?, choose: @escaping (String?) -> Void) -> some View {
        let books = session.document?.businessAccounting ?? []
        if !books.isEmpty || !(current ?? "").isEmpty {
            Menu("Owner") {
                Toggle("Personal", isOn: Binding(get: { current == nil }, set: { if $0 { choose(nil) } }))
                ForEach(books) { book in
                    Toggle(book.name, isOn: Binding(get: { current == book.id }, set: { if $0 { choose(book.id) } }))
                }
            }
        }
    }
    /// Every currency of a synced profile shares one owner. An empty owner means personal, even when a company shares the profile's name.
    func setAccountOwner(_ account: Account, owner: String?) {
        Task { await session.perform { doc in
            for index in doc.accounts.indices where doc.accounts[index].id == account.id || (account.externalProfileID != nil && doc.accounts[index].externalProfileID == account.externalProfileID) {
                doc.accounts[index].ownerBusinessID = owner ?? ""
            }
        } }
    }
    func trackingToggle(_ accounts: [Account]) -> some View {
        Toggle("Include in net worth", isOn: Binding(get: { session.document.map { doc in accounts.allSatisfy { doc.isBankTracked($0.id, at: Date()) } } ?? false }, set: { tracked in
            let now = Date()
            Task { await session.perform { doc in
                for account in accounts where doc.isBankTracked(account.id, at: now) != tracked { doc.setBankTracked(account.id, tracked: tracked, at: now) }
            } }
        }))
    }
}
