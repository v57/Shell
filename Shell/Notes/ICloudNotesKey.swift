import Crypto
import Foundation
import Security

/// The AES-256 key that encrypts iCloud-synced notes.
///
/// Unlike the local `SecureFileStore` key (Secure-Enclave-bound to ONE
/// device), this key is a plain 32-byte random value stored as a
/// *synchronizable* keychain item — iCloud Keychain — so every device
/// signed into the same iCloud account derives the same key and can open
/// the same encrypted notes.
enum ICloudNotesKey {
  enum KeyError: LocalizedError {
    case missingKeychainEntitlement
    case keychainAddFailed(OSStatus)
    case keychainReadFailed(OSStatus)

    var errorDescription: String? {
      switch self {
      case .missingKeychainEntitlement:
        return "This build is missing its Keychain entitlement. Rebuild Shell with code signing enabled."
      case .keychainAddFailed(let status):
        return "Could not save the iCloud notes key (OSStatus \(status))."
      case .keychainReadFailed(let status):
        return "Could not read the iCloud notes key (OSStatus \(status))."
      }
    }
  }

  private static let service = "dev.v57.sh"
  private static let account = "icloud-notes-aes-key-v1"

  /// True when the iCloud Keychain can serve the sync key (account signed
  /// in, iCloud Keychain enabled). Used to gate tests that need real iCloud
  /// state; also creates the item on first use (idempotent, app-owned).
  static var isAvailable: Bool {
    (try? loadOrCreate()) != nil
  }

  /// Loads the sync key, creating it on first use.
  static func loadOrCreate() throws -> SymmetricKey {
    if let data = try load() {
      return SymmetricKey(data: data)
    }
    let key = SymmetricKey(size: .bits256)
    let data = key.withUnsafeBytes { Data($0) }
    do {
      try save(data)
    } catch let error as KeyError {
      // A concurrent first run on another device may have won the race;
      // prefer the winner's key so all devices converge on one.
      if case .keychainAddFailed(let status) = error, status == errSecDuplicateItem {
        guard let data = try load() else { throw KeyError.keychainReadFailed(errSecItemNotFound) }
        return SymmetricKey(data: data)
      }
      throw error
    }
    return key
  }

  private static func save(_ data: Data) throws {
    // Syncable items must NOT be ThisDeviceOnly and must live in the
    // data-protection keychain (kSecUseDataProtectionKeychain, already
    // used by SecureFileStore). iCloud Keychain does the rest.
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrLabel as String: "Shell iCloud notes key",
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
      kSecAttrSynchronizable as String: kCFBooleanTrue,
      kSecUseDataProtectionKeychain as String: true,
    ]
    let status = SecItemAdd(query as CFDictionary, nil)
    if status == errSecMissingEntitlement { throw KeyError.missingKeychainEntitlement }
    guard status == errSecSuccess else { throw KeyError.keychainAddFailed(status) }
  }

  private static func load() throws -> Data? {
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
}
