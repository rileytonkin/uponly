import Foundation
import Security
import Testing
@testable import UpOnly

final class SetupTestKeyStore: VaultKeyStoring, @unchecked Sendable {
    let memory = MemoryKeyStore()
    var storeError: VaultError?
    /// Thrown after the key is stored, as if the Keychain reported a failure for an update that landed.
    var failAfterStore: VaultError?
    var loadError: VaultError?
    var probeReturnsMissing = false
    /// Runs as a store starts, before it can fail, e.g. to stop disk writes as if the app quit during the Keychain update.
    var beforeStore: (() -> Void)?
    /// Runs once a key is stored, e.g. to stop disk writes as if the app quit right after the Keychain update.
    var onStore: (() -> Void)?
    private(set) var lastStoredID: UUID?
    func store(vaultID: UUID, key: Data, context: AnyObject?) throws {
        beforeStore?()
        if let storeError { throw storeError }
        try memory.store(vaultID: vaultID, key: key, context: context)
        lastStoredID = vaultID
        onStore?()
        if let failAfterStore { throw failAfterStore }
    }
    func load(vaultID: UUID, context: AnyObject?) throws -> Data {
        if let loadError { throw loadError }
        return try memory.load(vaultID: vaultID, context: context)
    }
    func delete(vaultID: UUID) throws { try memory.delete(vaultID: vaultID) }
    func contains(vaultID: UUID) -> Bool { !probeReturnsMissing && memory.contains(vaultID: vaultID) }
}

/// Runs `during` while the user is at the prompt.
final class PromptTestAuthenticator: VaultAuthenticating, @unchecked Sendable {
    var during: (() -> Void)?
    func evaluate() async throws { during?() }
    func invalidate() {}
    var keychainContext: AnyObject? { nil }
}

/// A disk that stops taking changes at the step `crashBefore` picks, as if the app quit just before it: that step and every
/// later write, move or removal fail, and reads show what a relaunch finds. Its locks never conflict, so a second store can
/// stand for the relaunched app.
final class CrashingFileIO: VaultFileIO, @unchecked Sendable {
    let disk = MemoryFileIO()
    var crashBefore: ((_ step: String, _ url: URL) -> Bool)?
    var crashed = false
    private func step(_ name: String, _ url: URL) throws {
        if !crashed, crashBefore?(name, url) == true { crashed = true }
        if crashed { throw VaultError.diskWriteFailed }
    }
    func data(at url: URL) throws -> Data { try disk.data(at: url) }
    func write(_ data: Data, to url: URL, sync: Bool) throws { try step("write", url); try disk.write(data, to: url, sync: sync) }
    func replaceItem(at original: URL, withItemAt temp: URL) throws { try step("replace", original); try disk.replaceItem(at: original, withItemAt: temp) }
    func installItem(at destination: URL, from staging: URL) throws { try step("install", destination); try disk.installItem(at: destination, from: staging) }
    func replacementDirectory(for destination: URL) throws -> URL { try disk.replacementDirectory(for: destination) }
    func preserveVerifiedCopy(from src: URL, to dst: URL) throws { try step("copy", dst); try disk.preserveVerifiedCopy(from: src, to: dst) }
    func removeItem(at url: URL) throws { try step("remove", url); try disk.removeItem(at: url) }
    func fileExists(at url: URL) -> Bool { disk.fileExists(at: url) }
    func isDirectory(at url: URL) throws -> Bool { try disk.isDirectory(at: url) }
    func isSymbolicLink(at url: URL) throws -> Bool { try disk.isSymbolicLink(at: url) }
    func createDirectory(at url: URL) throws { try step("folder", url); try disk.createDirectory(at: url) }
    func contentsOfDirectory(at url: URL) throws -> [URL] { try disk.contentsOfDirectory(at: url) }
    func acquireExclusiveLock(at url: URL) throws -> AdvisoryLock { SharedLock() }
    func stored(_ url: URL) -> Data? { disk.stored(url) }
}
private struct SharedLock: AdvisoryLock { func release() {} }

/// The background configuration's two Keychain items in memory, with failures to order and a log of every change.
final class MemoryBackgroundStore: BackgroundConfigurationStore, @unchecked Sendable {
    var current: Data?, legacy: Data?
    /// Which reads fail, by `legacy`.
    var unreadable: Set<Bool> = []
    var saveFails = false
    private(set) var changes: [String] = []
    func read(legacy isLegacy: Bool) throws -> Data? {
        if unreadable.contains(isLegacy) { throw VaultError.unavailable }
        return isLegacy ? legacy : current
    }
    func save(_ data: Data) throws {
        changes.append("save")
        if saveFails { throw VaultError.unavailable }
        current = data
    }
    func deleteLegacy() {
        changes.append("delete old")
        legacy = nil
    }
}

struct VaultStoreTests {
    private func harness() -> (
        store: VaultStore,
        io: MemoryFileIO,
        keys: MemoryKeyStore,
        auth: FixtureAuthenticator,
        fence: UnlockFence,
        layout: VaultLayout,
        recovery: RecoveryCode
    ) {
        let io = MemoryFileIO()
        let keys = MemoryKeyStore()
        let auth = FixtureAuthenticator()
        let fence = UnlockFence()
        let layout = VaultLayout(root: URL(fileURLWithPath: "/tmp/uponly-fixture-\(UUID().uuidString)"))
        let store = VaultStore(layout: layout, io: io, keys: keys, authenticator: auth, fence: fence)
        return (store, io, keys, auth, fence, layout, RecoveryCode.random())
    }

    @Test("Create writes generation 1 and no previous file")
    func firstWriteHasNoPrevious() async throws {
        let h = harness()
        let session = try await h.store.create(recovery: h.recovery, confirmation: h.recovery.canonical)
        #expect(session.document.generation == 1)
        #expect(h.io.fileExists(at: h.layout.current))
        #expect(!h.io.fileExists(at: h.layout.previous))
        #expect(session.document.inboxPrivateKeyX963.count == 97)
    }

    @Test("Wrong confirmation refuses setup")
    func confirmationMustMatch() async throws {
        let h = harness()
        await #expect(throws: VaultError.confirmationMismatch) {
            try await h.store.create(recovery: h.recovery, confirmation: "DEADBEEF")
        }
        #expect(!h.io.fileExists(at: h.layout.current))
    }

    @Test("Keychain failure publishes no vault and setup can retry")
    func creationRequiresStoredKey() async throws {
        let io = MemoryFileIO(), keys = SetupTestKeyStore()
        let layout = VaultLayout(root: URL(fileURLWithPath: "/tmp/uponly-key-failure-" + UUID().uuidString))
        let store = VaultStore(layout: layout, io: io, keys: keys, authenticator: FixtureAuthenticator())
        let code = RecoveryCode.random()
        keys.storeError = .keychainUnavailable(-34018)
        await #expect(throws: VaultError.keychainUnavailable(-34018)) {
            try await store.create(recovery: code, confirmation: code.canonical)
        }
        #expect(!io.fileExists(at: layout.current) && !io.fileExists(at: layout.recovery))
        #expect(await !store.isUnlocked)
        keys.storeError = nil
        let created = try await store.create(recovery: code, confirmation: code.canonical)
        #expect(created.document.generation == 1)
        #expect(keys.contains(vaultID: created.document.vaultID))
    }

    @Test("Failed initial writes remove unpublished recovery material and keys", arguments: ["wrapper", "payload", "rename"])
    func failedFirstSaveIsRetryable(_ failure: String) async throws {
        let io = MemoryFileIO(), keys = SetupTestKeyStore()
        let layout = VaultLayout(root: URL(fileURLWithPath: "/tmp/uponly-first-save-" + UUID().uuidString))
        let store = VaultStore(layout: layout, io: io, keys: keys, authenticator: FixtureAuthenticator())
        let code = RecoveryCode.random()
        if failure == "rename" { io.failReplace = true }
        else { io.failWriteMatching = failure == "wrapper" ? "recovery.wrapper" : "vault.uponly.tmp" }
        await #expect(throws: VaultError.diskWriteFailed) {
            try await store.create(recovery: code, confirmation: code.canonical)
        }
        let id = try #require(keys.lastStoredID)
        #expect(!keys.contains(vaultID: id))
        #expect(!io.fileExists(at: layout.current) && !io.fileExists(at: layout.recovery))
        #expect(await !store.isUnlocked)
        io.failReplace = false; io.failWriteMatching = nil
        let created = try await store.create(recovery: code, confirmation: code.canonical)
        #expect(created.document.generation == 1)
    }

    @Test("Unlock uses the authenticated read instead of an inconclusive Keychain probe")
    func unlockDoesNotUsePresenceProbe() async throws {
        let io = MemoryFileIO(), keys = SetupTestKeyStore()
        let layout = VaultLayout(root: URL(fileURLWithPath: "/tmp/uponly-key-probe-" + UUID().uuidString))
        let store = VaultStore(layout: layout, io: io, keys: keys, authenticator: FixtureAuthenticator())
        let code = RecoveryCode.random()
        let created = try await store.create(recovery: code, confirmation: code.canonical)
        store.lock(); keys.probeReturnsMissing = true
        let reopened = try await store.unlock()
        #expect(reopened.document.vaultID == created.document.vaultID)
        #expect(reopened.document.generation == created.document.generation)
        #expect(reopened.document.inboxPrivateKeyX963 == created.document.inboxPrivateKeyX963)
    }

    @Test("Replacement keeps one verified previous generation")
    func replacementRetainsPrevious() async throws {
        let h = harness()
        var session = try await h.store.create(recovery: h.recovery, confirmation: h.recovery.canonical)
        var next = session.document
        next.generation += 1
        next.accounts = [Account(name: "Sample bank", currency: "GBP")]
        try await h.store.commit(next, expectedGeneration: session.document.generation, sessionID: session.sessionID)
        session = try await h.store.currentSession()
        #expect(session.document.generation == 2)
        #expect(h.io.fileExists(at: h.layout.previous))
        let previous = try VaultJSON.decode(PersistedVaultFile.self, from: h.io.stored(h.layout.previous)!)
        #expect(previous.generation == 1)
    }

    @Test("Wrong key cannot open the ciphertext")
    func wrongKeyFails() throws {
        let key = VaultCrypto.randomKey()
        let inbox = VaultCrypto.makeInboxKeyPair()
        let document = VaultDocument.empty(
            inboxPrivateKeyX963: inbox.privateX963,
            inboxPublicKeyX963: inbox.publicX963
        )
        let persisted = try VaultCrypto.persist(document, key: key)
        #expect(throws: VaultError.wrongKey) {
            _ = try VaultCrypto.reveal(persisted, key: VaultCrypto.randomKey())
        }
    }

    @Test("Modified tag refuses decrypt")
    func modifiedTagFails() throws {
        let key = VaultCrypto.randomKey()
        let inbox = VaultCrypto.makeInboxKeyPair()
        let document = VaultDocument.empty(
            inboxPrivateKeyX963: inbox.privateX963,
            inboxPublicKeyX963: inbox.publicX963
        )
        var persisted = try VaultCrypto.persist(document, key: key)
        persisted.tag[persisted.tag.startIndex] ^= 0xFF
        #expect(throws: VaultError.wrongKey) {
            _ = try VaultCrypto.reveal(persisted, key: key)
        }
    }

    @Test("Modified generation header fails AAD")
    func modifiedGenerationFails() throws {
        let key = VaultCrypto.randomKey()
        let inbox = VaultCrypto.makeInboxKeyPair()
        let document = VaultDocument.empty(
            inboxPrivateKeyX963: inbox.privateX963,
            inboxPublicKeyX963: inbox.publicX963
        )
        var persisted = try VaultCrypto.persist(document, key: key)
        persisted.generation = 99
        #expect(throws: VaultError.wrongKey) {
            _ = try VaultCrypto.reveal(persisted, key: key)
        }
    }

    @Test("Failed disk write leaves previous state")
    func writeFailureLeavesState() async throws {
        let h = harness()
        let session = try await h.store.create(recovery: h.recovery, confirmation: h.recovery.canonical)
        h.io.failWrite = true
        var next = session.document
        next.generation += 1
        await #expect(throws: VaultError.diskWriteFailed) {
            try await h.store.commit(next, expectedGeneration: 1, sessionID: session.sessionID)
        }
        let still = try await h.store.currentSession()
        #expect(still.document.generation == 1)
        let disk = try VaultJSON.decode(PersistedVaultFile.self, from: h.io.stored(h.layout.current)!)
        #expect(disk.generation == 1)
    }

    @Test("Rename failure leaves current generation")
    func replaceFailureLeavesState() async throws {
        let h = harness()
        let session = try await h.store.create(recovery: h.recovery, confirmation: h.recovery.canonical)
        h.io.failReplace = true
        var next = session.document
        next.generation += 1
        await #expect(throws: VaultError.diskWriteFailed) {
            try await h.store.commit(next, expectedGeneration: 1, sessionID: session.sessionID)
        }
        #expect((try await h.store.currentSession()).document.generation == 1)
    }

    @Test("Second writer is refused")
    func secondWriterRefused() async throws {
        let h = harness()
        _ = try await h.store.create(recovery: h.recovery, confirmation: h.recovery.canonical)
        let other = VaultStore(
            layout: h.layout,
            io: h.io,
            keys: h.keys,
            authenticator: FixtureAuthenticator(),
            fence: UnlockFence()
        )
        await #expect(throws: VaultError.alreadyOpen) {
            _ = try await other.unlock()
        }
    }

    @Test("Concurrent commits keep data and accepted batch IDs")
    func concurrentCommitReapply() async throws {
        let h = harness()
        let session = try await h.store.create(recovery: h.recovery, confirmation: h.recovery.canonical)
        var importDoc = session.document
        importDoc.generation += 1
        importDoc.acceptedBatchIDs.append(UUID())
        var editDoc = session.document
        editDoc.generation += 1
        editDoc.accounts = [Account(name: "Wise USD", currency: "USD")]

        let results = await withTaskGroup(of: Result<Void, Error>.self) { group in
            group.addTask {
                do {
                    try await h.store.commit(importDoc, expectedGeneration: 1, sessionID: session.sessionID)
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }
            group.addTask {
                do {
                    try await h.store.commit(editDoc, expectedGeneration: 1, sessionID: session.sessionID)
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }
            var collected: [Result<Void, Error>] = []
            for await result in group { collected.append(result) }
            return collected
        }
        let failures = results.compactMap { result -> VaultError? in
            if case .failure(let error) = result { return error as? VaultError }
            return nil
        }
        #expect(failures.contains(.staleGeneration))
        let winner = try await h.store.currentSession()
        var merged = winner.document
        if winner.document.acceptedBatchIDs.isEmpty {
            merged.acceptedBatchIDs = importDoc.acceptedBatchIDs
        }
        if winner.document.accounts.isEmpty {
            merged.accounts = editDoc.accounts
        }
        merged.generation = winner.document.generation + 1
        try await h.store.commit(
            merged,
            expectedGeneration: winner.document.generation,
            sessionID: winner.sessionID
        )
        let final = try await h.store.currentSession()
        #expect(!final.document.acceptedBatchIDs.isEmpty)
        #expect(!final.document.accounts.isEmpty)
    }

    @Test("Auth cancellation leaves the vault locked")
    func authCancel() async throws {
        let h = harness()
        _ = try await h.store.create(recovery: h.recovery, confirmation: h.recovery.canonical)
        await h.store.lock()
        h.auth.shouldCancel = true
        await #expect(throws: VaultError.cancelled) {
            _ = try await h.store.unlock()
        }
        #expect(await h.store.isUnlocked == false)
    }

    @Test("Lock during decrypt publishes nothing")
    func lockDuringDecrypt() async throws {
        let h = harness()
        _ = try await h.store.create(recovery: h.recovery, confirmation: h.recovery.canonical)
        await h.store.lock()
        h.io.onRead = { h.store.lock() }
        await #expect(throws: VaultError.locked) {
            _ = try await h.store.unlock()
        }
        #expect(await h.store.isUnlocked == false)
    }

    @Test("Lock during write does not replace the file")
    func lockDuringWrite() async throws {
        let h = harness()
        let session = try await h.store.create(recovery: h.recovery, confirmation: h.recovery.canonical)
        h.io.onWrite = { h.store.lock() }
        var next = session.document
        next.generation += 1
        await #expect(throws: VaultError.locked) {
            try await h.store.commit(next, expectedGeneration: 1, sessionID: session.sessionID)
        }
        let disk = try VaultJSON.decode(PersistedVaultFile.self, from: h.io.stored(h.layout.current)!)
        #expect(disk.generation == 1)
    }

    @Test("Missing key is recovery, never an empty vault")
    func missingKeyNeedsRecovery() async throws {
        let h = harness()
        let session = try await h.store.create(recovery: h.recovery, confirmation: h.recovery.canonical)
        try h.keys.delete(vaultID: session.document.vaultID)
        await h.store.lock()
        await #expect(throws: VaultError.needsRecovery) {
            _ = try await h.store.unlock()
        }
        await #expect(throws: VaultError.alreadyExists) {
            _ = try await h.store.create(recovery: h.recovery, confirmation: h.recovery.canonical)
        }
        #expect(h.io.fileExists(at: h.layout.current))
    }

    @Test("Fresh Keychain recovery restores inbox private key")
    func freshKeychainRecovery() async throws {
        let h = harness()
        let created = try await h.store.create(recovery: h.recovery, confirmation: h.recovery.canonical)
        let vaultID = created.document.vaultID
        let inboxPrivate = created.document.inboxPrivateKeyX963
        try h.keys.delete(vaultID: vaultID)
        await h.store.lock()
        let recovered = try await h.store.recover(h.recovery)
        #expect(recovered.document.vaultID == vaultID)
        #expect(recovered.document.inboxPrivateKeyX963 == inboxPrivate)
        #expect(h.keys.contains(vaultID: vaultID))
    }

    @Test("Wrong recovery code fails")
    func wrongRecoveryCode() async throws {
        let h = harness()
        let created = try await h.store.create(recovery: h.recovery, confirmation: h.recovery.canonical)
        try h.keys.delete(vaultID: created.document.vaultID)
        await h.store.lock()
        await #expect(throws: VaultError.wrongRecoveryCode) {
            _ = try await h.store.recover(RecoveryCode.random())
        }
        #expect(await h.store.isUnlocked == false)
    }

    @Test("Lock clears decrypted state")
    func lockClearsState() async throws {
        let h = harness()
        _ = try await h.store.create(recovery: h.recovery, confirmation: h.recovery.canonical)
        await h.store.lock()
        #expect(await h.store.isUnlocked == false)
        await #expect(throws: VaultError.locked) {
            _ = try await h.store.currentSession()
        }
        #expect(h.auth.invalidated)
    }

    @Test("Corrupt file does not become an empty vault")
    func corruptDoesNotReset() async throws {
        let h = harness()
        _ = try await h.store.create(recovery: h.recovery, confirmation: h.recovery.canonical)
        try h.io.write(Data("not-a-vault".utf8), to: h.layout.current, sync: true)
        await h.store.lock()
        await #expect(throws: VaultError.corrupt) {
            _ = try await h.store.unlock()
        }
        await #expect(throws: VaultError.alreadyExists) {
            _ = try await h.store.create(recovery: h.recovery, confirmation: h.recovery.canonical)
        }
    }

    @Test("Unlock without a file does not create one")
    func unlockMissingDoesNotCreate() async throws {
        let h = harness()
        await #expect(throws: VaultError.notFound) {
            _ = try await h.store.unlock()
        }
        #expect(!h.io.fileExists(at: h.layout.current))
    }

    @Test("Backup pause is released on failure and publishes nothing")
    func backupFailureReleasesPause() async throws {
        let h = harness()
        _ = try await h.store.create(recovery: h.recovery, confirmation: h.recovery.canonical)
        let producer = FixtureProducer()
        producer.failPause = true
        await #expect(throws: VaultError.pauseFailed) {
            _ = try await BackupCoordinator.makePackage(store: h.store, producers: [producer])
        }
        #expect(producer.resumeCount == 0)
        #expect(!producer.isPaused)
    }

    @Test("Coherent backup restores signers and settings")
    func backupRestorePreservesTrust() async throws {
        let h = harness()
        var session = try await h.store.create(recovery: h.recovery, confirmation: h.recovery.canonical)
        let signing = VaultCrypto.makeSigningKeyPair()
        var next = session.document
        next.generation += 1
        next.settings.privacyMode = true
        next.trustedSigners = [
            TrustedSigner(
                id: UUID(),
                publicKeyX963: signing.publicX963,
                role: .personalCollector,
                highWater: [SignerHighWater(source: .quote, accountIdentity: "coingecko", sequence: 4)]
            ),
        ]
        try await h.store.commit(next, expectedGeneration: 1, sessionID: session.sessionID)
        session = try await h.store.currentSession()
        let producer = FixtureProducer()
        let package = try await BackupCoordinator.makePackage(store: h.store, producers: [producer])
        #expect(producer.pauseCount == 1)
        #expect(producer.resumeCount == 1)

        let dest = URL(fileURLWithPath: "/tmp/uponly-backup-\(UUID().uuidString)")
        try BackupCoordinator.publish(package, to: dest, io: h.io)

        let freshKeys = MemoryKeyStore()
        let restoredLayout = VaultLayout(root: URL(fileURLWithPath: "/tmp/uponly-restore-\(UUID().uuidString)"))
        let restored = try BackupCoordinator.restore(
            package: package,
            recovery: h.recovery,
            keys: freshKeys,
            layout: restoredLayout,
            io: h.io
        )
        #expect(restored.document.trustedSigners.first?.highWater.first?.sequence == 4)
        #expect(restored.document.inboxPrivateKeyX963 == session.document.inboxPrivateKeyX963)
        #expect(restored.document.settings.privacyMode)
        #expect(freshKeys.contains(vaultID: restored.document.vaultID))
    }

    @Test("Backup export creates nothing beside the chosen path, and Replace swaps only an earlier backup")
    func backupStagingStaysInside() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UpOnlyTest-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let io = DiskFileIO(), code = RecoveryCode.random()
        let layout = VaultLayout(root: root.appendingPathComponent("Vault"))
        let store = VaultStore(layout: layout, io: io, keys: MemoryKeyStore(), authenticator: FixtureAuthenticator())
        _ = try await store.create(recovery: code, confirmation: code.canonical)
        let package = try await BackupCoordinator.makePackage(store: store, producers: [])
        let folder = root.appendingPathComponent("Backups")
        try io.createDirectory(at: folder)
        let chosen = folder.appendingPathComponent("Up Only Backup.uponlybackup")
        try BackupCoordinator.publish(package, to: chosen, io: io)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [chosen.lastPathComponent])
        #expect(try BackupCoordinator.read(from: chosen, io: io).manifest == package.manifest)
        // Confirming the save panel's "Replace" swaps out the earlier backup, again without touching its folder.
        try BackupCoordinator.publish(package, to: chosen, io: io)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [chosen.lastPathComponent])
        #expect(try BackupCoordinator.read(from: chosen, io: io).manifest == package.manifest)
        // A vault, or anything else that isn't a backup, is never replaced.
        #expect(throws: VaultError.alreadyExists) { try BackupCoordinator.publish(package, to: layout.root, io: io) }
        #expect(try io.data(at: layout.current) == package.vault)
    }

    @Test("A damaged vault file reopens from the previous generation, which is saved back as current", arguments: ["truncated", "tampered"])
    func previousGenerationFallback(_ damage: String) async throws {
        let h = harness()
        let created = try await h.store.create(recovery: h.recovery, confirmation: h.recovery.canonical)
        var next = created.document
        next.generation += 1
        next.accounts = [Account(name: "Sample bank", currency: "GBP")]
        try await h.store.commit(next, expectedGeneration: 1, sessionID: created.sessionID)
        let good = try #require(h.io.stored(h.layout.current))
        if damage == "truncated" {
            try h.io.write(good.prefix(good.count / 2), to: h.layout.current, sync: true)
        } else {
            var file = try VaultJSON.decode(PersistedVaultFile.self, from: good)
            file.ciphertext[file.ciphertext.startIndex] ^= 0xFF
            try h.io.write(try VaultJSON.encode(file), to: h.layout.current, sync: true)
        }
        h.store.lock()
        let reopened = try await h.store.unlock()
        #expect(reopened.document.generation == 1 && reopened.document.accounts.isEmpty)
        #expect(await h.store.openedPrevious)
        #expect(try VaultJSON.decode(PersistedVaultFile.self, from: try #require(h.io.stored(h.layout.current))).generation == 1)
        var after = reopened.document
        after.generation += 1
        try await h.store.commit(after, expectedGeneration: 1, sessionID: reopened.sessionID)
        h.store.lock()
        #expect(try await h.store.unlock().document.generation == 2)
        #expect(await !h.store.openedPrevious)
    }

    @Test("Recovery also falls back to the previous generation")
    func recoveryUsesPreviousGeneration() async throws {
        let h = harness()
        let created = try await h.store.create(recovery: h.recovery, confirmation: h.recovery.canonical)
        var next = created.document
        next.generation += 1
        try await h.store.commit(next, expectedGeneration: 1, sessionID: created.sessionID)
        try h.io.write(Data("not-a-vault".utf8), to: h.layout.current, sync: true)
        try h.keys.delete(vaultID: created.document.vaultID)
        h.store.lock()
        let recovered = try await h.store.recover(h.recovery)
        #expect(recovered.document.vaultID == created.document.vaultID && recovered.document.generation == 1)
        #expect(await h.store.openedPrevious)
    }

    @Test("A folder left with only an empty Inbox still counts as empty for restore")
    func emptyInboxAllowsRestore() async throws {
        let h = harness()
        try h.layout.ensureDirectories(h.io)
        try await h.store.releaseEmptyDestination()
        #expect(!h.io.fileExists(at: h.layout.root))
        try h.layout.ensureDirectories(h.io)
        try h.io.write(Data("x".utf8), to: h.layout.root.appendingPathComponent("other"), sync: true)
        await #expect(throws: VaultError.alreadyExists) { try await h.store.releaseEmptyDestination() }
    }

    /// Creates a vault and saves one account in it, so it has records.
    private func createWithAccount(_ store: VaultStore, _ recovery: RecoveryCode) async throws -> VaultSession {
        let created = try await store.create(recovery: recovery, confirmation: recovery.canonical)
        var next = created.document
        next.generation += 1
        next.accounts = [Account(name: "Sample bank", currency: "GBP")]
        try await store.commit(next, expectedGeneration: 1, sessionID: created.sessionID)
        return try await store.currentSession()
    }

    /// A backup of a different vault, with the code that opens it.
    private func otherBackup() async throws -> (package: BackupPackage, code: RecoveryCode) {
        let other = harness()
        _ = try await createWithAccount(other.store, other.recovery)
        let package = try await BackupCoordinator.makePackage(store: other.store, producers: [])
        return (package, other.recovery)
    }

    @Test("A new recovery code opens the vault and later backups; the old code no longer does")
    func rotatedRecoveryCode() async throws {
        let h = harness()
        let created = try await h.store.create(recovery: h.recovery, confirmation: h.recovery.canonical)
        let next = RecoveryCode.random()
        try await h.store.rotateRecovery(next, sessionID: created.sessionID)
        #expect(h.auth.evaluateCount == 2)
        #expect(await h.store.isUnlocked)
        #expect(!h.io.fileExists(at: h.layout.recovery.appendingPathExtension("tmp")))
        // A backup exported after the change opens with the new code only.
        let package = try await BackupCoordinator.makePackage(store: h.store, producers: [])
        let restoredLayout = VaultLayout(root: URL(fileURLWithPath: "/tmp/uponly-restore-\(UUID().uuidString)"))
        #expect(throws: VaultError.wrongRecoveryCode) {
            _ = try BackupCoordinator.restore(package: package, recovery: h.recovery, keys: MemoryKeyStore(), layout: restoredLayout, io: h.io)
        }
        let restored = try BackupCoordinator.restore(package: package, recovery: next, keys: MemoryKeyStore(), layout: restoredLayout, io: h.io)
        #expect(restored.document.vaultID == created.document.vaultID)
        try h.keys.delete(vaultID: created.document.vaultID)
        h.store.lock()
        await #expect(throws: VaultError.wrongRecoveryCode) { _ = try await h.store.recover(h.recovery) }
        #expect(try await h.store.recover(next).document.vaultID == created.document.vaultID)
    }

    @Test("Cancelled authentication or a failed write keeps the current recovery code", arguments: ["cancel", "write", "replace"])
    func rotationFailureKeepsCode(_ failure: String) async throws {
        let h = harness()
        let created = try await h.store.create(recovery: h.recovery, confirmation: h.recovery.canonical)
        let wrapper = try #require(h.io.stored(h.layout.recovery))
        let next = RecoveryCode.random()
        switch failure {
        case "cancel": h.auth.shouldCancel = true
        case "write": h.io.failWriteMatching = "recovery.wrapper"
        default: h.io.failReplace = true
        }
        await #expect(throws: failure == "cancel" ? VaultError.cancelled : VaultError.diskWriteFailed) {
            try await h.store.rotateRecovery(next, sessionID: created.sessionID)
        }
        h.auth.shouldCancel = false; h.io.failWriteMatching = nil; h.io.failReplace = false
        #expect(h.io.stored(h.layout.recovery) == wrapper)
        #expect(!h.io.fileExists(at: h.layout.recovery.appendingPathExtension("tmp")))
        #expect(await h.store.isUnlocked)
        try h.keys.delete(vaultID: created.document.vaultID)
        h.store.lock()
        await #expect(throws: VaultError.wrongRecoveryCode) { _ = try await h.store.recover(next) }
        #expect(try await h.store.recover(h.recovery).document.vaultID == created.document.vaultID)
    }

    @Test("The session replaces the recovery code; a failed save keeps the old one and says so")
    @MainActor func sessionReplacesRecoveryCode() async throws {
        let h = harness()
        let created = try await h.store.create(recovery: h.recovery, confirmation: h.recovery.canonical)
        h.store.lock()
        let session = UpOnlySession(testing: h.store, layout: h.layout)
        await session.unlock()
        h.io.failReplace = true
        #expect(await !session.replaceRecoveryCode(RecoveryCode.random()))
        #expect(session.message == "Your recovery code couldn’t be replaced. Your current code still works.")
        h.io.failReplace = false
        let next = RecoveryCode.random()
        #expect(await session.replaceRecoveryCode(next))
        #expect(session.state == .unlocked && !session.isBusy)
        try h.keys.delete(vaultID: created.document.vaultID)
        session.lock()
        await #expect(throws: VaultError.wrongRecoveryCode) { _ = try await h.store.recover(h.recovery) }
        #expect(try await h.store.recover(next).document.vaultID == created.document.vaultID)
    }

    @Test("Restoring over a vault moves its folder aside and opens the backup")
    func replaceMovesVaultAside() async throws {
        let h = harness()
        let current = try await createWithAccount(h.store, h.recovery)
        let original = try #require(h.io.stored(h.layout.current))
        let backup = try await otherBackup()
        let now = Date()
        let aside = h.layout.replacedRoot(at: now, io: h.io)
        #expect(aside.lastPathComponent == h.layout.replacedName(at: now))
        #expect(aside.deletingLastPathComponent().path == h.layout.root.deletingLastPathComponent().path)
        let opened = try await h.store.replace(with: backup.package, recovery: backup.code, aside: aside)
        #expect(opened.document.vaultID == backup.package.manifest.vaultID)
        #expect(h.io.stored(h.layout.current) == backup.package.vault)
        #expect(h.io.stored(VaultLayout(root: aside).current) == original)
        #expect(h.io.stored(VaultLayout(root: aside).recovery) != nil)
        // A second restore in the same minute gets its own folder.
        #expect(h.layout.replacedRoot(at: now, io: h.io).lastPathComponent == String(h.layout.replacedName(at: now).dropLast()) + " 2)")
        // The replaced session can't save into the restored vault.
        var stale = current.document
        stale.generation += 1
        await #expect(throws: VaultError.staleSession) {
            try await h.store.commit(stale, expectedGeneration: current.document.generation, sessionID: current.sessionID)
        }
        // The restored vault reopens from the Keychain; the replaced one keeps its key.
        h.store.lock()
        #expect(try await h.store.unlock().document.vaultID == backup.package.manifest.vaultID)
        #expect(h.keys.contains(vaultID: current.document.vaultID))
    }

    @Test("A restore that fails after the move puts the original vault back, locked", arguments: ["write", "lock"])
    func replaceFailurePutsVaultBack(_ failure: String) async throws {
        let h = harness()
        let current = try await createWithAccount(h.store, h.recovery)
        let original = try #require(h.io.stored(h.layout.current))
        let backup = try await otherBackup()
        let aside = h.layout.replacedRoot(at: Date(), io: h.io)
        // Both happen once the folder has moved: a restore write fails, or the vault locks before the backup opens.
        if failure == "write" { h.io.failWriteMatching = ".restore-" } else { h.io.onWrite = { h.store.lock() } }
        await #expect(throws: VaultError.self) {
            _ = try await h.store.replace(with: backup.package, recovery: backup.code, aside: aside)
        }
        h.io.failWriteMatching = nil; h.io.onWrite = nil
        #expect(!h.io.fileExists(at: aside))
        #expect(h.io.stored(h.layout.current) == original)
        #expect(await !h.store.isUnlocked)
        let reopened = try await h.store.unlock()
        #expect(reopened.document.vaultID == current.document.vaultID && reopened.document.accounts.count == 1)
    }

    @Test("A code that doesn't open the backup changes nothing")
    func replaceRefusesWrongCode() async throws {
        let h = harness()
        let current = try await createWithAccount(h.store, h.recovery)
        let original = try #require(h.io.stored(h.layout.current))
        let backup = try await otherBackup()
        let aside = h.layout.replacedRoot(at: Date(), io: h.io)
        #expect(!BackupCoordinator.opens(backup.package, with: h.recovery))
        await #expect(throws: VaultError.wrongRecoveryCode) {
            _ = try await h.store.replace(with: backup.package, recovery: h.recovery, aside: aside)
        }
        #expect(!h.io.fileExists(at: aside) && h.io.stored(h.layout.current) == original)
        #expect(try await h.store.currentSession().sessionID == current.sessionID)
    }

    @Test("Restoring from Backup & security asks first only when the vault has records")
    @MainActor func sessionRestoreConfirmation() async throws {
        let backup = try await otherBackup()
        // An empty vault is replaced without asking.
        let empty = harness()
        _ = try await empty.store.create(recovery: empty.recovery, confirmation: empty.recovery.canonical)
        empty.store.lock()
        let quick = UpOnlySession(testing: empty.store, layout: empty.layout)
        await quick.unlock()
        #expect(await quick.restoreBackup(backup.package, recovery: backup.code, confirmed: false) == .restored)
        #expect(quick.state == .unlocked && quick.document?.vaultID == backup.package.manifest.vaultID)

        // A vault with an account asks first. A wrong code or cancelled authentication leaves it open and in place.
        let h = harness()
        let current = try await createWithAccount(h.store, h.recovery)
        h.store.lock()
        let session = UpOnlySession(testing: h.store, layout: h.layout)
        await session.unlock()
        #expect(await session.restoreBackup(backup.package, recovery: RecoveryCode.random(), confirmed: true) == .failed)
        #expect(await session.restoreBackup(backup.package, recovery: backup.code, confirmed: false) == .needsConfirmation)
        h.auth.shouldCancel = true
        #expect(await session.restoreBackup(backup.package, recovery: backup.code, confirmed: true) == .cancelled)
        h.auth.shouldCancel = false
        #expect(session.state == .unlocked && session.document?.vaultID == current.document.vaultID)
        #expect(await session.restoreBackup(backup.package, recovery: backup.code, confirmed: true) == .restored)
        #expect(session.state == .unlocked && session.document?.vaultID == backup.package.manifest.vaultID)
        let aside = try #require(try h.io.contentsOfDirectory(at: h.layout.root.deletingLastPathComponent()).first {
            $0.lastPathComponent.hasPrefix(h.layout.root.lastPathComponent + " (replaced ")
        })
        #expect(try VaultJSON.decode(PersistedVaultFile.self, from: try #require(h.io.stored(VaultLayout(root: aside).current))).vaultID == current.document.vaultID)
    }

    private func emptyDocument() -> VaultDocument {
        let pair = VaultCrypto.makeInboxKeyPair()
        return VaultDocument.empty(inboxPrivateKeyX963: pair.privateX963, inboxPublicKeyX963: pair.publicX963)
    }

    @Test("A later same-day rate replaces a provisional one while its UTC day is open; a settled day keeps its value")
    func fxDayReplacement() throws {
        var doc = emptyDocument()
        let day = try ImportDateFormat.iso.date("2026-09-23")
        func rate(_ value: String, fetched: TimeInterval, at time: Date? = nil, provider: String = "Frankfurter") -> FXObservation {
            FXObservation(sourceCurrency: "GBP", targetCurrency: "USD", rate: PreciseDecimal(Decimal(string: value)!), providerTime: time ?? day, fetchedAt: day.addingTimeInterval(fetched), provider: provider)
        }
        doc = try PriceHistory.applying(PriceUpdate(rates: [rate("1.30", fetched: 300)]), to: doc, now: day.addingTimeInterval(3600))
        doc = try PriceHistory.applying(PriceUpdate(rates: [rate("1.31", fetched: 1800, at: day.addingTimeInterval(0.5))]), to: doc, now: day.addingTimeInterval(3600))
        #expect(doc.fx.map(\.rate.value) == [Decimal(string: "1.31")!])
        // The next day's history backfill settles the day; nothing fetched later moves it.
        doc = try PriceHistory.applying(PriceUpdate(rates: [rate("1.32", fetched: 86400 + 60)]), to: doc, now: day.addingTimeInterval(86400 + 3600))
        doc = try PriceHistory.applying(PriceUpdate(rates: [rate("1.33", fetched: 2 * 86400)]), to: doc, now: day.addingTimeInterval(2 * 86400 + 3600))
        #expect(doc.fx.map(\.rate.value) == [Decimal(string: "1.32")!])
        // A rate the user entered is never replaced.
        var manual = emptyDocument()
        manual.fx = [rate("2", fetched: 60, provider: "Manual")]
        manual = try PriceHistory.applying(PriceUpdate(rates: [rate("1.30", fetched: 600)]), to: manual, now: day.addingTimeInterval(3600))
        #expect(manual.fx.map(\.provider) == ["Manual"])
    }

    @Test("A fetched chunk is complete once every day has a price or it ended more than three days ago")
    func closedChunksComplete() throws {
        let start = try ImportDateFormat.iso.date("2026-08-01"), end = start.addingTimeInterval(7 * 86400)
        let request = PriceHistoryRequest(source: .metal, key: "asset:metal-gold-gram", identifier: PreciousMetal.gold.assetID.rawValue, start: start, end: end)
        let weekdays = (0..<5).map { start.addingTimeInterval(Double($0) * 86400 + 86399) }
        #expect(!PriceHistory.isComplete(request, observations: weekdays, now: end.addingTimeInterval(86400)))
        #expect(PriceHistory.isComplete(request, observations: weekdays, now: end.addingTimeInterval(4 * 86400)))
        #expect(PriceHistory.isComplete(request, observations: [], now: end.addingTimeInterval(4 * 86400)))
        #expect(PriceHistory.isComplete(request, observations: (0..<7).map { start.addingTimeInterval(Double($0) * 86400) }, now: end))
        // One unreadable point no longer discards the rest of a crypto chunk.
        let crypto = PriceHistoryRequest(source: .crypto, key: "asset:bitcoin", identifier: "bitcoin", start: start, end: end)
        let ms = Int(start.timeIntervalSince1970 * 1000)
        let quotes = try PriceHistory.decodeCrypto(Data("{\"prices\":[[\(ms),1],[\(ms + 86400000),null],[\(ms + 2 * 86400000),0],[\(ms + 3 * 86400000),4]]}".utf8), request: crypto, fetchedAt: end)
        #expect(quotes.map(\.priceUSD.value) == [1, 4])
    }

    @Test("Days before yesterday keep only each asset's last quote; yesterday and today keep every quote")
    func quotePruning() throws {
        let day = try ImportDateFormat.iso.date("2026-09-20"), today = day.addingTimeInterval(2 * 86400)
        func quote(_ asset: String, _ time: Date, _ price: Decimal) throws -> QuoteObservation {
            QuoteObservation(assetID: try CanonicalAssetID(asset), priceUSD: PreciseDecimal(price), providerTime: time, fetchedAt: time, provider: "CoinGecko")
        }
        var update = PriceUpdate()
        for hour in 0..<24 { update.quotes.append(try quote("bitcoin", day.addingTimeInterval(Double(hour) * 3600), Decimal(100 + hour))) }
        update.quotes.append(try quote("ethereum", day.addingTimeInterval(600), 5))
        update.quotes += [try quote("bitcoin", today.addingTimeInterval(600), 1), try quote("bitcoin", today.addingTimeInterval(4200), 2)]
        let saved = try PriceHistory.applying(update, to: emptyDocument(), now: today.addingTimeInterval(7200))
        #expect(saved.quotes.filter { $0.assetID.rawValue == "bitcoin" }.sorted { $0.providerTime < $1.providerTime }.map(\.priceUSD.value) == [123, 1, 2])
        #expect(saved.quotes.filter { $0.assetID.rawValue == "ethereum" }.count == 1)
        // Yesterday's hourly quotes stay, so a 24-hour change has a real price from 24 hours ago.
        var recent = PriceUpdate()
        for hour in 0..<24 { recent.quotes.append(try quote("solana", day.addingTimeInterval(86400 + Double(hour) * 3600), Decimal(hour))) }
        let kept = try PriceHistory.applying(recent, to: saved, now: today.addingTimeInterval(7200))
        #expect(kept.quotes.filter { $0.assetID.rawValue == "solana" }.count == 24)
    }

    @Test("Going offline frees the background slot; a real failure retries after five minutes, then backs off")
    func offlineDoesNotBlock() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UpOnlyTest-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let schedule = BackgroundRefreshSchedule(), signing = VaultCrypto.makeSigningKeyPair()
        let config = BackgroundConfiguration(vaultID: UUID(), inboxPublicKey: Data(), signingPrivateKey: signing.privateX963, signingPublicKey: signing.publicX963, crypto: ["bitcoin"], currencies: [], metals: [], pricesEnabled: true, fxEnabled: false, metalsEnabled: false, coinGeckoKey: "")
        let offline: [Error] = [URLError(.notConnectedToInternet), URLError(.networkConnectionLost), CancellationError()]
        for error in offline {
            let ok = await BackgroundRefresh.scheduled("crypto", configuration: config, root: root, schedule: schedule) { throw error }
            #expect(!ok)
            #expect(await !schedule.failed(vaultID: config.vaultID, root: root, source: "crypto"))
        }
        let ok = await BackgroundRefresh.scheduled("crypto", configuration: config, root: root, schedule: schedule) { throw PriceError.unavailable }
        let failedAt = Date()
        #expect(!ok)
        #expect(await schedule.failed(vaultID: config.vaultID, root: root, source: "crypto"))
        #expect(try await !schedule.claim(vaultID: config.vaultID, root: root, source: "crypto", now: failedAt.addingTimeInterval(240)))
        #expect(try await schedule.claim(vaultID: config.vaultID, root: root, source: "crypto", now: failedAt.addingTimeInterval(301)))
        try await schedule.finish(vaultID: config.vaultID, root: root, failed: true, source: "crypto", now: failedAt.addingTimeInterval(302))
        #expect(try await !schedule.claim(vaultID: config.vaultID, root: root, source: "crypto", now: failedAt.addingTimeInterval(302 + 590)))
        #expect(try await schedule.claim(vaultID: config.vaultID, root: root, source: "crypto", now: failedAt.addingTimeInterval(302 + 601)))
        // Current rates stop at the first connectivity error instead of recording an issue per currency.
        await #expect(throws: URLError.self) {
            try await PublicPrices.fx(currencies: ["EUR", "GBP"]) { _ in throw URLError(.notConnectedToInternet) }
        }
    }

    @Test("Offline dated-rate requests stop at once and leave no cooldown; real failures still back off")
    func offlinePerformanceFX() async throws {
        var doc = emptyDocument()
        doc.settings.automaticFX = true
        let now = try ImportDateFormat.iso.date("2026-09-06"), month = MonthKey("2026-08")!
        let offline = try await PublicPrices.performanceFX(document: doc, now: now, month: month, currencies: ["EUR", "GBP"], retry: true) { _ in throw URLError(.notConnectedToInternet) }
        #expect(offline.coverage.isEmpty && offline.rates.isEmpty && offline.fxIssues.count == 1)
        let failing = try await PublicPrices.performanceFX(document: doc, now: now, month: month, currencies: ["EUR", "GBP"], retry: true) { _ in throw PriceError.unavailable }
        #expect(failing.coverage.count == 2 && failing.coverage.allSatisfy { !$0.complete })
    }
    @Test("Large encrypted vault opens and publishes its dashboard with synthetic authentication")
    @MainActor func largeVaultUnlock() async throws {
        let h = harness()
        let opened = try await h.store.create(recovery: h.recovery, confirmation: h.recovery.canonical)
        var doc = opened.document
        doc.settings.setupComplete = true
        let now = Date(timeIntervalSince1970: 1788600000.123)
        doc.fx = (0..<18000).map { index in
            let date = now.addingTimeInterval(-Double(index) * 3600)
            return FXObservation(sourceCurrency: "EUR", targetCurrency: "USD", rate: PreciseDecimal(1), providerTime: date, fetchedAt: date, provider: "Synthetic benchmark")
        }
        var month = MonthKey.current()
        for _ in 0..<72 {
            for index in 0..<20 {
                doc.entries.append(Entry(month: month, kind: index.isMultiple(of: 2) ? .income : .expense, amount: 10, currency: "EUR", label: "Synthetic entry"))
            }
            month = month.previous
        }
        doc.generation += 1
        try await h.store.commit(doc, expectedGeneration: opened.document.generation, sessionID: opened.sessionID)
        h.store.lock()
        let session = UpOnlySession(testing: h.store, layout: h.layout)
        let started = Date()
        await session.unlock()
        let elapsed = Date().timeIntervalSince(started)
        #expect(session.state == .unlocked)
        #expect(session.document?.fx.count == 18000)
        #expect(session.monthModel?.history.count == 72)
        #expect(session.document?.entries.count == 1440)
        let modelStarted = Date()
        let model = PopoverModel()
        model.replace(with: try #require(session.document))
        let modelElapsed = Date().timeIntervalSince(modelStarted)
        let bytes = try h.io.data(at: h.layout.current).count
        let evidence: [String: Any] = ["model_only_seconds": modelElapsed, "unlock_and_publish_seconds": elapsed, "encrypted_bytes": bytes, "fx_observations": 18000, "entries": 1440]
        try JSONSerialization.data(withJSONObject: evidence, options: .sortedKeys).write(to: FileManager.default.temporaryDirectory.appendingPathComponent("uponly-large-unlock.json"), options: .atomic)
        session.lock()
        #expect(session.document == nil && session.monthModel == nil)
    }

    @Test("Fast vault timestamps retain legacy dates, bytes and malformed-input rejection")
    func timestampCompatibility() async throws {
        let examples = ["2026-09-07T00:00:00.123Z", "1970-01-01T00:00:00.000Z", "1969-12-31T23:59:59.999Z", "2000-02-29T12:34:56.001Z", "1900-01-01T00:00:00.100Z", "9999-12-31T23:59:59.999Z", "2026-09-07T00:00:00Z", "2026-09-07T00:00:00.123456Z", "2026-09-07T03:00:00.123+03:00"]
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    let fallback = ISO8601DateFormatter()
                    fallback.formatOptions = [.withInternetDateTime]
                    for text in examples {
                        let expected = try #require(formatter.date(from: text) ?? fallback.date(from: text))
                        let bytes = try JSONEncoder().encode([text])
                        let dates = try VaultJSON.decode([Date].self, from: bytes)
                        #expect(dates == [expected])
                        let encoded = try VaultJSON.encode(dates)
                        let strings = try JSONDecoder().decode([String].self, from: encoded)
                        #expect(strings == [formatter.string(from: expected)])
                    }
                }
            }
            try await group.waitForAll()
        }
        for invalid in ["not a timestamp", "2026-09-07T00:00:00.xyzZ", "2026-09-07"] {
            let bytes = try JSONEncoder().encode([invalid])
            #expect(throws: DecodingError.self) { try VaultJSON.decode([Date].self, from: bytes) }
        }
    }

    // MARK: A vault missing its main file

    @Test("A vault missing only its main file is still a vault: setup refuses it, and unlock and recovery open the previous copy")
    func missingMainFileOpensPrevious() async throws {
        let h = harness()
        let created = try await createWithAccount(h.store, h.recovery)
        h.store.lock()
        try h.io.removeItem(at: h.layout.current)
        #expect(h.layout.holdsVault(h.io))
        await #expect(throws: VaultError.alreadyExists) {
            _ = try await h.store.create(recovery: h.recovery, confirmation: h.recovery.canonical)
        }
        let reopened = try await h.store.unlock()
        #expect(reopened.document.vaultID == created.document.vaultID && reopened.document.generation == 1)
        #expect(await h.store.openedPrevious)
        #expect(h.io.stored(h.layout.current) == h.io.stored(h.layout.previous))
        h.store.lock()
        try h.io.removeItem(at: h.layout.current)
        try h.keys.delete(vaultID: created.document.vaultID)
        #expect(try await h.store.recover(h.recovery).document.generation == 1)
        #expect(await h.store.openedPrevious)
    }

    @Test("With only its recovery wrapper left, the folder is still not a new vault")
    func wrapperAloneIsNotNew() async throws {
        let h = harness()
        _ = try await h.store.create(recovery: h.recovery, confirmation: h.recovery.canonical)
        h.store.lock()
        try h.io.removeItem(at: h.layout.current)
        #expect(!h.io.fileExists(at: h.layout.previous) && h.layout.holdsVault(h.io))
        await #expect(throws: VaultError.alreadyExists) {
            _ = try await h.store.create(recovery: h.recovery, confirmation: h.recovery.canonical)
        }
        await #expect(throws: VaultError.notFound) { _ = try await h.store.unlock() }
        #expect(h.io.fileExists(at: h.layout.recovery))
    }

    @Test("The app shows unlock, not setup, while any of the vault's files is left, and setup can't write over them")
    @MainActor func sessionSeesPartialVault() async throws {
        let h = harness()
        _ = try await h.store.create(recovery: h.recovery, confirmation: h.recovery.canonical)
        let wrapper = try #require(h.io.stored(h.layout.recovery))
        h.store.lock()
        try h.io.removeItem(at: h.layout.current)
        let session = UpOnlySession(testing: h.store, layout: h.layout)
        session.returnToUnlock()
        #expect(session.state == .locked)
        await session.create(recovery: .random())
        #expect(session.state == .locked && h.io.stored(h.layout.recovery) == wrapper)
    }

    @Test("A main file this Mac can't read opens the previous copy and is kept beside it")
    func unreadableMainFile() async throws {
        let h = harness()
        _ = try await createWithAccount(h.store, h.recovery)
        let latest = try #require(h.io.stored(h.layout.current))
        h.store.lock()
        h.io.markUnreadable(h.layout.current)
        #expect(try await h.store.unlock().document.generation == 1)
        #expect(await h.store.openedPrevious)
        #expect(h.io.stored(h.layout.root.appendingPathComponent("vault.uponly.damaged")) == latest)
        #expect(h.io.stored(h.layout.current) == h.io.stored(h.layout.previous))
        h.store.lock()
        #expect(try await h.store.unlock().document.generation == 1)
        #expect(await !h.store.openedPrevious)
    }

    @Test("Setup refuses a folder holding anything but an empty Inbox")
    func setupNeedsEmptyFolder() async throws {
        let h = harness()
        let other = h.layout.root.appendingPathComponent("other")
        try h.layout.ensureDirectories(h.io)
        try h.io.write(Data("x".utf8), to: other, sync: true)
        await #expect(throws: VaultError.alreadyExists) {
            _ = try await h.store.create(recovery: h.recovery, confirmation: h.recovery.canonical)
        }
        #expect(h.auth.evaluateCount == 0)
        try h.io.removeItem(at: other)
        #expect(try await h.store.create(recovery: h.recovery, confirmation: h.recovery.canonical).document.generation == 1)
    }

    @Test("Setup checks the folder again after authentication, just before its first write")
    func setupRechecksBeforeWriting() async throws {
        let io = MemoryFileIO(), keys = SetupTestKeyStore(), auth = PromptTestAuthenticator()
        let layout = VaultLayout(root: URL(fileURLWithPath: "/tmp/uponly-recheck-" + UUID().uuidString))
        let store = VaultStore(layout: layout, io: io, keys: keys, authenticator: auth)
        let code = RecoveryCode.random(), other = Data("another vault's wrapper".utf8)
        auth.during = { try? layout.ensureDirectories(io); try? io.write(other, to: layout.recovery, sync: true) }
        await #expect(throws: VaultError.alreadyExists) { _ = try await store.create(recovery: code, confirmation: code.canonical) }
        #expect(io.stored(layout.recovery) == other && !io.fileExists(at: layout.current) && keys.lastStoredID == nil)
    }

    // MARK: Tolerant decoding and newer files

    @Test("A document saved before later fields existed still opens, and a saved document reads back to the same bytes")
    func tolerantDocumentDecoding() throws {
        var document = emptyDocument()
        // A whole second, so the saved timestamp reads back to exactly the same value.
        document.createdAt = Date(timeIntervalSince1970: 1_767_225_600)
        var object = try #require(try JSONSerialization.jsonObject(with: VaultJSON.encode(document)) as? [String: Any])
        for key in ["settings", "importedStatements", "reviewedMonths"] { object.removeValue(forKey: key) }
        let old = try VaultJSON.decode(VaultDocument.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.settings == AppSettings() && old.importedStatements.isEmpty && old.reviewedMonths.isEmpty)
        #expect(old.priceHistoryCoverage == nil && old.purchases == nil && old.pendingHistoryRebuild == nil)
        #expect(old.vaultID == document.vaultID && old.inboxPrivateKeyX963 == document.inboxPrivateKeyX963)
        document.statementArchive = Data([1]); document.priceHistoryCoverage = []; document.businessAccounting = []
        document.backgroundSignerPublicKey = Data([2]); document.backgroundAppliedAt = ["crypto": document.createdAt]
        document.purchases = []; document.transferCounterparties = ["Sample Ltd"]; document.reviewedMonths = ["2026-09"]
        document.pendingHistoryRebuild = PendingHistoryRebuild(from: document.createdAt, cursor: document.createdAt)
        let bytes = try VaultJSON.encode(document)
        #expect(try VaultJSON.encode(VaultJSON.decode(VaultDocument.self, from: bytes)) == bytes)
        // A new stored property has to be read in VaultDocument.init(from:) too, or the next save drops it. Then update this count.
        #expect(Mirror(reflecting: document).children.count == 32)
    }

    @Test("A background configuration saved before the Wise and accounting switches still loads, with both off")
    func tolerantBackgroundConfiguration() throws {
        let signing = VaultCrypto.makeSigningKeyPair()
        let config = BackgroundConfiguration(vaultID: UUID(), inboxPublicKey: Data([4]), signingPrivateKey: signing.privateX963, signingPublicKey: signing.publicX963, crypto: ["bitcoin"], currencies: ["EUR"], metals: [.gold], pricesEnabled: true, fxEnabled: true, metalsEnabled: false, coinGeckoKey: "", wiseEnabled: true, accountingEnabled: true)
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        object.removeValue(forKey: "wiseEnabled"); object.removeValue(forKey: "accountingEnabled")
        var old = try JSONDecoder().decode(BackgroundConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(!old.wiseEnabled && !old.accountingEnabled)
        old.wiseEnabled = true; old.accountingEnabled = true
        #expect(old == config)
    }

    @Test("A main file from a newer version is refused, never replaced by the previous copy", arguments: ["schema", "format"])
    func newerFileIsNotDamage(_ field: String) async throws {
        let h = harness()
        let created = try await createWithAccount(h.store, h.recovery)
        let bytes: Data
        if field == "schema" {
            // Sealed for a schema this build doesn't know, which the header names.
            var newer = created.document
            newer.schema = VaultSchema.document + 1
            newer.generation += 1
            let key = try VaultCrypto.key(from: h.keys.load(vaultID: newer.vaultID, context: nil))
            bytes = try VaultJSON.encode(VaultCrypto.persist(newer, key: key))
        } else {
            bytes = Data(#"{"format":2,"vault":"a shape this build can't read"}"#.utf8)
        }
        try h.io.write(bytes, to: h.layout.current, sync: true)
        h.store.lock()
        await #expect(throws: VaultError.unknownSchema) { _ = try await h.store.unlock() }
        try h.keys.delete(vaultID: created.document.vaultID)
        await #expect(throws: VaultError.unknownSchema) { _ = try await h.store.recover(h.recovery) }
        #expect(h.io.stored(h.layout.current) == bytes)
        #expect(!h.io.fileExists(at: h.layout.root.appendingPathComponent("vault.uponly.damaged")))
    }

    // MARK: Recovery-code changes replace the vault key

    @Test("A new recovery code also replaces the vault key: the old code and wrapper open no file saved since")
    func rotationReplacesKey() async throws {
        let h = harness()
        let created = try await createWithAccount(h.store, h.recovery)
        let oldWrapper = try VaultJSON.decode(RecoveryWrapperFile.self, from: try #require(h.io.stored(h.layout.recovery)))
        let oldKey = try VaultCrypto.key(from: VaultCrypto.unwrapVaultKey(oldWrapper, recovery: h.recovery))
        try await h.store.rotateRecovery(RecoveryCode.random(), sessionID: created.sessionID)
        #expect(!h.io.fileExists(at: h.layout.pendingRecovery))
        #expect(try h.keys.load(vaultID: created.document.vaultID, context: nil) != VaultCrypto.keyData(oldKey))
        func oldKeyOpensNothing() throws {
            for url in [h.layout.current, h.layout.previous] {
                let file = try VaultJSON.decode(PersistedVaultFile.self, from: try #require(h.io.stored(url)))
                #expect(throws: VaultError.wrongKey) { _ = try VaultCrypto.reveal(file, key: oldKey) }
            }
        }
        try oldKeyOpensNothing()
        let rotated = try await h.store.currentSession()
        #expect(rotated.document.generation == created.document.generation + 1 && rotated.document.accounts.count == 1)
        var later = rotated.document
        later.generation += 1
        try await h.store.commit(later, expectedGeneration: rotated.document.generation, sessionID: rotated.sessionID)
        try oldKeyOpensNothing()
        // The Keychain has the new key, so unlocking still needs no code.
        h.store.lock()
        #expect(try await h.store.unlock().document.generation == later.generation)
    }

    @Test("If the Keychain refuses the new key, the change is undone and the old key and code keep working")
    func rotationKeychainFailureRollsBack() async throws {
        let io = MemoryFileIO(), keys = SetupTestKeyStore()
        let layout = VaultLayout(root: URL(fileURLWithPath: "/tmp/uponly-rotation-" + UUID().uuidString))
        let store = VaultStore(layout: layout, io: io, keys: keys, authenticator: FixtureAuthenticator())
        let code = RecoveryCode.random(), next = RecoveryCode.random()
        let created = try await createWithAccount(store, code)
        let original = try #require(io.stored(layout.current)), wrapper = try #require(io.stored(layout.recovery))
        keys.storeError = .keychainUnavailable(-25308)
        await #expect(throws: VaultError.keychainUnavailable(-25308)) { try await store.rotateRecovery(next, sessionID: created.sessionID) }
        keys.storeError = nil
        #expect(io.stored(layout.current) == original && io.stored(layout.recovery) == wrapper)
        #expect(!io.fileExists(at: layout.pendingRecovery))
        // The session still saves under the old key, which the Keychain and the old code still open.
        let still = try await store.currentSession()
        var edit = still.document
        edit.generation += 1
        try await store.commit(edit, expectedGeneration: still.document.generation, sessionID: still.sessionID)
        store.lock()
        #expect(try await store.unlock().document.generation == edit.generation)
        try keys.delete(vaultID: created.document.vaultID)
        store.lock()
        await #expect(throws: VaultError.wrongRecoveryCode) { _ = try await store.recover(next) }
        #expect(try await store.recover(code).document.generation == edit.generation)
    }

    @Test("A code change cut off around its Keychain update is finished or undone at the next open, and each code works until then",
          arguments: ["unlock", "new code", "old code", "before Keychain", "backup"])
    func interruptedRotation(_ path: String) async throws {
        let io = MemoryFileIO(), keys = SetupTestKeyStore()
        let layout = VaultLayout(root: URL(fileURLWithPath: "/tmp/uponly-interrupted-" + UUID().uuidString))
        let store = VaultStore(layout: layout, io: io, keys: keys, authenticator: FixtureAuthenticator())
        let oldCode = RecoveryCode.random(), newCode = RecoveryCode.random()
        let created = try await createWithAccount(store, oldCode)
        let id = created.document.vaultID
        let oldKey = try keys.load(vaultID: id, context: nil)
        // No disk write lands once the new key is in the Keychain, as if the app quit there.
        keys.onStore = { io.failWrite = true }
        try await store.rotateRecovery(newCode, sessionID: created.sessionID)
        keys.onStore = nil; io.failWrite = false
        #expect(io.fileExists(at: layout.pendingRecovery))
        if path == "backup" {
            // Still open: a backup finishes the change first, so it carries the new code's wrapper.
            let package = try await BackupCoordinator.makePackage(store: store, producers: [])
            #expect(!io.fileExists(at: layout.pendingRecovery))
            #expect(BackupCoordinator.opens(package, with: newCode) && !BackupCoordinator.opens(package, with: oldCode))
            return
        }
        store.lock()
        // The Keychain update itself never landed.
        if path == "before Keychain" { try keys.store(vaultID: id, key: oldKey, context: nil) }
        switch path {
        case "new code":
            try keys.delete(vaultID: id)
            #expect(try await store.recover(newCode).document.accounts.count == 1)
        case "old code":
            try keys.delete(vaultID: id)
            #expect(try await store.recover(oldCode).document.accounts.count == 1)
        default:
            #expect(try await store.unlock().document.accounts.count == 1)
        }
        // Settled: nothing waits, and the Keychain, the wrapper and the files agree on one key again.
        #expect(!io.fileExists(at: layout.pendingRecovery))
        let forward = path == "unlock" || path == "new code"
        store.lock()
        #expect(try await store.unlock().document.accounts.count == 1)
        try keys.delete(vaultID: id)
        store.lock()
        await #expect(throws: VaultError.wrongRecoveryCode) { _ = try await store.recover(forward ? oldCode : newCode) }
        #expect(try await store.recover(forward ? newCode : oldCode).document.accounts.count == 1)
    }

    // MARK: Small safety items

    @Test("A bump returns its own new ticket")
    func bumpReturnsTicket() {
        let fence = UnlockFence()
        let ticket = fence.bump()
        #expect(ticket == 1 && ticket == fence.current())
    }

    @Test("An edited schedule file can't crash the back-off")
    func scheduleClampsFailures() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UpOnlyTest-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let schedule = BackgroundRefreshSchedule(), vaultID = UUID(), now = Date(timeIntervalSince1970: 1_767_312_000)
        for failures in [Int.max, Int.min] {
            let record = #"{"vaultID":"\#(vaultID.uuidString)","attemptedAt":"2026-01-01T00:00:00.000Z","failed":true,"failures":\#(failures)}"#
            try Data(record.utf8).write(to: root.appendingPathComponent("Background-crypto.schedule"))
            #expect(try await schedule.claim(vaultID: vaultID, root: root, source: "crypto", now: now))
            try await schedule.finish(vaultID: vaultID, root: root, failed: true, source: "crypto", now: now)
            #expect(await schedule.failed(vaultID: vaultID, root: root, source: "crypto"))
        }
    }

    // MARK: Restoring an earlier backup of the same vault

    /// A vault with one account, backed up under `old`; then a second account and a change to `new`. The backup is an
    /// earlier one of the same vault, under the key the change replaced.
    private func earlierBackup(_ store: VaultStore, old: RecoveryCode, new: RecoveryCode) async throws -> BackupPackage {
        let first = try await createWithAccount(store, old)
        let earlier = try await BackupCoordinator.makePackage(store: store, producers: [])
        var next = first.document
        next.generation += 1
        next.accounts.append(Account(name: "Second bank", currency: "USD"))
        try await store.commit(next, expectedGeneration: first.document.generation, sessionID: first.sessionID)
        try await store.rotateRecovery(new, sessionID: first.sessionID)
        return earlier
    }

    /// Whether the restore's journal and staging copy are both gone from beside the vault folder.
    private func restoreFinished(_ io: VaultFileIO, _ layout: VaultLayout) -> Bool {
        guard let names = try? io.contentsOfDirectory(at: layout.root.deletingLastPathComponent()) else { return false }
        return !io.fileExists(at: layout.restoreJournal) && !names.contains { $0.lastPathComponent.contains(".restore-") }
    }

    @Test("Owner's check: create, replace the code, lock, unlock, export and restore with the new code; the old code opens only the earlier backup")
    @MainActor func recoveryCodeRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UpOnlyTest-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let io = DiskFileIO()
        let layout = VaultLayout(root: root.appendingPathComponent("Vault", isDirectory: true))
        let store = VaultStore(layout: layout, io: io, keys: MemoryKeyStore(), authenticator: FixtureAuthenticator())
        let session = UpOnlySession(testing: store, layout: layout)
        let oldCode = RecoveryCode.random(), newCode = RecoveryCode.random()
        await session.create(recovery: oldCode)
        try await session.mutate { $0.accounts = [Account(name: "Sample bank", currency: "GBP")] }
        // A backup made before the code change.
        let earlier = try await BackupCoordinator.makePackage(store: store, producers: [])
        try await session.mutate { $0.accounts.append(Account(name: "Second bank", currency: "USD")) }
        #expect(await session.replaceRecoveryCode(newCode))
        session.lock()
        #expect(session.state == .locked)
        await session.unlock()
        #expect(session.state == .unlocked && session.document?.accounts.count == 2)
        // Exported, then read back as Restore reads it.
        let backups = root.appendingPathComponent("Backups", isDirectory: true)
        try io.createDirectory(at: backups)
        let exported = backups.appendingPathComponent("Up Only Backup.uponlybackup", isDirectory: true)
        let export = try await BackupCoordinator.makePackage(store: store, producers: [])
        try BackupCoordinator.publish(export, to: exported, io: io)
        let package = try BackupCoordinator.read(from: exported, io: io)
        // Into a fresh folder: the old code doesn't open the new backup and nothing is written; the new code restores it.
        #expect(BackupCoordinator.opens(package, with: newCode) && !BackupCoordinator.opens(package, with: oldCode))
        let fresh = VaultLayout(root: root.appendingPathComponent("Fresh", isDirectory: true).appendingPathComponent("Vault", isDirectory: true))
        let freshSession = UpOnlySession(testing: VaultStore(layout: fresh, io: io, keys: MemoryKeyStore(), authenticator: FixtureAuthenticator()), layout: fresh)
        #expect(await freshSession.restoreBackup(package, recovery: oldCode, confirmed: true) == .failed)
        #expect(!io.fileExists(at: fresh.root))
        #expect(await freshSession.restoreBackup(package, recovery: newCode, confirmed: true) == .restored)
        #expect(freshSession.state == .unlocked && freshSession.document?.accounts.count == 2)
        freshSession.lock()
        // The earlier backup restores over the vault with its own code, not the new one.
        #expect(await session.restoreBackup(earlier, recovery: newCode, confirmed: true) == .failed)
        #expect(session.state == .unlocked && session.document?.accounts.count == 2)
        #expect(await session.restoreBackup(earlier, recovery: oldCode, confirmed: true) == .restored)
        #expect(session.state == .unlocked && session.document?.accounts.count == 1)
        #expect(restoreFinished(io, layout))
        // The Keychain and the files agree, so it unlocks without a code.
        session.lock()
        await session.unlock()
        #expect(session.state == .unlocked && session.document?.accounts.count == 1)
        // The replaced vault is kept beside it, whole, and opens with the code it had.
        let aside = try #require(try io.contentsOfDirectory(at: root).first { $0.lastPathComponent.hasPrefix("Vault (replaced ") })
        let replaced = VaultLayout(root: aside)
        let wrapper = try VaultJSON.decode(RecoveryWrapperFile.self, from: io.data(at: replaced.recovery))
        let file = try VaultJSON.decode(PersistedVaultFile.self, from: io.data(at: replaced.current))
        #expect(try VaultCrypto.reveal(file, key: VaultCrypto.key(from: VaultCrypto.unwrapVaultKey(wrapper, recovery: newCode))).accounts.count == 2)
    }

    @Test("An earlier backup of this vault, from before a recovery-code change, restores over it with its own code")
    func replaceWithEarlierBackup() async throws {
        let io = MemoryFileIO(), keys = SetupTestKeyStore()
        let layout = VaultLayout(root: URL(fileURLWithPath: "/tmp/uponly-earlier-" + UUID().uuidString))
        let store = VaultStore(layout: layout, io: io, keys: keys, authenticator: FixtureAuthenticator())
        let old = RecoveryCode.random(), new = RecoveryCode.random()
        let earlier = try await earlierBackup(store, old: old, new: new)
        let id = earlier.manifest.vaultID, current = try #require(io.stored(layout.current))
        #expect(BackupCoordinator.opens(earlier, with: old) && !BackupCoordinator.opens(earlier, with: new))
        let aside = layout.replacedRoot(at: Date(), io: io)
        let opened = try await store.replace(with: earlier, recovery: old, aside: aside)
        #expect(opened.document.accounts.count == 1 && io.stored(layout.current) == earlier.vault)
        #expect(restoreFinished(io, layout))
        // The Keychain holds the backup's key, so the restored vault unlocks without a code.
        store.lock()
        #expect(try await store.unlock().document.accounts.count == 1)
        // The replaced vault is kept aside, whole, and opens with the code it had.
        #expect(io.stored(VaultLayout(root: aside).current) == current)
        let wrapper = try VaultJSON.decode(RecoveryWrapperFile.self, from: try #require(io.stored(VaultLayout(root: aside).recovery)))
        let file = try VaultJSON.decode(PersistedVaultFile.self, from: current)
        #expect(try VaultCrypto.reveal(file, key: VaultCrypto.key(from: VaultCrypto.unwrapVaultKey(wrapper, recovery: new))).accounts.count == 2)
        // Recovery follows the restored backup's code.
        try keys.delete(vaultID: id)
        store.lock()
        await #expect(throws: VaultError.wrongRecoveryCode) { _ = try await store.recover(new) }
        #expect(try await store.recover(old).document.accounts.count == 1)
    }

    @Test("If the Keychain doesn't take the backup's key, the restore is undone and the vault's own key is kept",
          arguments: ["refused", "reported failed after landing"])
    func replaceKeychainFailureRollsBack(_ failure: String) async throws {
        let io = MemoryFileIO(), keys = SetupTestKeyStore()
        let layout = VaultLayout(root: URL(fileURLWithPath: "/tmp/uponly-earlier-" + UUID().uuidString))
        let store = VaultStore(layout: layout, io: io, keys: keys, authenticator: FixtureAuthenticator())
        let old = RecoveryCode.random(), new = RecoveryCode.random()
        let earlier = try await earlierBackup(store, old: old, new: new)
        let id = earlier.manifest.vaultID, original = try #require(io.stored(layout.current))
        let key = try keys.load(vaultID: id, context: nil)
        if failure == "refused" { keys.storeError = .keychainUnavailable(-25308) } else { keys.failAfterStore = .keychainUnavailable(-25308) }
        let aside = layout.replacedRoot(at: Date(), io: io)
        await #expect(throws: VaultError.keychainUnavailable(-25308)) { _ = try await store.replace(with: earlier, recovery: old, aside: aside) }
        keys.storeError = nil; keys.failAfterStore = nil
        #expect(try keys.load(vaultID: id, context: nil) == key)
        #expect(!io.fileExists(at: aside) && io.stored(layout.current) == original)
        #expect(restoreFinished(io, layout))
        #expect(await !store.isUnlocked)
        #expect(try await store.unlock().document.accounts.count == 2)
    }

    @Test("A restore cut off anywhere is finished or undone at the next unlock, and the Keychain and the files agree",
          arguments: ["before the move", "while staging", "before installing the copy", "at the Keychain update", "after the Keychain update"])
    func interruptedRestore(_ point: String) async throws {
        let io = CrashingFileIO(), keys = SetupTestKeyStore()
        let layout = VaultLayout(root: URL(fileURLWithPath: "/tmp/uponly-crash-" + UUID().uuidString))
        let store = VaultStore(layout: layout, io: io, keys: keys, authenticator: FixtureAuthenticator())
        let old = RecoveryCode.random(), new = RecoveryCode.random()
        let earlier = try await earlierBackup(store, old: old, new: new)
        let aside = layout.replacedRoot(at: Date(), io: io)
        switch point {
        case "before the move": io.crashBefore = { step, url in step == "install" && url.path == aside.path }
        case "while staging": io.crashBefore = { step, url in step == "write" && url.path.contains(".restore-") }
        case "before installing the copy": io.crashBefore = { step, url in step == "install" && url.path == layout.root.path }
        case "at the Keychain update": keys.beforeStore = { io.crashed = true }; keys.storeError = .keychainUnavailable(-25308)
        default: keys.onStore = { io.crashed = true }
        }
        _ = try? await store.replace(with: earlier, recovery: old, aside: aside)
        keys.beforeStore = nil; keys.storeError = nil; keys.onStore = nil
        io.crashBefore = nil; io.crashed = false
        // The relaunched app shows unlock, never setup, and unlocking settles the restore first.
        #expect(layout.holdsVault(io))
        let relaunched = VaultStore(layout: layout, io: io, keys: keys, authenticator: FixtureAuthenticator())
        let committed = point == "after the Keychain update", accounts = committed ? 1 : 2
        #expect(try await relaunched.unlock().document.accounts.count == accounts)
        #expect(restoreFinished(io, layout))
        #expect(io.fileExists(at: aside) == committed)
        // The Keychain opens what's there, and so does the code that goes with it.
        relaunched.lock()
        #expect(try await relaunched.unlock().document.accounts.count == accounts)
        try keys.delete(vaultID: earlier.manifest.vaultID)
        relaunched.lock()
        await #expect(throws: VaultError.wrongRecoveryCode) { _ = try await relaunched.recover(committed ? new : old) }
        #expect(try await relaunched.recover(committed ? old : new).document.accounts.count == accounts)
    }

    @Test("A restore cut off at its Keychain update is settled by whichever code opens a folder, and a wrong code moves nothing",
          arguments: ["backup's", "current", "wrong"])
    func interruptedRestoreRecovery(_ code: String) async throws {
        let io = CrashingFileIO(), keys = SetupTestKeyStore()
        let layout = VaultLayout(root: URL(fileURLWithPath: "/tmp/uponly-crash-" + UUID().uuidString))
        let store = VaultStore(layout: layout, io: io, keys: keys, authenticator: FixtureAuthenticator())
        let old = RecoveryCode.random(), new = RecoveryCode.random()
        let earlier = try await earlierBackup(store, old: old, new: new)
        let aside = layout.replacedRoot(at: Date(), io: io)
        keys.beforeStore = { io.crashed = true }; keys.storeError = .keychainUnavailable(-25308)
        _ = try? await store.replace(with: earlier, recovery: old, aside: aside)
        keys.beforeStore = nil; keys.storeError = nil
        io.crashed = false
        // The backup's copy is in place and the vault aside; Touch ID can't help, so the user recovers with a code.
        #expect(io.stored(layout.current) == earlier.vault && io.fileExists(at: aside) && io.fileExists(at: layout.restoreJournal))
        try keys.delete(vaultID: earlier.manifest.vaultID)
        let relaunched = VaultStore(layout: layout, io: io, keys: keys, authenticator: FixtureAuthenticator())
        switch code {
        case "backup's":
            #expect(try await relaunched.recover(old).document.accounts.count == 1)
            #expect(io.fileExists(at: aside))
        case "current":
            #expect(try await relaunched.recover(new).document.accounts.count == 2)
            #expect(!io.fileExists(at: aside))
        default:
            await #expect(throws: VaultError.wrongRecoveryCode) { _ = try await relaunched.recover(.random()) }
            #expect(io.stored(layout.current) == earlier.vault && io.fileExists(at: aside) && io.fileExists(at: layout.restoreJournal))
            return
        }
        #expect(!io.fileExists(at: layout.restoreJournal))
        // Recovery saved the key it opened with, so the Keychain agrees with what's there.
        relaunched.lock()
        #expect(try await relaunched.unlock().document.accounts.count == (code == "backup's" ? 1 : 2))
    }

    // MARK: Start over after an unfinished setup

    @Test("Unlock offers Start over when setup left only its recovery wrapper, which is moved aside under a numbered name")
    @MainActor func sessionStartsOver() async throws {
        let io = CrashingFileIO(), keys = SetupTestKeyStore()
        let layout = VaultLayout(root: URL(fileURLWithPath: "/tmp/uponly-unfinished-" + UUID().uuidString))
        let store = VaultStore(layout: layout, io: io, keys: keys, authenticator: FixtureAuthenticator())
        let code = RecoveryCode.random()
        // Setup stops between saving the wrapper and the vault.
        io.crashBefore = { step, url in step == "write" && url.path == layout.current.appendingPathExtension("tmp").path }
        await #expect(throws: VaultError.diskWriteFailed) { _ = try await store.create(recovery: code, confirmation: code.canonical) }
        io.crashBefore = nil; io.crashed = false
        let wrapper = try #require(io.stored(layout.recovery))
        #expect(!io.fileExists(at: layout.current) && layout.holdsVault(io) && layout.holdsOnlyWrapper(io))
        // One set aside before keeps its name and contents.
        let first = layout.unusedWrapper(io)
        #expect(first.lastPathComponent == layout.root.lastPathComponent + " recovery.wrapper.unused")
        try io.disk.write(Data("earlier".utf8), to: first, sync: true)
        let session = UpOnlySession(testing: store, layout: layout)
        session.returnToUnlock()
        #expect(session.state == .locked && !session.canStartOver)
        await session.unlock()
        #expect(session.canStartOver && session.message == nil)
        await session.startOver()
        #expect(session.state == .newVault && !session.canStartOver && session.message == nil)
        let moved = first.deletingLastPathComponent().appendingPathComponent(first.lastPathComponent + " 2")
        #expect(io.stored(moved) == wrapper && io.stored(first) == Data("earlier".utf8) && !io.fileExists(at: layout.recovery))
        // Setup runs again in the same folder.
        await session.create(recovery: .random())
        #expect(session.state == .unlocked)
    }

    @Test("Start over is refused, moving nothing, while the folder holds any vault data",
          arguments: ["previous", "damaged", "half-written vault", "waiting wrapper", "pending import", "restore journal"])
    func startOverNeedsOnlyWrapper(_ extra: String) async throws {
        let h = harness()
        try h.layout.ensureDirectories(h.io)
        let wrapper = Data("wrapper".utf8)
        try h.io.write(wrapper, to: h.layout.recovery, sync: true)
        // Finder's file and a half-written wrapper aren't vault data.
        try h.io.write(Data(), to: h.layout.root.appendingPathComponent(".DS_Store"), sync: true)
        try h.io.write(Data(), to: h.layout.root.appendingPathComponent(".recovery.wrapper." + UUID().uuidString), sync: true)
        #expect(h.layout.holdsOnlyWrapper(h.io))
        let url: URL = switch extra {
        case "previous": h.layout.previous
        case "damaged": h.layout.root.appendingPathComponent("vault.uponly.damaged")
        case "half-written vault": h.layout.root.appendingPathComponent(".vault.uponly.tmp." + UUID().uuidString)
        case "waiting wrapper": h.layout.pendingRecovery
        case "pending import": h.layout.inbox.appendingPathComponent("batch")
        default: h.layout.restoreJournal
        }
        try h.io.write(Data("x".utf8), to: url, sync: true)
        #expect(!h.layout.holdsOnlyWrapper(h.io))
        await #expect(throws: VaultError.alreadyExists) { _ = try await h.store.startOver() }
        #expect(h.io.stored(h.layout.recovery) == wrapper && h.io.stored(url) == Data("x".utf8))
    }

    // MARK: A vault from a newer version

    @Test("A vault saved by a newer version says so on unlock and on recovery, and its files are left as they are")
    @MainActor func sessionNewerVault() async throws {
        let h = harness()
        let created = try await createWithAccount(h.store, h.recovery)
        var newer = created.document
        newer.schema = VaultSchema.document + 1
        newer.generation += 1
        let key = try VaultCrypto.key(from: h.keys.load(vaultID: newer.vaultID, context: nil))
        let bytes = try VaultJSON.encode(VaultCrypto.persist(newer, key: key))
        try h.io.write(bytes, to: h.layout.current, sync: true)
        let previous = h.io.stored(h.layout.previous)
        h.store.lock()
        let session = UpOnlySession(testing: h.store, layout: h.layout)
        session.returnToUnlock()
        await session.unlock()
        #expect(session.state == .locked && session.message == "This vault was saved by a newer version of Up Only. Update the app to open it.")
        await session.recover(code: h.recovery.canonical)
        #expect(session.state == .locked && session.message == UpOnlySession.newerVersionNotice)
        #expect(h.io.stored(h.layout.current) == bytes && h.io.stored(h.layout.previous) == previous)
        #expect(!h.io.fileExists(at: h.layout.root.appendingPathComponent("vault.uponly.damaged")))
    }

    @Test("A backup from a newer version says so, and the open vault stays as it was")
    @MainActor func sessionNewerBackup() async throws {
        var backup = try await otherBackup()
        backup.package.manifest.format += 1
        let h = harness()
        _ = try await createWithAccount(h.store, h.recovery)
        h.store.lock()
        let session = UpOnlySession(testing: h.store, layout: h.layout)
        await session.unlock()
        let vaultID = session.document?.vaultID
        #expect(await session.restoreBackup(backup.package, recovery: backup.code, confirmed: true) == .failed)
        #expect(session.message == "This backup was saved by a newer version of Up Only. Update the app to restore it.")
        #expect(session.state == .unlocked && session.document?.vaultID == vaultID)
    }

    // MARK: The background configuration's Keychain move

    @Test("The background configuration moves from the login keychain once, deleting the old item only after the new one is saved")
    func backgroundConfigurationMigration() throws {
        let signing = VaultCrypto.makeSigningKeyPair()
        let config = BackgroundConfiguration(vaultID: UUID(), inboxPublicKey: Data([4]), signingPrivateKey: signing.privateX963, signingPublicKey: signing.publicX963, crypto: ["bitcoin"], currencies: ["EUR"], metals: [.gold], pricesEnabled: true, fxEnabled: true, metalsEnabled: false, coinGeckoKey: "")
        let saved = try JSONEncoder().encode(config)
        let keychain = MemoryBackgroundStore()
        #expect(try BackgroundConfiguration.load(from: keychain) == nil)
        keychain.legacy = saved
        // A move that fails leaves the old item in place, and it still loads.
        keychain.saveFails = true
        #expect(try BackgroundConfiguration.load(from: keychain) == config)
        #expect(keychain.legacy == saved && keychain.current == nil && keychain.changes == ["save"])
        // The next load moves it: saved first, and only then the old item deleted.
        keychain.saveFails = false
        #expect(try BackgroundConfiguration.load(from: keychain) == config)
        #expect(keychain.current == saved && keychain.legacy == nil && keychain.changes == ["save", "save", "delete old"])
        // Once moved, loading changes nothing, even if an earlier build saves an old item again.
        keychain.legacy = saved
        #expect(try BackgroundConfiguration.load(from: keychain) == config)
        #expect(keychain.changes.count == 3 && keychain.legacy == saved)
        // An item that can't be read now is never taken for none: nothing is saved or deleted.
        keychain.unreadable = [false]
        #expect(throws: VaultError.unavailable) { _ = try BackgroundConfiguration.load(from: keychain) }
        keychain.current = nil; keychain.unreadable = [true]
        #expect(throws: VaultError.unavailable) { _ = try BackgroundConfiguration.load(from: keychain) }
        #expect(keychain.changes.count == 3 && keychain.legacy == saved)
        // Saving writes the new item only.
        try config.save(to: keychain)
        #expect(keychain.changes == ["save", "save", "delete old", "save"] && keychain.legacy == saved)
    }

    @Test("The background configuration is kept on this Mac only and readable after its first unlock; the old item is the login keychain's")
    func backgroundConfigurationItems() {
        let keychain = BackgroundKeychain(), add = keychain.addition(Data([1]))
        #expect(add[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(add[kSecUseDataProtectionKeychain as String] as? Bool == true && add[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(keychain.legacyItem[kSecUseDataProtectionKeychain as String] as? Bool == false)
        for item in [add, keychain.legacyItem] {
            #expect(item[kSecAttrService as String] as? String == BackgroundConfiguration.service)
            #expect(item[kSecAttrAccount as String] as? String == "sources")
        }
        #expect(BackgroundConfiguration.service == (Bundle.main.bundleIdentifier ?? "org.uponly") + ".background")
    }
}
