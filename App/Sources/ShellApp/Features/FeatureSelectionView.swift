import SwiftUI

/// A self-contained list of every toggleable Shell feature, each rendered as a
/// label + short description + `Toggle` bound back to `FeatureFlagsStore`.
///
/// The same view is used in two contexts:
/// - **Embedded** in the Settings scene (hosted by the Settings card /
///   `SettingsView`), as a passive feature panel the user flips on/off.
/// - **First-launch welcome**, presented as a "choose your features" sheet when
///   `FeatureFlagsStore.needsFirstLaunchSelection` is true (see
///   `FeatureWelcomeView`).
///
/// It reads the app-wide shared store by default; pass `store:` to bind a
/// seeded store (e.g. in previews or tests). Toggling calls
/// `FeatureFlagsStore.setEnabled(_:for:)`, which is `@Observable`, so every
/// consumer that reads `isEnabled(_:)` re-renders the instant a flag flips —
/// turning a feature off hides its UI and stops its background work, while the
/// store's contract guarantees the feature's own data is never touched.
struct FeatureSelectionView: View {
  private let store: FeatureFlagsStore

  init(store: FeatureFlagsStore? = nil) {
    self.store = store ?? .shared
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(FeatureID.available) { feature in
        // The row binds through an explicit get/set so the store stays the
        // sole writer of feature state (no local copy of the disabled set).
        FeatureRow(
          feature: feature,
          isOn: store.isEnabled(feature)
        ) { newValue in
          withAnimation {
            store.setEnabled(newValue, for: feature)
          }
        }
        if feature != FeatureID.available.last {
          Divider()
        }
      }
    }
  }
}

/// One toggleable feature row: label + description + a `Toggle`.
private struct FeatureRow: View {
  let feature: FeatureID
  let isOn: Bool
  let onToggle: (Bool) -> Void

  var body: some View {
    Toggle(isOn: Binding(get: { isOn }, set: onToggle)) {
      VStack(alignment: .leading, spacing: 2) {
        Text(feature.label)
        Text(feature.description)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .toggleStyle(.switch)
    .padding(.vertical, 6)
  }
}
