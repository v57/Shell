import ComponentKit
import SwiftUI

/// A button that opens the kit's menu under it: a toolbar tool (Distribute, the scheme) or a section's +. It takes
/// the look of the buttons around it (a `ToolGroup`'s tools, `.kitIcon`), which `KitMenuButton`'s pill doesn't.
///
/// ```swift
/// MenuToolButton("New", systemImage: "plus") {
///   Button("New Session", systemImage: "terminal") { … }
/// }
/// ```
struct MenuToolButton<Content: View>: View {
  let title: String
  let systemImage: String
  @ViewBuilder let content: () -> Content
  @State private var isOpen = false

  init(_ title: String, systemImage: String, @ViewBuilder content: @escaping () -> Content) {
    self.title = title
    self.systemImage = systemImage
    self.content = content
  }

  var body: some View {
    Button(title, systemImage: systemImage) { isOpen.toggle() }
      .kitMenu(isPresented: $isOpen, content: content)
  }
}
