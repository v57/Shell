import CryptoKit
import Foundation
#if canImport(Security)
import Security
#else
import VaultKit
#endif

/// The AES-256 key that encrypts iCloud-synced data (notes, SSH configs).
///
/// Unlike the local `SecureFileStore` key (Secure-Enclave-bound to ONE
/// device), this key is a plain 32-byte random value stored as a
/// *synchronizable* keychain item — iCloud Keychain — so every device
/// signed into the same iCloud account derives the same key and can open
/// the same encrypted data. Each data type gets its own account (separate
/// rotation), but the mechanics are shared.
enum ICloudSyncKey {
  enum KeyError: LocalizedError {
    case missingKeychainEntitlement
    case keychainAddFailed(OSStatus)
    case keychainReadFailed(OSStatus)

    var errorDescription: String? {
      switch self {
      case .missingKeychainEntitlement:
        return "This build is missing its Keychain entitlement. Rebuild Shell with code signing enabled."
      case .keychainAddFailed(let status):
        return "Could not save the iCloud sync key (OSStatus \(status))."
      case .keychainReadFailed(let status):
        return "Could not read the iCloud sync key (OSStatus \(status))."
      }
    }
  }

  private static let service = "dev.v57.sh"

  /// True when the iCloud Keychain can serve the given sync key (account
  /// signed in, iCloud Keychain enabled). Used to gate tests that need real
  /// iCloud state; also creates the item on first use (idempotent, app-owned).
  static func isAvailable(account: String, label: String) -> Bool {
    (try? loadOrCreate(account: account, label: label)) != nil
  }

  /// Loads the sync key for a data type, creating it on first use.
  static func loadOrCreate(account: String, label: String) throws -> SymmetricKey {
    if let data = try load(account: account) {
      return SymmetricKey(data: data)
    }
    let key = SymmetricKey(size: .bits256)
    let data = key.withUnsafeBytes { Data($0) }
    do {
      try save(data, account: account, label: label)
    } catch let error as KeyError {
      // A concurrent first run on another device may have won the race;
      // prefer the winner's key so all devices converge on one.
      if case .keychainAddFailed(let status) = error, status == errSecDuplicateItem {
        guard let data = try load(account: account) else { throw KeyError.keychainReadFailed(errSecItemNotFound) }
        return SymmetricKey(data: data)
      }
      throw error
    }
    return key
  }

#if canImport(Security)
  private static func save(_ data: Data, account: String, label: String) throws {
    // Syncable items must NOT be ThisDeviceOnly and must live in the
    // data-protection keychain (kSecUseDataProtectionKeychain, already
    // used by SecureFileStore). iCloud Keychain does the rest.
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrLabel as String: label,
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
      kSecAttrSynchronizable as String: kCFBooleanTrue,
      kSecUseDataProtectionKeychain as String: true,
    ]
    let status = SecItemAdd(query as CFDictionary, nil)
    if status == errSecMissingEntitlement { throw KeyError.missingKeychainEntitlement }
    guard status == errSecSuccess else { throw KeyError.keychainAddFailed(status) }
  }

  private static func load(account: String) throws -> Data? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
      // macOS: without this, SecItemCopyMatching returns only
      // NON-synchronizable items and can never see the iCloud Keychain
      // item (verified: SecItemAdd then reported duplicate while the
      // read found nothing).
      kSecAttrSynchronizable as String: kCFBooleanTrue,
      kSecUseDataProtectionKeychain as String: true,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    if status == errSecMissingEntitlement { throw KeyError.missingKeychainEntitlement }
    guard status == errSecSuccess else { throw KeyError.keychainReadFailed(status) }
    return result as? Data
  }
#else
  // Where Security is missing (Windows), VaultKit's keychain keeps the key (synced items stay apart there; the
  // Credential Manager doesn't sync them).
  private static var keychain: VaultKeychain { VaultKeychain(service: service, accessGroup: nil) }

  private static func save(_ data: Data, account: String, label: String) throws {
    do {
      try keychain.addNew(data, account: account, options: VaultKeychain.Options(synchronizable: true, label: label))
    } catch VaultKeychain.KeychainError.status(let status) {
      throw KeyError.keychainAddFailed(status)
    }
  }

  private static func load(account: String) throws -> Data? {
    do {
      return try keychain.read(account, options: .synced)
    } catch VaultKeychain.KeychainError.status(let status) {
      throw KeyError.keychainReadFailed(status)
    }
  }
#endif
}
