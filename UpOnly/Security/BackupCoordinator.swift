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
        if io.fileExists(at: directory) { throw VaultError.alreadyExists }
        let staging = directory.deletingLastPathComponent()
            .appendingPathComponent(directory.lastPathComponent + ".staging-" + UUID().uuidString, isDirectory: true)
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
            try io.installItem(at: directory, from: staging)
        } catch {
            try? io.removeItem(at: staging)
            throw VaultError.backupIncoherent
        }
    }

    static func restore(
        package: BackupPackage,
        recovery: RecoveryCode,
        keys: VaultKeyStoring,
        layout: VaultLayout,
        io: VaultFileIO,
        authenticator: VaultAuthenticating? = nil
    ) throws -> (document: VaultDocument, pending: [(name: String, bytes: Data)]) {
        try verifyPackage(package)
        if io.fileExists(at: layout.current) { throw VaultError.alreadyExists }
        let wrapper = try VaultJSON.decode(RecoveryWrapperFile.self, from: package.recovery)
        let keyData = try VaultCrypto.unwrapVaultKey(wrapper, recovery: recovery)
        let vaultKey = try VaultCrypto.key(from: keyData)
        let persisted = try VaultJSON.decode(PersistedVaultFile.self, from: package.vault)
        guard persisted.vaultID == package.manifest.vaultID,
              persisted.generation == package.manifest.generation,
              wrapper.vaultID == persisted.vaultID else {
            throw VaultError.backupIncoherent
        }
        let document = try VaultCrypto.reveal(persisted, key: vaultKey)
        if !io.fileExists(at: layout.root.deletingLastPathComponent()) {
            try io.createDirectory(at: layout.root.deletingLastPathComponent())
        }
        let lock = try io.acquireExclusiveLock(at: layout.lockFile)
        defer { lock.release() }
        guard !io.fileExists(at: layout.root) else { throw VaultError.alreadyExists }
        let stagingRoot = layout.root.deletingLastPathComponent()
            .appendingPathComponent(layout.root.lastPathComponent + ".restore-" + UUID().uuidString, isDirectory: true)
        let staging = VaultLayout(root: stagingRoot)
        defer { try? io.removeItem(at: stagingRoot) }
        do {
            try staging.ensureDirectories(io)
            try io.write(package.vault, to: staging.current, sync: true)
            try io.write(package.recovery, to: staging.recovery, sync: true)
            if let previous = package.previous {
                try io.write(previous, to: staging.previous, sync: true)
            }
            for item in package.pending {
                try io.write(item.bytes, to: staging.inbox.appendingPathComponent(item.name), sync: true)
            }
            guard try io.data(at: staging.current) == package.vault,
                  try io.data(at: staging.recovery) == package.recovery else {
                throw VaultError.backupIncoherent
            }
            for item in package.pending {
                guard try io.data(at: staging.inbox.appendingPathComponent(item.name)) == item.bytes else {
                    throw VaultError.backupIncoherent
                }
            }
            try keys.store(vaultID: document.vaultID, key: keyData, context: authenticator?.keychainContext)
            try io.installItem(at: layout.root, from: stagingRoot)
            return (document, package.pending)
        } catch {
            if let vaultError = error as? VaultError { throw vaultError }
            throw VaultError.backupIncoherent
        }
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
            if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > limit { throw VaultError.oversizedBatch }
            let bytes = try io.data(at: url)
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
