import Foundation
import Observation
import ShellKit
import SwiftUI
import VaultKit

/// The sidebar's saved database connections: the ones the v57 apps share through the vault (`../Vault`).
///
/// Each `DatabaseConnection` is a `VaultDatabase`, so Database list the same connections,
/// iCloud syncs them, and the list updates live when another app or device changes one. Fields Shell doesn't
/// show (Database's options, colors, read-only flag) stay in the shared record.
///
/// A connection without an SSH host of its own attaches to the saved host whose address is the database's
/// server (`VaultDatabase.tunnelHost`), so a database on a machine you SSH into shows under that host and
/// connects through it. Passwords are `VaultSecrets` items named after the connection.
@MainActor
@Observable
final class DatabaseConnectionStore {
  /// Connections in sidebar order.
  private(set) var all: [DatabaseConnection] = []
  /// The most recent persistence failure.
  var storageError: String?

  @ObservationIgnored private let vault: Vault
  @ObservationIgnored private var observer: VaultChangeObserver?
  /// Connections whose SSH host was picked automatically (none saved), so saving keeps it automatic.
  @ObservationIgnored private var automaticHosts: [UUID: UUID] = [:]

  init(vault: Vault = .shared) {
    self.vault = vault
    reload()
    observer = VaultChangeObserver { [weak self] in
      Task { @MainActor in self?.refreshOnActivation() }
    }
  }

  // MARK: - Persistence API

  /// Saves a connection and, when a non-nil `password` is provided, the password. Passing nil leaves the
  /// saved password alone; an empty string clears it.
  func save(_ connection: DatabaseConnection, password: String? = nil) {
    let id = connection.id.uuidString
    var record =
      vault.databases.first { $0.id == id }
      ?? VaultDatabase(
        id: id, engine: connection.engine.rawValue, port: Int(connection.port), order: nextOrder())
    Self.copy(connection, into: &record, automaticHost: automaticHosts[connection.id], hosts: vault.hosts)
    vault.save(record)
    storageError = vault.error
    if let password {
      do {
        try SSHKeychain.savePassword(password, account: connection.passwordAccount)
      } catch {
        storageError = error.localizedDescription
      }
    }
    reload()
  }

  func remove(_ id: UUID) {
    vault.perform { try $0.delete(id: id.uuidString) }
    SSHKeychain.deletePassword(account: "db-password-\(id.uuidString)")
    reload()
  }

  /// Replaces the whole list's order (drag-to-reorder).
  func reorder(_ list: [DatabaseConnection]) {
    let records = vault.databases
    vault.perform { store in
      for (index, connection) in list.enumerated() {
        guard var record = records.first(where: { $0.id == connection.id.uuidString }), record.order != index
        else { continue }
        record.order = index
        try store.save(record)
      }
    }
    reload()
  }

  #if DEBUG
  /// The screenshot demo's connections, as if they had last connected at `lastUsed` (`ScreenshotDemo`).
  func saveDemo(_ connection: DatabaseConnection, lastUsed: Date?) {
    save(connection)
    guard var record = vault.databases.first(where: { $0.id == connection.id.uuidString }) else { return }
    record.lastUsed = lastUsed
    vault.save(record)
    reload()
  }
  #endif

  /// Re-reads the shared connections (another app or device changed them).
  func refreshOnActivation() {
    vault.reload()
    reload()
  }

  // MARK: - Password access

  /// The saved password for a connection, nil when unset.
  func password(for connection: DatabaseConnection) -> String? {
    (try? SSHKeychain.loadPassword(account: connection.passwordAccount)) ?? nil
  }

  /// Removes the stored password for a connection.
  func removePassword(for connection: DatabaseConnection) {
    SSHKeychain.deletePassword(account: connection.passwordAccount)
  }

  // MARK: - Mapping

  private func reload() {
    let hosts = vault.hosts
    var automatic: [UUID: UUID] = [:]
    all = vault.databases.compactMap { record in
      guard let connection = Self.connection(from: record, hosts: hosts) else { return nil }
      if record.sshHostID == nil, let host = connection.sshConfigID { automatic[connection.id] = host }
      return connection
    }
    automaticHosts = automatic
  }

  static func connection(from record: VaultDatabase, hosts: [VaultHost]) -> DatabaseConnection? {
    guard let engine = DatabaseEngine(rawValue: record.engine) else { return nil }
    let host = record.tunnelHost(in: hosts)
    var connection = DatabaseConnection(
      id: UUID(uuidString: record.id) ?? stableUUID(record.id), engine: engine, name: record.name,
      host: engine.isFileBased ? record.filePath : record.host, port: UInt16(clamping: max(record.port, 0)),
      database: record.database.isEmpty ? nil : record.database, username: record.user.isEmpty ? nil : record.user,
      authSource: record.options["authSource"], directConnection: record.options["directConnection"] == "true",
      sshConfigID: host.map { UUID(uuidString: $0.id) ?? stableUUID($0.id) })
    connection.useTLS = record.useTLS
    connection.lastUsed = record.lastUsed
    return connection
  }

  /// Writes a connection over its shared record. An SSH host that was only picked automatically stays
  /// unsaved, so it follows the host list.
  static func copy(
    _ connection: DatabaseConnection, into record: inout VaultDatabase, automaticHost: UUID?, hosts: [VaultHost]
  ) {
    record.name = connection.name
    record.engine = connection.engine.rawValue
    if connection.engine.isFileBased {
      record.filePath = connection.host
      record.host = ""
    } else {
      record.host = connection.host
    }
    record.port = Int(connection.port)
    record.database = connection.database ?? ""
    record.user = connection.username ?? ""
    record.options["authSource"] = connection.authSource?.isEmpty == false ? connection.authSource : nil
    record.options["directConnection"] = connection.directConnection ? "true" : nil
    record.useTLS = connection.useTLS
    if connection.sshConfigID != automaticHost {
      // A Hub device's host has an id that isn't a UUID: the config's id is made from it.
      record.sshHostID = connection.sshConfigID.map { id in
        hosts.first { (UUID(uuidString: $0.id) ?? stableUUID($0.id)) == id }?.id ?? id.uuidString
      }
    }
  }

  private func nextOrder() -> Int {
    (vault.databases.map(\.order).max() ?? -1) + 1
  }
}
