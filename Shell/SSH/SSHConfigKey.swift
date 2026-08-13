import Crypto
import Foundation

/// Key mapping for synced SSH config records. Mirrors `NoteKeyID`:
/// `.icloud` prefers the iCloud Keychain sync key (usable everywhere);
/// `.device` is the Secure-Enclave-bound fallback for when the sync key
/// cannot be served (no iCloud Keychain session).
enum SSHConfigKey {
  static let icloud = "icloud"
  static let device = "device"

  static let account = "icloud-ssh-configs-aes-key-v1"
  static let label = "Shell iCloud SSH configs key"

  static func key(for keyId: String?) throws -> SymmetricKey {
    switch keyId {
    case icloud:
      return try ICloudSyncKey.loadOrCreate(account: account, label: label)
    case device:
      return try SecureFileStore.symmetricKey(for: .sshConfigs)
    default:
      throw SSHConfigStoreError.unknownKeyID(keyId)
    }
  }

  /// True when the iCloud sync key is servable (used by tests to skip
  /// real-keychain assertions when iCloud Keychain is unavailable).
  static var isAvailable: Bool {
    ICloudSyncKey.isAvailable(account: account, label: label)
  }
}
