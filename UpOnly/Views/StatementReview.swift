import SwiftUI
import AppKit

struct UpOnlyImportView: View {
    @Environment(UpOnlySession.self) private var session
    @State private var review: ImportEvaluation?
    @State private var reviewing = false
    @State private var reviewTask: Task<(ImportEvaluation, [String]), Never>?
    @State private var mappingTask: Task<[ImportDraftRow], Error>?
    @State private var reviewRevision = UUID()
    @State private var mappingChanged = Set<UUID>()
    @State private var selection = Set<UUID>()
    @State private var page = 0
    @State private var error: String?
    @State private var dropTargeted = false
    @State private var discard = false
    @State private var importDetails = false
    @State private var problemRows = Set<UUID>()
    @State private var problemSources = Set<UUID>()
    @State private var coveredMonths: [String] = []
    @State private var editingStatementAccount: UUID?
    @State private var starterRow: (id: UUID, content: ImportRowContent)?
    private let pageSize = 50
    private var accounts: [Account] { session.document?.accounts ?? [] }
    private var portfolios: [Portfolio] { session.document?.portfolios.filter { !$0.isArchived && $0.kind == (session.importDraft?.mode.kind ?? .crypto) } ?? [] }
    private var coins: [CatalogCoin] { ImportCoinList.coins(document: session.document, catalog: session.catalog) }
    private var busy: Bool { reviewing || session.importLoading || session.isBusy }
    var body: some View {
        Group {
        if discard {
            UpOnlyConfirmation(title: "Discard this unsaved draft?", detail: "Your saved information stays unchanged.", confirmTitle: "Discard draft", confirm: { discard = false; session.discardImport(); resetView() }, cancel: { discard = false }).padding(UpOnlyLayout.inset)
        } else {
        Group {
        if let batch = session.importDraft, usesSummary(batch), !importDetails {
            UpOnlyMenuScroll { importOverview(batch) }
        } else if let batch = session.importDraft, batch.mode != .statements, batch.rows.count <= 1, batch.sources.allSatisfy({ $0.grid.isEmpty }), !session.importTableMode {
            UpOnlyMenuScroll { UpOnlyEntryFlow(compact: true) }
        } else {
        UpOnlyMenuScroll {
        VStack(alignment: .leading, spacing: 16) {
            if let batch = session.importDraft {
                if usesSummary(batch) {
                    Button("Back to summary") { importDetails = false; beginReview() }.buttonStyle(.bordered)
                } else { batchHeader(batch); inputActions }
                if let message = session.importMessage { Text(message).fixedSize(horizontal: false, vertical: true).font(.callout).foregroundStyle(.secondary) }
                if session.importLoading {
                    HStack { ProgressView().controlSize(.small); Text("Reading your files on this Mac…").fixedSize(horizontal: false, vertical: true); Spacer(); Button("Cancel reading") { session.cancelImport() } }
                }
                ForEach(batch.sources) { source in
                    if !source.grid.isEmpty || (batch.mode == .statements && batch.rows.contains(where: { $0.sourceID == source.id })) {
                        if usesSummary(batch), !problemSources.contains(source.id) {
                            DisclosureGroup("File settings") { sourceCard(source, mode: batch.mode) }.font(.system(size: 12))
                        } else { sourceCard(source, mode: batch.mode) }
                    }
                }
                if !batch.rows.isEmpty {
                    if !usesSummary(batch) && batch.rows.count > 1 { rowActions(batch) }
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(displayedRows(batch).dropFirst(page * pageSize).prefix(pageSize))) { row in
                            ImportRowEditor(row: rowBinding(row), mode: batch.mode, accounts: accounts, portfolios: portfolios, coins: coins,
                                            usesDebitCredit: batch.sources.first(where: { $0.id == row.sourceID }).map { $0.mapping[.debit] != nil || $0.mapping[.credit] != nil } ?? false,
                                            sourceName: batch.sources.filter { !$0.grid.isEmpty }.count > 1 ? batch.sources.first(where: { $0.id == row.sourceID })?.filename ?? "" : "", state: review?.states[row.id], selected: selection.contains(row.id),
                                            manual: batch.sources.first(where: { $0.id == row.sourceID })?.grid.isEmpty == true, selectable: !usesSummary(batch),
                                            select: { if selection.contains(row.id) { selection.remove(row.id) } else { selection.insert(row.id) } },
                                            remove: { invalidateReview(); session.importDraft?.rows.removeAll { $0.id == row.id }; clampPage() }).disabled(busy)
                        }
                    }
                    if displayedRows(batch).count > pageSize {
                        HStack {
                            Button("Previous rows") { page = max(0, page - 1) }.disabled(page == 0)
                            Text("\(page * pageSize + 1)–\(min((page + 1) * pageSize, displayedRows(batch).count)) of \(displayedRows(batch).count)").fixedSize(horizontal: false, vertical: true).font(.caption).monospacedDigit()
                            Button("Next rows") { page += 1 }.disabled((page + 1) * pageSize >= displayedRows(batch).count)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        UpOnlySymbolBadge(symbol: batch.mode == .statements ? "doc.on.doc" : batch.mode.kind.symbol, tint: batch.mode.kind.tint, size: 42)
                        Text(batch.mode == .statements ? "Drop your statements here" : "Start with one, add as many as you like").fixedSize(horizontal: false, vertical: true).font(.headline)
                        Text(batch.mode == .statements ? "Choose several CSVs at once. You’ll review them before saving." : "Type a balance or paste a table from your spreadsheet.").fixedSize(horizontal: false, vertical: true).font(.callout).foregroundStyle(.secondary)
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                        .background(batch.mode.kind.tint.opacity(0.06), in: RoundedRectangle(cornerRadius: UpOnlyLayout.radius))
                }
                if let error { Text(error).fixedSize(horizontal: false, vertical: true).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                if let review {
                    if let global = review.globalError { Text(global).fixedSize(horizontal: false, vertical: true).foregroundStyle(.red) }
                    ForEach(batch.sources) { source in
                        if let problem = review.sourceErrors[source.id] { Text(review.needsAccount.contains(source.id) ? problem : source.filename + ": " + problem).fixedSize(horizontal: false, vertical: true).font(.caption).foregroundStyle(.red) }
                    }
                }
                if !mappingChanged.isEmpty { Text("Apply your column mapping before reviewing.").fixedSize(horizontal: false, vertical: true).font(.caption).foregroundStyle(.secondary) }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Menu {
                        ForEach(orderedModes, id: \.self) { mode in
                            Button(mode.title) { openMode(mode, bulk: true) }
                        }
                    } label: { Label("Import or paste…", systemImage: "doc.on.clipboard") }
                        .menuStyle(.borderedButton).fixedSize().accessibilityIdentifier("BulkImportOptions")
                }
                if let message = session.importMessage { Label(message, systemImage: "checkmark.circle.fill").fixedSize(horizontal: false, vertical: true).foregroundStyle(UpOnlyTint.cashFlow) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 14)], spacing: 14) {
                    ForEach(orderedModes, id: \.self) { mode in
                        VStack(alignment: .leading, spacing: 16) {
                        Button { openMode(mode) } label: {
                        VStack(alignment: .leading, spacing: 16) {
                            UpOnlySymbolBadge(symbol: mode.kind.symbol, tint: mode.kind.tint, size: 40)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(mode.title).fixedSize(horizontal: false, vertical: true).font(.system(size: 16, weight: .semibold))
                                Text(modeDescription(mode)).fixedSize(horizontal: false, vertical: true).font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            Label(mode == .statements ? "Choose statements" : "Add manually", systemImage: "arrow.right").font(.system(size: 12, weight: .medium)).foregroundStyle(mode.kind.tint)
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.bordered)
                        if mode != .statements, session.document?.hasData(mode.kind) == true {
                            Button(mode == .bankBalances ? "Update existing balances" : mode == .holdings ? "Update existing quantities" : "Update existing weights") { session.startImport(mode, prefill: true); resetView() }
                                .buttonStyle(.bordered).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        }.padding(UpOnlyLayout.inset).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: UpOnlyLayout.radius))
                            .overlay(RoundedRectangle(cornerRadius: UpOnlyLayout.radius).strokeBorder(Color.primary.opacity(0.06)))
                    }
                }
            }
            if let batch = session.importDraft, batch.mode != .statements || !batch.rows.isEmpty || busy { importFooter(batch) }
        }.padding(UpOnlyLayout.inset).frame(maxWidth: .infinity, alignment: .leading)
        }.background(Color(nsColor: .windowBackgroundColor))
        }
        }
        }
        }
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(dropTargeted ? UpOnlyTint.netWorth : .clear, lineWidth: 2))
        .dropDestination(for: URL.self) { urls, _ in
            guard !busy, !urls.isEmpty else { return false }
            if session.importDraft == nil { session.startImport(.statements) }
            prepareExternalInput(); Task { await session.readImportFiles(urls) }; return true
        } isTargeted: { dropTargeted = $0 }
        .onAppear { session.dropZoneVisible = session.importDraft?.mode == .statements }
        .onChange(of: session.importDraft?.mode) { _, mode in session.dropZoneVisible = mode == .statements }
        .onDisappear { session.dropZoneVisible = false }
        .onChange(of: session.importRevision) { _, _ in invalidateReview(); clampPage() }
        .onChange(of: session.importLoading) { _, loading in if !loading, let batch = session.importDraft, usesSummary(batch) { beginReview() } }
        .onChange(of: session.document?.generation) { _, _ in if let batch = session.importDraft, usesSummary(batch) { beginReview() } }
        .onAppear { if let batch = session.importDraft, usesSummary(batch) { beginReview() }; if let batch = session.importDraft, batch.mode != .statements, batch.rows.isEmpty, batch.sources.allSatisfy({ $0.grid.isEmpty }) { addRow() } }
        .onDisappear { invalidateReview() }
    }
    private func importOverview(_ batch: ImportBatchDraft) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if batch.sources.allSatisfy({ $0.grid.isEmpty }) {
                Button("Choose CSV files…") { Task { await session.chooseImportFiles() } }
                    .buttonStyle(.glassProminent).disabled(busy)
                Text("or drop CSVs here").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                ForEach(batch.sources.filter { !$0.grid.isEmpty }) { source in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            if batch.mode == .statements, !batch.rows.isEmpty {
                            Menu { accountChoices(source) } label: {
                                Text(source.account.name.isEmpty ? "Choose account" : accountTitle(source.account.name, source.account.currency)).lineLimit(1)
                            }.modifier(UpOnlyPillMenu()).accessibilityLabel("Statement account")
                            } else { Text(source.filename).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle).help(source.filename) }
                            Spacer(minLength: 0)
                            Menu {
                                Button("Add CSV files…") { Task { await session.chooseImportFiles() } }
                                Button("Remove file", role: .destructive) {
                                    invalidateReview(); session.importDraft?.sources.removeAll { $0.id == source.id }
                                    session.importDraft?.rows.removeAll { $0.sourceID == source.id }; beginReview()
                                }
                            } label: { Image(systemName: "ellipsis") }
                                .modifier(UpOnlyPillMenu()).accessibilityLabel("File options")
                        }.disabled(busy)
                        if batch.mode == .statements, !batch.rows.isEmpty { Text(source.filename).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(source.filename) }
                        if batch.mode == .statements, !batch.rows.isEmpty, editingStatementAccount != source.id {
                            // One real balance anchors the history rebuilt from these transactions.
                            HStack(spacing: 8) {
                                Text("Balance now").font(.system(size: 12)).foregroundStyle(.secondary)
                                UpOnlyValueField("0.00", text: sourceBinding(source, \.balance)).textFieldStyle(.roundedBorder).frame(width: 110)
                                    .accessibilityLabel("Current balance for " + (source.account.name.isEmpty ? source.filename : source.account.name))
                                Text(source.account.currency).font(.system(size: 12)).foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                            }
                        }
                        if editingStatementAccount == source.id {
                            UpOnlyOwnerPicker(owner: Binding(get: { source.account.ownerBusinessID }, set: { value in var account = source.account; account.ownerBusinessID = value; setStatementAccount(source, account) }))
                            HStack(spacing: 8) {
                                TextField("Account name", text: Binding(get: { source.account.name }, set: { value in var account = source.account; account.name = value; setStatementAccount(source, account) })).textFieldStyle(.roundedBorder)
                                TextField("Currency", text: Binding(get: { source.account.currency }, set: { value in var account = source.account; account.currency = value; setStatementAccount(source, account) })).frame(width: 52).textFieldStyle(.roundedBorder)
                                Button("Done") { editingStatementAccount = nil; beginReview() }.buttonStyle(.bordered)
                            }
                        }
                    }
                }
                if batch.rows.isEmpty {
                    Text("This file has no transactions.").font(.system(size: 13)).foregroundStyle(.secondary)
                    Button("Choose CSV files…") {
                        session.importDraft?.sources.removeAll { !$0.grid.isEmpty }
                        Task { await session.chooseImportFiles() }
                    }.buttonStyle(.glassProminent).disabled(busy)
                } else if let review {
                    if !coveredPeriod.isEmpty { Text(coveredPeriod).font(.system(size: 14, weight: .medium)) }
                    if let source = batch.sources.first(where: { review.needsAccount.contains($0.id) }) {
                        // The account is what's missing, so choosing one is the next step, not fixing rows.
                        Text("Which account are these transactions from?").font(UpOnlyType.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Menu { accountChoices(source) } label: { Text("Choose an account for " + source.filename).lineLimit(1).truncationMode(.middle) }
                            .menuStyle(.button).buttonStyle(.glassProminent).accessibilityLabel("Choose an account for " + source.filename)
                    } else if review.hasErrors || !mappingChanged.isEmpty {
                        Text(review.globalError ?? review.sourceErrors.values.first ?? "Some rows need a correction.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Fix rows") {
                            problemRows = Set(review.states.filter { $0.value.blocksSave }.map(\.key)); importDetails = true; page = 0
                        }.buttonStyle(.glassProminent)
                    } else if review.learnedDays > 0 && review.readyRows == 0 {
                        Text("Dates added for \(review.learnedDays.formatted()) saved transactions").font(.system(size: 14, weight: .medium))
                        Text("Balance history will be rebuilt when you save.").font(.system(size: 12)).foregroundStyle(.secondary)
                        Button("Save and rebuild history") { Task { await save() } }
                            .buttonStyle(.glassProminent).disabled(busy || editingStatementAccount != nil)
                    } else if review.added == 0 {
                        Text(batch.mode == .statements ? "No new transactions" : "Already up to date").font(.system(size: 14, weight: .medium))
                        Button("Done") { session.discardImport() }.buttonStyle(.glassProminent)
                    } else {
                        if batch.mode != .statements {
                            ForEach(batch.rows.filter { if case .ready = review.states[$0.id] { return true }; return false }) { row in
                                VStack(alignment: .leading, spacing: 3) {
                                    if batch.mode == .bankBalances {
                                        Text(row.bank.account.name).font(UpOnlyType.row.weight(.medium))
                                        HStack(spacing: 4) {
                                            UpOnlyPrivateText(balanceText(row, in: batch))
                                            Text(row.bank.account.currency + " · " + row.bank.date)
                                        }.font(UpOnlyType.body).foregroundStyle(.secondary)
                                    } else {
                                        Text(row.holding.portfolioName).font(UpOnlyType.row.weight(.medium))
                                        Text(review.states[row.id]?.displayText(privacy: session.privacyMode) ?? "").font(UpOnlyType.body).foregroundStyle(.secondary)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        let excluded = batch.rows.filter { !$0.included }.count
                        let skipped = [review.duplicates > 0 ? "\(review.duplicates.formatted()) " + (batch.mode == .statements ? "already imported" : "unchanged") : nil,
                                       excluded > 0 ? "\(excluded.formatted()) excluded" : nil].compactMap { $0 }.joined(separator: " · ")
                        if !skipped.isEmpty { Text(skipped).font(UpOnlyType.caption).foregroundStyle(.secondary) }
                        let count = review.readyRows
                        // Only the file itself, or a balance, is new: say so rather than "Import 0 transactions".
                        if count == 0 { Text(batch.mode == .statements ? "No new transactions" : "Already up to date").font(.system(size: 14, weight: .medium)) }
                        Button(count == 0 ? "Save" : batch.mode == .statements ? "Import \(count.formatted()) \(count == 1 ? "transaction" : "transactions")" : "Save \(count.formatted()) \(count == 1 ? "update" : "updates")") { Task { await save() } }
                            .buttonStyle(.glassProminent).disabled(busy || editingStatementAccount != nil)
                    }
                } else if !busy, editingStatementAccount == nil {
                    Button("Review") { beginReview() }.buttonStyle(.bordered)
                }
            }
            if let message = error ?? session.importMessage, !session.importLoading {
                Text(message).font(UpOnlyType.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(UpOnlyLayout.inset).frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private func accountChoices(_ source: ImportSourceDraft) -> some View {
        // One currency's part of a split file can only go to an account in that currency.
        ForEach(accounts.filter { source.splitCurrency == nil || $0.currency == source.splitCurrency }) { account in
            Button(accountTitle(account.name, account.currency)) {
                setStatementAccount(source, ImportAccount(existingID: account.id, name: account.name, currency: account.currency))
                beginReview()
            }
        }
        Button("New account…") {
            var account = source.account
            if account.existingID != nil { account.existingID = nil; account.name = "" }
            // A new account starts in the file's currency, not the last account's.
            if let currency = fileCurrency(source) { account.currency = currency }
            setStatementAccount(source, account); editingStatementAccount = source.id
        }
    }
    /// The one currency in the file's Currency column, if it has one.
    private func fileCurrency(_ source: ImportSourceDraft) -> String? {
        guard source.mapping[.currency] != nil else { return nil }
        let codes = Set(session.importDraft?.rows.filter { $0.sourceID == source.id }.compactMap { try? MoneyInput.normalizeCurrency($0.statement.currency) } ?? [])
        return codes.count == 1 ? codes.first : nil
    }
    private func balanceText(_ row: ImportDraftRow, in batch: ImportBatchDraft) -> String {
        let source = batch.sources.first { $0.id == row.sourceID }
        return (try? (source?.numberFormat ?? .point).decimal(row.bank.balance, typed: source?.isManual ?? true)).map { readBack($0, fraction: 2...18) } ?? row.bank.balance
    }
    private var coveredPeriod: String {
        guard let firstText = coveredMonths.first, let lastText = coveredMonths.last,
              let first = MonthKey(firstText), let last = MonthKey(lastText) else { return "" }
        if first == last { return first.title }
        return first.year == last.year ? first.shortName + "–" + last.title : first.title + "–" + last.title
    }
    private func importFooter(_ batch: ImportBatchDraft) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if usesSummary(batch) {
                Button("Check corrections") { beginReview() }.buttonStyle(.glassProminent)
                    .disabled(busy || !mappingChanged.isEmpty)
            } else {
            if let review {
                UpOnlyFlow(spacing: 12) {
                    Label(review.readyRows == 0 && review.added > 0 ? "Statement updates ready to save" : "\(review.readyRows) ready to save", systemImage: "checkmark.circle").foregroundStyle(UpOnlyTint.cashFlow)
                    if review.duplicates > 0 { Text("\(review.duplicates) " + (batch.mode == .statements ? "duplicates skipped" : "unchanged")).foregroundStyle(.secondary) }
                    if review.hasErrors { Label("Needs attention", systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
                }.font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            }
            UpOnlyFlow(spacing: 8) {
                if session.importLoading {
                    ProgressView().controlSize(.small)
                    Button("Cancel reading") { session.cancelImport() }.buttonStyle(.bordered)
                } else if reviewing {
                    ProgressView().controlSize(.small)
                    Button("Cancel review") { invalidateReview() }.buttonStyle(.bordered)
                } else if review != nil {
                    Button("Back to editing") { invalidateReview() }.buttonStyle(.bordered)
                } else if batch.mode != .statements {
                    Button { addRow() } label: { Label(addRowTitle(batch.mode), systemImage: "plus") }.buttonStyle(.bordered).disabled(busy)
                }
                if let review {
                    Button("Save reviewed changes") { Task { await save() } }.buttonStyle(.glassProminent)
                        .disabled(busy || review.hasErrors || review.added == 0 || !mappingChanged.isEmpty)
                } else if !batch.rows.isEmpty {
                    Button("Review changes") { beginReview() }.buttonStyle(.glassProminent)
                        .disabled(busy || batch.rows.isEmpty || !mappingChanged.isEmpty)
                }
            }.controlSize(.regular).font(.system(size: 12))
            }
        }.padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Divider() }
    }
    private var orderedModes: [ImportMode] {
        ImportMode.allCases.sorted { lhs, rhs in
            let left = session.document?.shows(lhs.kind) == true, right = session.document?.shows(rhs.kind) == true
            if left != right { return left }
            return ImportMode.allCases.firstIndex(of: lhs)! < ImportMode.allCases.firstIndex(of: rhs)!
        }
    }
    private func modeDescription(_ mode: ImportMode) -> String {
        switch mode {
        case .statements: "Your income and spending, from CSV files."
        case .bankBalances: "What’s in each account, as of a date."
        case .metals: "Your gold and silver weights."
        case .holdings: "The coins you own, wherever you keep them."
        }
    }
    private func batchHeader(_ batch: ImportBatchDraft) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(batch.mode == .metals ? "Enter pure metal weight, excluding alloys. Prices exclude dealer premiums." : batch.mode == .holdings ? "Enter total quantities, not changes in quantity." : "A snapshot of your accounts. Overdrafts and zero balances are welcome.").fixedSize(horizontal: false, vertical: true)
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
    /// Statements always use the summary, so these actions are for balances and holdings.
    private var inputActions: some View {
        Menu {
            Button("Choose CSV files…") { prepareExternalInput(); Task { await session.chooseImportFiles() } }
            Button("Paste from spreadsheet") {
                guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { error = "Copy some spreadsheet cells first."; return }
                prepareExternalInput(); Task { await session.pasteImport(text) }
            }
            Button("Download CSV template…") { Task { await session.saveImportTemplate() } }
            if let batch = session.importDraft, !batch.rows.isEmpty {
                Divider()
                Button("Discard draft…", role: .destructive) { discard = true }
            }
        } label: { Label("Import options", systemImage: "doc.badge.plus") }
            .modifier(UpOnlyPillMenu()).accessibilityLabel("Import options").disabled(busy)
    }
    private func openMode(_ mode: ImportMode, bulk: Bool = false) {
        guard session.startImport(mode) else { return }; resetView()
        session.importTableMode = bulk
        if mode != .statements { addRow() }
    }
    private func addRowTitle(_ mode: ImportMode) -> String {
        switch mode { case .statements: "Add transaction"; case .bankBalances: "Add account"; case .holdings: "Add coin"; case .metals: "Add metal" }
    }
    private func sourceCard(_ source: ImportSourceDraft, mode: ImportMode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(source.filename, systemImage: source.grid.isEmpty ? "square.and.pencil" : "doc.text").fixedSize(horizontal: false, vertical: true).font(.headline)
                Spacer()
                let count = session.importDraft?.rows.filter { $0.sourceID == source.id }.count ?? 0
                Text("\(count) \(count == 1 ? "row" : "rows")").fixedSize(horizontal: false, vertical: true).font(.caption).foregroundStyle(.secondary)
                Button { invalidateReview(); session.importDraft?.rows.removeAll { $0.sourceID == source.id }; session.importDraft?.sources.removeAll { $0.id == source.id }; mappingChanged.remove(source.id); clampPage() } label: { Image(systemName: "xmark.circle") }.buttonStyle(.bordered).help("Remove this source and its rows").accessibilityLabel("Remove " + source.filename)
            }
            if let review {
                let rows = session.importDraft?.rows.filter { $0.sourceID == source.id } ?? []
                let states = rows.compactMap { review.states[$0.id] }
                UpOnlyFlow(spacing: 10) {
                    Text("\(states.filter { if case .ready = $0 { return true }; return false }.count) new")
                    let duplicates = states.filter { $0 == .duplicate }.count
                    if duplicates > 0 { Text("\(duplicates) duplicates") }
                    let errors = states.filter(\.blocksSave).count
                    if errors > 0 { Text("\(errors) need attention").foregroundStyle(.orange) }
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if mode == .statements {
                ImportAccountEditor(account: Binding(get: { source.account }, set: { setStatementAccount(source, $0) }), accounts: accounts)
                // The balance anchors the history rebuilt from this statement's transactions.
                ImportField(title: "Balance now · " + source.account.currency + " (optional)") {
                    HStack(spacing: 8) {
                        UpOnlyValueField("0.00", text: sourceBinding(source, \.balance)).textFieldStyle(.roundedBorder).frame(width: 140)
                            .accessibilityLabel("Current balance for " + (source.account.name.isEmpty ? source.filename : source.account.name))
                        Text("Lets Up Only work out the balance on every day these transactions cover.").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                if !mode.isHolding { Picker("Dates", selection: sourceBinding(source, \.dateFormat)) { ForEach(ImportDateFormat.allCases, id: \.self) { Text($0.title).fixedSize(horizontal: false, vertical: true).tag($0) } } }
                Picker("Numbers", selection: sourceBinding(source, \.numberFormat)) { ForEach(ImportNumberFormat.allCases, id: \.self) { Text($0.rawValue).fixedSize(horizontal: false, vertical: true).tag($0) } }
            }.font(.caption)
            if !source.grid.isEmpty {
                DisclosureGroup("Map columns · \(source.hasHeader ? "First row is a header" : "No header")") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("First row contains column names", isOn: Binding(get: { source.hasHeader }, set: { value in
                            var updated = source; updated.hasHeader = value
                            updated.mapping = ImportParser.defaultMapping(updated, mode: mode)
                            replaceSource(updated); mappingChanged.insert(source.id)
                        })).toggleStyle(.checkbox)
                        LazyVGrid(columns: [GridItem(.flexible())], alignment: .leading) {
                            ForEach(mode.columns, id: \.self) { column in
                                Picker(column.title, selection: Binding(get: { source.mapping[column] ?? -1 }, set: { index in
                                    var updated = source
                                    if index < 0 { updated.mapping.removeValue(forKey: column) } else { updated.mapping[column] = index }
                                    replaceSource(updated); mappingChanged.insert(source.id)
                                })) {
                                    Text("Not provided").fixedSize(horizontal: false, vertical: true).tag(-1)
                                    ForEach(Array(source.headers.enumerated()), id: \.offset) { index, _ in Text(source.headers[index]).lineLimit(1).tag(index) }
                                }
                            }
                        }
                        Button("Apply mapping") { applyMapping(source) }.disabled(busy)
                    }.padding(.top, 8)
                }.font(.callout)
            }
        }.padding(14).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12)).disabled(busy)
    }
    private func rowActions(_ batch: ImportBatchDraft) -> some View {
        UpOnlyFlow {
            Menu(selection.isEmpty ? "Select rows" : "Selected rows (\(selection.count))") {
                Button(selection.count == batch.rows.count ? "Clear selection" : "Select all rows") { selection = selection.count == batch.rows.count ? [] : Set(batch.rows.map(\.id)) }
                if !selection.isEmpty {
                    Divider()
                    Button("Exclude") { editSelected { $0.included = false } }
                    Button("Include") { editSelected { $0.included = true } }
                }
            }
            Spacer()
            Text("\(batch.rows.filter(\.included).count) included").fixedSize(horizontal: false, vertical: true).font(.caption).foregroundStyle(.secondary)
        }.font(.caption).disabled(busy)
    }
    private func usesSummary(_ batch: ImportBatchDraft) -> Bool {
        batch.mode == .statements || (!batch.rows.isEmpty && batch.sources.filter { source in batch.rows.contains { $0.sourceID == source.id } }.allSatisfy { !$0.grid.isEmpty })
    }
    private func displayedRows(_ batch: ImportBatchDraft) -> [ImportDraftRow] {
        usesSummary(batch) ? batch.rows.filter { problemRows.contains($0.id) } : batch.rows
    }
    private func setStatementAccount(_ source: ImportSourceDraft, _ account: ImportAccount) {
        let previousCurrency = source.account.currency
        sourceBinding(source, \.account).wrappedValue = account
        if source.mapping[.currency] == nil, var batch = session.importDraft {
            for index in batch.rows.indices where batch.rows[index].sourceID == source.id && batch.rows[index].statement.currency == previousCurrency {
                batch.rows[index].statement.currency = account.currency
                batch.rows[index].duplicateApproved = false
            }
            session.importDraft = batch
        }
    }
    private func sourceBinding<T>(_ source: ImportSourceDraft, _ path: WritableKeyPath<ImportSourceDraft, T>) -> Binding<T> {
        Binding(get: { session.importDraft?.sources.first(where: { $0.id == source.id })?[keyPath: path] ?? source[keyPath: path] }, set: { value in
            guard let index = session.importDraft?.sources.firstIndex(where: { $0.id == source.id }) else { return }
            invalidateReview(); session.importDraft?.sources[index][keyPath: path] = value
        })
    }
    private func rowBinding(_ row: ImportDraftRow) -> Binding<ImportDraftRow> {
        Binding(get: { session.importDraft?.rows.first(where: { $0.id == row.id }) ?? row }, set: { value in
            guard let index = session.importDraft?.rows.firstIndex(where: { $0.id == row.id }) else { return }
            var updated = value
            if session.importDraft?.rows[index].content != updated.content { updated.duplicateApproved = false }
            invalidateReview(); session.importDraft?.rows[index] = updated
        })
    }
    private func replaceSource(_ source: ImportSourceDraft) {
        guard let index = session.importDraft?.sources.firstIndex(where: { $0.id == source.id }) else { return }
        invalidateReview(); session.importDraft?.sources[index] = source
    }
    private func applyMapping(_ source: ImportSourceDraft) {
        guard let mode = session.importDraft?.mode else { return }
        invalidateReview(); reviewing = true
        let token = session.sessionToken, revision = reviewRevision
        Task {
            do {
                let task = Task.detached(priority: .userInitiated) { try ImportParser.rows(source: source, mode: mode) }
                mappingTask = task
                let rows = try await task.value
                guard token == session.sessionToken, revision == reviewRevision else { return }
                session.importDraft?.rows.removeAll { $0.sourceID == source.id }
                session.importDraft?.rows.append(contentsOf: rows)
                mappingChanged.remove(source.id); clampPage()
            } catch { if token == session.sessionToken, revision == reviewRevision { self.error = error.localizedDescription } }
            if token == session.sessionToken, revision == reviewRevision { reviewing = false }
        }
    }
    private func editSelected(_ change: (inout ImportDraftRow) -> Void) {
        guard var batch = session.importDraft else { return }; invalidateReview()
        for index in batch.rows.indices where selection.contains(batch.rows[index].id) { change(&batch.rows[index]) }
        session.importDraft = batch
    }
    private func addRow() {
        guard var batch = session.importDraft, batch.mode != .statements else { return }; invalidateReview()
        if !batch.sources.contains(where: { $0.grid.isEmpty }) { batch.sources.append(ImportSourceDraft(filename: "Manual entry", bytes: Data(), grid: [])) }
        let source = batch.sources.first(where: { $0.grid.isEmpty })!
        let previous = batch.mode.isHolding ? batch.rows.last?.holding : nil
        let portfolio = portfolios.count == 1 ? portfolios.first : nil
        let content: ImportRowContent
        switch batch.mode {
        case .statements: return
        case .bankBalances: content = .bankBalance(BankBalanceInput())
        case .holdings, .metals: content = .holding(HoldingInput(portfolioID: previous?.portfolioID ?? portfolio?.id, portfolioName: previous?.portfolioName ?? portfolio?.name ?? (batch.mode == .metals ? "My metals" : "My crypto")))
        }
        let row = ImportDraftRow(sourceID: source.id, line: batch.rows.filter { $0.sourceID == source.id }.count + 1, content: content)
        if batch.rows.isEmpty { starterRow = (row.id, content) }
        batch.rows.append(row)
        session.importDraft = batch; page = (batch.rows.count - 1) / pageSize
    }
    private func prepareExternalInput() {
        invalidateReview()
        if let starterRow { session.importDraft?.rows.removeAll { $0.id == starterRow.id && $0.content == starterRow.content } }
        starterRow = nil
    }
    private func beginReview() {
        guard !session.importLoading, let batch = session.importDraft, (!batch.rows.isEmpty || batch.sources.contains { !$0.grid.isEmpty }), let document = session.document else { return }
        invalidateReview(); reviewing = true
        let token = session.sessionToken, revision = reviewRevision, catalog = session.catalog
        let task = Task.detached(priority: .userInitiated) {
            let evaluated = ImportBatchProcessor.evaluate(batch, document: document, catalog: catalog)
            var months = Set<String>()
            if batch.mode == .statements {
                let sources = Dictionary(uniqueKeysWithValues: batch.sources.map { ($0.id, $0) })
                for row in batch.rows where row.included {
                    if Task.isCancelled { break }
                    if let source = sources[row.sourceID], let date = try? source.dateFormat.date(row.statement.date) { months.insert(String(ImportDateFormat.today(date).prefix(7))) }
                }
            }
            return (evaluated, months.sorted())
        }
        reviewTask = task
        Task {
            let (evaluated, months) = await task.value
            guard token == session.sessionToken, revision == reviewRevision, !task.isCancelled else { return }
            review = evaluated; coveredMonths = months; reviewing = false; reviewTask = nil
            if usesSummary(batch) {
                if !evaluated.hasErrors && mappingChanged.isEmpty { importDetails = false }
                else { problemSources = Set(evaluated.sourceErrors.keys); problemRows = Set(evaluated.states.filter { $0.value.blocksSave }.map(\.key)); clampPage() }
            }
        }
    }
    private func invalidateReview() {
        reviewTask?.cancel(); reviewTask = nil; mappingTask?.cancel(); mappingTask = nil; review = nil; reviewing = false; error = nil; reviewRevision = UUID()
    }
    private func clampPage() { page = min(page, max(0, ((session.importDraft.map { displayedRows($0).count } ?? 0) - 1) / pageSize)) }
    private func resetView() { invalidateReview(); mappingChanged = []; selection = []; page = 0; starterRow = nil; importDetails = false; coveredMonths = []; editingStatementAccount = nil }
    private func save() async {
        guard let batch = session.importDraft, let review, !review.hasErrors, mappingChanged.isEmpty, !busy else { return }
        let token = session.sessionToken
        do { try await session.commitImportBatch(batch); resetView() }
        catch { if token == session.sessionToken { invalidateReview(); self.error = error.localizedDescription } }
    }
}

