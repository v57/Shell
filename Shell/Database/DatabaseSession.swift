import Foundation
import Observation
import ShellKit

import MongoDB
import PostgreSQL
import Redis
import SQLite

/// A single display field of a database document/row/value.
struct DatabaseField: Identifiable {
  let name: String
  let value: String
  var id: String { name }
}

/// A normalized renderable item in the browser panel (a Mongo document, a
/// Postgres/SQLite row, or a Redis key's detail). The view only ever sees
/// `[String]` names attached to a `DatabaseDocument` of fields, never a
/// driver type — so the browser compiles and renders identically on both
/// platforms.
struct DatabaseDocument: Identifiable {
  let id: String
  let fields: [DatabaseField]
}

/// Live connection lifecycle wrapper for a saved `DatabaseConnection`, powered
/// by the Database package's engine libraries (MongoConnection /
/// PostgresConnection / RedisConnection / SQLiteConnection). All four engines
/// build on both macOS and iOS, so this class references every engine module
/// unconditionally (guarded only by `canImport` so the package stays buildable
/// if an engine is ever dropped).
@MainActor
@Observable
final class DatabaseSession {
  enum State {
    case disconnected
    case connecting
    case connected
    case failed(String)
  }

  private enum LiveConnection {
    case mongodb(MongoConnection)
    case postgresql(PostgresConnection)
    case redis(RedisConnection)
    case sqlite(SQLiteConnection)
  }

  let connection: DatabaseConnection
  /// Resolves a saved `SSHConfig` by id when the connection is tunneled.
  /// Injected by AppModel so the session can reach the SSH store without
  /// owning one; nil in tests that exercise only local connections.
  private let sshConfigStore: SSHConfigStore?
  /// The forwarding-only SSH session backing a tunneled connection. Opened in
  /// `establishTunnel()`, closed in `disconnect()` (or on a failed driver
  /// connect), so the tunnel's lifecycle is tied to this connection's.
  private var sshSession: SSHSession?
  private(set) var state: State = .disconnected
  private(set) var statusMessage = ""
  private(set) var databases: [String] = []
  private(set) var selectedDatabase: String?
  private(set) var collections: [String] = []
  private(set) var selectedCollection: String?
  private(set) var documents: [DatabaseDocument] = []
  private(set) var selectedDocument: DatabaseDocument?

  /// Each engine's default database/namespace to select after connect.
  private var defaultDatabase: String = ""

  private var live: LiveConnection?

  init(connection: DatabaseConnection, sshConfigStore: SSHConfigStore? = nil) {
    self.connection = connection
    self.sshConfigStore = sshConfigStore
  }

  var isConnected: Bool {
    if case .connected = state { return true }
    return false
  }

  // MARK: - Connect / disconnect

  /// Connects using the saved connection, loading the password from the
  /// Keychain (via the store) at the last moment. On success loads the top
  /// level and selects the default database.
  func connect(password: String?) async {
    await disconnect()
    guard connection.isValid else {
      state = .failed("Connection is incomplete (host/port).")
      statusMessage = "Cannot connect: \(connection.displayName)"
      return
    }
    guard connection.engine.isAvailable else {
      // Defensive: all four engines link on both platforms today, but if a
      // platform ever excludes one, fail cleanly instead of crashing.
      state = .failed("\(connection.engine.displayName) is not available on this platform.")
      statusMessage = "Unavailable: \(connection.engine.displayName)"
      return
    }
    state = .connecting
    statusMessage = "Connecting to \(connection.subtitle)…"

    // Resolve the effective driver address: either the saved host:port (a
    // local DB connected directly) or 127.0.0.1:<tunneledLocalPort> once the
    // SSH port-forward is established (a remote DB reached over the tunnel).
    var effectiveHost = connection.host
    var effectivePort = connection.port
    if connection.requiresTunnel {
      do {
        effectivePort = UInt16(try await establishTunnel())
        effectiveHost = Self.tunnelHost
      } catch {
        // A partly-established tunnel (e.g. auth was cancelled or the SSH
        // connection dropped) must not be retained as a dead session object.
        closeTunnel()
        state = .failed(error.localizedDescription)
        statusMessage = "Connection failed: \(error.localizedDescription)"
        return
      }
    }

    defer { if case .connecting = state { state = .connected } }
    do {
      switch connection.engine {
      case .mongodb:
        let conn = MongoConnection(config: mongoConfig(password: password, host: effectiveHost, port: effectivePort))
        try await conn.connect()
        live = .mongodb(conn)
        databases = try await conn.listDatabases()
        defaultDatabase = connection.database ?? databases.first ?? "admin"
        await select(database: defaultDatabase)
      case .postgresql:
        let conn = PostgresConnection(config: postgresConfig(password: password, host: effectiveHost, port: effectivePort))
        try await conn.connect()
        live = .postgresql(conn)
        databases = try await conn.listDatabases()
        defaultDatabase = connection.database ?? databases.first ?? "postgres"
        await select(database: defaultDatabase)
      case .redis:
        let conn = RedisConnection(config: redisConfig(password: password, host: effectiveHost, port: effectivePort))
        try await conn.connect()
        live = .redis(conn)
        databases = try await conn.listDatabases().map { String($0) }
        defaultDatabase = connection.database ?? databases.first ?? "0"
        await select(database: defaultDatabase)
      case .sqlite:
        let conn = SQLiteConnection(config: sqliteConfig())
        try await conn.connect()
        live = .sqlite(conn)
        databases = try await conn.listDatabases()
        defaultDatabase = connection.database ?? databases.first ?? "main"
        await select(database: defaultDatabase)
      }
      statusMessage = "Connected to \(connection.displayName)"
    } catch {
      // A failed driver connect must not leak the SSH tunnel opened for it.
      if connection.requiresTunnel { closeTunnel() }
      state = .failed(error.localizedDescription)
      statusMessage = "Connection failed: \(error.localizedDescription)"
    }
  }

  func disconnect() async {
    // Close the SSH tunnel (if any) before/independently of the driver.
    closeTunnel()
    guard let live else {
      state = .disconnected
      databases = []
      collections = []
      documents = []
      statusMessage = ""
      return
    }
    switch live {
    case .mongodb(let c): await c.disconnect()
    case .postgresql(let c): await c.disconnect()
    case .redis(let c): await c.disconnect()
    case .sqlite(let c): await c.disconnect()
    }
    self.live = nil
    state = .disconnected
    databases = []
    selectedDatabase = nil
    collections = []
    selectedCollection = nil
    documents = []
    selectedDocument = nil
    statusMessage = ""
  }

  // MARK: - Selection

  /// Switches the active database and reloads its collections/tables/keys.
  func select(database: String) async {
    guard isConnected, let live else { return }
    do {
      switch live {
      case .mongodb(let c): try await c.use(database: database)
      case .postgresql(let c): try await c.use(database: database)
      case .redis(let c): try await c.use(database: database)
      case .sqlite(let c): try await c.use(database: database)
      }
      selectedDatabase = database
      await loadCollections()
    } catch {
      statusMessage = error.localizedDescription
    }
  }

  /// Loads the collections/tables/keys for the selected database.
  private func loadCollections() async {
    guard isConnected, let live, let selectedDatabase else { return }
    do {
      switch live {
      case .mongodb(let c):
        collections = try await c.listCollections()
      case .postgresql(let c):
        collections = try await c.listTables()
      case .redis(let c):
        collections = try await c.listKeys()
      case .sqlite(let c):
        collections = try await c.listTables()
      }
    } catch {
      statusMessage = error.localizedDescription
    }
  }

  /// Selects a collection/table/key and loads its documents/rows/entry.
  func selectCollection(_ name: String) async {
    guard isConnected, let live else { return }
    selectedCollection = name
    do {
      switch live {
      case .mongodb(let c):
        let docs = try await c.find(in: name, limit: 100)
        documents = docs.map(Self.document(fromMongo:))
        statusMessage = "\(documents.count) document(s) in \(name)"
      case .postgresql(let pg):
        let rows = try await pg.select(sql: "SELECT * FROM \(name)", limit: 100)
        documents = rows.map(Self.document(fromPostgres:))
        statusMessage = "\(rows.count) row(s) in \(name)"
      case .sqlite(let sqlite):
        let rows = try await sqlite.select(
          sql: "SELECT * FROM \(Self.quotedIdentifier(name)) LIMIT 100")
        documents = rows.map(Self.document(fromSQLite:))
        statusMessage = "\(rows.count) row(s) in \(name)"
      case .redis(let redis):
        let entry = try await redis.entry(for: name)
        documents = [Self.document(fromRedis: entry)]
        selectedDocument = documents.first
        statusMessage = "\(entry.typeName) · TTL \(entry.ttl)s"
        return
      }
      selectedDocument = documents.first
    } catch {
      statusMessage = error.localizedDescription
    }
  }

  // MARK: - SSH tunnel

  /// The address the DB driver connects THROUGH a tunnel: always loopback,
  /// since the reachable port is a locally-bound tunnel listener. Also the
  /// local bind host for the forward.
  private static let tunnelHost = "127.0.0.1"
  /// The remote target the tunnel bridges to — the SSH host's own loopback,
  /// where the DB server is expected to listen.
  private static let tunnelTargetHost = "127.0.0.1"

  /// Establishes an SSH local port-forward to the remote DB's
  /// `localhost:<port>` and resolves to the bound LOCAL port the driver should
  /// connect to. Reuses the shared `SSHSession`/`SSHLocalPortForward`
  /// machinery from the web card: the SSH session runs in forwarding-only mode
  /// (no remote shell), opens ONE authenticated connection, and multiplexes
  /// `direct-tcpip` channels over it — no re-dial or re-authentication.
  ///
  /// The tunnel's lifecycle is tied to this DB connection: it is opened here
  /// and closed in `disconnect()` (or on a failed driver connect), so a remote
  /// DB connection never leaks a forward.
  private func establishTunnel() async throws -> Int {
    guard let config = sshConfig() else {
      throw DatabaseConnectionTunnelError.missingSSHConfig
    }
    let session = SSHSession(config: config, forwardingOnly: true)
    self.sshSession = session

    // Trust on first use, never a changed key — opening a database connection
    // bound to a host IS the intent to connect (same policy as the web card /
    // file browser).
    session.onHostKeyPrompt = { prompt in
      prompt.respondTrustingFirstUse()
    }
    session.onPasswordPrompt = { [config] prompt in
      let saved = (try? SSHKeychain.loadPassword(account: config.passwordAccount)) ?? nil
      if let saved {
        prompt.respond(saved, false)
      } else {
        // No saved SSH password and key auth failed. Cancelling the prompt
        // makes the engine fail auth, which surfaces via onTerminated.
        prompt.respond(nil, false)
      }
    }

    return try await withCheckedThrowingContinuation { continuation in
      let gate = TunnelContinuationGate()
      session.onConnected = { [weak self] in
        guard let self else { return }
        self.openTunnel(session: session, continuation: continuation, gate: gate)
      }
      session.onTerminated = { message in
        gate.resume(continuation) { $0.resume(throwing: DatabaseConnectionTunnelError.tunnelFailed(message)) }
      }
      session.start()
    }
  }

  /// Opens the actual port-forward once SSH auth has completed, threading the
  /// bound local port back to the awaiting continuation.
  private func openTunnel(
    session: SSHSession,
    continuation: CheckedContinuation<Int, Error>,
    gate: TunnelContinuationGate
  ) {
    session.startLocalPortForward(
      bindHost: Self.tunnelHost,
      bindPort: 0,
      targetHost: Self.tunnelTargetHost,
      targetPort: Int(connection.port)
    ) { result in
      DispatchQueue.main.async { [gate, continuation] in
        gate.resume(continuation) { continuation in
          switch result {
          case .success(let boundPort):
            continuation.resume(returning: boundPort)
          case .failure(let error):
            continuation.resume(throwing: error)
          }
        }
      }
    }
  }

  /// Resolves this connection's saved SSH config by id, if it still exists.
  private func sshConfig() -> SSHConfig? {
    guard let sshConfigID = connection.sshConfigID else { return nil }
    return sshConfigStore?.all.first { $0.id == sshConfigID }
  }

  /// Closes the tunnel's listener + SSH session. Best-effort, safe to call
  /// even when no tunnel was opened.
  private func closeTunnel() {
    sshSession?.stopLocalPortForward()
    sshSession?.close()
    sshSession = nil
  }

  // MARK: - Engine config builders

  private func mongoConfig(password: String?, host: String, port: UInt16) -> ConnectionConfig {
    ConnectionConfig(
      name: connection.name,
      host: host,
      port: port,
      username: connection.username,
      password: password,
      authSource: connection.authSource,
      defaultDatabase: connection.database,
      directConnection: connection.directConnection
    )
  }

  private func postgresConfig(password: String?, host: String, port: UInt16) -> PostgresConnectionConfig {
    PostgresConnectionConfig(
      name: connection.name,
      host: host,
      port: port,
      username: connection.username,
      password: password,
      defaultDatabase: connection.database
    )
  }

  private func redisConfig(password: String?, host: String, port: UInt16) -> RedisConnectionConfig {
    RedisConnectionConfig(
      name: connection.name,
      host: host,
      port: port,
      username: connection.username,
      password: password,
      databaseIndex: connection.database.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    )
  }

  private func sqliteConfig() -> SQLiteConnectionConfig {
    SQLiteConnectionConfig(name: connection.name, filePath: connection.host)
  }

  // MARK: - Conversion to normalized docs

  private static func document(fromMongo doc: Document) -> DatabaseDocument {
    // `doc` is the Database package's BSON `Document` (BSONDocument). Render
    // it as single-line extended JSON for a stable, readable dump.
    let json = BSONSupport.json(doc)
    return DatabaseDocument(id: json, fields: [DatabaseField(name: "document", value: json)])
  }

  private static func document(fromPostgres row: PostgresRowData) -> DatabaseDocument {
    let fields = row.values.map { DatabaseField(name: $0.key, value: display($0.value)) }
    return DatabaseDocument(id: "\(row.id)", fields: fields)
  }

  private static func document(fromSQLite row: SQLiteRowData) -> DatabaseDocument {
    let fields = row.values.map { DatabaseField(name: $0.key, value: display($0.value)) }
    return DatabaseDocument(id: "\(row.id)", fields: fields)
  }

  private static func document(fromRedis entry: RedisKeyEntry) -> DatabaseDocument {
    DatabaseDocument(
      id: entry.key,
      fields: [
        DatabaseField(name: "key", value: entry.key),
        DatabaseField(name: "type", value: entry.typeName),
        DatabaseField(name: "value", value: entry.displayValue),
        DatabaseField(name: "ttl", value: "\(entry.ttl)"),
      ])
  }

  private static func display(_ value: PostgresValue) -> String {
    switch value {
    case .null: return "NULL"
    case .bool(let b): return b ? "true" : "false"
    case .int(let n): return "\(n)"
    case .double(let d): return "\(d)"
    case .string(let s): return s
    case .date(let date): return "\(date)"
    case .json(let s): return s
    case .bytes(let bytes): return bytes.map { String(format: "%02x", $0) }.joined()
    }
  }

  private static func display(_ value: SQLiteValue) -> String {
    switch value {
    case .null: return "NULL"
    case .int(let n): return "\(n)"
    case .double(let d): return "\(d)"
    case .string(let s): return s
    case .bytes(let bytes): return bytes.map { String(format: "%02x", $0) }.joined()
    }
  }

  /// Double-quotes a SQLite identifier, escaping embedded quotes.
  private static func quotedIdentifier(_ name: String) -> String {
    "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }
}

/// Errors specific to establishing a remote database connection's SSH tunnel.
enum DatabaseConnectionTunnelError: LocalizedError {
  case missingSSHConfig
  case tunnelFailed(String)

  var errorDescription: String? {
    switch self {
    case .missingSSHConfig:
      return "The SSH connection for this database no longer exists. Add it in the SSH settings, then reconnect."
    case .tunnelFailed(let message):
      return message
    }
  }
}

/// Guards a checked continuation against a double resume. The tunnel's
/// `onConnected`, the port-forward completion, and `onTerminated` can all race
/// (e.g. the SSH connection drops right after the forward resolves), so only
/// the first resumer wins.
private final class TunnelContinuationGate: @unchecked Sendable {
  private let lock = NSLock()
  private var resumed = false

  func resume(
    _ continuation: CheckedContinuation<Int, Error>,
    _ body: (CheckedContinuation<Int, Error>) -> Void
  ) {
    lock.lock()
    if resumed {
      lock.unlock()
      return
    }
    resumed = true
    lock.unlock()
    body(continuation)
  }
}
