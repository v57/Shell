import Foundation
import Observation
import ShellDatabaseEngines
import ShellKit

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
/// by Database's engine-neutral DatabaseKit (every engine but DuckDB,
/// pure Swift on macOS and iOS). Through SSH, Shell logs in itself and the
/// engine talks to SSH channels in-process: nothing listens on this device.
@MainActor
@Observable
final class DatabaseSession {
  enum State {
    case disconnected
    case connecting
    case connected
    case failed(String)
  }

  let connection: DatabaseConnection
  /// Resolves a saved `SSHConfig` by id when the connection is tunneled.
  /// Injected by AppModel so the session can reach the SSH store without
  /// owning one; nil in tests that exercise only local connections.
  private let sshConfigStore: SSHConfigStore?
  /// The forwarding-only SSH session carrying a tunneled connection's channels.
  /// Opened in `establishTunnel()`, closed in `disconnect()` (or on a failed
  /// driver connect), so the tunnel's lifecycle is tied to this connection's.
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

  private var live: (any DatabaseKit.DatabaseSession)?
  /// The tree node of each listed database (nil: the engine has no database level, like SQLite).
  private var databaseNodes: [String: TreeNode?] = [:]
  /// The object behind each listed collection/table/view name.
  private var objects: [String: ObjectRef] = [:]

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

    // How the engine reaches the database: directly at the saved host:port, or
    // over channels of an SSH session, where the host is as the SSH server sees
    // it (a database on the server itself is its 127.0.0.1).
    var effectiveHost = connection.host
    var dialer = WireDialer.direct
    if connection.requiresTunnel {
      do {
        let (sshDialer, target) = try await establishTunnel()
        dialer = sshDialer
        effectiveHost = target
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
      let profile = profile(host: effectiveHost, port: connection.port)
      let (session, _) = try await Connector.connect(
        profile, credentials: Credentials(password: password), dialer: dialer)
      live = session
      let top = try await session.children(of: nil)
      let containers: Set<TreeNode.Kind> = [.database, .keyspace, .redisDatabase]
      if top.contains(where: { containers.contains($0.kind) }) {
        let listed = top.filter { containers.contains($0.kind) }
        databases = listed.map(\.title)
        databaseNodes = Dictionary(listed.map { ($0.title, Optional($0)) }) { first, _ in first }
      } else {
        // No database level (SQLite): the file is the one database.
        let name = connection.displayName
        databases = [name]
        databaseNodes = [name: nil]
      }
      defaultDatabase = connection.database.flatMap { databases.contains($0) ? $0 : nil } ?? databases.first ?? ""
      await select(database: defaultDatabase)
      statusMessage = "Connected to \(connection.displayName)"
    } catch {
      // A failed driver connect must not leak the SSH tunnel opened for it.
      if connection.requiresTunnel { closeTunnel() }
      state = .failed(error.localizedDescription)
      statusMessage = "Connection failed: \(error.localizedDescription)"
    }
  }

  /// The DatabaseKit profile for this connection, aimed at `host:port` (as the SSH server sees it when
  /// tunneled). Shell opens its own SSH session, so the profile has none.
  private func profile(host: String, port: UInt16) -> ConnectionProfile {
    var options: [String: String] = [:]
    if let authSource = connection.authSource, !authSource.isEmpty { options["authSource"] = authSource }
    if connection.directConnection || connection.requiresTunnel { options["directConnection"] = "true" }
    let isFile = connection.engine == .sqlite
    return ConnectionProfile(
      id: connection.id, name: connection.displayName, engine: connection.engine.kind,
      host: isFile ? "" : host, port: isFile ? nil : Int(port), user: connection.username ?? "",
      database: connection.database ?? "", filePath: isFile ? connection.host : "", options: options,
      useTLS: connection.useTLS,
      // Through SSH the database is often named as the server sees it (127.0.0.1,
      // a private name), which its certificate doesn't name.
      allowUntrustedCertificate: connection.requiresTunnel)
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
    await live.close()
    self.live = nil
    databaseNodes = [:]
    objects = [:]
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
    guard live != nil, databaseNodes.keys.contains(database) else { return }
    selectedDatabase = database
    await loadCollections()
  }

  /// Lists the selected database's collections, tables and views (through schemas and folders).
  private func loadCollections() async {
    guard let live, let selectedDatabase, let node = databaseNodes[selectedDatabase] else { return }
    do {
      var found: [ObjectRef] = []
      try await collect(node, in: live, into: &found, depth: 0)
      objects = [:]
      collections = found.map { ref in
        let name = Self.displayName(of: ref)
        objects[name] = ref
        return name
      }
    } catch {
      statusMessage = error.localizedDescription
    }
  }

  private func collect(
    _ node: TreeNode?, in session: any DatabaseKit.DatabaseSession, into found: inout [ObjectRef], depth: Int
  ) async throws {
    for child in try await session.children(of: node) {
      if let ref = child.ref {
        found.append(ref)
      } else if child.hasChildren, depth < 3 {
        try await collect(child, in: session, into: &found, depth: depth + 1)
      }
    }
  }

  /// `name`, or `schema.name` outside the default schema.
  private static func displayName(of ref: ObjectRef) -> String {
    guard let schema = ref.schema, !["public", "dbo", "main", ""].contains(schema) else { return ref.name }
    return "\(schema).\(ref.name)"
  }

  /// Selects a collection/table/key space and loads its first 100 documents/rows/keys.
  func selectCollection(_ name: String) async {
    guard isConnected, let live, let ref = objects[name] else { return }
    selectedCollection = name
    do {
      let page = try await live.browse(BrowseRequest(ref: ref, limit: 100))
      let names = page.fields.map(\.name)
      documents = page.records.map { record in
        let keys = names.isEmpty ? record.values.keys.sorted() : names
        return DatabaseDocument(
          id: record.id,
          fields: keys.map { DatabaseField(name: $0, value: record.values[$0]?.displayText ?? "") })
      }
      selectedDocument = documents.first
      statusMessage = "\(documents.count) item(s) in \(name)"
    } catch {
      statusMessage = error.localizedDescription
    }
  }

  // MARK: - SSH tunnel

  /// Logs in to the connection's SSH host and resolves to a dialer for its
  /// channels plus the database's host as the SSH server sees it. The SSH
  /// session runs in forwarding-only mode (no remote shell), opens ONE
  /// authenticated connection, and carries every connection the engine makes as
  /// a `direct-tcpip` channel — no re-dial, no re-authentication, and no local
  /// port.
  ///
  /// The tunnel's lifecycle is tied to this DB connection: it is opened here
  /// and closed in `disconnect()` (or on a failed driver connect).
  private func establishTunnel() async throws -> (WireDialer, String) {
    guard let config = sshConfig() else {
      throw DatabaseConnectionTunnelError.missingSSHConfig
    }
    let target = connection.tunnelTarget(through: config)?.host ?? "127.0.0.1"
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

    let dialer: WireDialer = try await withCheckedThrowingContinuation { continuation in
      let gate = TunnelContinuationGate()
      session.onConnected = { [weak session] in
        gate.resume(continuation) { continuation in
          if let dialer = session?.dialer {
            continuation.resume(returning: dialer)
          } else {
            continuation.resume(throwing: DatabaseConnectionTunnelError.tunnelFailed("The SSH connection closed."))
          }
        }
      }
      session.onTerminated = { message in
        gate.resume(continuation) { $0.resume(throwing: DatabaseConnectionTunnelError.tunnelFailed(message)) }
      }
      session.start()
    }
    return (dialer, target)
  }

  /// Resolves this connection's saved SSH config by id, if it still exists.
  private func sshConfig() -> SSHConfig? {
    guard let sshConfigID = connection.sshConfigID else { return nil }
    return sshConfigStore?.all.first { $0.id == sshConfigID }
  }

  /// Closes the SSH session and with it every channel. Best-effort, safe to
  /// call even when no tunnel was opened.
  private func closeTunnel() {
    sshSession?.close()
    sshSession = nil
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
/// `onConnected` and `onTerminated` can race (e.g. the SSH connection drops
/// right after it connects), so only the first resumer wins.
private final class TunnelContinuationGate: @unchecked Sendable {
  private let lock = NSLock()
  private var resumed = false

  func resume(
    _ continuation: CheckedContinuation<WireDialer, Error>,
    _ body: (CheckedContinuation<WireDialer, Error>) -> Void
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
