import Foundation

enum Config {
    static let supportDirectory: URL = {
        #if UPONLY_FIXTURE
        return FileManager.default.temporaryDirectory.appendingPathComponent("UpOnlyPreview-" + UUID().uuidString)
        #elseif UPONLY_PERSONAL
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Up Only Personal", isDirectory: true)
        #else
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Up Only", isDirectory: true)
        #endif
    }()
}
