import Foundation

protocol PublicationControlling: Sendable {
    func pauseAndDrain() async throws
    func resume() async
}

struct BackupFile: Codable, Sendable, Equatable {
    var name: String
    var sha256: Data
}

struct BackupManifest: Codable, Sendable, Equatable {
    var format: Int
    var vaultID: UUID
    var generation: UInt64
    var files: [BackupFile]
}

struct BackupPackage: Sendable {
    var manifest: BackupManifest
    var vault: Data
    var previous: Data?
    var recovery: Data
    var pending: [(name: String, bytes: Data)]
}

nonisolated enum BackupCoordinator {
    static func makePackage(
        store: VaultStore,
        producers: [PublicationControlling]
    ) async throws -> BackupPackage {
        var paused: [PublicationControlling] = []
        do {
            for producer in producers {
                try await producer.pauseAndDrain()
                paused.append(producer)
            }
            let package = try await store.captureBackupPackage()
            try verifyPackage(package)
            for producer in paused { await producer.resume() }
            return package
        } catch {
            for producer in paused { await producer.resume() }
            throw error
        }
    }

    static func publish(_ package: BackupPackage, to directory: URL, io: VaultFileIO) throws {
        try verifyPackage(package)
        // The save panel's "Replace" may swap out an earlier backup, never a vault or any other item.
        let replacing = io.fileExists(at: directory)
        if replacing && !isBackup(at: directory, io: io) { throw VaultError.alreadyExists }
        // The sandbox grants the chosen path but not its folder, so nothing is created beside it: the backup is
        // staged on the same volume and moved into place, or else written straight into the new folder, manifest last.
        let scratch = try? io.replacementDirectory(for: directory)
        defer { if let scratch { try? io.removeItem(at: scratch) } }
        if replacing && scratch == nil { throw VaultError.backupIncoherent }
        let staging = scratch?.appendingPathComponent(directory.lastPathComponent, isDirectory: true) ?? directory
        do {
            try io.createDirectory(at: staging)
            try io.createDirectory(at: staging.appendingPathComponent("inbox", isDirectory: true))
            try io.write(package.vault, to: staging.appendingPathComponent("vault.uponly"), sync: true)
            try io.write(package.recovery, to: staging.appendingPathComponent("recovery.wrapper"), sync: true)
            if let previous = package.previous {
                try io.write(previous, to: staging.appendingPathComponent("vault.uponly.prev"), sync: true)
            }
            let names = try SafeFileName.requireUnique(package.pending.map(\.name))
            for (item, name) in zip(package.pending, names) {
                try io.write(
                    item.bytes,
                    to: staging.appendingPathComponent("inbox", isDirectory: true).appendingPathComponent(name),
                    sync: true
                )
            }
            try io.write(
                try VaultJSON.encode(package.manifest),
                to: staging.appendingPathComponent("manifest.json"),
                sync: true
            )
            if replacing { try io.replaceItem(at: directory, withItemAt: staging) }
            else if staging != directory { try io.installItem(at: directory, from: staging) }
        } catch {
            if !replacing { try? io.removeItem(at: staging) }
            throw VaultError.backupIncoherent
        }
    }

    /// An earlier Up Only backup: a real folder holding only backup files (and Finder's hidden ones) and a readable manifest.
    static func isBackup(at url: URL, io: VaultFileIO) -> Bool {
        let names: Set<String> = ["manifest.json", "vault.uponly", "vault.uponly.prev", "recovery.wrapper", "inbox"]
        guard (try? io.isSymbolicLink(at: url)) == false, (try? io.isDirectory(at: url)) == true,
              let children = try? io.contentsOfDirectory(at: url),
              Set(children.map(\.lastPathComponent).filter { !$0.hasPrefix(".") }).isSubset(of: names),
              let bytes = try? io.data(at: url.appendingPathComponent("manifest.json"), limit: VaultLimits.maxManifestBytes),
              let manifest = try? VaultJSON.decode(BackupManifest.self, from: bytes) else { return false }
        return manifest.format == VaultSchema.backupPackage
    }

    static func restore(
        package: BackupPackage,
        recovery: RecoveryCode,
        keys: VaultKeyStoring,
        layout: VaultLayout,
        io: VaultFileIO,
        authenticator: VaultAuthenticating? = nil
    ) throws -> (document: VaultDocument, pending: [(name: String, bytes: Data)]) {
        if io.fileExists(at: layout.current) { throw VaultError.alreadyExists }
        let opened = try open(package, recovery: recovery)
        if !io.fileExists(at: layout.root.deletingLastPathComponent()) {
            try io.createDirectory(at: layout.root.deletingLastPathComponent())
        }
        let lock = try io.acquireExclusiveLock(at: layout.lockFile)
        defer { lock.release() }
        guard !io.fileExists(at: layout.root) else { throw VaultError.alreadyExists }
        let stagingRoot = layout.root.deletingLastPathComponent()
            .appendingPathComponent(layout.root.lastPathComponent + ".restore-" + UUID().uuidString, isDirectory: true)
        defer { try? io.removeItem(at: stagingRoot) }
        try stage(package, at: stagingRoot, io: io)
        // The copy goes in place before the Keychain takes its key: if the app stops in between, the folder holds a vault
        // the code just typed opens, not a Keychain key with no vault. A staging folder left by an earlier stop is removed
        // at the next unlock or recovery.
        var installed = false
        do {
            try io.installItem(at: layout.root, from: stagingRoot)
            installed = true
            try keys.store(vaultID: opened.document.vaultID, key: opened.key, context: authenticator?.keychainContext)
            return (opened.document, package.pending)
        } catch {
            // The folder was empty before, so what's there is only the backup's copy, which the backup still holds.
            if installed { try? io.removeItem(at: layout.root) }
            if let vaultError = error as? VaultError { throw vaultError }
            throw VaultError.backupIncoherent
        }
    }

    /// Checks a backup and opens it with `recovery` before anything is written: its document and vault key.
    static func open(_ package: BackupPackage, recovery: RecoveryCode) throws -> (document: VaultDocument, key: Data) {
        try verifyPackage(package)
        let wrapper = try VaultJSON.decode(RecoveryWrapperFile.self, from: package.recovery)
        let keyData = try VaultCrypto.unwrapVaultKey(wrapper, recovery: recovery)
        let persisted = try VaultJSON.decode(PersistedVaultFile.self, from: package.vault)
        guard persisted.vaultID == package.manifest.vaultID,
              persisted.generation == package.manifest.generation,
              wrapper.vaultID == persisted.vaultID else {
            throw VaultError.backupIncoherent
        }
        return (try VaultCrypto.reveal(persisted, key: VaultCrypto.key(from: keyData)), keyData)
    }

    /// Writes the backup's files into a new vault folder at `staging`, flushed, and reads every one back.
    static func stage(_ package: BackupPackage, at staging: URL, io: VaultFileIO) throws {
        let folder = VaultLayout(root: staging)
        var files = [(url: folder.current, bytes: package.vault), (url: folder.recovery, bytes: package.recovery)]
        if let previous = package.previous { files.append((url: folder.previous, bytes: previous)) }
        files += package.pending.map { (url: folder.inbox.appendingPathComponent($0.name), bytes: $0.bytes) }
        do {
            try folder.ensureDirectories(io)
            for file in files { try io.write(file.bytes, to: file.url, sync: true) }
            for file in files {
                guard try io.data(at: file.url, limit: file.bytes.count) == file.bytes else { throw VaultError.backupIncoherent }
            }
        } catch {
            if let vaultError = error as? VaultError { throw vaultError }
            throw VaultError.backupIncoherent
        }
    }

    /// Whether `recovery` opens this backup's recovery wrapper, checked before anything is replaced or asked.
    static func opens(_ package: BackupPackage, with recovery: RecoveryCode) -> Bool {
        guard let wrapper = try? VaultJSON.decode(RecoveryWrapperFile.self, from: package.recovery) else { return false }
        return (try? VaultCrypto.unwrapVaultKey(wrapper, recovery: recovery)) != nil
    }

    static func verifyPackage(_ package: BackupPackage) throws {
        let manifestBytes = try VaultJSON.encode(package.manifest)
        guard package.vault.count <= VaultLimits.maxVaultFileBytes,
              (package.previous?.count ?? 0) <= VaultLimits.maxVaultFileBytes,
              package.recovery.count <= 16384,
              manifestBytes.count <= VaultLimits.maxManifestBytes,
              package.manifest.files.count <= 10000,
              package.pending.allSatisfy({ $0.bytes.count <= VaultLimits.maxBatchBytes }),
              package.pending.reduce(0, { $0 + $1.bytes.count }) <= VaultLimits.maxPendingInboxBytes,
              package.vault.count + (package.previous?.count ?? 0) + package.recovery.count + manifestBytes.count + package.pending.reduce(0, { $0 + $1.bytes.count }) <= VaultLimits.maxBackupBytes else { throw VaultError.oversizedVault }
        guard package.manifest.format == VaultSchema.backupPackage else { throw VaultError.unknownSchema }
        try SafeFileName.requireUnique(package.pending.map(\.name))
        func expect(_ name: String, _ data: Data) throws {
            guard let listed = package.manifest.files.first(where: { $0.name == name }),
                  listed.sha256 == VaultCrypto.sha256(data) else {
                throw VaultError.backupIncoherent
            }
        }
        try expect("vault.uponly", package.vault)
        try expect("recovery.wrapper", package.recovery)
        if let previous = package.previous {
            try expect("vault.uponly.prev", previous)
        } else if package.manifest.files.contains(where: { $0.name == "vault.uponly.prev" }) {
            throw VaultError.backupIncoherent
        }
        for item in package.pending {
            try expect("inbox/\(item.name)", item.bytes)
        }
        let expected = 2 + (package.previous == nil ? 0 : 1) + package.pending.count
        if package.manifest.files.count != expected { throw VaultError.backupIncoherent }
        let persisted = try VaultJSON.decode(PersistedVaultFile.self, from: package.vault)
        let wrapper = try VaultJSON.decode(RecoveryWrapperFile.self, from: package.recovery)
        guard persisted.vaultID == package.manifest.vaultID,
              persisted.generation == package.manifest.generation,
              wrapper.vaultID == persisted.vaultID else {
            throw VaultError.backupIncoherent
        }
    }
}

final class FixtureProducer: PublicationControlling, @unchecked Sendable {
    var failPause = false
    private(set) var pauseCount = 0
    private(set) var resumeCount = 0
    var isPaused = false

    func pauseAndDrain() async throws {
        if failPause { throw VaultError.pauseFailed }
        pauseCount += 1
        isPaused = true
    }

    func resume() async {
        resumeCount += 1
        isPaused = false
    }
}

extension BackupCoordinator {
    static func read(from root: URL, io: VaultFileIO) throws -> BackupPackage {
        var total = 0
        func read(_ name: String, limit: Int) throws -> Data {
            let url = root.appendingPathComponent(name)
            guard !(try io.isSymbolicLink(at: url)), !(try io.isDirectory(at: url)) else { throw VaultError.backupIncoherent }
            // A regular file within the limit, checked on the file as it's read, so a pipe or a swapped-in link can't
            // hang the read or make it unbounded.
            let bytes: Data
            do { bytes = try io.data(at: url, limit: limit) }
            catch CocoaError.fileReadTooLarge { throw VaultError.oversizedBatch }
            catch { throw VaultError.backupIncoherent }
            total += bytes.count
            guard bytes.count <= limit, total <= VaultLimits.maxBackupBytes else { throw VaultError.oversizedBatch }
            return bytes
        }
        guard !(try io.isSymbolicLink(at: root)) else { throw VaultError.backupIncoherent }
        let manifest = try VaultJSON.decode(BackupManifest.self, from: read("manifest.json", limit: VaultLimits.maxManifestBytes))
        guard manifest.files.count <= 10000, Set(manifest.files.map(\.name)).count == manifest.files.count else { throw VaultError.backupIncoherent }
        let vault = try read("vault.uponly", limit: VaultLimits.maxVaultFileBytes)
        let recovery = try read("recovery.wrapper", limit: 16384)
        let previous = manifest.files.contains { $0.name == "vault.uponly.prev" } ? try read("vault.uponly.prev", limit: VaultLimits.maxVaultFileBytes) : nil
        var pending: [(name: String, bytes: Data)] = []
        for file in manifest.files where file.name.hasPrefix("inbox/") {
            let name = try SafeFileName.require(String(file.name.dropFirst(6)))
            guard !(try io.isSymbolicLink(at: root.appendingPathComponent("inbox"))) else { throw VaultError.backupIncoherent }
            pending.append((name, try read("inbox/" + name, limit: VaultLimits.maxBatchBytes)))
        }
        let package = BackupPackage(manifest: manifest, vault: vault, previous: previous, recovery: recovery, pending: pending)
        try verifyPackage(package)
        return package
    }
}
