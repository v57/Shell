import ComponentKit
import ShellIntegrations
import SwiftUI
import VaultUI

/// The Settings panel: the kit's settings (`KitSettings`, the panes in its sidebar, each a column of form cards, as in
/// every v57 app) in the kit's overlay over the main window (`kitSheet` in ContentView), never a separate window or a
/// system sheet. A click on the dim or Esc closes it; on iPhone the panes are rows that push, with Done in the bar.
///
/// Panes:
/// - **Sessions** (desktop) — how new terminals start (`SessionsSettings`).
/// - **Features** — the feature flags (`FeatureSelectionView`).
/// - **Actions** — the shell actions, reachable here on iOS (macOS reaches the same actions through the Shell menu).
/// - **Accounts** — the v57 accounts, the same pane in every app (`VaultAccountsSettings`; the account picker's
///   Manage Accounts… opens it).
///
/// On macOS the Shell menu's Settings…/⌘, sets `AppModel.showingSettings`; on iOS the sidebar gear button does the same.
struct SettingsView: View {
  /// The pane shown, kept for the next time Settings opens.
  static let paneKey = "settings.pane"
  static let accountsPane = "accounts"

  @AppStorage(SettingsView.paneKey) private var pane = ""
  @Environment(AppModel.self) private var model
  @Environment(\.kitIdiom) private var idiom
  private var flags: FeatureFlagsStore { .shared }

  var body: some View {
    Group {
      if idiom == .phone {
        // A pane pushes on the stack around the settings.
        NavigationStack {
          settings
            .kitToolbar("Settings", systemImage: "gearshape", hue: .gray) {
              Button("Done") { model.showingSettings = false }.buttonStyle(.kit)
            }
        }
      } else {
        settings
      }
    }
    .frame(maxWidth: idiom == .phone ? .infinity : 680, maxHeight: idiom == .phone ? .infinity : 500)
  }

  private var settings: some View {
    KitSettings(selection: $pane, window: .titled) {
      #if os(macOS) || os(Windows) || os(Linux)
      SettingsPane("Sessions", systemImage: "terminal", hue: .gray, id: "sessions") { SessionsSettings() }
      #endif
      SettingsPane(
        "Features", systemImage: "square.grid.2x2", hue: .blue,
        value: "\(FeatureID.available.filter(flags.isEnabled).count) on", id: "features"
      ) {
        FeatureSelectionView(
          footer: "Turned-off features are hidden and stop their background work; their data is kept.")
      }
      SettingsPane("Actions", systemImage: "bolt", hue: .purple, id: "actions") { ActionsSettings() }
      SettingsPane("Accounts", systemImage: "person.2", hue: .indigo, section: "v57", id: Self.accountsPane) {
        VaultAccountsSettings()
      }
    }
    .toggleStyle(.kitSwitch)
  }
}

#if os(macOS) || os(Windows) || os(Linux)
/// Settings › Sessions: whether new terminals start as persistent sessions (and, on the Mac, whether they outlive
/// Shell: `SessionAgentRow`). Persistent sessions are the Screen feature's, so the switch is off and disabled while
/// that feature is.
private struct SessionsSettings: View {
  @Environment(AppModel.self) private var model
  private var flags: FeatureFlagsStore { .shared }

  var body: some View {
    let available = flags.isEnabled(.sessions) && flags.isEnabled(.screen)
    FormCard {
      FormRow(
        "Always Start Persistent Sessions",
        help: available
          ? "New terminals keep running after you close them; reopen them from the sidebar"
          : "Turn on Sessions and Screen sessions under Features to use this",
        systemImage: "rectangle.stack", hue: .teal
      ) {
        Toggle("Always Start Persistent Sessions", isOn: Binding(
          get: { available && model.alwaysPersistentSessions },
          set: { model.alwaysPersistentSessions = $0 }
        ))
        .kitLabelsHidden()
        .disabled(!available)
      }
      #if os(macOS)
      SessionAgentRow()
      #endif
    }
  }
}
#endif

#if os(macOS)
/// Whether the `session` tool's sessions outlive Shell: its daemon's LaunchAgent (`SessionAgentModel`), with the
/// one action its state calls for.
private struct SessionAgentRow: View {
  @Environment(AppModel.self) private var model
  @State private var confirmingRemove = false

  private var agent: SessionAgentModel { model.sessionAgent }

  var body: some View {
    FormRow(
      "Keep Sessions Running After Quit", help: caption, systemImage: "moon.zzz", hue: .indigo,
      error: agent.errorMessage
    ) {
      if agent.isWorking {
        LiveIcon(systemImage: "gearshape.2", hue: .indigo, status: .working, size: 20)
      } else {
        action.buttonStyle(.kit)
      }
    }
    .kitConfirmation(
      "Remove the login item?", isPresented: $confirmingRemove,
      message: "Sessions running now end, and new ones end when Shell quits.", systemImage: "person.badge.minus",
      confirm: "Remove"
    ) { agent.remove() }
  }

  private var caption: String {
    guard agent.isAvailable else { return "Needs the session tool (v57.dev/install/session)" }
    switch agent.status {
    case nil: return "Checking…"
    case .notInstalled: return "Sessions end when Shell quits; a login item keeps the session daemon running"
    case .outdated: return "The login item runs a session that is no longer installed"
    case .needsApproval: return "The login item is off in Login Items & Extensions"
    case .stopped: return "The login item is on, but the session daemon isn't running"
    case .waiting: return "Takes over when Shell quits; the sessions running now end then"
    case .running: return "Sessions keep running after Shell quits"
    }
  }

  @ViewBuilder private var action: some View {
    switch agent.status {
    case .notInstalled: Button("Install") { agent.install() }
    case .outdated: Button("Update") { agent.install() }
    case .needsApproval: Button("Open Login Items") { agent.openLoginItems() }
    case .stopped: Button("Start") { agent.start() }
    case .running: Button("Remove") { confirmingRemove = true }
    case .waiting, nil: EmptyView()
    }
  }
}
#endif

/// Settings › Actions: every shell action reachable on macOS through the Shell menu but with no dedicated control on
/// iOS, a row each with its button. Each row invokes the same `AppModel` method as its menu counterpart.
///
/// NOTE: the macOS Shell menu stays the macOS entry point (it is NOT trimmed); these rows make the same actions
/// reachable on iOS where there is no menu bar. If you add a row, call the exact `AppModel` method the menu item calls.
private struct ActionsSettings: View {
  @Environment(AppModel.self) private var model
  private var flags: FeatureFlagsStore { .shared }

  private struct Row: Identifiable {
    let title: String
    let systemImage: String
    let hue: Hue
    let button: String
    var disabled = false
    let action: () -> Void
    var id: String { title }
  }

  /// The rows whose feature is on: a disabled feature's actions are hidden here exactly like its menu items.
  private var rows: [Row] {
    var rows: [Row] = []
    if flags.isEnabled(.ssh) {
      rows.append(Row(title: "New Connection", systemImage: "plus", hue: .blue, button: "New…") {
        model.showingNewConnection = true
      })
    }
    if flags.isEnabled(.actions) {
      rows.append(Row(title: "Actions", systemImage: "folder", hue: .purple, button: "Show") {
        model.showingActions = true
      })
      rows.append(Row(title: "Create Action from Session", systemImage: "calendar.badge.plus", hue: .purple,
                      button: "Create", disabled: !model.canCreateActionFromCurrentSession) {
        model.createActionFromCurrentSession()
      })
    }
    rows.append(Row(title: "Insert into Terminal", systemImage: "arrow.down.to.line", hue: .gray, button: "Insert…",
                    disabled: model.selectedSession == nil) {
      model.showingCommandInsert = true
    })
    rows.append(Row(title: "Themes", systemImage: "paintpalette", hue: .pink, button: "Show") {
      model.showingThemes = true
    })
    if flags.isEnabled(.files) {
      rows.append(Row(title: "Files Panel", systemImage: "sidebar.left", hue: .teal,
                      button: model.directoryBrowser.visible ? "Hide" : "Show",
                      disabled: model.selectedSession == nil) {
        model.directoryBrowser.visible.toggle()
      })
      rows.append(Row(title: "Navigate Up", systemImage: "arrow.up.to.line", hue: .teal, button: "Go Up",
                      disabled: model.selectedSession == nil || !model.directoryBrowser.canNavigateUp) {
        model.directoryBrowser.navigateUp()
      })
    }
    if flags.isEnabled(.ssh) {
      rows.append(Row(title: "SSH Public Key", systemImage: "key", hue: .brown, button: "Copy") {
        model.copyPublicKey()
      })
    }
    if flags.isEnabled(.authorizedKeys) {
      rows.append(Row(title: "Authorized Keys", systemImage: "key.2.on.ring", hue: .brown, button: "Show") {
        model.openLocalAuthorizedKeys()
      })
    }
    return rows
  }

  var body: some View {
    FormCard {
      ForEach(rows) { row in
        FormRow(row.title, systemImage: row.systemImage, hue: row.hue) {
          Button(row.button, action: row.action).buttonStyle(.kit)
        }
        .disabled(row.disabled)
      }
    }
  }
}
