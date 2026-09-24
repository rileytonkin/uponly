import SwiftUI

// Pages share the menu's width and grow only as far as the available menu height.
// Longer forms scroll vertically; they never become a separate app window.
struct UpOnlyMenuScroll<Content: View>: View {
    @State var contentHeight: CGFloat = 360
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

/// The "…" options menu at the end of a row.
struct UpOnlyRowMenu: ViewModifier {
    func body(content: Content) -> some View {
        content.menuStyle(.borderedButton).menuIndicator(.hidden).fixedSize().controlSize(.small)
    }
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
        case .entry: "Income or expense"
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
                                 trailing: editor == nil ? monthMenu(review?.months ?? [], current: month) : nil).padding(UpOnlyLayout.inset)
                Divider()
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
                        .padding(UpOnlyLayout.inset)
                }
            } else if session.managementSection == "Add your info" {
                VStack(spacing: 0) {
                    if discardingImport {
                        UpOnlyConfirmation(title: "Discard this import?", detail: "Nothing from it has been saved yet.", confirmTitle: "Discard import", cancelTitle: "Keep editing",
                            confirm: { leaveImport(confirmed: true) }, cancel: { discardingImport = false }).padding(UpOnlyLayout.inset)
                    }
                    Group {
                        if session.importDraft == nil, !session.importTableMode { UpOnlyMenuScroll { UpOnlyEntryFlow(compact: true) } }
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
                    }.padding(UpOnlyLayout.inset)
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
        case "Precious metals": "Gold & silver"
        case "Sources": "Prices & rates"
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
    var navigation: some View {
        let crypto = hasData(.crypto) || hasArchived(.crypto), metals = hasData(.metals) || hasArchived(.metals)
        return VStack(spacing: 8) {
            if hasData(.banks) { navigationButton("Accounts", symbol: TrackedKind.banks.symbol, section: "Accounts") }
            if crypto { navigationButton("Crypto", symbol: TrackedKind.crypto.symbol, tint: UpOnlyTint.crypto, section: "Portfolios") }
            if metals { navigationButton("Gold & silver", symbol: TrackedKind.metals.symbol, tint: UpOnlyTint.metals, section: "Precious metals") }
            if hasData(.cashFlow) { navigationButton("Transactions", symbol: "list.bullet.rectangle.fill", tint: UpOnlyTint.cashFlow, section: "Entries") }
            if hasData(.banks) || crypto || metals || hasData(.cashFlow) { Divider().padding(.vertical, 4) }
            else {
                Text("Accounts, crypto, gold and silver, and transactions appear here once you add them with the plus button.")
                    .font(UpOnlyType.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.bottom, 4)
            }
            navigationButton("Prices & rates", symbol: "arrow.triangle.2.circlepath", section: "Sources")
            navigationButton("Backup & security", symbol: "lock.shield.fill", section: "Security")
        }
    }
    func hasData(_ kind: TrackedKind) -> Bool { session.document?.hasData(kind) == true }
    func hasArchived(_ kind: TrackedKind) -> Bool { session.document?.portfolios.contains { $0.isArchived && $0.kind == kind } == true }
    func navigationButton(_ title: String, symbol: String, tint: Color = UpOnlyTint.netWorth, section: String) -> some View {
        Button {
            session.managementSection = section
        } label: {
            HStack(spacing: 10) {
                UpOnlySymbolBadge(symbol: symbol, tint: tint, size: 24)
                Text(title).font(UpOnlyType.row.weight(.medium))
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }.padding(UpOnlyLayout.cardInset)
                .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: UpOnlyLayout.radius))
                .contentShape(RoundedRectangle(cornerRadius: UpOnlyLayout.radius))
        }.buttonStyle(UpOnlyCardButtonStyle(radius: UpOnlyLayout.radius)).accessibilityLabel(title)
    }
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
