import Foundation
import SQLite3
import ShellKit

/// Moves the SSH hosts and database connections that builds before the vault kept in their own CloudKit
/// store (`SSHConfigs.store`, encrypted with Shell's iCloud Keychain key) into the vault, once. The old
/// file is only read: builds before the vault still find it.
@MainActor
enum LegacyImport {
  private static let doneKey = "ImportedLegacySSHStore"

  static func run(configs: SSHConfigStore, databases: DatabaseConnectionStore) {
    let defaults = UserDefaults.standard
    guard !defaults.bool(forKey: doneKey) else { return }
    let url = URL.applicationSupportDirectory.appendingPathComponent("SSHConfigs.store")
    guard FileManager.default.fileExists(atPath: url.path) else {
      defaults.set(true, forKey: doneKey)
      return
    }
    var failed = false
    for row in rows(in: url, table: "ZSSHCONFIGRECORD") {
      guard let data = open(row), let config = try? JSONDecoder().decode(SSHConfig.self, from: data) else {
        failed = true
        continue
      }
      if !configs.all.contains(where: { $0.id == config.id }) { configs.save(config) }
    }
    for row in rows(in: url, table: "ZDATABASECONNECTIONRECORD") {
      guard let data = open(row), let connection = legacyConnection(data) else {
        failed = true
        continue
      }
      if !databases.all.contains(where: { $0.id == connection.id }) { databases.save(connection) }
    }
    // A record this device can't decrypt yet (the key hasn't arrived through iCloud Keychain) is tried again
    // next launch.
    if !failed { defaults.set(true, forKey: doneKey) }
  }

  private struct Row {
    let keyID: String?
    let payload: Data
  }

  private static func rows(in url: URL, table: String) -> [Row] {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "SELECT ZKEYID, ZPAYLOADCIPHER FROM \(table)", -1, &statement, nil) == SQLITE_OK
    else { return [] }
    defer { sqlite3_finalize(statement) }
    var rows: [Row] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      let keyID = sqlite3_column_text(statement, 0).map { String(cString: $0) }
      guard let bytes = sqlite3_column_blob(statement, 1) else { continue }
      rows.append(Row(keyID: keyID, payload: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1)))))
    }
    return rows
  }

  /// Decrypts a payload with the key it names: Shell's iCloud Keychain key, or the device-bound one.
  private static func open(_ row: Row) -> Data? {
    let key =
      row.keyID == "device"
      ? try? SecureFileStore.symmetricKey(for: .sshConfigs)
      : try? ICloudSyncKey.loadOrCreate(account: "icloud-ssh-configs-aes-key-v1", label: "Shell iCloud SSH configs key")
    guard let key else { return nil }
    return try? SecureFileStore.open(row.payload, using: key)
  }

  /// The old connection JSON named PostgreSQL `postgresql`; everything else decodes as it is.
  private static func legacyConnection(_ data: Data) -> DatabaseConnection? {
    guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    if object["engine"] as? String == "postgresql" { object["engine"] = DatabaseEngine.postgres.rawValue }
    if object["useTLS"] == nil { object["useTLS"] = false }
    guard let fixed = try? JSONSerialization.data(withJSONObject: object) else { return nil }
    return try? JSONDecoder().decode(DatabaseConnection.self, from: fixed)
  }
}
