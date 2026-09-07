import SwiftUI

final class UpOnlyApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct UpOnlyApp: App {
    @NSApplicationDelegateAdaptor(UpOnlyApplicationDelegate.self) private var applicationDelegate
    @State private var session = UpOnlySession()
    var body: some Scene {
        MenuBarExtra(isInserted: .constant(!session.isFixture || ProcessInfo.processInfo.environment["UPONLY_PREVIEW_MENU_BAR"] == "1")) {
            UpOnlyPanel().environment(session)
        } label: {
            #if UPONLY_FIXTURE
            Text("up*")
                .accessibilityLabel("Up Only Preview")
                .accessibilityIdentifier("UpOnlyStatusItem")
            #else
            Image(nsImage: UpOnlyArtwork.status).renderingMode(.template)
                .accessibilityLabel("Up Only")
                .accessibilityIdentifier("UpOnlyStatusItem")
            #endif
        }.menuBarExtraStyle(.window)
        #if UPONLY_FIXTURE
        Window("Up Only Preview", id: "preview") {
            UpOnlyPanel().environment(session)
        }.defaultSize(width: 344, height: 470).windowResizability(.contentSize)
            .defaultLaunchBehavior(.suppressed)
        #endif
    }
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
