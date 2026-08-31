import Foundation

/// Which database engine a connection talks to. Pure raw-value enum,
/// persisted in the sidebar records and switchable in the new-connection
/// form. New engines join `CaseIterable` plus the switches in
/// `DatabaseSession`/`DatabaseConnectionStore`.
enum DatabaseEngine: String, Codable, CaseIterable, Identifiable {
  case mongodb
  case postgresql
  case redis
  case sqlite

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .mongodb: return "MongoDB"
    case .postgresql: return "PostgreSQL"
    case .redis: return "Redis"
    case .sqlite: return "SQLite"
    }
  }

  /// Default network port, used to prefill the new-connection form when the
  /// engine changes. SQLite is file-based and has no port (the form hides it).
  var defaultPort: UInt16 {
    switch self {
    case .mongodb: return 27017
    case .postgresql: return 5432
    case .redis: return 6379
    case .sqlite: return 0
    }
  }

  /// SF Symbol used in sidebar rows and the engine picker.
  var systemImage: String {
    switch self {
    case .mongodb: return "leaf.fill"
    case .postgresql: return "elephant"
    case .redis: return "bolt.horizontal.fill"
    case .sqlite: return "internaldrive"
    }
  }

  /// Whether the engine is reachable on this platform. All four engines are
  /// cross-platform — the Database package's C-driver XCFramework ships iOS
  /// device + simulator slices and the SQLite engine uses the SDK's system
  /// SQLite3 module, both present on macOS and iOS — so every engine is
  /// available everywhere the app builds.
  var isAvailable: Bool {
    true
  }
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

  /// The remote target the SSH tunnel bridges to — the remote host's own
  /// `localhost:<port>` (so a DB server on the SSH host's loopback is
  /// reachable from the tunnel). Nil when no tunnel is needed.
  var tunnelTarget: (host: String, port: Int)? {
    guard requiresTunnel else { return nil }
    return ("127.0.0.1", Int(port))
  }
}
