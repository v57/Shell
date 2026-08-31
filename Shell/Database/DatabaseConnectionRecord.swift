import Foundation
import SwiftData

/// A saved database connection, persisted with SwiftData in the shared
/// container alongside the SSH-config and device-key records (one container,
/// low churn — the app deliberately keeps the SwiftData container count low).
///
/// Mirrors `SSHConfigRecord`: the entire connection (engine/name/host/port/
/// database/user/auth) travels as a single AES-GCM ciphertext (`payloadCipher`)
/// so CloudKit only ever sees the id, the sidebar sort order, the key id, and
/// an opaque blob. `keyId` says which key decrypts it (`.icloud` sync key or
/// the device-bound fallback).
///
/// The engine is also kept in plaintext so the sidebar can render the row icon
/// without decrypting. Saved PASSWORDS never sync: they stay in the device
/// Keychain under `DatabaseConnection.passwordAccount` — exactly like SSH
/// configs keep their passwords out of the record.
@Model
final class DatabaseConnectionRecord {
  /// The DatabaseConnection identity; also the CloudKit record id.
  var id: UUID = UUID()
  /// Sidebar sort order (drag-to-reorder).
  var order: Int = 0
  /// Which key encrypts `payloadCipher` ("icloud" | "device").
  var keyId: String?
  /// Plaintext engine for sidebar rendering without a decrypt.
  var engine: String = DatabaseEngine.mongodb.rawValue
  /// Sort/last-change timestamp (plaintext, like notes' lastUpdate).
  var updatedAt: Date = Date.distantPast
  /// Sealed JSON of the DatabaseConnection (engine/name/host/port/...).
  var payloadCipher: Data?

  init(
    id: UUID = UUID(),
    order: Int = 0,
    keyId: String? = nil,
    engine: DatabaseEngine = .mongodb,
    updatedAt: Date = Date.distantPast,
    payloadCipher: Data? = nil
  ) {
    self.id = id
    self.order = order
    self.keyId = keyId
    self.engine = engine.rawValue
    self.updatedAt = updatedAt
    self.payloadCipher = payloadCipher
  }
}
