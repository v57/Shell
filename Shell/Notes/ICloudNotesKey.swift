import CryptoKit
import Foundation

/// The AES-256 key that encrypts iCloud-synced notes. See `ICloudSyncKey`
/// for the shared synchronizable-keychain mechanics.
enum ICloudNotesKey {
  typealias KeyError = ICloudSyncKey.KeyError

  private static let account = "icloud-notes-aes-key-v1"
  private static let label = "Shell iCloud notes key"

  /// True when the iCloud Keychain can serve the notes key (account signed
  /// in, iCloud Keychain enabled). Used to gate tests that need real iCloud
  /// state; also creates the item on first use (idempotent, app-owned).
  static var isAvailable: Bool {
    ICloudSyncKey.isAvailable(account: account, label: label)
  }

  /// Loads the notes sync key, creating it on first use.
  static func loadOrCreate() throws -> SymmetricKey {
    try ICloudSyncKey.loadOrCreate(account: account, label: label)
  }
}
