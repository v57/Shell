import SwiftUI

/// The Settings panel — an in-window overlay (like `ActionsOverlayView`), NOT
/// a separate window or a `.sheet`, so it appears/closes instantly over the
/// main window.
///
/// Hosts two cards:
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
      actionRow("New Connection", systemImage: "plus") {
        model.showingNewConnection = true
      }
      Divider()
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
      Divider()
      actionRow("Authorized Keys", systemImage: "key.2.on.ring") {
        model.openLocalAuthorizedKeys()
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
