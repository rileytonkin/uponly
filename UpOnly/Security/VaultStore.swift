import CryptoKit
import Foundation

actor VaultStore {
    let layout: VaultLayout
    let io: VaultFileIO
    let keys: VaultKeyStoring
    let authenticator: VaultAuthenticating
    let fence: UnlockFence

    private var session: VaultSession?
    private var key: SymmetricKey?
    private var fileLock: AdvisoryLock?
    /// Set when the last unlock or recovery found the current file damaged and reopened the previous generation.
    private(set) var openedPrevious = false

    init(
        layout: VaultLayout,
        io: VaultFileIO,
        keys: VaultKeyStoring,
        authenticator: VaultAuthenticating,
        fence: UnlockFence = UnlockFence()
    ) {
        self.layout = layout
        self.io = io
        self.keys = keys
        self.authenticator = authenticator
        self.fence = fence
    }

    deinit {
        fileLock?.release()
    }

    var isUnlocked: Bool {
        guard let session else { return false }
        return fence.current() == session.fenceTicket
    }

    nonisolated func lock() {
        fence.bump()
        authenticator.invalidate()
        Task { await discardInvalidatedSession() }
    }

    private func discardInvalidatedSession() {
        guard let session, fence.current() != session.fenceTicket else { return }
        self.session = nil
        self.key = nil
    }

    func currentSession() throws -> VaultSession {
        guard let session, let _ = key else { throw VaultError.locked }
        guard fence.current() == session.fenceTicket else { throw VaultError.locked }
        return session
    }

    func create(recovery: RecoveryCode, confirmation: String) async throws -> VaultSession {
        guard recovery.matches(confirmation) else { throw VaultError.confirmationMismatch }
        try acquireProcessLock()
        if io.fileExists(at: layout.current) { throw VaultError.alreadyExists }
        let ticket = fence.current()
        try await authenticator.evaluate()
        guard fence.current() == ticket else { throw VaultError.locked }
        try layout.ensureDirectories(io)
        let inbox = VaultCrypto.makeInboxKeyPair()
        let document = VaultDocument.empty(
            inboxPrivateKeyX963: inbox.privateX963,
            inboxPublicKeyX963: inbox.publicX963
        )
        let vaultKey = VaultCrypto.randomKey()
        let wrapper = try VaultCrypto.wrapVaultKey(
            VaultCrypto.keyData(vaultKey),
            recovery: recovery,
            vaultID: document.vaultID
        )
        let persisted = try VaultCrypto.persist(document, key: vaultKey)
        let payload = try VaultJSON.encode(persisted)
        guard payload.count <= VaultLimits.maxVaultFileBytes else { throw VaultError.oversizedVault }
        let recoveryBytes = try VaultJSON.encode(wrapper)
        let opened: VaultSession = try fence.publish(ticket) {
            try keys.store(
                vaultID: document.vaultID,
                key: VaultCrypto.keyData(vaultKey),
                context: authenticator.keychainContext
            )
            do {
                try writeRecoveryBytes(recoveryBytes)
                try writeFirstPayload(payload)
            } catch {
                // A failed first save must not strand a vault without its key.
                // If publication succeeded before a durability error, retain
                // both recovery paths so the existing file stays readable.
                if !io.fileExists(at: layout.current) {
                    try? io.removeItem(at: layout.recovery)
                    try? keys.delete(vaultID: document.vaultID)
                }
                throw error
            }
            let session = VaultSession(sessionID: UUID(), document: document, fenceTicket: ticket)
            self.session = session
            self.key = vaultKey
            return session
        }
        return opened
    }

    func unlock(timing: UnlockTiming? = nil) async throws -> VaultSession {
        let ticket = fence.current()
        try await authenticator.evaluate()
        timing?.mark("authenticated", at: authenticator.successfulAuthenticationUptime ?? ProcessInfo.processInfo.systemUptime)
        guard fence.current() == ticket else { throw VaultError.locked }
        try acquireProcessLock()
        try layout.ensureDirectories(io)
        guard io.fileExists(at: layout.current) else { throw VaultError.notFound }
        let (document, vaultKey) = try openNewest { vaultID in
            let keyData = try keys.load(vaultID: vaultID, context: authenticator.keychainContext)
            timing?.mark("key_loaded")
            return try VaultCrypto.key(from: keyData)
        }
        timing?.mark("vault_opened")
        return try fence.publish(ticket) {
            let opened = VaultSession(sessionID: UUID(), document: document, fenceTicket: ticket)
            self.session = opened
            self.key = vaultKey
            return opened
        }
    }

    func recover(_ recovery: RecoveryCode) async throws -> VaultSession {
        let ticket = fence.current()
        try await authenticator.evaluate()
        guard fence.current() == ticket else { throw VaultError.locked }
        try acquireProcessLock()
        try layout.ensureDirectories(io)
        guard io.fileExists(at: layout.current) else { throw VaultError.notFound }
        guard io.fileExists(at: layout.recovery) else { throw VaultError.missingRecoveryWrapper }
        let wrapper = try VaultJSON.decode(RecoveryWrapperFile.self, from: try io.data(at: layout.recovery))
        let keyData: Data
        do {
            keyData = try VaultCrypto.unwrapVaultKey(wrapper, recovery: recovery)
        } catch {
            throw VaultError.wrongRecoveryCode
        }
        let recovered = try VaultCrypto.key(from: keyData)
        let (document, vaultKey) = try openNewest { vaultID in
            guard vaultID == wrapper.vaultID else { throw VaultError.corrupt }
            return recovered
        }
        return try fence.publish(ticket) {
            try keys.store(vaultID: document.vaultID, key: keyData, context: authenticator.keychainContext)
            let opened = VaultSession(sessionID: UUID(), document: document, fenceTicket: ticket)
            self.session = opened
            self.key = vaultKey
            return opened
        }
    }

    func commit(_ next: VaultDocument, expectedGeneration: UInt64, sessionID: UUID) throws {
        guard let session, let key else { throw VaultError.locked }
        guard session.sessionID == sessionID else { throw VaultError.staleSession }
        guard fence.current() == session.fenceTicket else { throw VaultError.locked }
        guard session.document.generation == expectedGeneration else { throw VaultError.staleGeneration }
        guard next.generation == expectedGeneration + 1 else { throw VaultError.invalidGeneration }
        guard next.vaultID == session.document.vaultID else { throw VaultError.corrupt }
        guard next.schema == VaultSchema.document else { throw VaultError.unknownSchema }
        let persisted = try VaultCrypto.persist(next, key: key)
        let payload = try VaultJSON.encode(persisted)
        guard payload.count <= VaultLimits.maxVaultFileBytes else { throw VaultError.oversizedVault }
        let temp = layout.current.appendingPathExtension("tmp")
        do {
            try io.write(payload, to: temp, sync: true)
        } catch {
            try? io.removeItem(at: temp)
            throw VaultError.diskWriteFailed
        }
        do {
            try fence.publish(session.fenceTicket) {
                guard self.session?.sessionID == sessionID else { throw VaultError.staleSession }
                guard self.session?.document.generation == expectedGeneration else {
                    throw VaultError.staleGeneration
                }
                if io.fileExists(at: layout.current) {
                    try io.preserveVerifiedCopy(from: layout.current, to: layout.previous)
                }
                try io.replaceItem(at: layout.current, withItemAt: temp)
                self.session = VaultSession(
                    sessionID: sessionID,
                    document: next,
                    fenceTicket: session.fenceTicket
                )
            }
        } catch {
            try? io.removeItem(at: temp)
            if error is VaultError { throw error }
            throw VaultError.diskWriteFailed
        }
    }

    /// Wraps the vault key with a new recovery code once the user confirms with Touch ID or the Mac password, and
    /// replaces the wrapper. The old wrapper isn't kept, so the old code stops opening this vault; if the write fails
    /// it stays in place and the old code keeps working. The vault key itself doesn't change.
    func rotateRecovery(_ recovery: RecoveryCode, sessionID: UUID) async throws {
        guard let session, key != nil, session.sessionID == sessionID, fence.current() == session.fenceTicket else {
            throw VaultError.locked
        }
        let ticket = session.fenceTicket
        try await authenticator.evaluate()
        // The vault may have locked while the prompt was up.
        guard let current = self.session, let key, current.sessionID == sessionID, fence.current() == ticket else {
            throw VaultError.locked
        }
        let wrapper = try VaultCrypto.wrapVaultKey(VaultCrypto.keyData(key), recovery: recovery, vaultID: current.document.vaultID)
        let bytes = try VaultJSON.encode(wrapper)
        let temp = layout.recovery.appendingPathExtension("tmp")
        do {
            try io.write(bytes, to: temp, sync: true)
            try fence.publish(ticket) {
                guard self.session?.sessionID == sessionID else { throw VaultError.staleSession }
                try io.replaceItem(at: layout.recovery, withItemAt: temp)
            }
        } catch {
            try? io.removeItem(at: temp)
            if error is VaultError { throw error }
            throw VaultError.diskWriteFailed
        }
    }

    // Runs on the actor, so no commit can interleave with the capture.
    func captureBackupPackage() throws -> BackupPackage {
        guard io.fileExists(at: layout.current), io.fileExists(at: layout.recovery) else {
            throw VaultError.notFound
        }
        let vault = try io.data(at: layout.current)
        let recovery = try io.data(at: layout.recovery)
        let previous = io.fileExists(at: layout.previous) ? try io.data(at: layout.previous) : nil
        let persisted = try VaultJSON.decode(PersistedVaultFile.self, from: vault)
        let pendingURLs = try io.contentsOfDirectory(at: layout.inbox)
        let names = try SafeFileName.requireUnique(pendingURLs.map(\.lastPathComponent))
        let pending = try zip(pendingURLs, names).map { url, name in
            (name: name, bytes: try io.data(at: url))
        }
        var files = [
            BackupFile(name: "vault.uponly", sha256: VaultCrypto.sha256(vault)),
            BackupFile(name: "recovery.wrapper", sha256: VaultCrypto.sha256(recovery)),
        ]
        if let previous {
            files.append(BackupFile(name: "vault.uponly.prev", sha256: VaultCrypto.sha256(previous)))
        }
        for item in pending {
            files.append(BackupFile(name: "inbox/\(item.name)", sha256: VaultCrypto.sha256(item.bytes)))
        }
        return BackupPackage(
            manifest: BackupManifest(
                format: VaultSchema.backupPackage,
                vaultID: persisted.vaultID,
                generation: persisted.generation,
                files: files
            ),
            vault: vault,
            previous: previous,
            recovery: recovery,
            pending: pending
        )
    }

    func releaseEmptyDestination() throws {
        guard !io.fileExists(at: layout.current), session == nil else { throw VaultError.alreadyExists }
        if io.fileExists(at: layout.root) {
            // A setup that failed after creating the folders leaves an empty Inbox; that is still an empty vault.
            let children = try io.contentsOfDirectory(at: layout.root).filter {
                $0.lastPathComponent != layout.inbox.lastPathComponent || !((try? io.contentsOfDirectory(at: layout.inbox))?.isEmpty ?? false)
            }
            guard children.isEmpty else { throw VaultError.alreadyExists }
            try io.removeItem(at: layout.root)
        }
        fileLock?.release(); fileLock = nil
    }

    /// Replaces this unlocked vault with a verified backup and opens it; the caller has just authenticated the user, so
    /// the backup's key is saved to the Keychain with that authentication. The vault's folder is moved to `aside`, never
    /// deleted. A refused backup or code throws before anything changes. After that the session is closed, and any
    /// failure removes the restored copy, puts the original folder back and leaves the vault locked.
    func replace(with package: BackupPackage, recovery: RecoveryCode, aside: URL) throws -> VaultSession {
        guard let current = session, let currentKey = key, fence.current() == current.fenceTicket else { throw VaultError.locked }
        try BackupCoordinator.verifyPackage(package)
        let wrapper = try VaultJSON.decode(RecoveryWrapperFile.self, from: package.recovery)
        let restoredKey = try VaultCrypto.key(from: VaultCrypto.unwrapVaultKey(wrapper, recovery: recovery))
        // A backup of this same vault carries this vault's key. One that doesn't would overwrite the key this vault needs.
        if wrapper.vaultID == current.document.vaultID, VaultCrypto.keyData(restoredKey) != VaultCrypto.keyData(currentKey) {
            throw VaultError.backupIncoherent
        }
        guard !io.fileExists(at: aside) else { throw VaultError.alreadyExists }
        // Nothing the replaced session prepared may be saved from here, whether the backup opens or the original goes back.
        // The authenticator stays valid: the restore's Keychain write needs it.
        fence.bump()
        let ticket = fence.current()
        session = nil; key = nil
        do {
            try acquireProcessLock()
            try io.installItem(at: aside, from: layout.root)
            // The restore takes the process lock itself.
            fileLock?.release(); fileLock = nil
            let restored = try BackupCoordinator.restore(
                package: package, recovery: recovery, keys: keys, layout: layout, io: io, authenticator: authenticator
            )
            try acquireProcessLock()
            return try fence.publish(ticket) {
                let opened = VaultSession(sessionID: UUID(), document: restored.document, fenceTicket: ticket)
                self.session = opened
                self.key = restoredKey
                self.openedPrevious = false
                return opened
            }
        } catch {
            session = nil; key = nil
            if io.fileExists(at: aside) { try putBack(from: aside) }
            throw error
        }
    }

    /// Puts back the folder `replace` moved aside. Whatever a failed restore left in its place is only a copy of the backup.
    private func putBack(from aside: URL) throws {
        try? acquireProcessLock()
        if io.fileExists(at: layout.root) { try io.removeItem(at: layout.root) }
        try io.installItem(at: layout.root, from: aside)
    }

    private func acquireProcessLock() throws {
        if fileLock != nil { return }
        if !io.fileExists(at: layout.root.deletingLastPathComponent()) {
            try io.createDirectory(at: layout.root.deletingLastPathComponent())
        }
        fileLock = try io.acquireExclusiveLock(at: layout.lockFile)
    }

    /// Opens the current file. If it is damaged (rather than written by a newer version), the previous generation
    /// is opened instead and saved back as current, and `openedPrevious` lets the caller tell the user.
    private func openNewest(key: (UUID) throws -> SymmetricKey) throws -> (document: VaultDocument, key: SymmetricKey) {
        openedPrevious = false
        var vaultID: UUID?, vaultKey: SymmetricKey?
        do {
            let persisted = try readPersisted(layout.current)
            vaultID = persisted.vaultID
            let currentKey = try key(persisted.vaultID)
            vaultKey = currentKey
            do { return (try VaultCrypto.reveal(persisted, key: currentKey), currentKey) }
            catch VaultError.unknownSchema { throw VaultError.unknownSchema }
            catch { throw VaultError.corrupt }
        } catch VaultError.corrupt {
            guard let bytes = try? io.data(at: layout.previous),
                  let persisted = try? VaultJSON.decode(PersistedVaultFile.self, from: bytes),
                  persisted.format == VaultSchema.persistedFile, vaultID == nil || persisted.vaultID == vaultID else { throw VaultError.corrupt }
            let previousKey = try vaultKey ?? key(persisted.vaultID)
            guard let document = try? VaultCrypto.reveal(persisted, key: previousKey) else { throw VaultError.corrupt }
            let temp = layout.current.appendingPathExtension("tmp")
            // Keep the damaged file beside the vault rather than discarding it.
            if let damaged = try? io.data(at: layout.current) { try? io.write(damaged, to: layout.current.appendingPathExtension("damaged"), sync: true) }
            do {
                try io.write(bytes, to: temp, sync: true)
                try io.replaceItem(at: layout.current, withItemAt: temp)
            } catch {
                try? io.removeItem(at: temp)
                throw VaultError.diskWriteFailed
            }
            openedPrevious = true
            return (document, previousKey)
        }
    }

    private func readPersisted(_ url: URL) throws -> PersistedVaultFile {
        let data: Data
        do {
            data = try io.data(at: url)
        } catch {
            throw VaultError.notFound
        }
        do {
            let file = try VaultJSON.decode(PersistedVaultFile.self, from: data)
            guard file.format == VaultSchema.persistedFile else { throw VaultError.unknownSchema }
            return file
        } catch let error as VaultError {
            throw error
        } catch {
            throw VaultError.corrupt
        }
    }

    private func writeRecoveryBytes(_ bytes: Data) throws {
        try io.write(bytes, to: layout.recovery, sync: true)
    }

    private func writeFirstPayload(_ payload: Data) throws {
        let temp = layout.current.appendingPathExtension("tmp")
        do {
            try io.write(payload, to: temp, sync: true)
            try io.installItem(at: layout.current, from: temp)
        } catch {
            try? io.removeItem(at: temp)
            throw VaultError.diskWriteFailed
        }
    }
}
