import SwiftUI

// Pages share the menu's width and grow only as far as the available menu height.
// Longer forms scroll vertically; they never become a separate app window.
struct UpOnlyMenuScroll<Content: View>: View {
    @State var contentHeight: CGFloat = 360
    /// The tallest it grows before scrolling: given, else the page's room (Manage pages share the dashboard's height).
    var maxHeight: CGFloat? = nil
    @ViewBuilder var content: () -> Content
    @Environment(\.upOnlyScrollHeight) private var pageHeight
    /// The page's header, when it has one. When the page scrolls it's pinned over the top as a bar, so rows pass
    /// beneath it under the system's soft blur rather than being cut off at a hard line.
    @Environment(\.upOnlyScrollHeader) private var header
    @State private var headerHeight: CGFloat = 0
    /// Whether rows have scrolled up under the header. Until they have, the header has no blur behind it at all, so
    /// the pointer passing over it doesn't bring up an empty bar.
    @State private var scrolled = false
    var body: some View {
        let maxHeight = self.maxHeight ?? pageHeight
        // A page that fits has its header above it as plain views: with nothing to scroll there's no bar to show,
        // even under the pointer. Only a page that scrolls pins its header as a bar with the blur behind it.
        let scrolls = contentHeight > maxHeight + 0.5
        VStack(spacing: 0) {
            if let header, !scrolls { measured(header) }
            ScrollView {
                // A scroll inside this one keeps its own edge; the header belongs to the page's outer scroll.
                content().environment(\.upOnlyScrollHeader, nil).frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        if height.isFinite && height > 0 { contentHeight = ceil(height) }
                    }
            }.scrollBounceBehavior(.basedOnSize)
                .scrollEdgeEffectStyle(.soft, for: .vertical)
                .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > 1 } action: { _, now in scrolled = now }
                .scrollEdgeEffectHidden(!scrolled, for: .top)
                .safeAreaBar(edge: .top, spacing: 0) { if let header, scrolls { measured(header) } }
                .frame(height: min(contentHeight, maxHeight) + (header != nil && scrolls ? headerHeight : 0))
        }
    }
    private func measured(_ header: AnyView) -> some View {
        header.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            if height.isFinite && height > 0 { headerHeight = ceil(height) }
        }
    }
}

extension EnvironmentValues {
    /// How tall a page's scrolling area may grow: set by the menu so Manage pages match the dashboard's height.
    @Entry var upOnlyScrollHeight: CGFloat = 540
    /// A page header for the page's scroll to pin as its top bar; nil for pages whose header scrolls with them.
    @Entry var upOnlyScrollHeader: AnyView? = nil
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
        let header: AnyView? = hasGuidedHeader ? nil : AnyView(
            UpOnlyPageHeader(title: editor?.title ?? pageTitle(month), backLabel: backLabel, backTitle: backTitle, back: back,
                             subtitle: editor == nil && month != nil ? "Is this month complete?" : nil,
                             trailing: editor == nil ? monthMenu(review?.months ?? [], current: month) ?? sectionActions : nil)
                .padding(.horizontal, UpOnlyLayout.inset).padding(.top, 14).padding(.bottom, 12))
        // A page that scrolls pins the header over its scroll; a confirmation, which doesn't, shows it above.
        let confirming = archive != nil || entryToRemove != nil || confirmingRestore || (session.managementSection == "Add your info" && discardingImport)
        VStack(spacing: 0) {
            if confirming, let header { header }
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
            else {
                UpOnlyMenuScroll {
                    VStack(alignment: .leading, spacing: 16) {
                        if let message = session.message { Text(message).fixedSize(horizontal: false, vertical: true).font(UpOnlyType.body).foregroundStyle(.secondary) }
                        if session.historyRebuilding {
                            Label("Updating past values…", systemImage: "clock.arrow.circlepath").font(UpOnlyType.caption).foregroundStyle(.secondary)
                        }
                        switch session.managementSection {
                        case "Manage", "Accounts", "Portfolios", "Precious metals": navigation
                        case "Needs attention":
                            if let review {
                                UpOnlyDataAttention(report: review.report, months: review.months, month: month, selection: $reviewSelection,
                                                    addEntry: { editor = .entry }, addRate: { editor = .exchangeRate })
                            }
                        case "Entries": entries
                        default: settings
                        }
                    }.padding(.horizontal, UpOnlyLayout.inset).padding(.bottom, UpOnlyLayout.inset)
                }
            }
        }
        .environment(\.upOnlyScrollHeader, confirming ? nil : header)
        .buttonStyle(.upOnlySecondary)
        .onAppear {
            // Reopening the menu shows this page again without recreating it; keep where it came from and the import's baseline.
            guard !configured else { return }
            configured = true
            origin = session.managementSection
            session.message = nil
            importBaseline = session.importDraft?.rows.map(\.content) ?? []
            if origin == "Entries" { entryMonth = session.entryMonthForManagement }
            if session.requestedRateCurrency != nil { editor = .exchangeRate; editorReturnsHome = true }
            if openRequestedHoldingEditor() { editorReturnsHome = true }
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
        .onChange(of: session.requestedHoldingEditor) { _, request in if request != nil, openRequestedHoldingEditor() { editorReturnsHome = true } }
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
        case "Accounts", "Portfolios", "Precious metals": "Manage"
        case "Sources", "Security": "Settings"
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
        if securityPage != nil { return "Back to Settings" }
        let section = session.managementSection
        if section == "Add your info" {
            if session.importReturnsHome || origin == section { return "Back to overview" }
            return session.importDraft == nil ? "Back to Manage" : "Back to " + sectionTitle(session.importReturnSection)
        }
        if Self.manageGroups.contains(section) || section == "Needs attention" || section == origin { return "Back to overview" }
        return returnToReview ? "Back to Needs attention" : "Back to Manage"
    }
    func back() {
        if discardingImport { discardingImport = false }
        else if archive != nil { archive = nil }
        else if entryToRemove != nil { entryToRemove = nil }
        else if confirmingRestore { cancelRestore() }
        else if securityPage != nil { session.message = nil; closeSecurityPage() }
        else if editor != nil { finishEditing() }
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
        if Self.manageGroups.contains(section) || section == "Needs attention" || section == origin { leaveManage() }
        else { session.managementSection = returnToReview ? "Needs attention" : "Manage" }
    }
    /// A holding's purchases, or moving it, asked for from its dashboard page. Closing the form goes back there.
    func openRequestedHoldingEditor() -> Bool {
        guard let request = session.requestedHoldingEditor else { return false }
        let id: UUID = switch request { case .purchases(let id), .move(let id): id }
        guard let holding = session.document?.holdings.first(where: { $0.id == id }) else { session.requestedHoldingEditor = nil; return false }
        switch request {
        case .purchases: editor = .purchases(holding)
        case .move: editor = .move(holding)
        }
        return true
    }
    func leaveManage() {
        session.entryMonthForManagement = ""; session.message = nil; session.managementInMenu = false
    }
    func finishEditing() {
        editor = nil; session.requestedRateCurrency = nil; session.requestedHoldingEditor = nil
        if editorReturnsHome { editorReturnsHome = false; leaveManage() }
    }
    /// Manage's first page, in the home list's style: what you've recorded in one card, how it's kept in another,
    /// each row saying what's inside.
    /// Manage is the things themselves: every bank account, portfolio and metal with its actions, grouped by whose
    /// it is, then transactions and settings. Opened for one group (Accounts, Crypto, Metals), it starts there.
    var navigation: some View {
        let doc = session.document
        let crypto = hasData(.crypto) || hasArchived(.crypto), metals = hasData(.metals) || hasArchived(.metals)
        let banks = hasData(.banks)
        return ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 22) {
                if !banks && !crypto && !metals && !hasData(.cashFlow) {
                    Text("Bank accounts, crypto, gold and silver, and transactions appear here once you add them with the plus button.")
                        .font(UpOnlyType.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                // Adding, updating all and importing are the + above, so the groups carry no menus of their own.
                if banks { manageGroup("Bank accounts") { accounts }.id("Accounts") }
                if crypto { manageGroup("Crypto") { holdings(.crypto) }.id("Portfolios") }
                if metals { manageGroup("Metals") { holdings(.metals) }.id("Precious metals") }
                ManageCard {
                    if hasData(.cashFlow) {
                        UpOnlyRow(title: "Transactions", caption: count(doc?.entries.count ?? 0, "transaction"), chevron: true, action: { session.managementSection = "Entries" }) {
                            UpOnlySymbolBadge(symbol: "list.bullet.rectangle.fill", tint: UpOnlyTint.cashFlow, size: 28)
                        }
                    }
                    UpOnlyRow(title: "Settings", caption: sourcesSummary, chevron: true, action: { session.managementSection = "Security" }) {
                        UpOnlySymbolBadge(symbol: "gearshape.fill", tint: UpOnlyTint.netWorth, size: 28)
                    }
                }
            }
            .onAppear { scrollToGroup(proxy) }
            .onChange(of: session.managementSection) { scrollToGroup(proxy) }
        }
    }
    /// The pages Manage replaced (Accounts, Crypto, Metals) open Manage at their group.
    static let manageGroups: Set<String> = ["Manage", "Accounts", "Portfolios", "Precious metals"]
    func scrollToGroup(_ proxy: ScrollViewProxy) {
        let section = session.managementSection
        guard section != "Manage", Self.manageGroups.contains(section) else { return }
        Task { @MainActor in proxy.scrollTo(section, anchor: .top) }
    }
    /// One of Manage's groups: its name, then its cards.
    func manageGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(UpOnlyType.group)
            content()
        }
    }
    /// A heading inside a group: whose it is, or a portfolio's name, and its total, lined up with the rows below.
    func manageSubheader(_ title: String, total: Decimal?) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Text(title).font(UpOnlyType.body.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            subheaderTotal(total)
        }.padding(.horizontal, UpOnlyLayout.cardInset)
    }
    /// The same heading whose name opens its actions ("Personal ⌄"), for a portfolio, instead of another "…".
    func manageSubheader<Actions: View>(_ title: String, total: Decimal?, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Menu { actions() } label: {
                HStack(spacing: 4) {
                    Text(title).font(UpOnlyType.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }.foregroundStyle(.secondary).contentShape(Rectangle())
            // A long portfolio name shortens rather than pushing the page wider than the menu.
            }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize(horizontal: false, vertical: true).accessibilityLabel(title + " options")
            Spacer(minLength: 8)
            subheaderTotal(total)
        }.padding(.horizontal, UpOnlyLayout.cardInset)
    }
    /// Lined up with the row values below, which sit left of each row's "…" (22 pt wide, 6 pt away).
    @ViewBuilder private func subheaderTotal(_ total: Decimal?) -> some View {
        if let total {
            UpOnlyPrivateText(UpOnlyFormat.exactMoney(total)).font(UpOnlyType.body.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                .minimumScaleFactor(0.7).layoutPriority(1).padding(.trailing, 28)
        }
    }
    /// Settings: where prices and rates come from, then locking, the recovery code and backups, on one page.
    @ViewBuilder var settings: some View {
        if securityPage != nil { security } else {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Data sources").font(UpOnlyType.group)
                    UpOnlySources(pendingChanges: $sourceEditsPending, embedded: true)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Security & backups").font(UpOnlyType.group)
                    securityOverview
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
        // Manage lists everything, so its + adds anything, as the dashboard's does.
        case "Manage", "Accounts", "Portfolios", "Precious metals": return AnyView(ManageAddButton(label: "Add") { session.managementSection = "Add your info" })
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
            Menu("Belongs to") {
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
    /// Every account counts in net worth unless left out, as for money kept for someone else; its history is kept.
    func netWorthButton(_ accounts: [Account]) -> some View {
        let counted = session.document.map { doc in accounts.allSatisfy { doc.isBankTracked($0.id, at: Date()) } } ?? true
        return Button(counted ? "Leave out of net worth" : "Count in net worth") {
            let now = Date()
            Task { await session.perform { doc in
                for account in accounts where doc.isBankTracked(account.id, at: now) == counted { doc.setBankTracked(account.id, tracked: !counted, at: now) }
            } }
        }
    }
}
