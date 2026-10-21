import ComponentKit
import SwiftUI
import ShellMonitoring

/// The sidebar's SHARED state: what its sections and its own presentation need,
/// in ONE object. `SidebarView` owns a `@State` instance and hands it to the
/// sections and to `.sidebarChrome(_:)`; every per-section state stays in its
/// section.
@Observable
final class SidebarState {
  /// The bottom bar's filter: rows whose name doesn't contain it are hidden.
  var searchText = ""

  /// Whether a row named `name` passes the filter.
  func matches(_ name: String) -> Bool {
    let query = searchText.trimmingCharacters(in: .whitespaces)
    return query.isEmpty || name.localizedCaseInsensitiveContains(query)
  }

  /// The session currently being renamed (shows an inline text field). SHARED:
  /// both the Local and the Remote section rename session rows in place.
  var renamingSessionID: UUID?

  /// Whether the session `id` is being renamed, as the binding `.kitRename` takes.
  func isRenamingSession(_ id: UUID) -> Binding<Bool> {
    Binding(
      get: { self.renamingSessionID == id },
      set: { renaming in
        if renaming {
          self.renamingSessionID = id
        } else if self.renamingSessionID == id {
          self.renamingSessionID = nil
        }
      })
  }

  /// The database connection being renamed (drives the rename sheet), and the
  /// text field's draft value, pre-filled with the connection's display name.
  /// SHARED: database rows render in both the Local and the Remote section.
  var renamingDatabaseConnection: DatabaseConnection?
  var databaseRenameText = ""
  /// The database connection whose Delete… awaits confirmation.
  var deletingDatabaseConnection: DatabaseConnection?

  #if os(macOS) || os(Windows)
  /// Live CPU/GPU/wattage for the Local section header (macOS only — the reads
  /// need IOKit's AppleSMC / IOAccelerator).
  ///
  /// Owned by the sidebar rather than by `LocalSectionView` because its
  /// LIFETIME belongs to the sidebar: `SidebarChrome` starts it while the
  /// Monitoring feature is on and stops it the moment the feature flips off, and
  /// a lazy section's own onAppear/onDisappear also fire when it scrolls out of
  /// view — which must not stop the sampling. `LocalSectionView` only RENDERS
  /// it.
  let statsMonitor = SystemStatsMonitor()
  /// The stats graphs sheet, opened by clicking the Local section header.
  var showingStatsGraphs = false
  #endif

  /// Opens the database rename sheet pre-filled with the connection's current
  /// name (or its display name fallback).
  func beginRenameDatabase(_ connection: DatabaseConnection) {
    databaseRenameText = connection.displayName
    renamingDatabaseConnection = connection
  }

  /// Applies a database rename (empty input resets to the engine display name)
  /// and dismisses the sheet.
  func commitRenameDatabase(_ connection: DatabaseConnection, in model: AppModel) {
    model.renameDatabaseConnection(connection, to: databaseRenameText)
    renamingDatabaseConnection = nil
  }
}

/// What the sidebar DOES around its sections, as ONE modifier:
///
///  - the selection routing (`onChange(of: model.selection)`), which turns a
///    clicked row's `Selection` into a connect/attach/open action;
///  - the sheets and alerts whose STATE is shared by more than one section (the
///    web-session editor, the database rename sheet, the authorized-keys panel);
///  - the live-stats monitor's lifetime (`SidebarState.statsMonitor`).
struct SidebarChrome: ViewModifier {
  @Environment(AppModel.self) private var model
  /// The sidebar's shared state (see `SidebarState`).
  let state: SidebarState

  /// The feature-flag source of truth. Reads `.isEnabled(_:)` here so a
  /// disabled feature's rows/sections vanish from the sidebar. Accessing it
  /// through `@Observable` re-renders the sidebar when a flag flips.
  private var flags: FeatureFlagsStore { .shared }

  func body(content: Content) -> some View {
    @Bindable var model = model
    @Bindable var state = state
    content
      // Clicking a row writes its `Selection`; AppModel routes it to the item
      // (connect / attach / open / focus) — the section views only tag rows.
      .onChange(of: model.selection) { _, newValue in
        if state.renamingSessionID != nil { state.renamingSessionID = nil }
        guard let selection = newValue else { return }
        model.activate(selection)
      }
      .navigationTitle("Terminals")
      // Drive the history-mode → terminals swap with a blur-replace transition
      // (both branches carry .transition(.blurReplace)).
      .animation(.kit, value: model.historyMode)
      #if os(macOS) || os(Windows)
      .alert(item: $model.screenMonitor.actionError) { error in
        Alert(
          title: Text(error.title),
          message: Text(error.message),
          dismissButton: .default(Text("OK"))
        )
      }
      #endif
      // The authorized-keys panel (key.2.on.ring in the Local/Remote
      // headers); opens for this Mac or the selected SSH connection.
      .sheet(isPresented: $model.showingAuthorizedKeys) {
        if let target = model.authorizedKeysTarget, flags.isEnabled(.authorizedKeys) {
          AuthorizedKeysView(target: target)
            .environment(model)
        }
      }
      // The Edit… action on a saved web session: the same form as new,
      // prefilled, saving in place (same id).
      .sheet(item: $model.editingWebSession) { web in
        NewWebSessionView(web: web)
      }
      // The Rename… action on a database connection: a small sheet with a
      // TextField pre-filled with the connection's current name/display name.
      // Empty input resets to the engine display name.
      .sheet(item: $state.renamingDatabaseConnection) { connection in
        DatabaseRenameSheet(
          connection: connection,
          text: $state.databaseRenameText,
          onCommit: { state.commitRenameDatabase(connection, in: model) },
          onCancel: { state.renamingDatabaseConnection = nil }
        )
        .environment(model)
      }
      .kitConfirmation(
        "Delete “\(state.deletingDatabaseConnection?.displayName ?? "")”?",
        isPresented: Binding(
          get: { state.deletingDatabaseConnection != nil }, set: { if !$0 { state.deletingDatabaseConnection = nil } }),
        message: "This removes the saved connection, its password and its saved queries from every v57 app. The database itself isn't touched.",
        systemImage: "trash", confirm: "Delete Connection"
      ) {
        if let connection = state.deletingDatabaseConnection { model.deleteDatabaseConnection(connection) }
        state.deletingDatabaseConnection = nil
      }
      .alert("Authorized Keys", isPresented: Binding(
        get: { model.authorizedKeysError != nil },
        set: { if !$0 { model.authorizedKeysError = nil } }
      )) {
        Button("OK", role: .cancel) { model.authorizedKeysError = nil }
      } message: {
        Text(model.authorizedKeysError ?? "")
      }
      #if os(macOS) || os(Windows)
      #if os(macOS)
      .background {
        // The observer owns the enable-state policy: it starts the monitor when
        // the Monitoring feature is on and stops it the moment the feature is
        // toggled off (and never restarts it while disabled). Always installed
        // so the enable toggle is handled here rather than by view teardown.
        WindowStatsObserver(monitor: state.statsMonitor, enabled: monitoringEnabled)
      }
      #endif
      .onAppear {
        if monitoringEnabled { state.statsMonitor.start() }
      }
      .onDisappear { state.statsMonitor.stop() }
      // Stats graphs for the last minute, opened from the Local header.
      .sheet(isPresented: $state.showingStatsGraphs) {
        StatsGraphView(monitor: state.statsMonitor)
      }
      #endif
  }

  #if os(macOS) || os(Windows)
  /// Whether the Monitoring feature is on — gates the live stats monitor so
  /// it never samples when the feature is off.
  private var monitoringEnabled: Bool {
    flags.isEnabled(.monitoring)
  }
  #endif
}

extension View {
  /// Applies the sidebar's shared behavior (selection routing, sheets, alerts,
  /// the live-stats monitor) — see `SidebarChrome`.
  func sidebarChrome(_ state: SidebarState) -> some View {
    modifier(SidebarChrome(state: state))
  }
}
