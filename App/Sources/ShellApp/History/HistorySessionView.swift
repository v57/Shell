import SwiftUI
import ShellKit

struct HistorySessionView: View {
  let session: HistorySession

  var body: some View {
    ScrollView([.horizontal, .vertical]) {
      Text(session.output.isEmpty ? "No output captured." : session.output)
        .font(.system(size: 13).monospaced())
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(12)
    }
    .background(TerminalPalette.windowBackground)
  }
}
