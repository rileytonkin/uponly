import Foundation
import LocalAuthentication
import Security

protocol VaultFileIO: Sendable {
    nonisolated func data(at url: URL) throws -> Data
    nonisolated func write(_ data: Data, to url: URL, sync: Bool) throws
    nonisolated func replaceItem(at original: URL, withItemAt temp: URL) throws
    nonisolated func installItem(at destination: URL, from staging: URL) throws
    nonisolated func copyItem(at src: URL, to dst: URL) throws
    nonisolated func preserveVerifiedCopy(from src: URL, to dst: URL) throws
    nonisolated func removeItem(at url: URL) throws
    nonisolated func fileExists(at url: URL) -> Bool
    nonisolated func isDirectory(at url: URL) throws -> Bool
    nonisolated func isSymbolicLink(at url: URL) throws -> Bool
    nonisolated func createDirectory(at url: URL) throws
    nonisolated func contentsOfDirectory(at url: URL) throws -> [URL]
    nonisolated func acquireExclusiveLock(at url: URL) throws -> AdvisoryLock
}

protocol AdvisoryLock: Sendable {
    nonisolated func release()
}

protocol VaultKeyStoring: Sendable {
    nonisolated func store(vaultID: UUID, key: Data, context: AnyObject?) throws
    nonisolated func load(vaultID: UUID, context: AnyObject?) throws -> Data
    nonisolated func delete(vaultID: UUID) throws
    nonisolated func contains(vaultID: UUID) -> Bool
}

protocol VaultAuthenticating: Sendable {
    func evaluate() async throws
    nonisolated func invalidate()
    nonisolated var keychainContext: AnyObject? { get }
}

final class UnlockFence: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func current() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func bump() {
        lock.lock(); defer { lock.unlock() }
        value += 1
    }

    func publish<T>(_ ticket: UInt64, _ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard value == ticket else { throw VaultError.locked }
        return try body()
    }
}

final class MemoryFileIO: VaultFileIO, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data] = [:]
    private var directories: Set<String> = []
    private var heldLocks: Set<String> = []
    private var unreadable: Set<String> = []
    private var unlistable: Set<String> = []

    var failWrite = false
    var failReplace = false
    var failSync = false
    var failWriteMatching: String?
    var onRead: (() -> Void)?
    var onWrite: (() -> Void)?

    func markUnreadable(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        unreadable.insert(url.path)
    }

    func markUnlistable(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        unlistable.insert(url.path)
    }

    func data(at url: URL) throws -> Data {
        onRead?()
        lock.lock(); defer { lock.unlock() }
        if unreadable.contains(url.path) { throw CocoaError(.fileReadNoPermission) }
        guard let data = files[url.path] else {
            throw CocoaError(.fileNoSuchFile)
        }
        return data
    }

    func write(_ data: Data, to url: URL, sync: Bool) throws {
        onWrite?()
        if failWrite { throw VaultError.diskWriteFailed }
        if let matching = failWriteMatching, url.path.contains(matching) { throw VaultError.diskWriteFailed }
        if failSync && sync { throw VaultError.diskWriteFailed }
        lock.lock(); defer { lock.unlock() }
        files[url.path] = data
    }

    func replaceItem(at original: URL, withItemAt temp: URL) throws {
        if failReplace { throw VaultError.diskWriteFailed }
        lock.lock(); defer { lock.unlock() }
        if let data = files[temp.path] {
            files[original.path] = data
            files.removeValue(forKey: temp.path)
            return
        }
        let tempPrefix = temp.path.hasSuffix("/") ? temp.path : temp.path + "/"
        let origPrefix = original.path.hasSuffix("/") ? original.path : original.path + "/"
        let children = files.filter { $0.key.hasPrefix(tempPrefix) }
        guard !children.isEmpty || directories.contains(temp.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        files = files.filter { !$0.key.hasPrefix(origPrefix) && $0.key != original.path }
        for (path, data) in children {
            let rest = String(path.dropFirst(tempPrefix.count))
            files[origPrefix + rest] = data
            files.removeValue(forKey: path)
        }
        directories.remove(temp.path)
        directories.insert(original.path)
    }

    func installItem(at destination: URL, from staging: URL) throws {
        guard !fileExists(at: destination) else { throw VaultError.alreadyExists }
        try replaceItem(at: destination, withItemAt: staging)
    }

    func copyItem(at src: URL, to dst: URL) throws {
        lock.lock(); defer { lock.unlock() }
        guard let data = files[src.path] else { throw CocoaError(.fileNoSuchFile) }
        files[dst.path] = data
    }

    func preserveVerifiedCopy(from src: URL, to dst: URL) throws {
        let data = try self.data(at: src)
        let temp = dst.appendingPathExtension("tmp")
        try write(data, to: temp, sync: true)
        let copied = try self.data(at: temp)
        guard copied == data else { throw VaultError.diskWriteFailed }
        try replaceItem(at: dst, withItemAt: temp)
    }

    func removeItem(at url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        files.removeValue(forKey: url.path)
        directories.remove(url.path)
        let prefix = url.path.hasSuffix("/") ? url.path : url.path + "/"
        files = files.filter { !$0.key.hasPrefix(prefix) }
    }

    func fileExists(at url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return files[url.path] != nil || directories.contains(url.path)
    }

    func isDirectory(at url: URL) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        return directories.contains(url.path) && files[url.path] == nil
    }

    func isSymbolicLink(at url: URL) throws -> Bool {
        false
    }

    func createDirectory(at url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        directories.insert(url.path)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        lock.lock(); defer { lock.unlock() }
        if unlistable.contains(url.path) { throw CocoaError(.fileReadNoPermission) }
        let prefix = url.path.hasSuffix("/") ? url.path : url.path + "/"
        var names = Set<String>()
        for key in files.keys where key.hasPrefix(prefix) {
            let rest = String(key.dropFirst(prefix.count))
            guard let first = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).first else { continue }
            names.insert(String(first))
        }
        for dir in directories where dir.hasPrefix(prefix) && dir != url.path {
            let rest = String(dir.dropFirst(prefix.count))
            guard let first = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).first else { continue }
            names.insert(String(first))
        }
        return names.map { URL(fileURLWithPath: prefix + $0, isDirectory: directories.contains(prefix + $0)) }
    }

    func acquireExclusiveLock(at url: URL) throws -> AdvisoryLock {
        lock.lock(); defer { lock.unlock() }
        if heldLocks.contains(url.path) { throw VaultError.alreadyOpen }
        heldLocks.insert(url.path)
        return MemoryAdvisoryLock(path: url.path, table: self)
    }

    fileprivate func releaseLock(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        heldLocks.remove(path)
    }

    func stored(_ url: URL) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return files[url.path]
    }
}

private final class MemoryAdvisoryLock: AdvisoryLock, @unchecked Sendable {
    let path: String
    weak var table: MemoryFileIO?
    private let lock = NSLock()
    private var released = false

    init(path: String, table: MemoryFileIO) {
        self.path = path
        self.table = table
    }

    func release() {
        lock.lock(); defer { lock.unlock() }
        guard !released else { return }
        released = true
        table?.releaseLock(path)
    }

    deinit { release() }
}

final class DiskFileIO: VaultFileIO, @unchecked Sendable {
    private let fileManager = FileManager.default

    func data(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    func write(_ data: Data, to url: URL, sync: Bool) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        if sync {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.synchronize()
        }
    }

    func replaceItem(at original: URL, withItemAt temp: URL) throws {
        if fileManager.fileExists(atPath: original.path) {
            _ = try fileManager.replaceItemAt(original, withItemAt: temp)
        } else {
            try fileManager.moveItem(at: temp, to: original)
        }
        if fileManager.fileExists(atPath: original.path) {
            var isDir: ObjCBool = false
            fileManager.fileExists(atPath: original.path, isDirectory: &isDir)
            try fileManager.setAttributes(
                [.posixPermissions: isDir.boolValue ? 0o700 : 0o600],
                ofItemAtPath: original.path
            )
        }
        try syncDirectory(containing: original)
    }

    func installItem(at destination: URL, from staging: URL) throws {
        guard !fileExists(at: destination), !((try? isSymbolicLink(at: destination)) ?? false)
        else { throw VaultError.alreadyExists }
        try fileManager.moveItem(at: staging, to: destination)
        try syncDirectory(containing: destination)
    }

    func copyItem(at src: URL, to dst: URL) throws {
        if fileManager.fileExists(atPath: dst.path) {
            let backup = dst.appendingPathExtension("replacing")
            try fileManager.copyItem(at: src, to: backup)
            try replaceItem(at: dst, withItemAt: backup)
        } else {
            try fileManager.copyItem(at: src, to: dst)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dst.path)
        }
    }

    func preserveVerifiedCopy(from src: URL, to dst: URL) throws {
        let temp = dst.appendingPathExtension("tmp")
        if fileManager.fileExists(atPath: temp.path) {
            try fileManager.removeItem(at: temp)
        }
        try fileManager.copyItem(at: src, to: temp)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
        let handle = try FileHandle(forWritingTo: temp)
        try handle.synchronize()
        try handle.close()
        let original = try Data(contentsOf: src)
        let copy = try Data(contentsOf: temp)
        guard original == copy else {
            try? fileManager.removeItem(at: temp)
            throw VaultError.diskWriteFailed
        }
        try replaceItem(at: dst, withItemAt: temp)
    }

    func removeItem(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    func fileExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    func isDirectory(at url: URL) throws -> Bool {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return isDir.boolValue
    }

    func isSymbolicLink(at url: URL) throws -> Bool {
        let attrs = try fileManager.attributesOfItem(atPath: url.path)
        return (attrs[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    func createDirectory(at url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    }

    func acquireExclusiveLock(at url: URL) throws -> AdvisoryLock {
        try DiskAdvisoryLock(url: url)
    }

    private func syncDirectory(containing url: URL) throws {
        let fd = open(url.deletingLastPathComponent().path, O_RDONLY)
        guard fd >= 0 else { throw VaultError.diskWriteFailed }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw VaultError.diskWriteFailed }
    }
}

final class DiskAdvisoryLock: AdvisoryLock, @unchecked Sendable {
    private var descriptor: CInt
    private var released = false
    private let lock = NSLock()

    init(url: URL) throws {
        let fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw VaultError.alreadyOpen }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            throw VaultError.alreadyOpen
        }
        descriptor = fd
    }

    func release() {
        lock.lock(); defer { lock.unlock() }
        guard !released else { return }
        released = true
        let fd = descriptor
        descriptor = -1
        flock(fd, LOCK_UN)
        close(fd)
    }

    deinit { release() }
}

final class MemoryKeyStore: VaultKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [UUID: Data] = [:]

    func store(vaultID: UUID, key: Data, context: AnyObject?) throws {
        lock.lock(); defer { lock.unlock() }
        keys[vaultID] = key
    }

    func load(vaultID: UUID, context: AnyObject?) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let key = keys[vaultID] else { throw VaultError.needsRecovery }
        return key
    }

    func delete(vaultID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        keys.removeValue(forKey: vaultID)
    }

    func contains(vaultID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return keys[vaultID] != nil
    }
}

final class KeychainVaultKeyStore: VaultKeyStoring, @unchecked Sendable {
    private let service = "org.uponly.app.vault-key"

    func store(vaultID: UUID, key: Data, context: AnyObject?) throws {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence,
            &error
        ) else {
            throw error!.takeRetainedValue() as Error
        }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: vaultID.uuidString,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let context {
            query[kSecUseAuthenticationContext as String] = context
        }
        var add = query
        add[kSecValueData as String] = key
        add[kSecAttrAccessControl as String] = access
        let added = SecItemAdd(add as CFDictionary, nil)
        if added == errSecSuccess { return }
        if added == errSecDuplicateItem {
            var update: [String: Any] = [kSecValueData as String: key]
            if let context {
                update[kSecUseAuthenticationContext as String] = context
            }
            let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            guard status == errSecSuccess else { throw VaultError.corrupt }
            return
        }
        throw VaultError.corrupt
    }

    func load(vaultID: UUID, context: AnyObject?) throws -> Data {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: vaultID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain as String: true,
            kSecUseOperationPrompt as String: "Unlock Up Only",
        ]
        if let context {
            query[kSecUseAuthenticationContext as String] = context
        }
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecUserCanceled || status == errSecAuthFailed { throw VaultError.cancelled }
        if status == errSecItemNotFound { throw VaultError.needsRecovery }
        guard status == errSecSuccess, let data = result as? Data else { throw VaultError.needsRecovery }
        return data
    }

    func delete(vaultID: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: vaultID.uuidString,
            kSecUseDataProtectionKeychain as String: true,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultError.corrupt }
    }

    func contains(vaultID: UUID) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: vaultID.uuidString,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain as String: true,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }
}

final class FixtureAuthenticator: VaultAuthenticating, @unchecked Sendable {
    var shouldCancel = false
    private(set) var invalidated = false
    private(set) var evaluateCount = 0
    nonisolated(unsafe) private var context: NSObject? = NSObject()

    func evaluate() async throws {
        evaluateCount += 1
        if shouldCancel { throw VaultError.cancelled }
        context = NSObject()
        invalidated = false
    }

    nonisolated func invalidate() {
        invalidated = true
        context = nil
    }

    nonisolated var keychainContext: AnyObject? { context }
}

final class LiveAuthenticator: VaultAuthenticating, @unchecked Sendable {
    private let lock = NSLock()
    private var context = LAContext()

    func evaluate() async throws {
        let next = LAContext()
        next.localizedCancelTitle = "Cancel"
        lock.lock()
        context = next
        lock.unlock()
        let reason = "Unlock Up Only"
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            next.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: VaultError.cancelled)
                    _ = error
                }
            }
        }
    }

    nonisolated func invalidate() {
        lock.lock()
        let current = context
        lock.unlock()
        current.invalidate()
    }

    nonisolated var keychainContext: AnyObject? {
        lock.lock(); defer { lock.unlock() }
        return context
    }
}
