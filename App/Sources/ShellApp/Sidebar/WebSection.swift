import ComponentKit
import SwiftUI

/// The Web section: the saved web pages, local ones and those tunneled through a saved host, on their own card so
/// they don't interleave with terminals. Shown once there's a page (This Mac's and a host's menus make one).
struct WebSectionView: View {
  @Environment(AppModel.self) private var model
  /// The sidebar's shared state (SidebarChrome.swift): the filter.
  let state: SidebarState

  @AppStorage("sidebar.web.collapsed") private var collapsed = false

  private var flags: FeatureFlagsStore { .shared }

  var body: some View {
    let pages = model.webSessions.all
    if flags.isEnabled(.web), !pages.isEmpty {
      let shown = pages.filter { state.matches($0.sidebarTitle) }
      let open = pages.filter { model.liveWebSession(for: $0) != nil }.count
      KitSection("Web", systemImage: "globe", hue: .teal, isExpanded: .expanded(collapsed: $collapsed)) {
        ReorderableSection(shown, move: { source, destination in
          let move = FilteredMove(source, destination, shown: shown, in: pages)
          model.moveWebSession(from: move.source, to: move.destination)
        }) { web in
          WebSessionRow(web: web)
        }
      } meta: {
        MetaLine(open > 0 ? "\(open) open" : "", pages.count == 1 ? "1 page" : "\(pages.count) pages")
      } accessory: {
        Button("New Web Session", systemImage: "plus") { model.openEmptyWebSession() }
          .kitHelp("New web session")
      }
    }
  }
}
