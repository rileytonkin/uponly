import UIKit
import UniformTypeIdentifiers

/// The Files picker, for what the Mac does with open and save panels: choosing statements and a backup folder, and
/// saving a template or a backup. Chosen files are copied in, so nothing outside the app stays open; a backup folder is
/// opened in place, under the security scope the session already takes. One picker at a time.
@MainActor enum UpOnlyFilePicker {
    private static var current: (controller: UIDocumentPickerViewController, delegate: Delegate)?

    /// The files chosen, or none when cancelled.
    static func open(_ types: [UTType], multiple: Bool, asCopy: Bool = true) async -> [URL] {
        await present(UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: asCopy), multiple: multiple)
    }

    /// Hands a file or folder to Files to save wherever the user chooses; true once it's saved.
    static func export(_ url: URL) async -> Bool {
        !(await present(UIDocumentPickerViewController(forExporting: [url], asCopy: true), multiple: false)).isEmpty
    }

    /// Closes an open picker, as locking does.
    static func dismiss() {
        guard let current else { return }
        current.controller.dismiss(animated: false)
        current.delegate.finish([])
    }

    private static func present(_ picker: UIDocumentPickerViewController, multiple: Bool) async -> [URL] {
        dismiss()
        guard let presenter = topController() else { return [] }
        picker.allowsMultipleSelection = multiple
        picker.shouldShowFileExtensions = true
        return await withCheckedContinuation { continuation in
            let delegate = Delegate { urls in
                current = nil
                continuation.resume(returning: urls)
            }
            picker.delegate = delegate
            current = (picker, delegate)
            presenter.present(picker, animated: true)
        }
    }

    private static func topController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
        var top = scene?.keyWindow?.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }

    @MainActor private final class Delegate: NSObject, UIDocumentPickerDelegate {
        private var done: (([URL]) -> Void)?
        init(_ done: @escaping ([URL]) -> Void) { self.done = done }
        func finish(_ urls: [URL]) { let done = self.done; self.done = nil; done?(urls) }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { finish(urls) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish([]) }
    }
}
