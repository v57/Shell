import ComponentKit
import SwiftUI

/// A pane waiting on work (a file loading, a tunnel connecting): the kit's empty state with its tile as a live icon
/// running the work indicator, since the kit's `EmptyState` takes no status and the kit shows work in the live icon,
/// never a spinner.
///
/// ```swift
/// WorkState(systemImage: "globe", title: "Connecting", message: "Opening the tunnel to atlas…")
/// ```
struct WorkState: View {
  let systemImage: String
  let title: String
  var message: String?
  var status: WorkStatus = .working

  var body: some View {
    VStack(spacing: 6) {
      LiveIcon(systemImage: systemImage, status: status, size: 52)
        .padding(.bottom, 6)
        .accessibilityHidden(true)
      Text(title)
        .kitFont(.title3)
        .multilineTextAlignment(.center)
      if let message {
        Text(message)
          .kitFont(.callout)
          .foregroundStyle(.kitSecondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 300)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .combine)
  }
}
