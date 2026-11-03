import ComponentKit
import SwiftUI

/// Settings › Appearance (Shell menu → Appearance…, ⌘⇧H): the forced color scheme and the "disable character
/// backgrounds" switch.
struct AppearanceSettings: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var model = model
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
          .kitLabelsHidden()
      }
    }
  }
}
