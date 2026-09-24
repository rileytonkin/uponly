import SwiftUI

/// Manage → Backup & security: lock, backup export, restore, recovery code and diagnostics.
extension UpOnlyManagement {
    @ViewBuilder var security: some View {
        switch securityPage {
        case .recoveryCode?: newRecoveryCodePage
        case .restore?: restorePage
        case nil: securityOverview
        }
    }
    /// Backup & security as one list: locking, the recovery code, backups, and diagnostics apart from them.
    var securityOverview: some View {
        VStack(alignment: .leading, spacing: 14) {
            ManageCard {
                ManageRow(title: "Lock now", caption: "Touch ID or your Mac password opens it. Locks after five minutes idle, or when your Mac locks or sleeps.",
                          action: { session.lockAndAuthenticate() }) {
                    UpOnlySymbolBadge(symbol: "lock.fill", size: 24)
                } menu: { EmptyView() }
                ManageRow(title: "New recovery code", caption: "Opens this vault if Touch ID and your password can’t. Replace it if someone may have seen it.",
                          divided: true, chevron: true, action: { openSecurityPage(.recoveryCode) }) {
                    UpOnlySymbolBadge(symbol: "key.fill", size: 24)
                } menu: { EmptyView() }
            }
            ManageCard {
                ManageRow(title: "Export encrypted backup", caption: "Restoring it needs your recovery code; keep the two apart.",
                          action: { Task { await session.exportBackup() } }) {
                    UpOnlySymbolBadge(symbol: "square.and.arrow.up", size: 24)
                } menu: { EmptyView() }
                ManageRow(title: "Restore from a backup", caption: "Replaces everything here; your current vault is kept beside it.",
                          divided: true, chevron: true, action: { openSecurityPage(.restore) }) {
                    UpOnlySymbolBadge(symbol: "clock.arrow.circlepath", size: 24)
                } menu: { EmptyView() }
            }
            ManageCard {
                ManageRow(title: "Write diagnostics file", caption: "An unencrypted list of account and holding names and dates (no amounts), to help find chart gaps. Delete it when you’re done.",
                          action: { diagnosticsMessage = session.writeDiagnostics() }) {
                    UpOnlySymbolBadge(symbol: "stethoscope", tint: Color.secondary, size: 24)
                } menu: { EmptyView() }
            }
            if let diagnosticsMessage { Text(diagnosticsMessage).font(UpOnlyType.caption).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
        }
    }
    @ViewBuilder var newRecoveryCodePage: some View {
        if let code = newRecoveryCode {
            VStack(alignment: .leading, spacing: 14) {
                Text("Once you replace it, your current code stops opening this vault. Keep the new one separately from your backups.")
                    .font(UpOnlyType.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                UpOnlyRecoveryCodeCard(code: code)
                Toggle("I’ve saved my new recovery code somewhere safe", isOn: $savedNewCode).toggleStyle(.checkbox)
                    .font(UpOnlyType.body).fixedSize(horizontal: false, vertical: true)
                Text("Backups you’ve already exported still open with the code that was current when you exported them. Export a new backup after this.")
                    .font(UpOnlyType.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button { Task { await replaceRecoveryCode(code) } } label: { Text("Replace recovery code").frame(maxWidth: .infinity) }
                    .buttonStyle(.glassProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                    .disabled(!savedNewCode || session.isBusy)
                Text("Touch ID or your Mac password confirms the change.")
                    .font(UpOnlyType.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    var restorePage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Everything in Up Only is replaced with the backup. Your current vault is kept in a folder next to it, not deleted.")
                .font(UpOnlyType.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            // People copy the code from paper, so they need to see what they type: a monospaced field, not a secure one.
            TextField("Recovery code for the backup", text: $restoreCode).textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced)).autocorrectionDisabled()
                .accessibilityLabel("Recovery code for the backup")
            Text("Use the code that was current when the backup was exported.")
                .font(UpOnlyType.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button { Task { await restoreFromBackup(confirmed: false) } } label: { Label("Choose backup…", systemImage: "folder") }
                .buttonStyle(.glassProminent).disabled(session.isBusy || (try? RecoveryCode(canonical: restoreCode)) == nil)
            if session.isBusy { ProgressView().controlSize(.small) }
        }
    }
    func openSecurityPage(_ page: SecurityPage) {
        session.message = nil
        if page == .recoveryCode, newRecoveryCode == nil { newRecoveryCode = RecoveryCode.random(); savedNewCode = false }
        securityPage = page
    }
    func closeSecurityPage() {
        cancelRestore(); restoreCode = ""; securityPage = nil
    }
    func cancelRestore() {
        confirmingRestore = false; session.cancelPendingRestore()
    }
    func replaceRecoveryCode(_ code: RecoveryCode) async {
        guard await session.replaceRecoveryCode(code) else { return }
        // Back on Backup & security, with the session's note that the code was replaced.
        newRecoveryCode = nil; savedNewCode = false; securityPage = nil
    }
    func restoreFromBackup(confirmed: Bool) async {
        confirmingRestore = false
        if await session.restoreReplacingVault(code: restoreCode, confirmed: confirmed) == .needsConfirmation { confirmingRestore = true }
    }
}
