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
            UpOnlyMenuScroll { UpOnlyEntryFlow() }
        } else {
        UpOnlyMenuScroll {
        VStack(alignment: .leading, spacing: 16) {
            if let batch = session.importDraft {
                if usesSummary(batch) {
                    Button("Back to summary") { importDetails = false; beginReview() }.buttonStyle(.upOnlySecondary)
                } else if !isBalanceUpdate(batch) { batchHeader(batch) }
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
                    if let review, review.possibleDuplicates > 0 { duplicateChoices(review.possibleDuplicates) }
                    // Updating existing balances is one list of rows; anything else keeps a card per row.
                    let compact = isBalanceUpdate(batch)
                    if !usesSummary(batch) && batch.rows.count > 1 && !compact { rowActions(batch) }
                    let visibleRows = Array(displayedRows(batch).dropFirst(page * pageSize).prefix(pageSize))
                    if compact {
                        // One date for every balance, as they're usually all read on the same day.
                        HStack {
                            Text("As of").font(UpOnlyType.body).foregroundStyle(.secondary)
                            Spacer()
                            UpOnlyDateButton(date: Binding(get: { batch.rows.first.flatMap { try? ImportDateFormat.iso.date($0.bank.date) } ?? UTCDay.today() }, set: { date in
                                invalidateReview()
                                for index in session.importDraft?.rows.indices ?? 0..<0 { session.importDraft?.rows[index].bank.date = ImportDateFormat.today(date) }
                            }))
                        }
                        ManageCard {
                            ForEach(Array(visibleRows.enumerated()), id: \.element.id) { index, row in
                                rowEditor(row, batch: batch, compact: true)
                            }
                            if review == nil { addRowItem(batch) }
                        }
                    } else {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(visibleRows) { row in rowEditor(row, batch: batch, compact: false) }
                    }
                    // Another row is part of the list, not a button under it.
                    if batch.mode != .statements, review == nil, !usesSummary(batch) { ManageCard { addRowItem(batch) } }
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
                // Several at once, as lists in the home style: bring something in, or update what's tracked. Statements
                // are Add's own row, so they aren't repeated here.
                if let message = session.importMessage {
                    Label(message, systemImage: "checkmark.circle.fill").font(UpOnlyType.body).foregroundStyle(UpOnlyTint.cashFlow).fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Bring in").font(UpOnlyType.section)
                    ManageCard {
                        ForEach(Array(orderedModes.filter { $0 != .statements }.enumerated()), id: \.element) { index, mode in
                            UpOnlyRow(title: bulkTitle(mode), caption: bulkCaption(mode), chevron: true, action: { openMode(mode, bulk: true) }) {
                                UpOnlySymbolBadge(symbol: mode == .statements ? "doc.text.fill" : mode.kind.symbol, tint: mode.kind.tint, size: 28)
                            }
                        }
                    }
                }
                let tracked = orderedModes.filter { $0 != .statements && session.document?.hasData($0.kind) == true }
                if !tracked.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Update what you have").font(UpOnlyType.section)
                        ManageCard {
                            ForEach(Array(tracked.enumerated()), id: \.element) { index, mode in
                                UpOnlyRow(title: mode == .bankBalances ? "All balances" : mode == .holdings ? "All crypto" : "All metals",
                                          caption: mode == .bankBalances ? "Every account’s balance, in one table" : mode == .holdings ? "Every coin’s quantity, in one table" : "Every metal’s weight, in one table", chevron: true, action: { session.startImport(mode, prefill: true); resetView() }) {
                                    UpOnlySymbolBadge(symbol: "arrow.triangle.2.circlepath", tint: mode.kind.tint, size: 28)
                                }
                            }
                        }
                    }
                }
            }
            if let batch = session.importDraft, batch.mode != .statements || !batch.rows.isEmpty || busy { importFooter(batch) }
        }.padding(.horizontal, UpOnlyLayout.inset).padding(.bottom, UpOnlyLayout.inset).frame(maxWidth: .infinity, alignment: .leading)
        }.background(UpOnlyBackdrop())
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
        .onChange(of: session.importRequest) { _, request in
            guard let request else { return }
            session.importRequest = nil
            switch request {
            case .paste:
                guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { error = "Copy some spreadsheet cells first."; return }
                prepareExternalInput(); Task { await session.pasteImport(text) }
            case .chooseFiles: prepareExternalInput(); Task { await session.chooseImportFiles() }
            case .template: Task { await session.saveImportTemplate() }
            case .discard: discard = true
            }
        }
        .onChange(of: session.importLoading) { _, loading in if !loading, let batch = session.importDraft, usesSummary(batch) { beginReview() } }
        .onChange(of: session.document?.generation) { _, _ in if let batch = session.importDraft, usesSummary(batch) { beginReview() } }
        .onAppear { if let batch = session.importDraft, usesSummary(batch) { beginReview() }; if let batch = session.importDraft, batch.mode != .statements, batch.rows.isEmpty, batch.sources.allSatisfy({ $0.grid.isEmpty }) { addRow() } }
        .onDisappear { invalidateReview() }
    }
    private func importOverview(_ batch: ImportBatchDraft) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if batch.sources.allSatisfy({ $0.grid.isEmpty }) {
                ManageEmptyState(title: batch.mode == .statements ? "Choose your statements" : "Choose a file",
                                 detail: "Pick CSV files, or drop them here. You’ll check them before anything is saved.",
                                 symbol: "doc.text.fill", tint: batch.mode.kind.tint, actionTitle: "Choose CSV files…") { Task { await session.chooseImportFiles() } }
                    .disabled(busy)
            } else {
                // Each file is a card: the account it's for (with its bank's logo), and for a statement, today's balance.
                ForEach(batch.sources.filter { !$0.grid.isEmpty }) { source in
                    let statement = batch.mode == .statements && !batch.rows.isEmpty
                    ManageCard {
                        HStack(spacing: 10) {
                            UpOnlyBankBadge(name: statement ? source.account.name : source.filename, size: 28)
                            if statement {
                                Menu { accountChoices(source) } label: {
                                    HStack(spacing: 4) {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(source.account.name.isEmpty ? "Choose account" : accountTitle(source.account.name, source.account.currency))
                                                .font(UpOnlyType.row.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                                            Text(source.filename).font(UpOnlyType.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                        }
                                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                                    }.contentShape(Rectangle())
                                }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                                    .accessibilityLabel("Statement account").help(source.filename)
                            } else {
                                Text(source.filename).font(UpOnlyType.row.weight(.medium)).lineLimit(1).truncationMode(.middle).help(source.filename)
                            }
                            Spacer(minLength: 0)
                            ManageRowMenu(label: "File options") {
                                Button("Add CSV files…") { Task { await session.chooseImportFiles() } }
                                Button("Remove file", role: .destructive) {
                                    invalidateReview(); session.importDraft?.sources.removeAll { $0.id == source.id }
                                    session.importDraft?.rows.removeAll { $0.sourceID == source.id }; beginReview()
                                }
                            }
                        }.padding(.vertical, 8).disabled(busy)
                        if statement, editingStatementAccount != source.id {
                            // One real balance anchors the history rebuilt from these transactions.
                            HStack(spacing: 8) {
                                Text("Balance now").font(UpOnlyType.body).foregroundStyle(.secondary)
                                Spacer(minLength: 8)
                                UpOnlyValueField("Optional", text: sourceBinding(source, \.balance)).textFieldStyle(.plain).multilineTextAlignment(.trailing)
                                    .font(UpOnlyType.row.monospacedDigit()).frame(width: 110)
                                    .accessibilityLabel("Current balance for " + (source.account.name.isEmpty ? source.filename : source.account.name))
                                Text(source.account.currency).font(UpOnlyType.body).foregroundStyle(.secondary)
                            }.padding(.vertical, 9).help("Lets Up Only work out the balance on every day these transactions cover.")
                        }
                        if editingStatementAccount == source.id {
                            VStack(alignment: .leading, spacing: 8) {
                                UpOnlyOwnerPicker(owner: Binding(get: { source.account.ownerBusinessID }, set: { value in var account = source.account; account.ownerBusinessID = value; setStatementAccount(source, account) }))
                                HStack(spacing: 8) {
                                    TextField("Account name", text: Binding(get: { source.account.name }, set: { value in var account = source.account; account.name = value; setStatementAccount(source, account) })).textFieldStyle(.roundedBorder)
                                    // A new account starts in the file's own currency; left empty, it goes back to it.
                                    UpOnlyCurrencyField(code: Binding(get: { source.account.currency }, set: { value in var account = source.account; account.currency = value; setStatementAccount(source, account) }),
                                                        fallback: fileCurrency(source) ?? "USD", label: "Account currency").frame(width: 52).textFieldStyle(.roundedBorder)
                                    Button("Done") { editingStatementAccount = nil; beginReview() }.buttonStyle(.upOnlySecondary)
                                }
                            }.padding(.vertical, 9)
                        }
                        if editingStatementAccount != source.id, !batch.rows.isEmpty { fileQuestions(source, mode: batch.mode) }
                    }
                }
                if batch.rows.isEmpty {
                    Text("This file has no transactions.").font(UpOnlyType.body).foregroundStyle(.secondary)
                    primaryAction("Choose other files…") {
                        session.importDraft?.sources.removeAll { !$0.grid.isEmpty }
                        Task { await session.chooseImportFiles() }
                    }.disabled(busy)
                } else if let review {
                    if !coveredPeriod.isEmpty { Text(coveredPeriod).font(UpOnlyType.section) }
                    if let source = batch.sources.first(where: { review.needsAccount.contains($0.id) }) {
                        // The account is what's missing, so choosing one is the next step, not fixing rows.
                        Text("Which account are these transactions from?").font(UpOnlyType.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Menu { accountChoices(source) } label: { Text("Choose an account").frame(maxWidth: .infinity) }
                            .menuStyle(.button).buttonStyle(.upOnlyPrimary).controlSize(.large).accessibilityLabel("Choose an account for " + source.filename)
                    } else if let source = batch.sources.first(where: { review.needsFormat.contains($0.id) }) {
                        // Also a question about the file, answered on its card above.
                        Text("Choose how " + source.filename + " writes " + (source.unconfirmedDate != nil ? "dates" : "amounts") + " above to continue.")
                            .font(UpOnlyType.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else if review.hasErrors || !mappingChanged.isEmpty {
                        if review.possibleDuplicates > 0 { duplicateChoices(review.possibleDuplicates) }
                        if review.possibleDuplicates == 0 || hasOtherProblems(review) {
                            UpOnlyNotice(review.globalError ?? review.sourceErrors.values.first ?? "Some rows need a correction.", style: .warning)
                            primaryAction("Fix rows") { showProblems(review) }
                        } else {
                            Button("Check them one by one") { showProblems(review) }.buttonStyle(.upOnlySecondary)
                        }
                    } else if review.learnedDays > 0 && review.readyRows == 0 {
                        Text("Dates added for \(review.learnedDays.formatted()) saved transactions").font(UpOnlyType.section)
                        Text("Balance history will be rebuilt when you save.").font(UpOnlyType.body).foregroundStyle(.secondary)
                        primaryAction("Save and rebuild history") { Task { await save() } }.disabled(busy || editingStatementAccount != nil)
                    } else if review.added == 0 {
                        Text(batch.mode == .statements ? "Nothing new: every transaction here is already saved." : "Already up to date.").font(UpOnlyType.body).foregroundStyle(.secondary)
                        primaryAction("Done") { session.discardImport() }
                    } else {
                        if batch.mode != .statements {
                            // What will be saved, as a list: each account with its logo and new balance, or each holding.
                            let ready = batch.rows.filter { if case .ready = review.states[$0.id] { return true }; return false }
                            ManageCard {
                                ForEach(Array(ready.enumerated()), id: \.element.id) { index, row in
                                    if batch.mode == .bankBalances {
                                        UpOnlyRow(title: row.bank.account.name, caption: row.bank.account.currency + " · " + row.bank.date,
                                                  value: balanceText(row, in: batch) + " " + row.bank.account.currency) {
                                            UpOnlyBankBadge(name: row.bank.account.name, size: 28)
                                        }
                                    } else {
                                        UpOnlyRow(title: row.holding.assetName.isEmpty ? row.holding.portfolioName : row.holding.assetName,
                                                  caption: row.holding.portfolioName + " · " + (review.states[row.id]?.displayText(privacy: session.privacyMode) ?? "")) {
                                            UpOnlyAssetBadge(assetID: row.holding.resolvedCoinID.nilIfEmpty ?? row.holding.coin, symbol: row.holding.assetName, size: 28)
                                        }
                                    }
                                }
                            }
                        }
                        let excluded = batch.rows.filter { !$0.included }.count
                        let skipped = [review.duplicates > 0 ? "\(review.duplicates.formatted()) " + (batch.mode == .statements ? "already imported" : "unchanged") : nil,
                                       excluded > 0 ? "\(excluded.formatted()) excluded" : nil].compactMap { $0 }.joined(separator: " · ")
                        if !skipped.isEmpty { Text(skipped).font(UpOnlyType.caption).foregroundStyle(.secondary) }
                        if review.unarchivedFiles > 0 {
                            Text("The archive of original files is full, so " + (review.unarchivedFiles == 1 ? "this file’s original isn’t" : "these files’ originals aren’t") + " kept. The transactions import as usual.")
                                .font(UpOnlyType.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        let count = review.readyRows
                        // Only the file itself, or a balance, is new: say so rather than "Import 0 transactions".
                        if count == 0 { Text(batch.mode == .statements ? "No new transactions" : "Already up to date").font(UpOnlyType.section) }
                        primaryAction(count == 0 ? "Save" : batch.mode == .statements ? "Import \(count.formatted()) \(count == 1 ? "transaction" : "transactions")" : "Save \(count.formatted()) \(count == 1 ? "update" : "updates")") { Task { await save() } }
                            .disabled(busy || editingStatementAccount != nil)
                    }
                } else if !busy, editingStatementAccount == nil {
                    primaryAction("Review") { beginReview() }
                } else if busy {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                }
            }
            if let message = error ?? session.importMessage, !session.importLoading {
                Text(message).font(UpOnlyType.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.horizontal, UpOnlyLayout.inset).padding(.bottom, UpOnlyLayout.inset).frame(maxWidth: .infinity, alignment: .leading)
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
    private func rowEditor(_ row: ImportDraftRow, batch: ImportBatchDraft, compact: Bool) -> some View {
        ImportRowEditor(row: rowBinding(row), mode: batch.mode, accounts: accounts, portfolios: portfolios, coins: coins,
                        usesDebitCredit: batch.sources.first(where: { $0.id == row.sourceID }).map { $0.mapping[.debit] != nil || $0.mapping[.credit] != nil } ?? false,
                        sourceName: batch.sources.filter { !$0.grid.isEmpty }.count > 1 ? batch.sources.first(where: { $0.id == row.sourceID })?.filename ?? "" : "", state: review?.states[row.id], selected: selection.contains(row.id),
                        manual: batch.sources.first(where: { $0.id == row.sourceID })?.grid.isEmpty == true, selectable: !usesSummary(batch), compact: compact,
                        select: { if selection.contains(row.id) { selection.remove(row.id) } else { selection.insert(row.id) } },
                        remove: { invalidateReview(); session.importDraft?.rows.removeAll { $0.id == row.id }; clampPage() }).disabled(busy)
    }
    /// New balances for accounts that already exist, typed in: a list to fill in, not a form per account.
    private func isBalanceUpdate(_ batch: ImportBatchDraft) -> Bool {
        batch.mode == .bankBalances && batch.rows.count > 1 && batch.rows.allSatisfy { row in
            row.bank.account.existingID != nil && batch.sources.first(where: { $0.id == row.sourceID })?.grid.isEmpty == true
        }
    }
    /// The page's one main action: full width, prominent.
    private func primaryAction(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).frame(maxWidth: .infinity) }
            .buttonStyle(.upOnlyPrimary).controlSize(.large).keyboardShortcut(.defaultAction)
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
                primaryAction("Check corrections") { beginReview() }.disabled(busy || !mappingChanged.isEmpty)
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
                    Button("Cancel reading") { session.cancelImport() }.buttonStyle(.upOnlySecondary)
                } else if reviewing {
                    ProgressView().controlSize(.small)
                    Button("Cancel review") { invalidateReview() }.buttonStyle(.upOnlySecondary)
                } else if review != nil {
                    Button("Back to editing") { invalidateReview() }.buttonStyle(.upOnlySecondary)
                }
            }.controlSize(.small).font(UpOnlyType.body)
            // The main action, full width like the rest of the app's.
            if let review {
                primaryAction("Save reviewed changes") { Task { await save() } }
                    .disabled(busy || review.hasErrors || review.added == 0 || !mappingChanged.isEmpty)
            } else if !batch.rows.isEmpty {
                primaryAction("Review changes") { beginReview() }
                    .disabled(busy || batch.rows.isEmpty || !mappingChanged.isEmpty)
            }
            }
        }.padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    private var orderedModes: [ImportMode] {
        ImportMode.allCases.sorted { lhs, rhs in
            let left = session.document?.shows(lhs.kind) == true, right = session.document?.shows(rhs.kind) == true
            if left != right { return left }
            return ImportMode.allCases.firstIndex(of: lhs)! < ImportMode.allCases.firstIndex(of: rhs)!
        }
    }
    private func bulkTitle(_ mode: ImportMode) -> String {
        switch mode { case .statements: "Bank statements"; case .bankBalances: "Balances"; case .holdings: "Crypto"; case .metals: "Metals" }
    }
    private func bulkCaption(_ mode: ImportMode) -> String {
        switch mode {
        case .statements: "CSV files from your bank, several at once"
        case .bankBalances: "Paste or import a table of accounts"
        case .holdings: "Paste or import coins and quantities"
        case .metals: "Paste or import weights"
        }
    }
    private func batchHeader(_ batch: ImportBatchDraft) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(batch.mode == .metals ? "Enter pure metal weight, excluding alloys. Prices exclude dealer premiums." : batch.mode == .holdings ? "Enter total quantities, not changes in quantity." : "A snapshot of your accounts. Overdrafts and zero balances are welcome.").fixedSize(horizontal: false, vertical: true)
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
    private func openMode(_ mode: ImportMode, bulk: Bool = false) {
        guard session.startImport(mode) else { return }; resetView()
        session.importTableMode = bulk
        if mode != .statements { addRow() }
    }
    /// The list's own last row for adding another account, coin or metal.
    private func addRowItem(_ batch: ImportBatchDraft) -> some View {
        UpOnlyRow(title: addRowTitle(batch.mode), caption: batch.mode == .bankBalances ? "Another account and its balance" : batch.mode == .metals ? "Another metal and its weight" : "Another coin and its quantity", action: busy ? nil : { addRow() }) {
            UpOnlySymbolBadge(symbol: "plus", tint: UpOnlyTint.brand, size: batch.mode == .bankBalances ? 28 : 24)
        }
    }
    private func addRowTitle(_ mode: ImportMode) -> String {
        switch mode { case .statements: "Add a transaction"; case .bankBalances: "Add an account"; case .holdings: "Add a coin"; case .metals: "Add a metal" }
    }
    private func sourceCard(_ source: ImportSourceDraft, mode: ImportMode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(source.filename, systemImage: source.grid.isEmpty ? "square.and.pencil" : "doc.text").fixedSize(horizontal: false, vertical: true).font(UpOnlyType.section)
                Spacer()
                let count = session.importDraft?.rows.filter { $0.sourceID == source.id }.count ?? 0
                Text("\(count) \(count == 1 ? "row" : "rows")").fixedSize(horizontal: false, vertical: true).font(.caption).foregroundStyle(.secondary)
                Button { invalidateReview(); session.importDraft?.rows.removeAll { $0.sourceID == source.id }; session.importDraft?.sources.removeAll { $0.id == source.id }; mappingChanged.remove(source.id); clampPage() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).help("Remove this source and its rows").accessibilityLabel("Remove " + source.filename)
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
            VStack(spacing: 0) { fileQuestions(source, mode: mode, all: true) }
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
        }.padding(UpOnlyLayout.cardInset).modifier(UpOnlyContentSurface()).disabled(busy)
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
    /// What a file leaves open, as rows of its card: a date or number format two readings fit, asked with a note until
    /// one is chosen, and for a signed Amount column, which way positive amounts go. `all` shows every setting.
    @ViewBuilder private func fileQuestions(_ source: ImportSourceDraft, mode: ImportMode, all: Bool = false) -> some View {
        if !mode.isHolding, all || source.unconfirmedDate != nil {
            if let example = source.unconfirmedDate { UpOnlyNotice(dateQuestion(example)).padding(.top, 9) }
            UpOnlyFormRow(label: "Dates") {
                UpOnlyFormMenu(value: source.dateFormat.title, label: "Date format for " + source.filename) {
                    ForEach(ImportDateFormat.allCases, id: \.self) { format in Button(format.title) { updateSource(source) { $0.dateFormat = format; $0.unconfirmedDate = nil } } }
                }
            }
        }
        if all || source.unconfirmedNumber != nil {
            if let example = source.unconfirmedNumber {
                UpOnlyNotice("Amounts like " + example + " read differently in each number format. Choose the one this file uses.").padding(.top, 9)
            }
            UpOnlyFormRow(label: "Numbers") {
                UpOnlyFormMenu(value: source.numberFormat.rawValue, label: "Number format for " + source.filename) {
                    ForEach(ImportNumberFormat.allCases, id: \.self) { format in Button(format.rawValue) { updateSource(source) { $0.numberFormat = format; $0.unconfirmedNumber = nil } } }
                }
            }
        }
        // The summary asks only when it's on (a card export) or nothing in the file is negative; known banks write
        // money out as negative. The details always show it.
        if mode == .statements, source.hasSignedAmount, all || source.positiveIsOutflow || !ImportParser.signsKnown(source.grid) && !source.hasNegativeAmount {
            UpOnlyFormRow(label: "Positive amounts are money out") {
                Toggle("Positive amounts are money out", isOn: Binding(get: { source.positiveIsOutflow }, set: { value in updateSource(source) { $0.positiveIsOutflow = value } }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(UpOnlyTint.brand)
            }.help("Card exports often list purchases as positive amounts and payments as negative.")
        }
    }
    /// "03/04/2025 could be 3 April 2025 or 4 March 2025."
    private func dateQuestion(_ example: String) -> String {
        var readings: [String] = []
        for format in ImportDateFormat.allCases {
            guard let date = try? format.date(example) else { continue }
            let text = date.formatted(Date.FormatStyle(date: .long, time: .omitted, timeZone: UTCDay.timeZone))
            if !readings.contains(text) { readings.append(text) }
        }
        guard readings.count > 1 else { return "Check how this file writes dates." }
        return example + " could be " + readings.joined(separator: " or ") + ". Choose how this file writes dates."
    }
    /// A file setting changed on the summary is checked straight away; in the details, with the other corrections.
    private func updateSource(_ source: ImportSourceDraft, _ change: (inout ImportSourceDraft) -> Void) {
        guard var batch = session.importDraft, let index = batch.sources.firstIndex(where: { $0.id == source.id }) else { return }
        invalidateReview(); change(&batch.sources[index]); session.importDraft = batch
        if usesSummary(batch), !importDetails { beginReview() }
    }
    /// Rows that repeat another (same day, description and amount), settled together rather than a click each.
    private func duplicateChoices(_ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            UpOnlyNotice(count == 1 ? "1 transaction has the same day, description and amount as another." : "\(count.formatted()) transactions have the same day, description and amount as others.")
            ManageCard {
                UpOnlyRow(title: "Skip all duplicates", caption: "Leave them out of this import", action: busy ? nil : { settleDuplicates(keep: false) }) {
                    UpOnlySymbolBadge(symbol: "minus", tint: .secondary, size: 28)
                }
                UpOnlyRow(title: "Keep all as separate payments", caption: "Each one is a payment of its own", action: busy ? nil : { settleDuplicates(keep: true) }) {
                    UpOnlySymbolBadge(symbol: "plus", tint: UpOnlyTint.cashFlow, size: 28)
                }
            }
        }
    }
    private func settleDuplicates(keep: Bool) {
        guard let review, var batch = session.importDraft else { return }
        batch.settleDuplicates(review, keep: keep)
        invalidateReview(); session.importDraft = batch; beginReview()
    }
    /// Anything besides possible duplicates that stops saving.
    private func hasOtherProblems(_ review: ImportEvaluation) -> Bool {
        review.globalError != nil || !review.sourceErrors.isEmpty || !mappingChanged.isEmpty || review.states.values.contains { $0.blocksSave && $0 != .possibleDuplicate }
    }
    private func showProblems(_ review: ImportEvaluation) {
        problemRows = Set(review.states.filter { $0.value.blocksSave }.map(\.key)); importDetails = true; page = 0
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

