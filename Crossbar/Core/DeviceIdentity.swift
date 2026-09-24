import CryptoKit
import Foundation
import Security
import UIKit

/// The Keychain, as this app uses it.
///
/// One item per named value, no access groups: this app is the only reader of any of
/// them, and every item is written `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` —
/// after first unlock, because a call has to be answerable while the phone is locked, and
/// this-device-only, because neither a signing key nor a session token is any use on
/// hardware it was not issued to.
enum DeviceKeychain {
    /// One query shape, so an account can never be read with a different access class or
    /// service than it was written with — which is a write and a read that silently
    /// disagree rather than an error either side can see.
    private static func query(_ account: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppSettings.Key.deviceService,
            kSecAttrAccount as String: account,
        ]
        for (key, value) in extra { query[key] = value }
        return query
    }

    static func data(for account: String) -> Data? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    static func string(for account: String) -> String? {
        data(for: account).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Writes a value, replacing anything already stored under the account.
    ///
    /// Delete-then-add rather than update: `SecItemUpdate` cannot change an item's
    /// accessibility, and every value here has to land under the class this app asks for.
    /// The caller is told whether it landed, because a key that was enrolled but not
    /// stored is a device that cannot sign after the next launch.
    @discardableResult
    static func set(_ value: Data, for account: String) -> Bool {
        remove(account)
        return SecItemAdd(query(account, [
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]) as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        set(Data(value.utf8), for: account)
    }

    static func remove(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}

/// What this device signs with, and the id the service issued for the public half of it.
///
/// A Crossbar service that turns device auth on identifies a *device* rather than a
/// person, and it does so with a public key it holds for each enrolled device: this
/// device signs a challenge with a P-256 private key that never leaves it, and presents
/// the signature. Nothing here is a credential in the "secret you send" sense — there is
/// no key to steal from the service, and no shared secret for two deployments to share.
///
/// The key is generated on first enrollment and never regenerated behind the service's
/// back: a new key is an unknown device, and the enrollment code that vetted it is spent.
@MainActor
final class DeviceIdentity {
    /// What the service calls this device until it answers with a name of its own.
    ///
    /// The device's own name, not a generated id: enrollment is a person showing a code to
    /// a person, and "Azzaam's iPhone" is how the person on the other end recognises which
    /// device is asking to join.
    static var defaultDeviceName: String {
        let name = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "iPhone" : name
    }

    /// The id the service issued for this device's public key.
    private(set) var deviceId: String?

    private var key: SigningKey?

    /// Whether this device has both halves of an identity: a key, and an id for it.
    ///
    /// Both, because either one alone is a device that cannot authenticate: a key the
    /// service has never seen, or an id for a key that is gone.
    var isEnrolled: Bool { deviceId != nil && key != nil }

    /// The public half, base64 of its SPKI DER encoding — which is the encoding the
    /// service's enrollment route takes (`publicKey` in `POST /api/auth/enroll`).
    var publicKeyBase64: String? {
        key?.publicKey.derRepresentation.base64EncodedString()
    }

    init() {
        deviceId = DeviceKeychain.string(for: AppSettings.Key.deviceID)
        key = Self.loadKey()
    }

    // MARK: - Signing

    /// The DER ECDSA signature over `data`, hashed with SHA-256 — the `ES256` the
    /// service's challenge route verifies.
    ///
    /// `signature(for:)` hashes the message itself, so the bytes that go in are the
    /// canonical message exactly as it is built by `DeviceAuth`, and not a digest of it.
    func sign(_ data: Data) throws -> Data {
        guard let key else { throw DeviceIdentityError.noKey }
        return try key.signature(for: data).derRepresentation
    }

    // MARK: - Enrollment

    /// Creates this device's key if it has none.
    ///
    /// Called immediately before enrollment and nowhere else, so the key the service is
    /// told about is the key that will sign. Creating it lazily at the first signature
    /// instead would let a device believe it is enrolled while holding a key the service
    /// has never seen, and the failure would arrive as a rejected signature rather than as
    /// a missing identity.
    func createKeyIfNeeded() throws {
        guard key == nil else { return }

        // The Secure Enclave where the hardware has one: the private half is then not
        // extractable at all, not even by this app, and a signing operation is a request
        // to the Enclave rather than arithmetic on bytes in this process. The default
        // access control CryptoKit creates the key with is after-first-unlock and
        // this-device-only, the same protection the Keychain items here carry.
        //
        // The Enclave key cannot be exported, so what is stored below is its
        // `dataRepresentation` — a handle the Enclave unwraps, meaningful only to the
        // Enclave that minted it. That is the tradeoff of using it: the handle cannot be
        // restored onto another device, or after the Enclave has been wiped, and the
        // device then has to be enrolled again rather than recovering silently.
        if SecureEnclave.isAvailable, let enclave = try? SecureEnclave.P256.Signing.PrivateKey() {
            guard DeviceKeychain.set(enclave.dataRepresentation, for: AppSettings.Key.deviceSigningKeyHandle) else {
                throw DeviceIdentityError.keyStorageFailed
            }
            key = .secureEnclave(enclave)
            return
        }

        // The software key otherwise: in the simulator, on hardware without an Enclave,
        // and when the Enclave refuses to create one — which it does on a device with no
        // passcode set. It is a real P-256 key either way; what is given up is the
        // guarantee that the private half cannot be read out of this process, and the
        // raw representation stored below is exactly that private half.
        let software = P256.Signing.PrivateKey()
        guard DeviceKeychain.set(software.rawRepresentation, for: AppSettings.Key.deviceSigningKey) else {
            throw DeviceIdentityError.keyStorageFailed
        }
        key = .software(software)
    }

    /// Records the id the service issued for this device's key.
    ///
    /// The name is deliberately not kept. It is a fact about the phone rather than about the
    /// enrollment — iOS knows it and says so whenever it is asked — and a copy taken at
    /// enrollment goes on describing a phone that has been renamed since.
    func enroll(as id: String) {
        deviceId = id
        DeviceKeychain.set(id, for: AppSettings.Key.deviceID)
    }

    /// Destroys this device's identity: the key, and everything the service issued for it.
    ///
    /// The key is deleted rather than kept aside. A device that was "forgotten" but could
    /// still sign would be a device that was never really forgotten, and the service's
    /// copy of the public key is the only other record of it — which is exactly what
    /// revocation is for.
    func forget() {
        DeviceKeychain.remove(AppSettings.Key.deviceSigningKey)
        DeviceKeychain.remove(AppSettings.Key.deviceSigningKeyHandle)
        DeviceKeychain.remove(AppSettings.Key.deviceID)
        key = nil
        deviceId = nil
    }

    // MARK: - Storage

    /// The stored key, if there is one that can still sign.
    ///
    /// A handle whose Enclave key is gone — the item was restored to another device, or
    /// the Enclave was wiped — cannot be loaded, and the device is then simply not
    /// enrolled. That is the honest outcome: the service's record of the old key cannot
    /// be satisfied, and carrying on would only move the failure to the first signature.
    private static func loadKey() -> SigningKey? {
        if let handle = DeviceKeychain.data(for: AppSettings.Key.deviceSigningKeyHandle),
           let enclave = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: handle) {
            return .secureEnclave(enclave)
        }
        if let raw = DeviceKeychain.data(for: AppSettings.Key.deviceSigningKey),
           let software = try? P256.Signing.PrivateKey(rawRepresentation: raw) {
            return .software(software)
        }
        return nil
    }
}

/// Where the key lives, which is the one thing that differs between the two.
///
/// The two key types are separate CryptoKit types with no common protocol, and the
/// difference is not cosmetic: one can be exported and one cannot, and one signs through
/// the Secure Enclave's own hardware. Wrapping them keeps that difference in the storage
/// decision above rather than in every caller.
private enum SigningKey {
    case secureEnclave(SecureEnclave.P256.Signing.PrivateKey)
    case software(P256.Signing.PrivateKey)

    var publicKey: P256.Signing.PublicKey {
        switch self {
        case .secureEnclave(let key): key.publicKey
        case .software(let key): key.publicKey
        }
    }

    func signature(for data: Data) throws -> P256.Signing.ECDSASignature {
        switch self {
        case .secureEnclave(let key): try key.signature(for: data)
        case .software(let key): try key.signature(for: data)
        }
    }
}

enum DeviceIdentityError: Error, LocalizedError {
    case noKey
    case keyStorageFailed

    var errorDescription: String? {
        switch self {
        case .noKey:
            "This device has no signing key."
        case .keyStorageFailed:
            "The signing key could not be stored in the keychain."
        }
    }
}
