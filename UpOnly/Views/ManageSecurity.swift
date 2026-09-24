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
    var securityOverview: some View {
        VStack(alignment: .leading, spacing: 16) {
            UpOnlySettingsCard(title: "App lock", subtitle: "", symbol: "lock.shield.fill") {
                Label("Unlock with Touch ID or your Mac password", systemImage: "touchid")
                    .font(UpOnlyType.body).fixedSize(horizontal: false, vertical: true)
                Text("Locks after five minutes of inactivity, or when your Mac locks or sleeps.")
                    .font(UpOnlyType.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button { session.lockAndAuthenticate() } label: { Label("Lock now", systemImage: "lock") }
            }
            UpOnlySettingsCard(title: "Recovery code", subtitle: "", symbol: "key.fill") {
                Text("Opens this vault if Touch ID and your Mac password can’t. Replace it if someone may have seen it.")
                    .font(UpOnlyType.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button { openSecurityPage(.recoveryCode) } label: { Label("Create a new recovery code…", systemImage: "key") }
            }
            UpOnlySettingsCard(title: "Backup and recovery", subtitle: "", symbol: "externaldrive.fill") {
                Text("Keep your recovery code separately. You’ll need it to restore a backup.")
                    .font(UpOnlyType.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button { Task { await session.exportBackup() } } label: { Label("Export encrypted backup…", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.glassProminent)
                Button { openSecurityPage(.restore) } label: { Label("Restore from a backup…", systemImage: "clock.arrow.circlepath") }
            }
            UpOnlySettingsCard(title: "Diagnostics", subtitle: "", symbol: "stethoscope") {
                Text("Writes an unencrypted text file to the app's support folder listing account and holding names and dates (no amounts), to help find chart gaps. Delete it when you're done.")
                    .font(UpOnlyType.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Write diagnostics file") { diagnosticsMessage = session.writeDiagnostics() }.buttonStyle(.bordered)
                if let diagnosticsMessage { Text(diagnosticsMessage).font(UpOnlyType.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }
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
