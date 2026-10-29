import ComponentKit
import SwiftUI

extension View {
  /// A message with an OK button, as the kit's sheet: over the window on the Mac and iPad (an alert there is a window
  /// sheet), the system sheet on iPhone. For errors to read and acknowledge; a choice is `kitConfirmation`.
  func noticeSheet(
    _ title: String, isPresented: Binding<Bool>, message: String,
    systemImage: String = "exclamationmark.triangle", hue: Hue = .orange
  ) -> some View {
    kitSheet(isPresented: isPresented) {
      NoticeSheet(title: title, message: message, systemImage: systemImage, hue: hue)
    }
  }
}

private struct NoticeSheet: View {
  let title: String
  let message: String
  let systemImage: String
  let hue: Hue
  @Environment(\.kitDismiss) private var dismiss

  var body: some View {
    KitSheet(title: title, meta: message, systemImage: systemImage, hue: hue, width: 380) {
    } footer: {
      Button("OK") { dismiss() }
        .buttonStyle(.kitPrimary)
        .keyboardShortcut(.defaultAction)
    }
  }
}
