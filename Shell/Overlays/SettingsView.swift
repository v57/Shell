import SwiftUI

/// The Settings panel — an in-window overlay (like `ActionsOverlayView`), NOT
/// a separate window or a `.sheet`, so it appears/closes instantly over the
/// main window.
///
/// Hosts these cards:
/// - **Sessions** (macOS) — how new terminals start (`SettingsSessionsCard`).
/// - **Features** — the feature-flags panel (`FeatureSelectionView`).
/// - **Actions** — the shell actions surfaced here so they're reachable on iOS
///   (macOS reaches the same actions through the Shell menu).
///
/// Presented the same way on macOS and iOS: a non-modal overlay over the main
/// window (Backdrop click or Esc closes it). On macOS the Shell menu's
/// Settings…/⌘, entry point sets `AppModel.showingSettings`; on iOS the sidebar
/// gear button does the same.
struct SettingsView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("Settings").font(.headline)
        Spacer()
        Button {
          model.showingSettings = false
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .help("Close (Esc)")
      }
      .padding(.top, 12)

      ScrollView {
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
        .padding(.vertical, 12)
      }
    }
    .frame(width: 480, height: 420)
    .safeAreaPadding(.horizontal, 12)
    .background {
      RoundedRectangle(cornerRadius: 16).fill(.background)
        .strokeBorder(.quaternary).shadow(radius: 32, y: 8)
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
/// The "Sessions" card: whether new terminals start as persistent sessions.
/// Persistent sessions are the Screen feature's, so the toggle is off and
/// disabled while that feature is.
private struct SettingsSessionsCard: View {
  @Environment(AppModel.self) private var model
  private var flags: FeatureFlagsStore { .shared }

  var body: some View {
    let available = flags.isEnabled(.sessions) && flags.isEnabled(.screen)
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
