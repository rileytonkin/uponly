import SwiftUI
import LocalAuthentication
import LocalAuthenticationEmbeddedUI

struct UpOnlyLockView: View {
    @Environment(UpOnlySession.self) private var session
    /// The code generated for a new vault. It survives Back, so stepping back and forward never silently swaps it.
    @State private var recovery: RecoveryCode?
    @State private var showsRecoveryCode = false
    @State private var savedCode = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var recoveryText = ""
    @State private var showRecovery = false
    @State private var showRestore = false
    private var compactUnlock: Bool { session.state == .locked && !showRecovery && !showRestore }
    private var codeIsComplete: Bool { (try? RecoveryCode(canonical: recoveryText)) != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let recovery, showsRecoveryCode, session.state == .newVault {
                UpOnlySetupHeader(step: 1, symbol: "key.fill", title: "Save your recovery code", subtitle: "We generated this code for you. Save it in case you lose access to this Mac.")
                UpOnlyRecoveryCodeCard(code: recovery)
                Toggle("I’ve saved my recovery code somewhere safe", isOn: $savedCode).toggleStyle(.checkbox).font(UpOnlyType.body).fixedSize(horizontal: false, vertical: true)
                Text("Keep it separately from your encrypted backups.").fixedSize(horizontal: false, vertical: true).font(UpOnlyType.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Back") { showsRecoveryCode = false }.buttonStyle(.bordered).disabled(session.isBusy)
                    Spacer(minLength: 4)
                    Button("Create encrypted vault") { Task { await session.create(recovery: recovery) } }
                        .buttonStyle(.glassProminent).controlSize(.large).keyboardShortcut(.defaultAction).disabled(session.isBusy || !savedCode)
                }
                Text("Touch ID or your Mac password will protect the vault key.").fixedSize(horizontal: false, vertical: true).font(UpOnlyType.caption).foregroundStyle(.secondary)
            } else if showRestore {
                UpOnlyWordmark(width: 64)
                Text("Restore your backup").font(UpOnlyType.title)
                Text("Use the recovery code saved when this backup’s vault was created.").font(UpOnlyType.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                recoveryField("Recovery code for your backup")
                    .accessibilityLabel("Recovery code for backup")
                    .onAppear {
                        #if UPONLY_FIXTURE
                        if let code = ProcessInfo.processInfo.environment["UPONLY_PREVIEW_RESTORE_CODE"] { recoveryText = code }
                        #endif
                    }
                // The code stays in the field after a failed attempt, so one typo doesn't mean typing it all again.
                Button("Choose encrypted backup…") { Task { await session.restoreBackup(code: recoveryText); if session.state == .unlocked { recoveryText = "" } } }
                    .disabled(session.isBusy || !codeIsComplete)
                Button("Back") { showRestore = false; recoveryText = "" }.disabled(session.isBusy)
            } else if showRecovery || session.state == .recovery {
                UpOnlyWordmark(width: 64)
                Text("Use your saved recovery code").font(UpOnlyType.title).fixedSize(horizontal: false, vertical: true)
                Text("Up Only generated this code during setup. On this Mac, you can also try unlocking with Touch ID or your Mac password.").font(UpOnlyType.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                recoveryField("Recovery code").accessibilityLabel("Recovery code")
                Button("Recover vault") { Task { await session.recover(code: recoveryText); if session.state == .unlocked { recoveryText = "" } } }
                    .buttonStyle(.glassProminent).disabled(session.isBusy || !codeIsComplete)
                Button("Back to unlock") { showRecovery = false; recoveryText = ""; session.returnToUnlock() }.buttonStyle(.bordered).disabled(session.isBusy)
            } else if session.state == .newVault {
                UpOnlyWordmark()
                VStack(alignment: .leading, spacing: 8) {
                    Text("All your wealth, in one place.").font(.system(size: 15, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    Text("Your accounts, assets and cash flow.").font(UpOnlyType.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("Encrypted. Stored on your Mac.").font(UpOnlyType.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                #if UPONLY_PERSONAL
                if !session.wiseProfiles.isEmpty {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(session.wiseProfiles) { profile in
                            VStack(spacing: 6) {
                                UpOnlyProfileImage(data: profile.image, name: profile.name, size: 44)
                                Text(profile.name).fixedSize(horizontal: false, vertical: true).font(UpOnlyType.caption).multilineTextAlignment(.center)
                            }.frame(maxWidth: .infinity)
                        }
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(UpOnlyTint.netWorth.opacity(0.07), in: RoundedRectangle(cornerRadius: UpOnlyLayout.radius))
                }
                #endif
                VStack(spacing: 10) {
                    Button { if recovery == nil { recovery = RecoveryCode.random(); savedCode = false }; showsRecoveryCode = true } label: {
                        Text("Get started").fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity)
                    }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                    Button { showRestore = true } label: {
                        Text("Restore an encrypted backup…").fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity)
                    }.buttonStyle(.bordered)
                }.controlSize(.large).disabled(session.isBusy)
            } else {
                // The logo and the fingerprint side by side in a small pill, nothing between them.
                HStack(spacing: 10) {
                    UpOnlyWordmark(width: 42)
                        .contextMenu {
                            Button("Use Mac password") { session.beginUnlock(usePassword: true) }
                            Button("Use recovery code") { showRecovery = true }
                        }
                        .accessibilityAction(named: Text("Use recovery code")) { showRecovery = true }
                        .accessibilityAction(named: Text("Use Mac password")) { session.beginUnlock(usePassword: true) }
                        .help("Control-click to use your recovery code")
                    if let context = session.authenticationContext {
                        UpOnlyAuthenticationIcon(context: context, password: { session.beginUnlock(usePassword: true) }) {
                            Task { await session.unlockEmbedded(context) }
                        }.id(ObjectIdentifier(context)).frame(width: 32, height: 32)
                    } else {
                        // Before Touch ID is ready, and after it's cancelled, the same fingerprint (never a spinner that
                        // swaps out): clicking it tries again, or asks for the Mac password after a failed attempt.
                        Image(systemName: "touchid").font(.system(size: 26)).foregroundStyle(.secondary)
                            .frame(width: 32, height: 32).accessibilityHidden(true)
                            .overlay { UpOnlyPasswordClick { session.authenticationFailed ? session.beginUnlock(usePassword: true) : session.beginUnlock() } }
                    }
                }.frame(height: 36)
            }
            if let message = session.message { Text(message).fixedSize(horizontal: false, vertical: true).font(UpOnlyType.body).foregroundStyle(.secondary) }
            if session.isBusy && !compactUnlock { ProgressView().controlSize(.small) }
        }.padding(.horizontal, compactUnlock ? 12 : UpOnlyLayout.inset).padding(.vertical, compactUnlock ? 10 : UpOnlyLayout.inset)
        // An error on the compact row gets the full width rather than wrapping into a narrow column.
        .frame(width: compactUnlock && session.message == nil ? 108 : 344, alignment: .leading)
        .accessibilityIdentifier("UpOnlyLocked")
        .animation(reduceMotion ? nil : .snappy, value: showsRecoveryCode)
        .onAppear {
            #if UPONLY_FIXTURE
            if session.state == .newVault, ProcessInfo.processInfo.environment["UPONLY_PREVIEW_DESTINATION"] == "recovery" { recovery = RecoveryCode.random(); showsRecoveryCode = true }
            #endif
        }
    }
    /// People copy the code from paper, so they need to see what they type: a monospaced field, not a secure one.
    private func recoveryField(_ title: String) -> some View {
        TextField(title, text: $recoveryText).textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced)).autocorrectionDisabled()
    }
}



// Attach Apple's authentication view before requesting evaluation. The same context
// then authorizes the existing protected Keychain read; no app-managed credential UI.
private struct UpOnlyAuthenticationIcon: View {
    let context: LAContext
    let password: () -> Void
    let ready: @MainActor @Sendable () -> Void
    var body: some View {
        UpOnlyEmbeddedAuthentication(context: context, ready: ready)
            .accessibilityHidden(true)
            .overlay {
                UpOnlyPasswordClick(action: password)
            }
    }
}

// The system password dialog can leave the menu visible but inactive. Accept
// its first mouse click as an action as well as activation, including retries.
private struct UpOnlyPasswordClick: NSViewRepresentable {
    let action: () -> Void
    func makeNSView(context: Context) -> UpOnlyPasswordButton {
        let button = UpOnlyPasswordButton()
        button.title = ""
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.setAccessibilityLabel("Use Mac password")
        button.toolTip = "Click to use your Mac password"
        button.target = button
        button.action = #selector(UpOnlyPasswordButton.clicked)
        button.onClick = action
        return button
    }
    func updateNSView(_ button: UpOnlyPasswordButton, context: Context) { button.onClick = action }
}

private final class UpOnlyPasswordButton: NSButton {
    var onClick: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    @objc func clicked() { onClick?() }
}

private struct UpOnlyEmbeddedAuthentication: NSViewControllerRepresentable {
    let context: LAContext
    let ready: @MainActor @Sendable () -> Void
    func makeNSViewController(context coordinator: Context) -> UpOnlyAuthenticationViewController {
        UpOnlyAuthenticationViewController(context: context, ready: ready)
    }
    func updateNSViewController(_ controller: UpOnlyAuthenticationViewController, context: Context) {}
}

// Embedded Touch ID pauses while its app is inactive. A menu-bar panel can be
// visible without activating its accessory app, so attachment alone is not ready.
final class UpOnlyAuthenticationViewController: NSViewController {
    private let authenticationContext: LAContext
    private var ready: (@MainActor @Sendable () -> Void)?
    private var activationObserver: NSObjectProtocol?
    init(context: LAContext, ready: @escaping @MainActor @Sendable () -> Void) {
        authenticationContext = context
        self.ready = ready
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func loadView() {
        view = LAAuthenticationView(context: authenticationContext, controlSize: .small)
    }
    override func viewDidAppear() {
        super.viewDidAppear()
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.startWhenVisible() }
        }
        NSApp.activate()
        view.window?.makeKey()
        DispatchQueue.main.async { [weak self] in self?.startWhenVisible() }
    }
    private func startWhenVisible() {
        guard NSApp.isActive, let window = view.window, window.isVisible, let ready else { return }
        window.makeKey()
        self.ready = nil
        ready()
    }
    override func viewDidDisappear() {
        super.viewDidDisappear()
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
    }
    deinit {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }
}
