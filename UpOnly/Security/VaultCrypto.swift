import CryptoKit
import Foundation
import Security

nonisolated enum VaultCrypto {
    static func randomKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    static func keyData(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    static func key(from data: Data) throws -> SymmetricKey {
        guard data.count == 32 else { throw VaultError.wrongKey }
        return SymmetricKey(data: data)
    }

    static func authenticatedData(schema: Int, vaultID: UUID, generation: UInt64) -> Data {
        Data("\(schema)|\(vaultID.uuidString)|\(generation)".utf8)
    }

    static func seal(
        _ plaintext: Data,
        key: SymmetricKey,
        schema: Int,
        vaultID: UUID,
        generation: UInt64
    ) throws -> (nonce: Data, ciphertext: Data, tag: Data) {
        let aad = authenticatedData(schema: schema, vaultID: vaultID, generation: generation)
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: aad)
        return (Data(sealed.nonce), sealed.ciphertext, sealed.tag)
    }

    static func open(
        nonce: Data,
        ciphertext: Data,
        tag: Data,
        key: SymmetricKey,
        schema: Int,
        vaultID: UUID,
        generation: UInt64
    ) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonce),
                ciphertext: ciphertext,
                tag: tag
            )
            let aad = authenticatedData(schema: schema, vaultID: vaultID, generation: generation)
            return try AES.GCM.open(box, using: key, authenticating: aad)
        } catch {
            throw VaultError.wrongKey
        }
    }

    static func wrapVaultKey(_ vaultKey: Data, recovery: RecoveryCode, vaultID: UUID) throws -> RecoveryWrapperFile {
        let recoveryKey = SymmetricKey(data: recovery.secret)
        let sealed = try seal(
            vaultKey,
            key: recoveryKey,
            schema: VaultSchema.recoveryWrapper,
            vaultID: vaultID,
            generation: 0
        )
        return RecoveryWrapperFile(
            format: VaultSchema.recoveryWrapper,
            vaultID: vaultID,
            nonce: sealed.nonce,
            ciphertext: sealed.ciphertext,
            tag: sealed.tag
        )
    }

    static func unwrapVaultKey(_ wrapper: RecoveryWrapperFile, recovery: RecoveryCode) throws -> Data {
        guard wrapper.format == VaultSchema.recoveryWrapper else { throw VaultError.unknownSchema }
        let recoveryKey = SymmetricKey(data: recovery.secret)
        do {
            return try open(
                nonce: wrapper.nonce,
                ciphertext: wrapper.ciphertext,
                tag: wrapper.tag,
                key: recoveryKey,
                schema: VaultSchema.recoveryWrapper,
                vaultID: wrapper.vaultID,
                generation: 0
            )
        } catch {
            throw VaultError.wrongRecoveryCode
        }
    }

    static func persist(_ document: VaultDocument, key: SymmetricKey) throws -> PersistedVaultFile {
        let plaintext = try VaultJSON.encode(document)
        let sealed = try seal(
            plaintext,
            key: key,
            schema: document.schema,
            vaultID: document.vaultID,
            generation: document.generation
        )
        return PersistedVaultFile(
            format: VaultSchema.persistedFile,
            vaultID: document.vaultID,
            generation: document.generation,
            nonce: sealed.nonce,
            ciphertext: sealed.ciphertext,
            tag: sealed.tag
        )
    }

    static func reveal(_ file: PersistedVaultFile, key: SymmetricKey) throws -> VaultDocument {
        guard file.format == VaultSchema.persistedFile else { throw VaultError.unknownSchema }
        let plaintext = try open(
            nonce: file.nonce,
            ciphertext: file.ciphertext,
            tag: file.tag,
            key: key,
            schema: VaultSchema.document,
            vaultID: file.vaultID,
            generation: file.generation
        )
        let document = try VaultJSON.decode(VaultDocument.self, from: plaintext)
        guard document.schema == VaultSchema.document else { throw VaultError.unknownSchema }
        guard document.vaultID == file.vaultID, document.generation == file.generation else {
            throw VaultError.corrupt
        }
        return document
    }

    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    static func makeInboxKeyPair() -> (privateX963: Data, publicX963: Data) {
        let privateKey = P256.KeyAgreement.PrivateKey()
        return (privateKey.x963Representation, privateKey.publicKey.x963Representation)
    }

    static func makeSigningKeyPair() -> (privateX963: Data, publicX963: Data) {
        let privateKey = P256.Signing.PrivateKey()
        return (privateKey.x963Representation, privateKey.publicKey.x963Representation)
    }

    static func sign(_ data: Data, privateKeyX963: Data) throws -> Data {
        let key = try P256.Signing.PrivateKey(x963Representation: privateKeyX963)
        let signature = try key.signature(for: data)
        return signature.rawRepresentation
    }

    static func verify(_ data: Data, signature: Data, publicKeyX963: Data) throws {
        let key = try P256.Signing.PublicKey(x963Representation: publicKeyX963)
        let sig = try P256.Signing.ECDSASignature(rawRepresentation: signature)
        guard key.isValidSignature(sig, for: data) else { throw VaultError.invalidSignature }
    }

    static func wrapAESKey(_ aesKey: Data, inboxPublicX963: Data) throws -> Data {
        try ecies(encrypt: aesKey, publicX963: inboxPublicX963)
    }

    static func unwrapAESKey(_ wrapped: Data, inboxPrivateX963: Data) throws -> Data {
        try ecies(decrypt: wrapped, privateX963: inboxPrivateX963)
    }

    private static func ecies(encrypt data: Data, publicX963: Data) throws -> Data {
        let key = try secKey(publicX963, isPrivate: false)
        var error: Unmanaged<CFError>?
        guard let wrapped = SecKeyCreateEncryptedData(
            key,
            .eciesEncryptionCofactorX963SHA256AESGCM,
            data as CFData,
            &error
        ) as Data? else {
            throw error!.takeRetainedValue() as Error
        }
        return wrapped
    }

    private static func ecies(decrypt data: Data, privateX963: Data) throws -> Data {
        let key = try secKey(privateX963, isPrivate: true)
        var error: Unmanaged<CFError>?
        guard let plain = SecKeyCreateDecryptedData(
            key,
            .eciesEncryptionCofactorX963SHA256AESGCM,
            data as CFData,
            &error
        ) as Data? else {
            throw error!.takeRetainedValue() as Error
        }
        return plain
    }

    private static func secKey(_ x963: Data, isPrivate: Bool) throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: isPrivate ? kSecAttrKeyClassPrivate : kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 256,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(x963 as CFData, attributes as CFDictionary, &error) else {
            throw error!.takeRetainedValue() as Error
        }
        return key
    }
}
