import ComponentKit
import ShellKit
import SwiftUI

/// Settings › Appearance (Shell menu → Appearance…, ⌘⇧H): the forced color scheme, the terminals' text size and the
/// "disable character backgrounds" switch. The previews show both sides of a choice, drawn by the real terminal view,
/// with the one in use outlined.
struct AppearanceSettings: View {
  @Environment(AppModel.self) private var model
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    @Bindable var model = model
    FormCard {
      // First: the previews change height with the size, and would move the stepper from under the pointer.
      FormRow("Text Size", systemImage: "textformat.size", hue: .gray) {
        KitStepper(value: $model.terminalFontSize, in: 9...24, unit: "pt")
      }
      FormRow("Color Scheme", systemImage: "circle.lefthalf.filled", hue: .gray) {
        KitSegmented(selection: $model.appearanceMode, options: AppearanceMode.allCases.map { ($0.label, $0) })
      }
      .preview(height: previewHeight) {
        samples(
          TerminalSample("Dark", scheme: .dark, backgroundsDisabled: model.disableTerminalBackgrounds, isCurrent: colorScheme == .dark),
          TerminalSample("Light", scheme: .light, backgroundsDisabled: model.disableTerminalBackgrounds, isCurrent: colorScheme == .light)
        )
      }
      FormRow(
        "Disable Background Colors",
        help: "When enabled, terminals stop drawing character backgrounds and low-contrast text colors are replaced with the default text color.",
        systemImage: "rectangle.slash", hue: .gray
      ) {
        Toggle("Disable Background Colors", isOn: $model.disableTerminalBackgrounds)
          .kitLabelsHidden()
      }
      .preview(height: previewHeight) {
        samples(
          TerminalSample("Colors", scheme: colorScheme, backgroundsDisabled: false, isCurrent: !model.disableTerminalBackgrounds),
          TerminalSample("Disabled", scheme: colorScheme, backgroundsDisabled: true, isCurrent: model.disableTerminalBackgrounds)
        )
      }
    }
  }

  /// The sample's lines at the current text size, the grid's padding and the panes' margin.
  private var previewHeight: CGFloat {
    CGFloat(SampleOutput.lines) * TerminalScreenView.metrics(ofSize: model.terminalFontSize).lineHeight + 8 + 12
  }

  private func samples(_ first: TerminalSample, _ second: TerminalSample) -> some View {
    HStack(spacing: 6) {
      first
      second
    }
    .padding(6)
  }
}

/// One side of a choice: the real terminal view on `SampleOutput`. Disabled, so it takes no focus or keyboard.
private struct TerminalSample: View {
  /// One session behind every pane: they're all the same size.
  @MainActor private static let session = TerminalSession(transport: SampleOutput())

  @Environment(AppModel.self) private var model
  let title: String
  let scheme: ColorScheme
  let backgroundsDisabled: Bool
  let isCurrent: Bool

  init(_ title: String, scheme: ColorScheme, backgroundsDisabled: Bool, isCurrent: Bool) {
    self.title = title
    self.scheme = scheme
    self.backgroundsDisabled = backgroundsDisabled
    self.isCurrent = isCurrent
  }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
    TerminalView(session: Self.session)
      .disabled(true)
      .background(TerminalPalette.windowBackground)
      .overlay(alignment: .bottomTrailing) {
        Text(title)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 7)
          .padding(.vertical, 2)
          .background(.kitPanel, in: Capsule())
          .padding(5)
      }
      .environment(\.terminalBackgroundsDisabled, backgroundsDisabled)
      .environment(\.terminalFontSize, model.terminalFontSize)
      .environment(\.colorScheme, scheme)
      .clipShape(shape)
      .overlay(shape.strokeBorder(isCurrent ? AnyShapeStyle(.kitAccent) : AnyShapeStyle(.clear), lineWidth: 2))
  }
}

/// A short test run with what the settings change: colored backgrounds and text too dim to read on them.
private final class SampleOutput: TerminalTransport {
  var onOutput: ((Data) -> Void)?
  var onConnected: (() -> Void)?
  var onTerminated: ((String) -> Void)?
  var onExit: ((Int32) -> Void)?

  /// Short enough for a pane at the largest text size, where a longer line would wrap.
  private static let output = [
    "\u{1B}[2J\u{1B}[3J\u{1B}[H",
    "\u{1B}[32m~\u{1B}[0m % npm test\r\n",
    "\u{1B}[42;30m PASS \u{1B}[0m auth\r\n",
    "\u{1B}[41;97m FAIL \u{1B}[0m api\r\n",
    "\u{1B}[43;30m WARN \u{1B}[0m \u{1B}[34mdeps\u{1B}[0m\r\n",
    "\u{1B}[44;97m main \u{1B}[K\u{1B}[0m\r\n",
    "\u{1B}[32m~\u{1B}[0m % ",
  ].joined()
  static let lines = 6

  func start() {
    onConnected?()
    onOutput?(Data(Self.output.utf8))
  }

  /// Drawn again, to end the status line at the new width.
  func resize(columns: Int, rows: Int) {
    DispatchQueue.main.async { [weak self] in self?.onOutput?(Data(Self.output.utf8)) }
  }

  func write(_ data: Data) {}
  func close() {}
}
