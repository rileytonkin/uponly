import Foundation
import Testing
@testable import UpOnly

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

    @Test("Coherent backup restores signers and pending envelopes")
    func backupRestorePreservesTrust() async throws {
        let h = harness()
        var session = try await h.store.create(recovery: h.recovery, confirmation: h.recovery.canonical)
        let signing = VaultCrypto.makeSigningKeyPair()
        var next = session.document
        next.generation += 1
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
        let pending = Data("pending-envelope".utf8)
        try await h.store.writeInbox(pending, name: "batch-1.uponlyenv")
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
        #expect(restored.pending.contains { $0.name == "batch-1.uponlyenv" && $0.bytes == pending })
        #expect(freshKeys.contains(vaultID: restored.document.vaultID))
    }
}
