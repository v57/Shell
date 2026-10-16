import ComponentKit
import SwiftUI

/// A toolbar item drawn by the kit alone: without the shared glass the system
/// puts behind toolbar items (macOS 26 / iOS 26), so a `ToolGroup` or the
/// `KitTitle` is the only card there.
struct PlainToolbarItem<Content: View>: ToolbarContent {
  let placement: ToolbarItemPlacement
  @ViewBuilder let content: () -> Content

  var body: some ToolbarContent {
    if #available(macOS 26.0, iOS 26.0, *) {
      ToolbarItem(placement: placement) { content() }
        .sharedBackgroundVisibility(.hidden)
    } else {
      ToolbarItem(placement: placement) { content() }
    }
  }
}

extension View {
  /// The detail page's title in the toolbar as the kit's rich title (a tile or
  /// live icon, the name, one status line) instead of the system title. The
  /// page keeps its `navigationTitle` for the window's name.
  func detailTitle(
    _ title: String, meta: [String] = [], systemImage: String, hue: Hue = .accent, status: WorkStatus = .idle
  ) -> some View {
    toolbar {
      PlainToolbarItem(placement: .navigation) {
        KitTitle(title, meta: meta, systemImage: systemImage, hue: hue, status: status)
          .padding(.leading, 6)
      }
      // Without the system title, the tools would follow the title; the space
      // between keeps them at the trailing edge.
      if #available(macOS 26.0, iOS 26.0, *) {
        ToolbarSpacer(.flexible)
      }
    }
    .modifier(RemovingSystemTitle())
  }
}

/// Removes the system's title from the toolbar where the OS can (macOS 15 / iOS 18).
private struct RemovingSystemTitle: ViewModifier {
  func body(content: Content) -> some View {
    if #available(macOS 15.0, iOS 18.0, *) {
      content.toolbar(removing: .title)
    } else {
      content
    }
  }
}
