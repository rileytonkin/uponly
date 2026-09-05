import Foundation

enum Config {
    static let supportDirectory: URL = {
        #if UPONLY_FIXTURE
        return FileManager.default.temporaryDirectory.appendingPathComponent("UpOnlyPreview-" + UUID().uuidString)
        #else
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Up Only", isDirectory: true)
        #endif
    }()
}
