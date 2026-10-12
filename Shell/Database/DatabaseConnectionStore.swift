import CryptoKit
import Foundation
import Observation
import SwiftData
import SwiftUI
import ShellKit

/// Persists the sidebar's saved database connections, synced through iCloud —
/// the same shape as `SSHConfigStore`.
///
/// Every connection is one `DatabaseConnectionRecord` in the app's shared
/// CloudKit-synced store (alongside the SSH-config and device-key records).
/// The store is created unconditionally; with no iCloud account it behaves as
/// a plain local store and syncs silently when an account appears. No push or
/// background modes: changes arrive at launch/activation
/// (`refreshOnActivation`), exactly like SSH configs and notes.
///
/// The whole connection travels as ONE AES-GCM ciphertext (engine, name, host,
/// port, database, username, auth) — CloudKit never sees plaintext connection
/// data. Decryption is eager but bounded (a handful of connections).
///
/// Saved PASSWORDS never sync — they stay in the device Keychain under
/// `DatabaseConnection.passwordAccount` (`db-password-<id>`), so a connection
/// synced to another device keeps its auth method but requires the password to
/// be entered there. The password is set explicitly via `save(_:password:)` and
/// is never read back into the `DatabaseConnection` value.
@MainActor
@Observable
final class DatabaseConnectionStore {
  /// Decrypted connections in sidebar order.
  private(set) var all: [DatabaseConnection] = []
  /// The most recent encryption/persistence failure.
  var storageError: String?

  private let context: ModelContext

  // MARK: Test seam — hermetic keys (the real keychain needs an unlocked
  // screen / iCloud session; tests inject generated keys).
  var iCloudKeyProvider: () throws -> SymmetricKey = {
    try SSHConfigKey.key(for: SSHConfigKey.icloud)
  }
  var deviceKeyProvider: () throws -> SymmetricKey = {
    try SSHConfigKey.key(for: SSHConfigKey.device)
  }

  init(
    container: ModelContainer? = nil,
    iCloudKeyProvider: (() throws -> SymmetricKey)? = nil,
    deviceKeyProvider: (() throws -> SymmetricKey)? = nil
  ) {
    // The CloudKit schema (all models) must be initialized before ANY
    // CloudKit-configured store opens. Idempotent; DEBUG-only.
    NoteStores.initializeCloudKitSchemaForDevelopment()
    let resolved: ModelContainer
    if let container {
      resolved = container
    } else if let made = try? DatabaseConnectionStore.makeContainer() {
      resolved = made
    } else {
      // CloudKit setup failed — degrade to a plain local store rather than
      // crash. The plain SQLite store is effectively infallible.
      resolved = try! ModelContainer(
        for: DatabaseConnectionRecord.self,
        configurations: ModelConfiguration("DatabaseConnections", cloudKitDatabase: .none)
      )
    }
    context = resolved.mainContext
    if let iCloudKeyProvider { self.iCloudKeyProvider = iCloudKeyProvider }
    if let deviceKeyProvider { self.deviceKeyProvider = deviceKeyProvider }
    reload()
  }

  /// The shared store: creates a container over the database-connection model
  /// ONLY, for callers that want a standalone container. Production code uses
  /// the app-wide shared container (which also holds the SSH/device-key
  /// models) instead — see `AppModel.sharedSSHContainer`.
  static func makeContainer() throws -> ModelContainer {
    try ModelContainer(
      for: DatabaseConnectionRecord.self,
      configurations: ModelConfiguration(
        "DatabaseConnections",
        cloudKitDatabase: .private("iCloud.dev.v57.sh")
      )
    )
  }

  /// Hermetic test container: plain SQLite in a temp directory, using a config
  /// name that never collides with the app's real store.
  static func makeTestContainer(in directory: URL) throws -> ModelContainer {
    try ModelContainer(
      for: DatabaseConnectionRecord.self,
      configurations: ModelConfiguration(
        "DatabaseConnectionsTests",
        url: directory.appendingPathComponent("db.store"),
        cloudKitDatabase: .none
      )
    )
  }

  // MARK: - Persistence API (same shape as SSHConfigStore)

  /// Saves a connection and, when a non-nil `password` is provided, writes it
  /// to the device Keychain. Passing `nil` leaves the existing password alone
  /// (edit-without-touching-credentials); pass an explicit empty string to
  /// clear it.
  func save(_ connection: DatabaseConnection, password: String? = nil) {
    do {
      let (keyId, cipher) = try seal(connection)
      if let record = fetch(connection.id) {
        record.payloadCipher = cipher
        record.keyId = keyId
        record.engine = connection.engine.rawValue
        record.updatedAt = Date()
      } else {
        context.insert(DatabaseConnectionRecord(
          id: connection.id,
          order: nextOrder(),
          keyId: keyId,
          engine: connection.engine,
          updatedAt: Date(),
          payloadCipher: cipher
        ))
      }
      try context.save()
      storageError = nil
    } catch {
      storageError = error.localizedDescription
      NSLog("DatabaseConnectionStore: could not save connection: \(error)")
    }
    // Persist the credential to the Keychain only after the record write
    // succeeded, so a removal never leaves an orphan secret behind.
    if let password {
      do {
        try SSHKeychain.savePassword(password, account: connection.passwordAccount)
      } catch {
        storageError = error.localizedDescription
        NSLog("DatabaseConnectionStore: could not save a connection's password: \(error)")
      }
    }
    reload()
  }

  func remove(_ id: UUID) {
    if let record = fetch(id) {
      context.delete(record)
      try? context.save()
    }
    SSHKeychain.deletePassword(account: "db-password-\(id.uuidString)")
    reload()
  }

  /// Replaces the whole list's order (drag-to-reorder). `updatedAt` is not
  /// bumped — reordering is not a content change.
  func reorder(_ list: [DatabaseConnection]) {
    for (index, connection) in list.enumerated() {
      if let record = fetch(connection.id) {
        record.order = index
      }
    }
    try? context.save()
    reload()
  }

  /// Moves a subset of `all` (the local, no-SSH-tunnel connections shown in
  /// the Local section) and reassigns `order` for the whole list, leaving
  /// every tunneled connection in its slot. The displayed Local slice is a
  /// filtered view of `all`, so the subset indices are mapped back into the
  /// full array before rewriting orders.
  func moveLocalSubset(from source: IndexSet, to destination: Int) {
    guard !source.isEmpty else { return }
    let indexes = all.indices.filter { all[$0].sshConfigID == nil }
    var items = indexes.map { all[$0] }
    items.move(fromOffsets: source, toOffset: destination)
    var reordered = all
    for (j, item) in items.enumerated() {
      reordered[indexes[j]] = item
    }
    reorder(reordered)
  }

  /// Re-fetches + re-decrypts — the no-push sync trigger (called when the
  /// scene becomes active, like notes/SSH).
  func refreshOnActivation() {
    reload()
  }

  // MARK: - Password access

  /// The saved password for a connection (from the Keychain), nil when unset.
  func password(for connection: DatabaseConnection) -> String? {
    (try? SSHKeychain.loadPassword(account: connection.passwordAccount)) ?? nil
  }

  /// Removes the stored password for a connection.
  func removePassword(for connection: DatabaseConnection) {
    SSHKeychain.deletePassword(account: connection.passwordAccount)
  }

  // MARK: - Encryption

  /// Seals a connection, preferring the iCloud Keychain sync key and falling
  /// back to the device-bound key when the sync key cannot be served.
  private func seal(_ connection: DatabaseConnection) throws -> (keyId: String, cipher: Data) {
    let data = try JSONEncoder().encode(connection)
    if let key = try? iCloudKeyProvider() {
      return (SSHConfigKey.icloud, try SecureFileStore.seal(data, using: key))
    }
    let key = try deviceKeyProvider()
    return (SSHConfigKey.device, try SecureFileStore.seal(data, using: key))
  }

  private func unseal(_ record: DatabaseConnectionRecord) throws -> DatabaseConnection? {
    guard let payloadCipher = record.payloadCipher else { return nil }
    let key = try (record.keyId == SSHConfigKey.device ? deviceKeyProvider() : iCloudKeyProvider())
    let data = try SecureFileStore.open(payloadCipher, using: key)
    return try JSONDecoder().decode(DatabaseConnection.self, from: data)
  }

  // MARK: - Store access

  private func reload() {
    let records = (try? context.fetch(
      FetchDescriptor<DatabaseConnectionRecord>(sortBy: [SortDescriptor(\.order)])
    )) ?? []
    var connections: [DatabaseConnection] = []
    for record in records {
      do {
        if let connection = try unseal(record) {
          connections.append(connection)
        }
      } catch {
        // Undecryptable here (e.g. a device-keyed record synced from another
        // machine) — skip it rather than break the list.
        NSLog("DatabaseConnectionStore: could not decrypt a connection record: \(error)")
      }
    }
    all = connections
  }

  private func fetch(_ id: UUID) -> DatabaseConnectionRecord? {
    // Plain fetch + Swift filter instead of a #Predicate (same rationale as
    // SSHConfigStore: SwiftData's predicate machinery proved unstable in the
    // hosted test runner). The list is bounded, so filtering in Swift costs
    // nothing.
    let records = (try? context.fetch(FetchDescriptor<DatabaseConnectionRecord>())) ?? []
    return records.first { $0.id == id }
  }

  private func nextOrder() -> Int {
    let orders = (try? context.fetch(FetchDescriptor<DatabaseConnectionRecord>()).map(\.order)) ?? []
    return (orders.max() ?? -1) + 1
  }
}
