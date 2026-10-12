import Foundation
import SwiftData
import ShellKit

/// A synced SSH connection config: one CloudKit record per saved host.
///
/// The entire config (name/host/user/port/auth method/flags) travels as a
/// single AES-GCM ciphertext (`payloadCipher`) — CloudKit only ever sees
/// the id, the sidebar sort order, the key id, and an opaque blob.
/// `keyId` says which key decrypts it:
/// - `.icloud` — the iCloud Keychain sync key (`ICloudSyncKey`), usable on
///   every device signed into the same Apple Account (the normal case).
/// - `.device` — fallback when the sync key is unavailable (no iCloud
///   Keychain); bound to this device only, so such records never decrypt
///   elsewhere.
///
/// Saved PASSWORDS never sync: they stay in the device Keychain
/// (`SSHConfig.passwordAccount`), so a connection synced to another device
/// has the auth method but requires the password to be entered there.
@Model
final class SSHConfigRecord {
  /// The SSHConfig identity; also the CloudKit record id.
  var id: UUID = UUID()
  /// Sidebar sort order (drag-to-reorder).
  var order: Int = 0
  /// Which key encrypts `payloadCipher` ("icloud" | "device").
  var keyId: String?
  /// Sort/last-change timestamp (plaintext, like notes' lastUpdate).
  var updatedAt: Date = Date.distantPast
  /// Sealed JSON of the SSHConfig (name/host/user/port/authMethod/...).
  var payloadCipher: Data?

  init(
    id: UUID = UUID(),
    order: Int = 0,
    keyId: String? = nil,
    updatedAt: Date = Date.distantPast,
    payloadCipher: Data? = nil
  ) {
    self.id = id
    self.order = order
    self.keyId = keyId
    self.updatedAt = updatedAt
    self.payloadCipher = payloadCipher
  }
}
