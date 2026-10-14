import Foundation
import ShellDatabaseEngines
import ShellKit

/// Which database engine a connection talks to: every engine Database's libraries have but DuckDB
/// (DatabaseKit, through ShellDatabaseEngines). Raw values are the shared records' engine names
/// (`VaultDatabase.Engine`), so Database read the same connections.
enum DatabaseEngine: String, Codable, CaseIterable, Identifiable {
  case postgres
  case mysql
  case mariadb
  case sqlserver
  case sqlite
  case mongodb
  case redis
  case cassandra
  case scylla

  var id: String { rawValue }

  /// The engine in DatabaseKit.
  var kind: EngineKind { EngineKind(rawValue: rawValue) ?? .postgres }

  var displayName: String { kind.displayName }

  /// Default network port, used to prefill the new-connection form when the
  /// engine changes. SQLite is file-based and has no port (the form hides it).
  var defaultPort: UInt16 { UInt16(kind.defaultPort) }

  /// SF Symbol used in sidebar rows and the engine picker.
  var systemImage: String {
    switch self {
    case .mongodb: return "leaf.fill"
    case .postgres: return "server.rack"
    case .mysql, .mariadb: return "cylinder.split.1x2"
    case .sqlserver: return "server.rack"
    case .redis: return "bolt.horizontal.fill"
    case .sqlite: return "internaldrive"
    case .cassandra, .scylla: return "circle.hexagongrid"
    }
  }

  /// Every engine is pure Swift and runs on macOS and iOS.
  var isAvailable: Bool { true }
}

/// A saved database connection. Pure value type: `Codable` (persistable,
/// encrypted like `SSHConfig`), `Hashable`/`Identifiable` (SwiftUI lists),
/// and free of any driver types.
///
/// Credentials are deliberately NOT stored here. The value carries the
/// username/auth method but no password; the password lives in the device
/// Keychain under `passwordAccount` and is loaded at connect time. The
/// encrypted record therefore never sees a credential, and the plaintext
/// value that reaches the sidebar never carries one either.
struct DatabaseConnection: Identifiable, Codable, Hashable {
  var id: UUID
  var engine: DatabaseEngine
  var name: String
  /// Server host, or the SQLite file path (file databases have no server).
  var host: String
  /// TCP port (0 for SQLite).
  var port: UInt16
  /// Database preselected after connect. For Redis this is the logical
  /// database index as a string ("0"…"15").
  var database: String?
  /// Optional username / role.
  var username: String?
  /// Mongo auth source (admin DB for credentials). Redis ignores it.
  var authSource: String?
  /// Mongo: connect directly to the single server, bypassing topology
  /// discovery. Encoded as `?directConnection=true`.
  var directConnection: Bool
  /// Encrypted connection (TLS), for hosted databases.
  var useTLS: Bool = false
  /// Optional SSH config id when the connection is reached through an SSH
  /// tunnel. When set (and the engine is not a file-based SQLite DB) the
  /// engine connects to `127.0.0.1:<tunneledLocalPort>`, bridging to the
  /// remote host's `localhost:<port>` over an SSH local port-forward.
  /// Local connections (no sshConfigID) connect directly to `host:port`.
  var sshConfigID: UUID?

  init(
    id: UUID = UUID(),
    engine: DatabaseEngine = .mongodb,
    name: String = "",
    host: String = "",
    port: UInt16 = 27017,
    database: String? = nil,
    username: String? = nil,
    authSource: String? = nil,
    directConnection: Bool = false,
    sshConfigID: UUID? = nil
  ) {
    self.id = id
    self.engine = engine
    self.name = name
    self.host = host
    self.port = port
    self.database = database
    self.username = username
    self.authSource = authSource
    self.directConnection = directConnection
    self.sshConfigID = sshConfigID
  }

  /// Keychain account for this connection's saved password. Stable per id so
  /// edits to the row (same id) keep the credential.
  var passwordAccount: String {
    "db-password-\(id.uuidString)"
  }

  /// Name if given, otherwise `engine host`, or the file name for SQLite.
  var displayName: String {
    if !name.isEmpty { return name }
    if engine == .sqlite {
      return (host as NSString).lastPathComponent.isEmpty ? host : (host as NSString).lastPathComponent
    }
    if username?.isEmpty == false {
      return "\(engine.displayName) \(username!)@\(host)"
    }
    return engine == .sqlite ? host : "\(engine.displayName) \(host)"
  }

  /// Whether the connection is fillable enough to attempt a connect.
  var isValid: Bool {
    if engine == .sqlite { return !host.isEmpty }
    return !host.isEmpty && port > 0
  }

  /// Subtitle shown under the row: `host:port` (or the file path).
  var subtitle: String {
    if engine == .sqlite { return host }
    return "\(host):\(port)"
  }

  /// Whether the connection should be routed through an SSH tunnel. SQLite is
  /// file-based and never tunnels; every other engine tunnels when an
  /// `sshConfigID` is set. Pure — unit-testable without a live SSH server.
  var requiresTunnel: Bool {
    engine != .sqlite && sshConfigID != nil
  }

  /// Where the SSH tunnel connects on the far side: the SSH host's own
  /// loopback when the database runs there (its address is local, or the
  /// host's), else the database's address as the SSH host reaches it (a
  /// server behind a bastion). Nil when no tunnel is needed.
  func tunnelTarget(through config: SSHConfig) -> (host: String, port: Int)? {
    guard requiresTunnel else { return nil }
    let address = host.lowercased()
    let onHost =
      ["", "localhost", "127.0.0.1", "::1"].contains(address) || address == config.host.lowercased()
      || (!config.name.isEmpty && address == config.name.lowercased())
    return (onHost ? "127.0.0.1" : host, Int(port))
  }
}
