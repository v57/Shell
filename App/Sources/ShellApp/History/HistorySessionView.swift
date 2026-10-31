import ComponentKit
import SwiftUI
import ShellKit

/// An archived session's captured output, read-only in the kit's code block.
struct HistorySessionView: View {
  let session: HistorySession

  var body: some View {
    KitCodeBlock(session.output, wraps: false, maxHeight: .infinity, placeholder: "No output captured.")
      .padding(KitMetrics.gutter)
  }
}
