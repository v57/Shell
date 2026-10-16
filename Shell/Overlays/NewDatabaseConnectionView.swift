import ComponentKit
import SwiftUI
import ShellKit

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
    KitSheet(
      title: title, meta: summary, systemImage: "cylinder.split.1x2", hue: .indigo, width: 480
    ) {
      ScrollView {
        VStack(alignment: .leading, spacing: KitMetrics.gutter) {
          FormCard("Engine") {
            FormRow(
              "Engine", help: engine.isAvailable ? nil : "Not available on this platform",
              systemImage: engine.systemImage, hue: engine.isAvailable ? .indigo : .orange
            ) {
              KitPicker("Engine", selection: $engine, options: DatabaseEngine.allCases.map { ($0.displayName, $0) })
                .fixedSize()
            }
            // A new connection's port follows the engine's default port. Only
            // reset when the user hasn't typed a custom port (i.e. the field still
            // holds the previous engine's default).
            .onChange(of: engine) { oldEngine, newEngine in
              guard !isEditing else { return }
              if port == String(oldEngine.defaultPort) {
                port = String(newEngine.defaultPort)
              }
            }
          }

          FormCard("Connection") {
            FormRow(
              engine == .sqlite ? "File Path" : "Host", systemImage: engine == .sqlite ? "doc" : "server.rack",
              field: TextField(engine == .sqlite ? "/path/to/database.sqlite" : "localhost", text: $host)
                .autocorrectionDisabled()
            )
            if engine != .sqlite {
              FormRow("Port", systemImage: "number", field: TextField(String(engine.defaultPort), text: $port))
            }
            FormRow(
              "Database", help: isEditing ? "Leave blank for the default" : nil, systemImage: "tray.2",
              field: TextField("Default", text: $database)
            )
            // Authorization is gated on a switch (SQLite is file-based and uses
            // no credentials). Off by default for new connections.
            if engine != .sqlite {
              FormRow("Authorization", help: "A user name and password", systemImage: "person.badge.key") {
                Toggle("Authorization", isOn: $authorizationEnabled)
                  .toggleStyle(.kitSwitch)
                  .kitLabelsHidden()
              }
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
              FormRow(
                "Username", systemImage: "person",
                field: TextField("Username", text: $username).autocorrectionDisabled())
              FormRow(
                "Password", help: "Kept in the Keychain", systemImage: "key",
                field: SecureField("Password", text: $password))
              if engine == .mongodb {
                FormRow("Auth Source", systemImage: "building.columns", field: TextField("admin", text: $authSource))
                FormRow("Direct Connection", systemImage: "arrow.right") {
                  Toggle("Direct connection", isOn: $directConnection)
                    .toggleStyle(.kitSwitch)
                    .kitLabelsHidden()
                }
              }
            }
          }

          FormCard(
            "Tunnel",
            footer: "Remote (non-SQLite) connections route through the selected SSH tunnel; SQLite is always local."
          ) {
            FormRow("SSH Tunnel", systemImage: "network") {
              KitPicker(
                "SSH Tunnel", selection: $sshConfigID,
                options: [("None", UUID?.none)] + model.connections.map { ($0.displayName, Optional($0.id)) }
              )
              .fixedSize()
            }
          }
        }
        .padding(.bottom, 2)
      }
      .scrollBounceBehavior(.basedOnSize)
      .frame(maxHeight: 520)
    } footer: {
      Button("Cancel") { dismiss() }
        .keyboardShortcut(.cancelAction)
      Button(isEditing ? "Save" : "Add") { commit() }
        .buttonStyle(.kitPrimary)
        .keyboardShortcut(.defaultAction)
        .disabled(!isValid)
    }
    .navigationTitle(title)
  }

  /// The header's line: what the connection will reach.
  private var summary: String {
    if engine == .sqlite { return host.isEmpty ? "SQLite file" : "SQLite at \(host)" }
    let target = host.isEmpty ? engine.displayName : "\(engine.displayName) on \(host):\(port)"
    if let id = sshConfigID, let config = model.connections.first(where: { $0.id == id }) {
      return "\(target) through \(config.displayName)"
    }
    return target
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
