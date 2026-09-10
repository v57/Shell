import SwiftUI

/// The first-launch "choose your features" welcome: hosts `FeatureSelectionView`
/// with a header and a Continue button that records the selection so the welcome
/// does not reappear. Present this as a sheet when
/// `FeatureFlagsStore.needsFirstLaunchSelection` is true.
struct FeatureWelcomeView: View {
  @Environment(\.dismiss) private var dismiss
  private let store: FeatureFlagsStore

  init(store: FeatureFlagsStore? = nil) {
    self.store = store ?? .shared
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Choose your features")
          .font(.title)
        Text("Turn off anything you don't need. Disabled features are hidden and stop their background work, but your data is kept.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      ScrollView {
        FeatureSelectionView(store: store)
      }
      Button {
        store.markConfigured()
        dismiss()
      } label: {
        Text("Continue")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .keyboardShortcut(.defaultAction)
    }
    .padding(24)
    .frame(minWidth: 440, minHeight: 520)
  }
}
