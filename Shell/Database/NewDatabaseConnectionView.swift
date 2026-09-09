import SwiftUI
import Terminal

/// Create/edit form for a database connection. Mirrors the SSH
/// `NewConnectionView` shape: an engine picker, connection fields, and a
/// password field whose value goes straight to the Keychain (never the record).
struct NewDatabaseConnectionView: View {
  @Environment(AppModel.self) private var model
  /// The connection being edited (nil = creating a new one).
  let connection: DatabaseConnection?

  @State private var engine: DatabaseEngine
  @State private var host: String
  @State private var port: String
  @State private var database: String
  @State private var username: String
  @State private var password: String = ""
  @State private var authSource: String
  @State private var directConnection: Bool
  @State private var authorizationEnabled = false
  @State private var sshConfigID: UUID?

  /// Password loaded for an edit, so the field shows a non-empty value when a
  /// credential already exists (re-saving would otherwise clear it).
  private let savedPassword: String?
  private let isEditing: Bool

  init(connection: DatabaseConnection?, savedPassword: String? = nil, presetSSHConfigID: UUID? = nil) {
    self.connection = connection
    self.savedPassword = savedPassword
    self.isEditing = connection != nil
    let c = connection
    // Seed the engine first so host/port defaults can reference its defaultPort.
    let chosenEngine = c?.engine ?? .mongodb
    _engine = State(initialValue: chosenEngine)
    // Network engines default the host to "localhost"; SQLite is file-based and
    // starts with an empty file-path field instead.
    _host = State(initialValue: c?.host ?? (chosenEngine == .sqlite ? "" : "localhost"))
    _port = State(initialValue: c.map { String($0.port) } ?? String(chosenEngine.defaultPort))
    _database = State(initialValue: c?.database ?? "")
    _username = State(initialValue: c?.username ?? "")
    _authSource = State(initialValue: c?.authSource ?? "")
    _directConnection = State(initialValue: c?.directConnection ?? false)
    _authorizationEnabled = State(initialValue: Self.hasAnyAuth(c, savedPassword: savedPassword))
    _sshConfigID = State(initialValue: c?.sshConfigID ?? presetSSHConfigID)
  }

  /// Whether an existing connection carries any configured auth (a non-empty
  /// username or auth source, or a saved Keychain password) — used to seed the
  /// Authorization toggle on for edits, while new connections start OFF.
  private static func hasAnyAuth(_ c: DatabaseConnection?, savedPassword: String?) -> Bool {
    guard let c = c else { return false }
    return c.username?.isEmpty == false || c.authSource?.isEmpty == false || savedPassword != nil
  }

  private var title: String { isEditing ? "Edit Database Connection" : "New Database Connection" }

  var body: some View {
    @Bindable var model = model
    VStack(alignment: .leading, spacing: 0) {
      Form {
        Section("Engine") {
          Picker("Engine", selection: $engine) {
            ForEach(DatabaseEngine.allCases) { e in
              Text(e.displayName).tag(e)
            }
          }
          .pickerStyle(.menu)
          // A new connection's port follows the engine's default port. Only
          // reset when the user hasn't typed a custom port (i.e. the field still
          // holds the previous engine's default).
          .onChange(of: engine) { oldEngine, newEngine in
            guard !isEditing else { return }
            if port == String(oldEngine.defaultPort) {
              port = String(newEngine.defaultPort)
            }
          }
          // Engines that don't link on this platform can't connect; grey the
          // picker setting rather than allow a doomed selection.
          if !engine.isAvailable {
            Text("\(engine.displayName) is not available on this platform.")
              .font(.caption)
              .foregroundStyle(.orange)
          }
        }

        Section("Connection") {
          TextField(engine == .sqlite ? "File Path" : "Host", text: $host)
            .autocorrectionDisabled()
          if engine != .sqlite {
            TextField("Port", text: $port)
              .textContentType(.none)
          }
          TextField(isEditing ? "Database (leave blank for default)" : "Database", text: $database)
          // Authorization is gated on a switch (SQLite is file-based and uses
          // no credentials). Off by default for new connections.
          if engine != .sqlite {
            Toggle("Authorization", isOn: $authorizationEnabled)
              .onChange(of: authorizationEnabled) { _, enabled in
                // Hidden fields reset when the toggle is turned off.
                if !enabled {
                  username = ""
                  authSource = ""
                  directConnection = false
                }
              }
          }
          if authorizationEnabled {
            TextField("Username", text: $username)
              .autocorrectionDisabled()
            SecureField("Password (Keychain)", text: $password)
            if engine == .mongodb {
              TextField("Auth Source (admin)", text: $authSource)
              Toggle("Direct connection", isOn: $directConnection)
            }
          }
        }

        Section("Tunnel") {
          Picker("SSH Tunnel", selection: $sshConfigID) {
            Text("None").tag(UUID?.none)
            ForEach(model.connections) { config in
              Text(config.displayName).tag(Optional(config.id))
            }
          }
          .pickerStyle(.menu)
          Text("Remote (non-SQLite) connections route through the selected SSH tunnel; SQLite is always local.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)

      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(isEditing ? "Save" : "Add") { commit() }
          .keyboardShortcut(.defaultAction)
          .disabled(!isValid)
      }
      .padding()
    }
    .frame(minWidth: 420, minHeight: 460)
    .navigationTitle(title)
  }

  private var isValid: Bool {
    guard !host.isEmpty else { return false }
    if engine == .sqlite { return true }
    return !port.isEmpty && (Int(port) ?? 0) > 0
  }

  private func dismiss() {
    model.editingDatabaseConnection = nil
    model.showingNewDatabaseConnection = false
  }

  private func commit() {
    let connection: DatabaseConnection
    if let existing = self.connection {
      connection = DatabaseConnection(
        id: existing.id,
        engine: engine,
        name: existing.name,
        host: host,
        port: UInt16(Int(port) ?? Int(engine.defaultPort)),
        database: database.isEmpty ? nil : database,
        username: authorizationEnabled && !username.isEmpty ? username : nil,
        authSource: authorizationEnabled && !authSource.isEmpty ? authSource : nil,
        directConnection: authorizationEnabled && directConnection,
        sshConfigID: sshConfigID
      )
    } else {
      connection = DatabaseConnection(
        engine: engine,
        name: engine.displayName,
        host: host,
        port: UInt16(Int(port) ?? Int(engine.defaultPort)),
        database: database.isEmpty ? nil : database,
        username: authorizationEnabled && !username.isEmpty ? username : nil,
        authSource: authorizationEnabled && !authSource.isEmpty ? authSource : nil,
        directConnection: authorizationEnabled && directConnection,
        sshConfigID: sshConfigID
      )
    }
    model.saveDatabaseConnection(connection, password: password.isEmpty ? savedPassword : password)
    dismiss()
    // Open the browser immediately after a fresh add; an edit keeps the row.
    if !isEditing {
      model.openOrFocusDatabaseConnection(connection)
    }
  }
}
