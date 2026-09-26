import Foundation
import LocalAuthentication
import Security

protocol VaultFileIO: Sendable {
    nonisolated func data(at url: URL) throws -> Data
    /// A regular file of at most `limit` bytes, never through a symlink (`BoundedFile`): for files anyone could have
    /// swapped, such as a chosen backup's, and for the vault's own, so a stray pipe or huge file can't hang or fill memory.
    nonisolated func data(at url: URL, limit: Int) throws -> Data
    nonisolated func write(_ data: Data, to url: URL, sync: Bool) throws
    nonisolated func replaceItem(at original: URL, withItemAt temp: URL) throws
    nonisolated func installItem(at destination: URL, from staging: URL) throws
    /// A fresh scratch folder on the destination's volume, outside the folder that holds it.
    nonisolated func replacementDirectory(for destination: URL) throws -> URL
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
    nonisolated var successfulAuthenticationUptime: TimeInterval? { get }
}
extension VaultAuthenticating {
    nonisolated var successfulAuthenticationUptime: TimeInterval? { nil }
}

// Explicitly enabled diagnostic: timings only, never document or credential data.
nonisolated final class UnlockTiming: @unchecked Sendable {
    private let lock = NSLock()
    private var phases: [String: TimeInterval] = [:]
    private let method: String
    init(method: String) { self.method = method; mark("requested") }
    func mark(_ phase: String, at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        phases[phase] = uptime
    }
    func finish(at url: URL) {
        mark("menu_displayed")
        lock.lock(); let snapshot = phases; lock.unlock()
        guard let authenticated = snapshot["authenticated"] else { return }
        let milliseconds = snapshot.mapValues { ($0 - authenticated) * 1000 }
        let method = method
        Task.detached(priority: .utility) {
            let record: [String: Any] = ["method": method, "milliseconds_from_authentication": milliseconds,
                                       "measured_at": Date().timeIntervalSince1970]
            guard let bytes = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
            try? DiskFileIO().write(bytes, to: url, sync: false)
        }
    }
}

final class UnlockFence: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func current() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    /// Returns the new ticket, read under the same lock, so no other bump can slip in between.
    @discardableResult func bump() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
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


    func data(at url: URL) throws -> Data {
        onRead?()
        lock.lock(); defer { lock.unlock() }
        if unreadable.contains(url.path) { throw CocoaError(.fileReadNoPermission) }
        guard let data = files[url.path] else {
            throw CocoaError(.fileNoSuchFile)
        }
        return data
    }

    func data(at url: URL, limit: Int) throws -> Data {
        let data = try self.data(at: url)
        guard data.count <= limit else { throw CocoaError(.fileReadTooLarge) }
        return data
    }

    func write(_ data: Data, to url: URL, sync: Bool) throws {
        onWrite?()
        if failWrite { throw VaultError.diskWriteFailed }
        if let matching = failWriteMatching, url.path.contains(matching) { throw VaultError.diskWriteFailed }
        if failSync && sync { throw VaultError.diskWriteFailed }
        lock.lock(); defer { lock.unlock() }
        files[url.path] = data
        unreadable.remove(url.path)
    }

    func replaceItem(at original: URL, withItemAt temp: URL) throws {
        if failReplace { throw VaultError.diskWriteFailed }
        lock.lock(); defer { lock.unlock() }
        if let data = files[temp.path] {
            files[original.path] = data
            files.removeValue(forKey: temp.path)
            // As on disk, a file's permissions move with it.
            if unreadable.remove(temp.path) != nil { unreadable.insert(original.path) } else { unreadable.remove(original.path) }
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
        // Folders inside move with it, as on disk.
        let nested = directories.filter { $0.hasPrefix(tempPrefix) }
        directories = directories.filter { !$0.hasPrefix(origPrefix) && !$0.hasPrefix(tempPrefix) }
        for path in nested { directories.insert(origPrefix + String(path.dropFirst(tempPrefix.count))) }
        directories.remove(temp.path)
        directories.insert(original.path)
    }

    func installItem(at destination: URL, from staging: URL) throws {
        guard !fileExists(at: destination) else { throw VaultError.alreadyExists }
        try replaceItem(at: destination, withItemAt: staging)
    }

    func replacementDirectory(for destination: URL) throws -> URL {
        let url = URL(fileURLWithPath: "/memory-replacement/" + UUID().uuidString, isDirectory: true)
        try createDirectory(at: url)
        return url
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
        directories = directories.filter { !$0.hasPrefix(prefix) }
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

    func data(at url: URL, limit: Int) throws -> Data {
        try BoundedFile.read(url, limit: limit)
    }

    func write(_ data: Data, to url: URL, sync: Bool) throws {
        // Created 0600 from the start, so the file never exists with wider permissions, then renamed into place.
        let temp = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + "." + UUID().uuidString)
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw VaultError.diskWriteFailed }
        do {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            if sync { try Self.flush(fd) }
        } catch {
            unlink(temp.path)
            throw error
        }
        guard rename(temp.path, url.path) == 0 else {
            unlink(temp.path)
            throw VaultError.diskWriteFailed
        }
    }

    func replaceItem(at original: URL, withItemAt temp: URL) throws {
        if fileManager.fileExists(atPath: original.path) {
            _ = try fileManager.replaceItemAt(original, withItemAt: temp)
        } else {
            try fileManager.moveItem(at: temp, to: original)
        }
        // The swap happened and its data was flushed first. Reporting a later permissions or folder-flush failure as
        // "not saved" would leave the caller believing the old file while the new one is in place.
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: original.path, isDirectory: &isDir) {
            try? fileManager.setAttributes(
                [.posixPermissions: isDir.boolValue ? 0o700 : 0o600],
                ofItemAtPath: original.path
            )
        }
        try? syncDirectory(containing: original)
    }

    func installItem(at destination: URL, from staging: URL) throws {
        guard !fileExists(at: destination), !((try? isSymbolicLink(at: destination)) ?? false)
        else { throw VaultError.alreadyExists }
        try fileManager.moveItem(at: staging, to: destination)
        // As in `replaceItem`: once moved, it is in place.
        try? syncDirectory(containing: destination)
    }

    func replacementDirectory(for destination: URL) throws -> URL {
        try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
    }

    func preserveVerifiedCopy(from src: URL, to dst: URL) throws {
        let temp = dst.appendingPathExtension("tmp")
        if fileManager.fileExists(atPath: temp.path) {
            try fileManager.removeItem(at: temp)
        }
        // On APFS the copy is a clone, so no data is read or rewritten. A size check stands in for reading
        // both files back; AES-GCM still authenticates the copy whenever it is opened.
        try fileManager.copyItem(at: src, to: temp)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
        let fd = open(temp.path, O_RDONLY)
        guard fd >= 0 else { throw VaultError.diskWriteFailed }
        defer { close(fd) }
        try Self.flush(fd)
        let sizes = try [src, temp].map { try fileManager.attributesOfItem(atPath: $0.path)[.size] as? Int }
        guard sizes[0] != nil, sizes[0] == sizes[1] else {
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

    /// fsync leaves data in the drive's cache on macOS; F_FULLFSYNC flushes it (plain fsync where unsupported).
    private static func flush(_ fd: CInt) throws {
        guard fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0 else { throw VaultError.diskWriteFailed }
    }

    private func syncDirectory(containing url: URL) throws {
        let fd = open(url.deletingLastPathComponent().path, O_RDONLY)
        // A save panel grants the chosen item but not its folder; the item's own files were already flushed.
        guard fd >= 0 else { if errno == EPERM || errno == EACCES { return }; throw VaultError.diskWriteFailed }
        defer { close(fd) }
        try Self.flush(fd)
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
            throw error.map { $0.takeRetainedValue() as Error } ?? VaultError.keychainUnavailable(errSecParam)
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
            // Only real item attributes may be updated; the authentication context stays in the query.
            let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: key] as CFDictionary)
            if status == errSecUserCanceled || status == errSecAuthFailed { throw VaultError.cancelled }
            guard status == errSecSuccess else { throw VaultError.keychainUnavailable(status) }
            return
        }
        if added == errSecUserCanceled || added == errSecAuthFailed { throw VaultError.cancelled }
        throw VaultError.keychainUnavailable(added)
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
        guard status == errSecSuccess else { throw VaultError.keychainUnavailable(status) }
        guard let data = result as? Data else { throw VaultError.corrupt }
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
    private var embeddedContext: LAContext?
    private var passwordRequested = false
    private var successUptime: TimeInterval?
    nonisolated var successfulAuthenticationUptime: TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return successUptime
    }
    private func authenticated(_ evaluated: LAContext) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock(); defer { lock.unlock() }
        if context === evaluated { successUptime = now }
    }

    func prepareEmbedded(_ next: LAContext) {
        lock.lock(); defer { lock.unlock() }
        embeddedContext = next
        passwordRequested = false
        context = next
    }

    func preparePassword() {
        lock.lock(); defer { lock.unlock() }
        embeddedContext = nil
        passwordRequested = true
    }

    private func nextEvaluation() -> (LAContext, LAPolicy, Bool) {
        lock.lock(); defer { lock.unlock() }
        let embedded = embeddedContext
        let password = passwordRequested
        embeddedContext = nil
        passwordRequested = false
        let next = embedded ?? LAContext()
        context = next
        successUptime = nil
        return (next, embedded == nil ? .deviceOwnerAuthentication : .deviceOwnerAuthenticationWithBiometrics, password)
    }

    func evaluate() async throws {
        let (next, policy, password) = nextEvaluation()
        next.localizedCancelTitle = "Cancel"
        next.localizedFallbackTitle = password ? "" : "Use Password"
        let reason = "access your encrypted finances"
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let reply: @Sendable (Bool, Error?) -> Void = { success, error in
                if success {
                    self.authenticated(next)
                    continuation.resume()
                } else {
                    continuation.resume(throwing: VaultError.cancelled)
                    _ = error
                }
            }
            if password {
                // A fresh, unembedded context with a passcode-only constraint opens
                // the system Mac password field directly. Reuse it for the vault's
                // existing protected Keychain read; the app never handles the password.
                var error: Unmanaged<CFError>?
                guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .devicePasscode, &error) else {
                    continuation.resume(throwing: VaultError.cancelled)
                    return
                }
                next.evaluateAccessControl(access, operation: .useItem, localizedReason: reason, reply: reply)
            } else {
                next.evaluatePolicy(policy, localizedReason: reason, reply: reply)
            }
        }
    }

    nonisolated func invalidate() {
        lock.lock()
        let current = context
        embeddedContext = nil
        passwordRequested = false
        lock.unlock()
        current.invalidate()
    }

    nonisolated var keychainContext: AnyObject? {
        lock.lock(); defer { lock.unlock() }
        return context
    }
}

/// Reads a regular file of at most `limit` bytes. It never follows a symlink or waits on a pipe, and the type and size
/// are checked on the open descriptor, so the file can't be swapped between the check and the read.
nonisolated enum BoundedFile {
    static func read(_ url: URL, limit: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw CocoaError(errno == ENOENT ? .fileReadNoSuchFile : .fileReadNoPermission) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw CocoaError(.fileReadUnknown) }
        guard info.st_size <= off_t(limit) else { throw CocoaError(.fileReadTooLarge) }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw CocoaError(.fileReadTooLarge) }
        return data
    }
}
