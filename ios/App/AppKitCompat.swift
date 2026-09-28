import SwiftUI
import UIKit

// The shared views were written for the Mac. These iPhone stand-ins give the handful of AppKit names they use a UIKit
// meaning, so those views compile unchanged here and read on the Mac exactly as before. Anything that has no fair
// equivalent (the menu, embedded Touch ID, window sharing) is behind `#if os(macOS)` where it's used instead.

typealias NSImage = UIImage
typealias NSFont = UIFont

extension UIImage {
    /// AppKit's check that an image decoded; a UIImage that exists has, if it has pixels.
    var isValid: Bool { cgImage != nil }
    func cgImage(forProposedRect rect: UnsafeMutablePointer<CGRect>?, context: Any?, hints: [AnyHashable: Any]?) -> CGImage? { cgImage }
}

extension UIColor {
    static var windowBackgroundColor: UIColor { .systemBackground }
}

extension Image {
    init(nsImage: UIImage) { self.init(uiImage: nsImage) }
}

extension Color {
    init(nsColor: UIColor) { self.init(uiColor: nsColor) }
}

/// A checkbox is a switch on iPhone.
extension ToggleStyle where Self == SwitchToggleStyle {
    static var checkbox: SwitchToggleStyle { .switch }
}

/// The Mac's bordered menu button is a plain menu button on iPhone.
extension MenuStyle where Self == ButtonMenuStyle {
    static var borderedButton: ButtonMenuStyle { .button }
}

extension View {
    /// Esc has no key on iPhone: every page that handles it also has a Back or Cancel button.
    func onExitCommand(perform action: (() -> Void)?) -> some View { self }
}
