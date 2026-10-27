import ComponentKit
import SwiftUI

/// The Themes sheet (Shell menu → Themes…, ⌘⇧H): the forced color scheme
/// picker and the "disable character backgrounds" toggle.
struct ThemesView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.kitDismiss) private var dismiss

  var body: some View {
    @Bindable var model = model
    VStack(alignment: .leading, spacing: 14) {
      Text("Themes")
        .font(.headline)

      Text("Color Scheme")
        .font(.caption)
        .foregroundStyle(.secondary)
      KitSegmented(selection: $model.appearanceMode, options: AppearanceMode.allCases.map { ($0.label, $0) })

      Toggle("Disable Background Colors", isOn: $model.disableTerminalBackgrounds)
#if os(macOS) || os(Windows) || os(Linux)
        .toggleStyle(.checkbox)
#else
        .toggleStyle(.switch)
#endif

      Text("When enabled, terminals stop drawing character backgrounds and low-contrast text colors are replaced with the default text color.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      HStack {
        Spacer()
        Button("Done") { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 380)
  }
}