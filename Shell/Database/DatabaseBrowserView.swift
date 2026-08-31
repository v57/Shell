import SwiftUI
import Terminal

/// The per-engine documents/tables browser shown in the detail pane for a
/// `.database` session. Reads a live `DatabaseSession` (an `@Observable`
/// `@MainActor` object) and renders whatever the selected engine returns:
/// MongoDB collections + documents, PostgreSQL/SQLite tables + rows, or Redis
/// keys + entry detail.
struct DatabaseBrowserView: View {
  let session: DatabaseSession

  @State private var pendingDisconnect = false

  var body: some View {
    VStack(spacing: 0) {
      statusBar
      Divider()
      if session.isConnected {
#if os(macOS)
        HSplitView {
          collectionsPane
            .frame(minWidth: 180, idealWidth: 220, maxWidth: 360)
          documentsPane
            .frame(minWidth: 300, maxWidth: .infinity)
        }
#else
        // iOS: no side-by-side split; stack the collections list above the
        // documents pane.
        VStack(spacing: 0) {
          collectionsPane
            .frame(height: 180)
          Divider()
          documentsPane
        }
#endif
      } else {
        ContentUnavailableView(
          "Database Disconnected",
          systemImage: "server.rack",
          description: Text(session.statusMessage.isEmpty
            ? "Select a database connection to browse it."
            : session.statusMessage)
        )
      }
    }
    .navigationTitle(session.connection.displayName)
    .navigationDatabaseSubtitle(session.connection.subtitle)
  }

  // MARK: - Status bar

  private var statusBar: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(statusColor)
        .frame(width: 8, height: 8)
      Text(statusText)
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Spacer()
      if session.isConnected {
        Button {
          pendingDisconnect = true
          Task { await session.disconnect() }
        } label: {
          Label("Disconnect", systemImage: "bolt.horizontal.circle")
        }
        .help("Disconnect this database")
      } else if case .failed = session.state {
        Button {
          Task { await session.connect(password: nil) }
        } label: {
          Label("Retry", systemImage: "arrow.clockwise")
        }
        .help("Retry the connection")
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
  }

  private var statusColor: Color {
    switch session.state {
    case .connected: return .green
    case .connecting: return .yellow
    case .disconnected: return .gray
    case .failed: return .red
    }
  }

  private var statusText: String {
    if !session.statusMessage.isEmpty { return session.statusMessage }
    switch session.state {
    case .connected: return "Connected"
    case .connecting: return "Connecting…"
    case .disconnected: return "Disconnected"
    case .failed(let message): return "Failed: \(message)"
    }
  }

  // MARK: - Collections / tables / keys pane

  private var collectionsPane: some View {
    VStack(alignment: .leading, spacing: 0) {
      if session.databases.count > 1 {
        Picker("Database", selection: Binding(
          get: { session.selectedDatabase ?? "" },
          set: { newValue in
            Task { await session.select(database: newValue) }
          }
        )) {
          ForEach(session.databases, id: \.self) { Text($0).tag($0) }
        }
        .pickerStyle(.menu)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
      }
      List(selection: Binding(
        get: { session.selectedCollection },
        set: { newValue in
          if let name = newValue {
            Task { await session.selectCollection(name) }
          }
        }
      )) {
        ForEach(session.collections, id: \.self) { name in
          Label(name, systemImage: collectionIcon)
            .tag(name)
        }
      }
      if session.collections.isEmpty {
        Text("No collections/tables/keys")
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .center)
          .padding()
      }
    }
  }

  private var collectionIcon: String {
    switch session.connection.engine {
    case .redis: return "key.fill"
    case .mongodb: return "shippingbox"
    case .postgresql, .sqlite: return "tablecells"
    }
  }

  // MARK: - Documents / rows pane

  private var documentsPane: some View {
    Group {
      if session.documents.isEmpty {
        ContentUnavailableView(
          "No Data",
          systemImage: "tray",
          description: Text("Select a collection, table, or key to see its data.")
        )
      } else {
        VStack(spacing: 0) {
          List(selection: Binding(
            get: { session.selectedDocument?.id },
            set: { _ in }
          )) {
            ForEach(session.documents) { doc in
              DocumentRow(doc: doc)
                .tag(doc.id)
            }
          }
          if let selected = session.selectedDocument {
            Divider()
            DocumentDetailView(doc: selected)
              .frame(maxHeight: 260)
          }
        }
      }
    }
  }
}

// MARK: - Row + detail

/// Availability-guarded navigation subtitle (`.navigationSubtitle` is only
/// available iOS 26 / macOS 26+). Mirrors ContentView's helper so the browser
/// shows a subtitle where the OS supports it and nothing otherwise.
private extension View {
  @ViewBuilder
  func navigationDatabaseSubtitle(_ text: String) -> some View {
    if text.isEmpty {
      self
    } else if #available(iOS 26.0, macOS 26.0, *) {
      self.navigationSubtitle(Text(text))
    } else {
      self
    }
  }
}

private struct DocumentRow: View {
  let doc: DatabaseDocument

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 6) {
        Image(systemName: "doc.text")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(summary)
          .font(.callout)
          .lineLimit(1)
        Spacer(minLength: 0)
      }
    }
    .padding(.vertical, 2)
  }

  private var summary: String {
    // Prefer a "name"-liked field for the row label, else the id.
    for field in doc.fields {
      if field.name == "name" || field.name == "key" || field.name == "_id" {
        return field.value
      }
    }
    return doc.id
  }
}

private struct DocumentDetailView: View {
  let doc: DatabaseDocument

  var body: some View {
    List {
      ForEach(doc.fields) { field in
        VStack(alignment: .leading, spacing: 2) {
          Text(field.name)
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(field.value)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
        }
        .padding(.vertical, 2)
      }
    }
  }
}
