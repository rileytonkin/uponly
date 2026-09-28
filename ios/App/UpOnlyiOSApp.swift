import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Up Only on iPhone: the Mac menu's pages at the phone's width, full screen. Opening the app is opening the menu, so it
/// asks for Face ID; leaving it locks the vault, and the app switcher's snapshot shows a cover rather than the figures.
@main
struct UpOnlyiOSApp: App {
    @State private var session = UpOnlySession()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            UpOnlyiOSRoot()
                .environment(session)
                .preferredColorScheme(.dark)
                .onAppear {
                    // Lock only, never a Face ID prompt straight after: the next opening asks.
                    session.closeMenuHandler = {}
                    session.menuOpened()
                }
                .onChange(of: scenePhase) { previous, phase in
                    switch phase {
                    case .background:
                        session.surfaceClosed()
                        session.lock()
                    case .active where previous == .background:
                        // Back from another app. Not after Face ID's own prompt, which only makes the app inactive:
                        // a cancelled prompt mustn't bring up another.
                        session.menuOpened()
                    default: break
                    }
                }
        }
    }
}

struct UpOnlyiOSRoot: View {
    @Environment(UpOnlySession.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        GeometryReader { geometry in
            let _ = UpOnlyLayout.adopt(width: geometry.size.width)
            UpOnlyPanel(menuLifecycleManaged: true)
                .id(geometry.size.width)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: session.state == .unlocked ? .top : .center)
                .onAppear { session.dashboardHeight = geometry.size.height }
                .onChange(of: geometry.size.height) { _, height in session.dashboardHeight = height }
        }
        .background { UpOnlyBackdrop().ignoresSafeArea() }
        .background { UpOnlyActivityProbe { session.handleActivity() }.frame(width: 0, height: 0) }
        .overlay {
            // The app switcher keeps a picture of the screen; unlocked figures stay out of it.
            if scenePhase != .active, session.state == .unlocked {
                ZStack { UpOnlyBackdrop.base; UpOnlyWordmark() }.ignoresSafeArea()
            }
        }
    }
}

extension UpOnlyLayout {
    /// The page is the screen's width on iPhone. Read once per width: the pages are rebuilt when it changes.
    static func adopt(width: CGFloat) {
        if width > 0, menuWidth != width { menuWidth = width }
    }
}

/// Any touch anywhere counts as activity for the idle lock, as the Mac counts clicks and keys. It watches without
/// taking part: every touch still reaches the control under it.
private struct UpOnlyActivityProbe: UIViewRepresentable {
    var touched: () -> Void
    func makeUIView(context: Context) -> ProbeView { let view = ProbeView(); view.touched = touched; return view }
    func updateUIView(_ view: ProbeView, context: Context) { view.touched = touched }
    final class ProbeView: UIView {
        var touched: (() -> Void)?
        private var recognizer: Watcher?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let recognizer { recognizer.view?.removeGestureRecognizer(recognizer) }
            guard let window else { recognizer = nil; return }
            let watcher = Watcher { [weak self] in self?.touched?() }
            window.addGestureRecognizer(watcher)
            recognizer = watcher
        }
    }
    final class Watcher: UIGestureRecognizer, UIGestureRecognizerDelegate {
        private let touched: () -> Void
        init(_ touched: @escaping () -> Void) {
            self.touched = touched
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false; delaysTouchesBegan = false; delaysTouchesEnded = false
            delegate = self
        }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            touched()
            state = .failed
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

/// The artwork the Mac draws from its vector PDFs, drawn here from the same files at the screen's scale.
@MainActor enum UpOnlyArtwork {
    static let status = load("UpOnlyStatus", size: CGSize(width: 26, height: 16))
    static let wordmark = load("UpOnlyWordmark", size: CGSize(width: 92, height: 73))
    static let wordmarkLight = load("UpOnlyWordmarkLight", size: CGSize(width: 92, height: 73))

    private static func load(_ name: String, size: CGSize) -> UIImage {
        guard let url = Bundle.main.url(forResource: name, withExtension: "pdf"),
              let document = CGPDFDocument(url as CFURL), let page = document.page(at: 1) else {
            assertionFailure("Missing bundled artwork: \(name)")
            return UIImage(systemName: "arrow.up.right") ?? UIImage()
        }
        // Drawn large enough for the biggest place it's shown (the welcome wordmark), at 3x.
        let scale: CGFloat = 4
        let box = page.getBoxRect(.mediaBox)
        let format = UIGraphicsImageRendererFormat(); format.scale = 3; format.opaque = false
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        return UIGraphicsImageRenderer(size: target, format: format).image { context in
            let cg = context.cgContext
            cg.translateBy(x: 0, y: target.height)
            cg.scaleBy(x: target.width / box.width, y: -target.height / box.height)
            cg.translateBy(x: -box.minX, y: -box.minY)
            cg.drawPDFPage(page)
        }
    }
}

struct UpOnlyWordmark: View {
    @Environment(\.colorScheme) private var colorScheme
    var width: CGFloat = 92
    var body: some View {
        Image(uiImage: colorScheme == .dark ? UpOnlyArtwork.wordmark : UpOnlyArtwork.wordmarkLight)
            .renderingMode(.original).resizable().scaledToFit()
            .frame(width: width, height: width * 73 / 92, alignment: .leading)
            .accessibilityLabel("Up Only").accessibilityAddTraits(.isHeader)
    }
}

struct UpOnlyBrandMark: View {
    var width: CGFloat = 22
    var body: some View {
        Image(uiImage: UpOnlyArtwork.status).renderingMode(.template).resizable().scaledToFit()
            .frame(width: width, height: width * 16 / 26)
            .accessibilityLabel("Up Only")
    }
}
