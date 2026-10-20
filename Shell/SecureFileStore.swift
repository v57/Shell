import CryptoKit
import Foundation
#if canImport(Security)
import Security
#else
import VaultKit
#endif

/// Device-bound encrypted file storage shared by notes and terminal history.
///
/// The Secure Enclave owns the P-256 private key. A stable ECDH secret is
/// computed against a non-secret peer public key, then split into independent
/// AES-256 keys with HKDF. Only the Secure Enclave's opaque representation and
/// the peer public key are persisted in the data-protection Keychain.
nonisolated enum SecureFileStore {
  enum Domain: String, Sendable {
    case notes = "dev.v57.sh.encrypted-files.notes.v1"
    case history = "dev.v57.sh.encrypted-files.history.v1"
    case sshConfigs = "dev.v57.sh.encrypted-files.ssh-configs.v1"
    case smartActions = "dev.v57.sh.encrypted-files.smart-actions.v1"
  }

  enum StoreError: LocalizedError {
    case secureEnclaveUnavailable
    case accessControlCreationFailed
    case missingKeychainEntitlement
    case keychainAddFailed(OSStatus)
    case keychainReadFailed(OSStatus)
    case invalidKeyEnvelope
    case invalidCiphertext

    var errorDescription: String? {
      switch self {
      case .secureEnclaveUnavailable:
        return "Secure Enclave is unavailable. Encrypted files cannot be accessed."
      case .accessControlCreationFailed:
        return "Could not create unlocked-device access control for encrypted files."
      case .missingKeychainEntitlement:
        return "This build is missing its Keychain Sharing entitlement. Rebuild Shell with code signing enabled."
      case .keychainAddFailed(let status):
        return "Could not save the encrypted-file key (OSStatus \(status))."
      case .keychainReadFailed(let status):
        return "Could not read the encrypted-file key (OSStatus \(status))."
      case .invalidKeyEnvelope:
        return "The encrypted-file key is invalid or belongs to another device."
      case .invalidCiphertext:
        return "The encrypted file is damaged or was created with another key."
      }
    }
  }

  private struct KeyEnvelope: Codable {
    let privateKeyRepresentation: Data
    let peerPublicKeyRepresentation: Data
  }

  private static let service = "dev.v57.sh"
  private static let account = "encrypted-file-secure-enclave-key-v1"
  private static let hkdfSalt = Data("Shell encrypted file storage v1".utf8)

  static func write(_ plaintext: Data, to url: URL, domain: Domain) throws {
    let ciphertext = try seal(plaintext, domain: domain)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try ciphertext.write(to: url, options: .atomic)
  }

  static func read(from url: URL, domain: Domain) throws -> Data {
    try open(Data(contentsOf: url), domain: domain)
  }

  static func seal(_ plaintext: Data, domain: Domain) throws -> Data {
    try seal(plaintext, using: symmetricKey(for: domain))
  }

  static func seal(_ plaintext: Data, using key: SymmetricKey) throws -> Data {
    let box = try AES.GCM.seal(plaintext, using: key)
    guard let combined = box.combined else { throw StoreError.invalidCiphertext }
    return combined
  }

  static func open(_ ciphertext: Data, domain: Domain) throws -> Data {
    try open(ciphertext, using: symmetricKey(for: domain))
  }

  static func open(_ ciphertext: Data, using key: SymmetricKey) throws -> Data {
    do {
      let box = try AES.GCM.SealedBox(combined: ciphertext)
      return try AES.GCM.open(box, using: key)
    } catch let error as StoreError {
      throw error
    } catch {
      throw StoreError.invalidCiphertext
    }
  }

  /// True when the device-bound key is readable (Secure Enclave up, screen
  /// unlocked — `WhenUnlocked` items are inaccessible while locked, which
  /// surfaces as errSecInteractionNotAllowed). Used to gate tests that need
  /// the real device keychain.
  static var isAvailable: Bool {
    (try? symmetricKey(for: .notes)) != nil
  }

  /// The AES-256 key for a storage domain. Local (device-bound) files are
  /// encrypted with the Secure Enclave ECDH-derived key; iCloud notes use
  /// `ICloudNotesKey` instead. Internal so notes migration can decrypt
  /// local files with the domain key.
  static func symmetricKey(for domain: Domain) throws -> SymmetricKey {
    let (privateKey, peerPublicKey) = try loadOrCreateKeyAgreement()
    let secret = try privateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
    return deriveSymmetricKey(from: secret, domain: domain)
  }

  /// Kept internal so tests can verify that the production HKDF context
  /// produces cryptographically independent keys for each storage domain.
  static func deriveSymmetricKey(from secret: SharedSecret, domain: Domain) -> SymmetricKey {
    return secret.hkdfDerivedSymmetricKey(
      using: SHA256.self,
      salt: hkdfSalt,
      sharedInfo: Data(domain.rawValue.utf8),
      outputByteCount: 32
    )
  }

  private static func loadOrCreateKeyAgreement() throws -> (
    SecureEnclave.P256.KeyAgreement.PrivateKey,
    P256.KeyAgreement.PublicKey
  ) {
    guard SecureEnclave.isAvailable else { throw StoreError.secureEnclaveUnavailable }

    if let data = try loadKeyEnvelope() {
      guard let envelope = try? JSONDecoder().decode(KeyEnvelope.self, from: data),
            let privateKey = try? SecureEnclave.P256.KeyAgreement.PrivateKey(
              dataRepresentation: envelope.privateKeyRepresentation
            ),
            let peerPublicKey = try? P256.KeyAgreement.PublicKey(
              x963Representation: envelope.peerPublicKeyRepresentation
            )
      else { throw StoreError.invalidKeyEnvelope }
      return (privateKey, peerPublicKey)
    }

    #if canImport(Security)
    var accessError: Unmanaged<CFError>?
    guard let accessControl = SecAccessControlCreateWithFlags(
      kCFAllocatorDefault,
      kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
      .privateKeyUsage,
      &accessError
    ) else {
      throw StoreError.accessControlCreationFailed
    }

    let privateKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(
      compactRepresentable: false,
      accessControl: accessControl
    )
    #else
    // Sealed to this device's user (the CryptoKit stand-in's Secure Enclave).
    let privateKey = try SecureEnclave.P256.KeyAgreement.PrivateKey()
    #endif
    let peerPrivateKey = P256.KeyAgreement.PrivateKey(compactRepresentable: false)
    let envelope = KeyEnvelope(
      privateKeyRepresentation: privateKey.dataRepresentation,
      peerPublicKeyRepresentation: peerPrivateKey.publicKey.x963Representation
    )
    try saveKeyEnvelope(try JSONEncoder().encode(envelope))
    return (privateKey, peerPrivateKey.publicKey)
  }

#if canImport(Security)
  private static func saveKeyEnvelope(_ data: Data) throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrLabel as String: "Shell encrypted files (Secure Enclave P-256)",
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
      kSecUseDataProtectionKeychain as String: true,
    ]
    let status = SecItemAdd(query as CFDictionary, nil)
    if status == errSecMissingEntitlement { throw StoreError.missingKeychainEntitlement }
    guard status == errSecSuccess else { throw StoreError.keychainAddFailed(status) }
  }

  private static func loadKeyEnvelope() throws -> Data? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
      kSecUseDataProtectionKeychain as String: true,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    if status == errSecMissingEntitlement { throw StoreError.missingKeychainEntitlement }
    guard status == errSecSuccess else { throw StoreError.keychainReadFailed(status) }
    guard let data = result as? Data else { throw StoreError.invalidKeyEnvelope }
    return data
  }
#else
  // Where Security is missing (Windows), VaultKit's keychain keeps the envelope: the Credential Manager.
  private static var keychain: VaultKeychain { VaultKeychain(service: service, accessGroup: nil) }

  private static func saveKeyEnvelope(_ data: Data) throws {
    do {
      try keychain.write(
        data, account: account,
        options: VaultKeychain.Options(synchronizable: false, label: "Shell encrypted files (Secure Enclave P-256)"))
    } catch VaultKeychain.KeychainError.status(let status) {
      throw StoreError.keychainAddFailed(status)
    }
  }

  private static func loadKeyEnvelope() throws -> Data? {
    do {
      return try keychain.read(account, options: .thisDevice)
    } catch VaultKeychain.KeychainError.status(let status) {
      throw StoreError.keychainReadFailed(status)
    }
  }
#endif
}
