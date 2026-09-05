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
    private var barrierDepth = 0

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
            try writeRecoveryBytes(recoveryBytes)
            try writeFirstPayload(payload)
            try keys.store(
                vaultID: document.vaultID,
                key: VaultCrypto.keyData(vaultKey),
                context: authenticator.keychainContext
            )
            let session = VaultSession(sessionID: UUID(), document: document, fenceTicket: ticket)
            self.session = session
            self.key = vaultKey
            return session
        }
        return opened
    }

    func unlock() async throws -> VaultSession {
        let ticket = fence.current()
        try await authenticator.evaluate()
        guard fence.current() == ticket else { throw VaultError.locked }
        try acquireProcessLock()
        try layout.ensureDirectories(io)
        guard io.fileExists(at: layout.current) else { throw VaultError.notFound }
        let persisted = try readPersisted(layout.current)
        guard keys.contains(vaultID: persisted.vaultID) else { throw VaultError.needsRecovery }
        let keyData = try keys.load(vaultID: persisted.vaultID, context: authenticator.keychainContext)
        let vaultKey = try VaultCrypto.key(from: keyData)
        let document: VaultDocument
        do {
            document = try VaultCrypto.reveal(persisted, key: vaultKey)
        } catch {
            throw VaultError.corrupt
        }
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
        let vaultKey = try VaultCrypto.key(from: keyData)
        let persisted = try readPersisted(layout.current)
        let document = try VaultCrypto.reveal(persisted, key: vaultKey)
        guard document.vaultID == wrapper.vaultID else { throw VaultError.corrupt }
        return try fence.publish(ticket) {
            try keys.store(vaultID: document.vaultID, key: keyData, context: authenticator.keychainContext)
            let opened = VaultSession(sessionID: UUID(), document: document, fenceTicket: ticket)
            self.session = opened
            self.key = vaultKey
            return opened
        }
    }

    func commit(_ next: VaultDocument, expectedGeneration: UInt64, sessionID: UUID) throws {
        if barrierDepth > 0 { throw VaultError.barrierHeld }
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

    func withWriterBarrier<T>(_ body: () throws -> T) throws -> T {
        barrierDepth += 1
        defer { barrierDepth -= 1 }
        return try body()
    }

    func captureBackupPackage() throws -> BackupPackage {
        try withWriterBarrier {
            try pinnedBackupState()
        }
    }

    private func pinnedBackupState() throws -> BackupPackage {
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

    func deleteInboxFile(at url: URL, batchID: UUID) throws {
        if barrierDepth > 0 { throw VaultError.barrierHeld }
        let session = try currentSession()
        guard session.document.acceptedBatchIDs.contains(batchID) else { throw VaultError.inboxNotCommitted }
        let name = try SafeFileName.require(url.lastPathComponent)
        let expected = layout.inbox.appendingPathComponent(name)
        guard expected.standardizedFileURL.path == url.standardizedFileURL.path else {
            throw VaultError.unsafeFilename
        }
        try io.removeItem(at: expected)
    }

    func pendingInboxBytes() throws -> Int {
        try io.contentsOfDirectory(at: layout.inbox).reduce(0) { total, url in
            total + (try io.data(at: url)).count
        }
    }

    func releaseEmptyDestination() throws {
        guard !io.fileExists(at: layout.current), session == nil else { throw VaultError.alreadyExists }
        if io.fileExists(at: layout.root) {
            let children = try io.contentsOfDirectory(at: layout.root)
            guard children.isEmpty else { throw VaultError.alreadyExists }
            try io.removeItem(at: layout.root)
        }
        fileLock?.release(); fileLock = nil
    }

    func writeInbox(_ bytes: Data, name: String) throws {
        let safe = try SafeFileName.require(name)
        let pending = try pendingInboxBytes()
        if pending + bytes.count > VaultLimits.maxPendingInboxBytes {
            throw VaultError.oversizedInbox
        }
        try io.write(bytes, to: layout.inbox.appendingPathComponent(safe), sync: true)
    }

    private func acquireProcessLock() throws {
        if fileLock != nil { return }
        if !io.fileExists(at: layout.root.deletingLastPathComponent()) {
            try io.createDirectory(at: layout.root.deletingLastPathComponent())
        }
        fileLock = try io.acquireExclusiveLock(at: layout.lockFile)
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
            try io.replaceItem(at: layout.current, withItemAt: temp)
        } catch {
            try? io.removeItem(at: temp)
            throw VaultError.diskWriteFailed
        }
    }
}
