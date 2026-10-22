import ComponentKit
import ShellIntegrations
import SwiftUI

/// The Settings panel: the kit's sheet over the main window (`kitSheet` in
/// ContentView), never a separate window or a system sheet.
///
/// Hosts these cards:
/// - **Sessions** (macOS) — how new terminals start (`SettingsSessionsCard`).
/// - **Features** — the feature-flags panel (`FeatureSelectionView`).
/// - **Actions** — the shell actions surfaced here so they're reachable on iOS
///   (macOS reaches the same actions through the Shell menu).
///
/// Presented the same way on macOS and iPad: a card over the dimmed window (a
/// click on the dim, Esc or its close button closes it); a system sheet on
/// iPhone. On macOS the Shell menu's Settings…/⌘, entry point sets
/// `AppModel.showingSettings`; on iOS the sidebar gear button does the same.
struct SettingsView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    KitSheet(
      title: "Settings", systemImage: "gearshape", hue: .gray, width: 480,
      onClose: { model.showingSettings = false }
    ) {
      VStack(alignment: .leading, spacing: 20) {
        #if os(macOS) || os(Windows)
        SettingsCard(title: "Sessions", systemImage: "terminal") {
          SettingsSessionsCard()
        }
        #endif
        SettingsCard(title: "Features", systemImage: "square.grid.2x2") {
          FeatureSelectionView()
        }
        SettingsCard(title: "Actions", systemImage: "bolt") {
          SettingsActionsCard()
        }
      }
      .padding(.horizontal, 4)
    }
  }
}

/// A rounded card: an icon + title header and a labelled body. Cross-platform
/// (no UIKit-typed colors) so it renders in the Settings overlay.
private struct SettingsCard<Content: View>: View {
  let title: String
  let systemImage: String
  let content: Content

  init(title: String, systemImage: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.systemImage = systemImage
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label(title, systemImage: systemImage)
        .font(.headline)
      content
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color.secondary.opacity(0.12))
    }
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(Color.secondary.opacity(0.25))
    }
  }
}

#if os(macOS) || os(Windows)
/// The "Sessions" card: whether new terminals start as persistent sessions
/// (and, on the Mac, whether they outlive Shell: `SessionAgentRow`).
/// Persistent sessions are the Screen feature's, so the toggle is off and
/// disabled while that feature is.
private struct SettingsSessionsCard: View {
  @Environment(AppModel.self) private var model
  private var flags: FeatureFlagsStore { .shared }

  var body: some View {
    let available = flags.isEnabled(.sessions) && flags.isEnabled(.screen)
    VStack(alignment: .leading, spacing: 0) {
      Toggle(isOn: Binding(
        get: { available && model.alwaysPersistentSessions },
        set: { model.alwaysPersistentSessions = $0 }
      )) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Always Start Persistent Sessions")
          Text(available
               ? "New terminals keep running after you close them; reopen them from the sidebar"
               : "Turn on Sessions and Screen sessions under Features to use this")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .toggleStyle(.switch)
      .disabled(!available)
      .padding(.vertical, 6)
      #if os(macOS)
      Divider()
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
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Keep Sessions Running After Quit")
        Text(caption)
          .font(.caption)
          .foregroundStyle(.secondary)
        if let error = agent.errorMessage {
          Text(error)
            .font(.caption)
            .foregroundStyle(.red)
            .textSelection(.enabled)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if agent.isWorking {
        ProgressView().controlSize(.small)
      } else {
        action
      }
    }
    .padding(.vertical, 6)
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

/// The "Actions" card: every shell action reachable on macOS through the Shell
/// menu but with no dedicated control on iOS. Each row invokes the same
/// `AppModel` method as its menu counterpart.
///
/// NOTE: the macOS Shell menu stays the macOS entry point (it is NOT trimmed);
/// these rows make the same actions reachable on iOS where there is no menu
/// bar. If you add a row, call the exact `AppModel` method the menu item calls.
private struct SettingsActionsCard: View {
  @Environment(AppModel.self) private var model
  private var flags: FeatureFlagsStore { .shared }

  private struct Row: Identifiable {
    let title: String
    let systemImage: String
    var disabled = false
    let action: () -> Void
    var id: String { title }
  }

  /// The rows whose feature is on: a disabled feature's actions are hidden
  /// here exactly like its menu items.
  private var rows: [Row] {
    var rows: [Row] = []
    if flags.isEnabled(.ssh) {
      rows.append(Row(title: "New Connection", systemImage: "plus") {
        model.showingNewConnection = true
      })
    }
    if flags.isEnabled(.actions) {
      rows.append(Row(title: "Actions…", systemImage: "folder") {
        model.showingActions = true
      })
      rows.append(Row(title: "Create Action from Session", systemImage: "calendar.badge.plus",
                      disabled: !model.canCreateActionFromCurrentSession) {
        model.createActionFromCurrentSession()
      })
    }
    rows.append(Row(title: "Insert into Terminal…", systemImage: "arrow.down.to.line",
                    disabled: model.selectedSession == nil) {
      model.showingCommandInsert = true
    })
    rows.append(Row(title: "Themes…", systemImage: "paintpalette") {
      model.showingThemes = true
    })
    if flags.isEnabled(.files) {
      rows.append(Row(title: "Toggle Files Panel", systemImage: "sidebar.left",
                      disabled: model.selectedSession == nil) {
        model.directoryBrowser.visible.toggle()
      })
      rows.append(Row(title: "Navigate Up", systemImage: "arrow.up.to.line",
                      disabled: model.selectedSession == nil || !model.directoryBrowser.canNavigateUp) {
        model.directoryBrowser.navigateUp()
      })
    }
    if flags.isEnabled(.ssh) {
      rows.append(Row(title: "Copy SSH Public Key", systemImage: "key") {
        model.copyPublicKey()
      })
    }
    if flags.isEnabled(.authorizedKeys) {
      rows.append(Row(title: "Authorized Keys", systemImage: "key.2.on.ring") {
        model.openLocalAuthorizedKeys()
      })
    }
    return rows
  }

  var body: some View {
    VStack(spacing: 0) {
      ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
        if index > 0 { Divider() }
        actionRow(row.title, systemImage: row.systemImage, disabled: row.disabled, action: row.action)
      }
    }
  }

  private func actionRow(
    _ title: String,
    systemImage: String,
    disabled: Bool = false,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Label(title, systemImage: systemImage)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(disabled)
    .foregroundStyle(disabled ? Color.secondary : Color.primary)
  }
}
