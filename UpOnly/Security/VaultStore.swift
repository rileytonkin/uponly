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
    /// Set when the last unlock or recovery found the current file missing, unreadable or damaged and reopened the previous generation.
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
        guard try isEmptyDestination() else { throw VaultError.alreadyExists }
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
            // Checked again just before the first write: setup never writes into a folder that holds anything.
            guard try isEmptyDestination() else { throw VaultError.alreadyExists }
            try keys.store(
                vaultID: document.vaultID,
                key: VaultCrypto.keyData(vaultKey),
                context: authenticator.keychainContext
            )
            var wroteRecovery = false
            do {
                try writeRecoveryBytes(recoveryBytes)
                wroteRecovery = true
                try writeFirstPayload(payload)
            } catch {
                // A failed first save must not strand a vault without its key.
                // If publication succeeded before a durability error, retain
                // both recovery paths so the existing file stays readable.
                if !io.fileExists(at: layout.current) {
                    if wroteRecovery { try? io.removeItem(at: layout.recovery) }
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
        try settleRestore { copy, _ in
            // The restore reached its commit point if the Keychain's key opens the backup's copy.
            let keyData: Data
            do { keyData = try keys.load(vaultID: copy.vaultID, context: authenticator.keychainContext) }
            catch VaultError.needsRecovery { return false }
            return (try? VaultCrypto.reveal(copy, key: VaultCrypto.key(from: keyData))) != nil
        }
        try layout.ensureDirectories(io)
        guard io.fileExists(at: layout.current) || io.fileExists(at: layout.previous) else { throw VaultError.notFound }
        let (document, vaultKey) = try openNewest { vaultID in
            let keyData = try keys.load(vaultID: vaultID, context: authenticator.keychainContext)
            timing?.mark("key_loaded")
            return try VaultCrypto.key(from: keyData)
        }
        timing?.mark("vault_opened")
        return try fence.publish(ticket) {
            settleRotation(key: vaultKey)
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
        try settleRestore { copy, aside in
            // The backup's copy stands if this code opens it, and the folder aside goes back if the code opens that instead.
            if let keyData = unwrappedKey(in: layout, recovery: recovery),
               (try? VaultCrypto.reveal(copy, key: VaultCrypto.key(from: keyData))) != nil { return true }
            guard unwrappedKey(in: aside, recovery: recovery) != nil else { throw VaultError.wrongRecoveryCode }
            return false
        }
        try layout.ensureDirectories(io)
        guard io.fileExists(at: layout.current) || io.fileExists(at: layout.previous) else { throw VaultError.notFound }
        // While a recovery-code change finishes, the new code's wrapper waits beside the old one; each code opens its own.
        let wrappers = [layout.recovery, layout.pendingRecovery].filter { io.fileExists(at: $0) }
        guard !wrappers.isEmpty else { throw VaultError.missingRecoveryWrapper }
        var found: (wrapper: RecoveryWrapperFile, key: Data)?, failure = VaultError.wrongRecoveryCode
        for url in wrappers where found == nil {
            guard let wrapper = try? VaultJSON.decode(RecoveryWrapperFile.self, from: io.data(at: url)) else { continue }
            do {
                let keyData = try VaultCrypto.unwrapVaultKey(wrapper, recovery: recovery)
                found = (wrapper: wrapper, key: keyData)
            } catch VaultError.unknownSchema { failure = .unknownSchema } catch {}
        }
        guard let match = found else { throw failure }
        let wrapper = match.wrapper, keyData = match.key
        let recovered = try VaultCrypto.key(from: keyData)
        let (document, vaultKey) = try openNewest { vaultID in
            guard vaultID == wrapper.vaultID else { throw VaultError.corrupt }
            return recovered
        }
        return try fence.publish(ticket) {
            try keys.store(vaultID: document.vaultID, key: keyData, context: authenticator.keychainContext)
            settleRotation(key: vaultKey)
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

    /// Replaces the recovery code and the vault key together once the user confirms with Touch ID or the Mac password,
    /// so the old code, with any copy of the old wrapper, opens no file saved from then on. Backups exported earlier keep
    /// the old key and code. In crash-safe order: the new code's wrapper waits beside the old one; the document is saved
    /// under the new key as the next generation, the previous copy keeping the same records under the old key; then the
    /// Keychain takes the new key, the commit point. The previous copy is re-saved under the new key and the new wrapper
    /// replaces the old. Before the commit point a failure puts everything back and the old code keeps working, and a
    /// crash is undone at the next unlock; after it the change stands, and a crash's leftovers are finished at the next
    /// unlock. Until then the Keychain opens the vault, and each code opens it through its own wrapper (`settleRotation`).
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
        // One left unfinished is settled first, so only one new wrapper is ever waiting.
        guard settleRotation(key: key) else { throw VaultError.diskWriteFailed }
        let newKey = VaultCrypto.randomKey()
        var next = current.document
        next.generation += 1
        let payload = try VaultJSON.encode(VaultCrypto.persist(next, key: newKey))
        guard payload.count <= VaultLimits.maxVaultFileBytes else { throw VaultError.oversizedVault }
        let wrapper = try VaultJSON.encode(VaultCrypto.wrapVaultKey(
            VaultCrypto.keyData(newKey), recovery: recovery, vaultID: next.vaultID, keyID: VaultCrypto.keyID(newKey)
        ))
        let temp = layout.current.appendingPathExtension("tmp")
        var replaced = false
        do {
            try io.write(payload, to: temp, sync: true)
            try fence.publish(ticket) {
                guard self.session?.sessionID == sessionID, self.session?.document.generation == current.document.generation else {
                    throw VaultError.staleSession
                }
                try io.write(wrapper, to: layout.pendingRecovery, sync: true)
                try io.preserveVerifiedCopy(from: layout.current, to: layout.previous)
                try io.replaceItem(at: layout.current, withItemAt: temp)
                replaced = true
                try keys.store(vaultID: next.vaultID, key: VaultCrypto.keyData(newKey), context: authenticator.keychainContext)
                // Committed: the Keychain opens only the new file. Whatever fails from here is finished at the next unlock.
                settleRotation(key: newKey)
                self.session = VaultSession(sessionID: sessionID, document: next, fenceTicket: ticket)
                self.key = newKey
            }
        } catch {
            // Not committed, so the old key, code and file stay in charge. The previous copy is the old file, checked when saved.
            try? io.removeItem(at: temp)
            if replaced { try? io.preserveVerifiedCopy(from: layout.previous, to: layout.current) }
            try? io.removeItem(at: layout.pendingRecovery)
            if error is VaultError { throw error }
            throw VaultError.diskWriteFailed
        }
    }

    // Runs on the actor, so no commit can interleave with the capture.
    func captureBackupPackage() throws -> BackupPackage {
        // A backup never pairs the vault with a wrapper for another key: a code change still finishing is settled first.
        if io.fileExists(at: layout.pendingRecovery) {
            guard let key, settleRotation(key: key) else { throw VaultError.diskWriteFailed }
        }
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
        guard session == nil, try isEmptyDestination() else { throw VaultError.alreadyExists }
        if io.fileExists(at: layout.root) { try io.removeItem(at: layout.root) }
        fileLock?.release(); fileLock = nil
    }

    /// Start over, for a folder setup left holding only its recovery wrapper (`VaultLayout.holdsOnlyWrapper`): the wrapper
    /// is moved beside the folder under a numbered name, never deleted, and the folder is left empty for setup. Returns where.
    func startOver() throws -> URL {
        guard session == nil else { throw VaultError.alreadyExists }
        try acquireProcessLock()
        // Checked again under the process lock, just before the move.
        guard layout.holdsOnlyWrapper(io) else { throw VaultError.alreadyExists }
        let destination = layout.unusedWrapper(io)
        try io.installItem(at: destination, from: layout.recovery)
        return destination
    }

    /// Whether the vault folder is missing or holds only the empty Inbox a failed setup leaves (and hidden files such as
    /// Finder's, which are never vault files). Setup and welcome-screen restore both require it, so neither writes over
    /// any part of a vault, even one missing its main file. Nor while a restore that stopped partway is still unsettled.
    private func isEmptyDestination() throws -> Bool {
        guard !io.fileExists(at: layout.restoreJournal) else { return false }
        guard io.fileExists(at: layout.root) else { return true }
        return try io.contentsOfDirectory(at: layout.root).allSatisfy {
            $0.lastPathComponent.hasPrefix(".") || ($0.lastPathComponent == layout.inbox.lastPathComponent
                && ((try? io.contentsOfDirectory(at: layout.inbox))?.isEmpty ?? false))
        }
    }

    /// Replaces this unlocked vault with a verified backup and opens it; the caller has just authenticated the user, so
    /// the backup's key is saved to the Keychain with that authentication. The vault's folder is moved to `aside`, never
    /// deleted. A refused backup or code throws before anything changes. The backup may be an earlier one of this vault,
    /// under a key a recovery-code change has since replaced, so the Keychain takes its key last, once the copy is in the
    /// folder's place: that is the commit point, and nothing can fail after it. Before it, the session is closed and any
    /// failure removes the copy and puts the original folder back, locked, with the Keychain as it was. A journal beside the
    /// folder lets the next unlock or recovery finish or undo a restore the app didn't live through (`settleRestore`).
    func replace(with package: BackupPackage, recovery: RecoveryCode, aside: URL) throws -> VaultSession {
        guard let current = session, let currentKey = key, fence.current() == current.fenceTicket else { throw VaultError.locked }
        let restored = try BackupCoordinator.open(package, recovery: recovery)
        let restoredKey = try VaultCrypto.key(from: restored.key)
        let parent = layout.root.deletingLastPathComponent(), name = layout.root.lastPathComponent
        // The journal names both folders beside this one, where `settleRestore` looks for them.
        guard aside.deletingLastPathComponent().path == parent.path, aside.lastPathComponent.hasPrefix(name + " (") else {
            throw VaultError.unsafeFilename
        }
        guard !io.fileExists(at: aside) else { throw VaultError.alreadyExists }
        let staging = parent.appendingPathComponent(name + ".restore-" + UUID().uuidString, isDirectory: true)
        let journal = try VaultJSON.encode(RestoreJournal(
            aside: aside.lastPathComponent, staging: staging.lastPathComponent, vaultSHA256: VaultCrypto.sha256(package.vault)
        ))
        // Nothing the replaced session prepared may be saved from here, whether the backup opens or the original goes back.
        // The authenticator stays valid: the restore's Keychain write needs it.
        let ticket = fence.bump()
        session = nil; key = nil
        var moved = false, triedKeychain = false
        do {
            try acquireProcessLock()
            try io.write(journal, to: layout.restoreJournal, sync: true)
            try io.installItem(at: aside, from: layout.root)
            moved = true
            try BackupCoordinator.stage(package, at: staging, io: io)
            try io.installItem(at: layout.root, from: staging)
            let published: VaultSession = try fence.publish(ticket) {
                triedKeychain = true
                try keys.store(vaultID: restored.document.vaultID, key: restored.key, context: authenticator.keychainContext)
                // Committed: the Keychain opens the backup's copy, and the folder aside keeps the replaced vault.
                let opened = VaultSession(sessionID: UUID(), document: restored.document, fenceTicket: ticket)
                self.session = opened
                self.key = restoredKey
                self.openedPrevious = false
                return opened
            }
            // One left behind is settled at the next unlock, and the copy stands: the Keychain opens it.
            try? io.removeItem(at: layout.restoreJournal)
            return published
        } catch {
            session = nil; key = nil
            // Not committed. A Keychain update is all or nothing, but if one was tried this vault's own key is saved again.
            if triedKeychain, restored.document.vaultID == current.document.vaultID {
                try? keys.store(vaultID: current.document.vaultID, key: VaultCrypto.keyData(currentKey), context: authenticator.keychainContext)
            }
            try? io.removeItem(at: staging)
            if moved {
                // Whatever is in the folder's place is only the backup's copy. If the original can't go back, the journal stays.
                try? io.removeItem(at: layout.root)
                try io.installItem(at: layout.root, from: aside)
            }
            try? io.removeItem(at: layout.restoreJournal)
            throw error
        }
    }

    /// Finishes or undoes a restore that stopped partway (`replace`), before anything is opened. If the vault's folder was
    /// moved aside and nothing is in its place, it goes back. If the backup's copy is in its place, still byte for byte as
    /// restored, `keepsCopy` decides with the caller's key (the Keychain's on unlock, the code's on recovery): the copy stands
    /// if that key opens it, as it does once the Keychain took the backup's key; otherwise the copy is removed and the folder
    /// goes back. A copy saved over since stands. Only the staging copy and an untouched copy are ever removed.
    private func settleRestore(keepsCopy: (_ copy: PersistedVaultFile, _ aside: VaultLayout) throws -> Bool) throws {
        guard io.fileExists(at: layout.restoreJournal) else { return }
        let parent = layout.root.deletingLastPathComponent(), name = layout.root.lastPathComponent
        // Written atomically, so one that doesn't read, or names anything else, was changed outside the app: nothing is moved.
        guard let journal = try? VaultJSON.decode(RestoreJournal.self, from: io.data(at: layout.restoreJournal)),
              let asideName = try? SafeFileName.require(journal.aside), asideName.hasPrefix(name + " ("),
              let stagingName = try? SafeFileName.require(journal.staging), stagingName.hasPrefix(name + ".restore-") else {
            throw VaultError.corrupt
        }
        let aside = VaultLayout(root: parent.appendingPathComponent(asideName, isDirectory: true))
        do {
            try? io.removeItem(at: parent.appendingPathComponent(stagingName, isDirectory: true))
            if io.fileExists(at: aside.root) {
                if !io.fileExists(at: layout.root) {
                    try io.installItem(at: layout.root, from: aside.root)
                } else if let bytes = try? io.data(at: layout.current), VaultCrypto.sha256(bytes) == journal.vaultSHA256,
                          let copy = try? VaultJSON.decode(PersistedVaultFile.self, from: bytes), try !keepsCopy(copy, aside) {
                    try io.removeItem(at: layout.root)
                    try io.installItem(at: layout.root, from: aside.root)
                }
            }
            // Settled; one left behind comes to the same answer next time.
            try? io.removeItem(at: layout.restoreJournal)
        } catch let error as VaultError {
            throw error
        } catch {
            throw VaultError.diskWriteFailed
        }
    }

    /// The vault key `recovery` opens from one of the folder's wrappers, if any.
    private func unwrappedKey(in folder: VaultLayout, recovery: RecoveryCode) -> Data? {
        for url in [folder.recovery, folder.pendingRecovery] where io.fileExists(at: url) {
            if let wrapper = try? VaultJSON.decode(RecoveryWrapperFile.self, from: io.data(at: url)),
               let keyData = try? VaultCrypto.unwrapVaultKey(wrapper, recovery: recovery) { return keyData }
        }
        return nil
    }

    private func acquireProcessLock() throws {
        if fileLock != nil { return }
        if !io.fileExists(at: layout.root.deletingLastPathComponent()) {
            try io.createDirectory(at: layout.root.deletingLastPathComponent())
        }
        fileLock = try io.acquireExclusiveLock(at: layout.lockFile)
    }

    /// Opens the current file. If it is missing, unreadable or damaged (rather than written by a newer version), the
    /// previous generation is opened instead and saved back as current, and `openedPrevious` lets the caller tell the
    /// user. Only a previous copy that opens does so, and the file it replaces is moved aside, never overwritten.
    ///
    /// A failed authentication can't tell damage from a file sealed under another key, such as one a recovery-code change
    /// wrote before a crash; both are handled alike and nothing is lost. A newer version is told apart by the plain-text
    /// header (`PersistedVaultFile.schema`, `format`), checked before any key is tried, so it is never rolled back.
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
        } catch let failure as VaultError where failure == .corrupt || failure == .notFound {
            guard let bytes = try? io.data(at: layout.previous),
                  let persisted = try? VaultJSON.decode(PersistedVaultFile.self, from: bytes),
                  persisted.format == VaultSchema.persistedFile, vaultID == nil || persisted.vaultID == vaultID else { throw failure }
            let previousKey = try vaultKey ?? key(persisted.vaultID)
            guard let document = try? VaultCrypto.reveal(persisted, key: previousKey) else { throw failure }
            let temp = layout.current.appendingPathExtension("tmp")
            do {
                try io.write(bytes, to: temp, sync: true)
                // Moved rather than copied, so even a file this Mac can't read stays beside the vault.
                if io.fileExists(at: layout.current) { try io.installItem(at: layout.damagedCopy(io), from: layout.current) }
                try io.replaceItem(at: layout.current, withItemAt: temp)
            } catch {
                try? io.removeItem(at: temp)
                throw VaultError.diskWriteFailed
            }
            openedPrevious = true
            return (document, previousKey)
        }
    }

    /// Unreadable is `notFound`, damaged is `corrupt`, and a header naming a newer format or schema is `unknownSchema`.
    private func readPersisted(_ url: URL) throws -> PersistedVaultFile {
        let data: Data
        do {
            data = try io.data(at: url)
        } catch {
            throw VaultError.notFound
        }
        do {
            let file = try VaultJSON.decode(PersistedVaultFile.self, from: data)
            guard file.format == VaultSchema.persistedFile, VaultSchema.documents.contains(file.schema ?? 1) else {
                throw VaultError.unknownSchema
            }
            return file
        } catch let error as VaultError {
            throw error
        } catch {
            // A newer version may change the header's shape; its format or schema field still says so.
            if let header = try? VaultJSON.decode(HeaderProbe.self, from: data),
               header.format.map({ $0 != VaultSchema.persistedFile }) == true || header.schema.map({ !VaultSchema.documents.contains($0) }) == true {
                throw VaultError.unknownSchema
            }
            throw VaultError.corrupt
        }
    }

    /// Finishes or undoes a recovery-code change that stopped partway. The waiting wrapper replaces the old one if it
    /// holds `key`, the key the vault just opened with, after the previous copy is re-saved from current so it is under
    /// that key too; otherwise the change never took and the wrapper is removed. Returns whether nothing is left waiting.
    @discardableResult private func settleRotation(key: SymmetricKey) -> Bool {
        guard io.fileExists(at: layout.pendingRecovery) else { return true }
        guard let bytes = try? io.data(at: layout.pendingRecovery),
              let pending = try? VaultJSON.decode(RecoveryWrapperFile.self, from: bytes) else { return false }
        do {
            if pending.keyID == VaultCrypto.keyID(key) {
                try io.preserveVerifiedCopy(from: layout.current, to: layout.previous)
                try io.replaceItem(at: layout.recovery, withItemAt: layout.pendingRecovery)
            } else {
                try io.removeItem(at: layout.pendingRecovery)
            }
            return true
        } catch {
            return false
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

/// Only the fields that say which version wrote a vault file, read when the rest of it doesn't decode.
private struct HeaderProbe: Decodable {
    var format: Int?
    var schema: Int?
}

/// Written beside the vault folder while `VaultStore.replace` swaps it for a backup: folder names and a hash, no key or code.
private struct RestoreJournal: Codable {
    /// Where the replaced vault's folder is moved, beside it.
    var aside: String
    /// The folder the backup is written to before it takes the vault folder's place.
    var staging: String
    /// SHA-256 of the backup's `vault.uponly`, which tells an untouched copy from one saved over since.
    var vaultSHA256: Data
}
