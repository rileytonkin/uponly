import SwiftUI
import Observation

@MainActor final class UpOnlyApplicationDelegate: NSObject, NSApplicationDelegate {
    let session = UpOnlySession()
    private var menu: UpOnlyMenuController?
    func startMenu() {
        guard menu == nil else { return }
        if !session.isFixture || ProcessInfo.processInfo.environment["UPONLY_PREVIEW_MENU_BAR"] == "1" {
            menu = UpOnlyMenuController(session: session)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
@MainActor enum UpOnlyApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = UpOnlyApplicationDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        delegate.startMenu()
        withExtendedLifetime(delegate) { app.run() }
    }
}

/// The same compact menu content, with explicit lifetime while importing or
/// presenting system dialogs. Finder can become active without losing the drop target.
@MainActor final class UpOnlyMenuController: NSObject, NSPopoverDelegate {
    private let session: UpOnlySession
    private let item: NSStatusItem
    private let popover = NSPopover()
    private var host: NSHostingController<AnyView>!
    init(session: UpOnlySession) {
        self.session = session
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.isVisible = true
        if let button = item.button {
            #if UPONLY_FIXTURE
            button.title = "up*"
            button.setAccessibilityLabel("Up Only Preview")
            #else
            button.image = UpOnlyArtwork.status
            button.setAccessibilityLabel("Up Only")
            #endif
            button.setAccessibilityIdentifier("UpOnlyStatusItem")
            button.target = self; button.action = #selector(toggle)
        }
        popover.delegate = self; popover.animates = false
        host = NSHostingController(rootView: AnyView(UpOnlyPanel(menuLifecycleManaged: true, closeMenu: { [weak self] in self?.close() }).environment(session)))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        observeLifetime()
        #if UPONLY_FIXTURE
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            print("UPONLY_STATUS visible=\(item.isVisible) frame=\(String(describing: item.button?.window?.frame))")
            fflush(stdout)
        }
        #endif
    }
    private func observeLifetime() {
        withObservationTracking {
            popover.behavior = session.menuStaysOpen ? .applicationDefined : .transient
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeLifetime() }
        }
    }
    @objc private func toggle() {
        if session.filePickerIsOpen { session.focusFilePicker(); return }
        if popover.isShown { close(); return }
        guard let button = item.button else { return }
        session.checkInactivity()
        popover.behavior = session.menuStaysOpen ? .applicationDefined : .transient
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        host.view.window?.makeKey()
    }
    private func close() {
        guard !session.filePickerIsOpen else { session.focusFilePicker(); return }
        popover.performClose(nil)
    }
    func popoverWillShow(_ notification: Notification) { session.menuOpened() }
    func popoverDidClose(_ notification: Notification) { session.surfaceClosed() }
    func popoverShouldClose(_ popover: NSPopover) -> Bool { !session.filePickerIsOpen }
}

enum UpOnlyArtwork {
    static let status: NSImage = {
        let image = load("UpOnlyStatus")
        // MenuBarExtra uses the native image size when constructing its status item.
        image.size = NSSize(width: 26, height: 16)
        image.isTemplate = true
        return image
    }()
    static let wordmark = load("UpOnlyWordmark")
    static let wordmarkLight = load("UpOnlyWordmarkLight")

    private static func load(_ name: String) -> NSImage {
        // Vector PDFs retain smooth contours at each display's native scale.
        if let url = Bundle.main.url(forResource: name, withExtension: "pdf"),
           let image = NSImage(contentsOf: url) { return image }
        assertionFailure("Missing bundled artwork: \(name)")
        return NSImage(systemSymbolName: "arrow.up.right", accessibilityDescription: "Up Only") ?? NSImage()
    }
}

struct UpOnlyWordmark: View {
    @Environment(\.colorScheme) private var colorScheme
    var width: CGFloat = 92
    var body: some View {
        Image(nsImage: colorScheme == .dark ? UpOnlyArtwork.wordmark : UpOnlyArtwork.wordmarkLight)
            .renderingMode(.original).resizable().scaledToFit()
            .frame(width: width, height: width * 73 / 92, alignment: .leading)
            .accessibilityLabel("Up Only").accessibilityAddTraits(.isHeader)
    }
}

struct UpOnlyBrandMark: View {
    var width: CGFloat = 22
    var body: some View {
        Image(nsImage: UpOnlyArtwork.status).renderingMode(.template).resizable().scaledToFit()
            .frame(width: width, height: width * 16 / 26)
            .accessibilityLabel("Up Only")
    }
}
