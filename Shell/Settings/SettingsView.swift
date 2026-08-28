import SwiftUI

/// The Settings screen.
///
/// Hosts two cards:
/// - **Features** — the feature-flags panel (`FeatureSelectionView`), a passive
///   list of every toggleable Shell feature.
/// - **Actions** — the shell actions surfaced here so they're reachable on iOS
///   (macOS reaches the same actions through the Shell menu). Each row calls the
///   same `AppModel` method as its menu counterpart.
///
/// Presented two ways:
/// - **macOS** — as the `Settings` scene (⌘, / Shell > Settings…), registered
///   in `ShellApp`; the platform provides the window and the keyboard shortcut.
/// - **iOS** — as a `.sheet` opened from the sidebar gear button (`SidebarView`);
///   there is no menu bar on iOS, so the gear is the only entry point.
struct SettingsView: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    #if os(iOS)
    NavigationStack {
      settingsContent
        .navigationTitle("Settings")
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
          }
        }
    }
    #else
    settingsContent
    #endif
  }

  private var settingsContent: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        SettingsCard(title: "Features", systemImage: "square.grid.2x2") {
          FeatureSelectionView()
        }
        SettingsCard(title: "Actions", systemImage: "bolt") {
          SettingsActionsCard()
        }
      }
      .padding(20)
      .frame(maxWidth: 560, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
  }
}

/// A rounded card: an icon + title header and a labelled body. Cross-platform
/// (no UIKit-typed colors) so it renders in the macOS Settings scene AND the
/// iOS sheet.
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

/// The "Actions" card: every shell action reachable on macOS through the Shell
/// menu but with no dedicated control on iOS. Each row invokes the same
/// `AppModel` method as its menu counterpart.
///
/// NOTE: the macOS Shell menu stays the macOS entry point (it is NOT trimmed);
/// these rows make the same actions reachable on iOS where there is no menu
/// bar. If you add a row, call the exact `AppModel` method the menu item calls.
private struct SettingsActionsCard: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    VStack(spacing: 0) {
      actionRow("Actions…", systemImage: "folder") {
        model.showingActions = true
      }
      Divider()
      actionRow("Create Action from Session", systemImage: "calendar.badge.plus",
                disabled: !model.canCreateActionFromCurrentSession) {
        model.createActionFromCurrentSession()
      }
      Divider()
      actionRow("Insert into Terminal…", systemImage: "arrow.down.to.line",
                disabled: model.selectedSession == nil) {
        model.showingCommandInsert = true
      }
      Divider()
      actionRow("Themes…", systemImage: "paintpalette") {
        model.showingThemes = true
      }
      Divider()
      actionRow("Toggle Files Panel", systemImage: "sidebar.left",
                disabled: model.selectedSession == nil) {
        model.directoryBrowser.visible.toggle()
      }
      Divider()
      actionRow("Navigate Up", systemImage: "arrow.up.to.line",
                disabled: model.selectedSession == nil || !model.directoryBrowser.canNavigateUp) {
        model.directoryBrowser.navigateUp()
      }
      Divider()
      actionRow("Copy SSH Public Key", systemImage: "key") {
        model.copyPublicKey()
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
