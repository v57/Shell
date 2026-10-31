import ComponentKit
import SwiftUI

/// The Themes sheet (Shell menu → Themes…, ⌘⇧H): the forced color scheme
/// picker and the "disable character backgrounds" toggle.
struct ThemesView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.kitDismiss) private var dismiss

  var body: some View {
    @Bindable var model = model
    KitSheet(title: "Themes", systemImage: "paintpalette", hue: .pink, width: 420) {
      FormCard {
        FormRow("Color Scheme", systemImage: "circle.lefthalf.filled", hue: .gray) {
          KitSegmented(selection: $model.appearanceMode, options: AppearanceMode.allCases.map { ($0.label, $0) })
        }
        FormRow(
          "Disable Background Colors",
          help: "When enabled, terminals stop drawing character backgrounds and low-contrast text colors are replaced with the default text color.",
          systemImage: "rectangle.slash", hue: .gray
        ) {
          Toggle("Disable Background Colors", isOn: $model.disableTerminalBackgrounds)
            .toggleStyle(.kitSwitch)
            .kitLabelsHidden()
        }
      }
    } footer: {
      Button("Done") { dismiss() }
        .buttonStyle(.kitPrimary)
        .keyboardShortcut(.defaultAction)
    }
  }
}
