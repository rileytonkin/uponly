import SwiftUI

struct StatementReview: View {
    @Environment(UpOnlySession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State var draft: StatementDraft
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review statement").font(.title2.weight(.semibold))
            Text("Check transfers between your own accounts. They should be marked Transfer so they never count as income or spending.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Account: " + (session.document?.accounts.first(where: { $0.id == draft.accountID })?.name ?? "Unavailable")).font(.headline)
            Text("\(draft.entries.count) entries · " + draft.filename).font(.caption).foregroundStyle(.secondary)
            List($draft.entries) { $entry in
                HStack {
                    VStack(alignment: .leading) { Text(entry.label).lineLimit(1); Text(entry.month).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Text(UpOnlyFormat.quantity(entry.amount) + " " + entry.currency).monospacedDigit()
                    Picker("Type", selection: $entry.kind) {
                        Text("Income").tag(EntryKind.income); Text("Expense").tag(EntryKind.expense); Text("Transfer").tag(EntryKind.transfer)
                    }.labelsHidden().frame(width: 110)
                }
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Button("Cancel") { session.pendingStatement = nil; dismiss() }
                Spacer()
                Button("Import reviewed entries") { Task {
                    do { try await session.importStatement(draft); session.pendingStatement = nil; dismiss() }
                    catch { self.error = "Import could not be saved. Your existing entries are unchanged." }
                } }.buttonStyle(.borderedProminent).disabled(session.isBusy)
            }
        }.padding(24).frame(width: 640, height: 460)
    }
}

struct StatementAccountChooser: View {
    @Environment(UpOnlySession.self) private var session
    @State private var selected: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Which account is this statement for?").font(.title3.weight(.semibold))
            if session.document?.accounts.isEmpty == true {
                Text("Add a bank account first, then import its statement.").foregroundStyle(.secondary)
            } else {
                Picker("Account", selection: $selected) {
                    Text("Choose an account").tag(nil as UUID?)
                    ForEach(session.document?.accounts ?? []) { account in Text(account.name + " · " + account.currency).tag(Optional(account.id)) }
                }
            }
            HStack {
                Button("Cancel") { session.choosingStatementAccount = false }
                Spacer()
                Button("Choose statement…") {
                    guard let selected else { return }
                    session.choosingStatementAccount = false
                    Task { await session.chooseStatements(accountID: selected) }
                }.disabled(selected == nil).buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 400)
    }
}
