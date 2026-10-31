import ComponentKit
import SwiftUI

/// The first-launch "choose your features" welcome: hosts `FeatureSelectionView`
/// with a header and a Continue button that records the selection so the welcome
/// does not reappear. Present this as a sheet when
/// `FeatureFlagsStore.needsFirstLaunchSelection` is true.
struct FeatureWelcomeView: View {
  @Environment(\.kitDismiss) private var dismiss
  private let store: FeatureFlagsStore

  init(store: FeatureFlagsStore? = nil) {
    self.store = store ?? .shared
  }

  var body: some View {
    KitSheet(
      title: "Choose your features",
      meta: "Turn off anything you don't need. Disabled features are hidden and stop their background work, but your data is kept.",
      systemImage: "square.grid.2x2", hue: .blue, width: 480
    ) {
      FeatureSelectionView(store: store)
    } footer: {
      Button("Continue") {
        store.markConfigured()
        dismiss()
      }
      .buttonStyle(.kitPrimary)
      .keyboardShortcut(.defaultAction)
    }
  }
}
