import ComponentKit
import SwiftUI

/// A self-contained list of every toggleable Shell feature: a form card with a row per feature (its tile, label,
/// short description and a switch) bound back to `FeatureFlagsStore`.
///
/// The same view is used in two contexts:
/// - **Embedded** in Settings › Features (`SettingsView`), as a passive feature panel the user flips on/off.
/// - **First-launch welcome**, presented as a "choose your features" sheet when
///   `FeatureFlagsStore.needsFirstLaunchSelection` is true (see `FeatureWelcomeView`).
///
/// It reads the app-wide shared store by default; pass `store:` to bind a seeded store (e.g. in previews or tests).
/// Toggling calls `FeatureFlagsStore.setEnabled(_:for:)`, which is `@Observable`, so every consumer that reads
/// `isEnabled(_:)` re-renders the instant a flag flips — turning a feature off hides its UI and stops its background
/// work, while the store's contract guarantees the feature's own data is never touched.
struct FeatureSelectionView: View {
  private let store: FeatureFlagsStore
  private let footer: String?

  init(store: FeatureFlagsStore? = nil, footer: String? = nil) {
    self.store = store ?? .shared
    self.footer = footer
  }

  var body: some View {
    FormCard(footer: footer) {
      ForEach(FeatureID.available) { feature in
        FormRow(feature.label, help: feature.description, systemImage: feature.systemImage, hue: feature.hue) {
          // An explicit get/set so the store stays the sole writer of feature state (no local copy of the
          // disabled set).
          Toggle(feature.label, isOn: Binding(
            get: { store.isEnabled(feature) },
            set: { newValue in withKitAnimation { store.setEnabled(newValue, for: feature) } }
          ))
          .toggleStyle(.kitSwitch)
          .kitLabelsHidden()
        }
      }
    }
  }
}

extension FeatureID {
  /// The feature's tile in the features list; the sidebar's glyph and hue where it has a section.
  fileprivate var systemImage: String {
    switch self {
    case .animations: return "sparkles"
    case .sessions: return "terminal"
    case .screen: return "rectangle.stack"
    case .ssh: return "network"
    case .notes: return "doc.text"
    case .history: return "clock.arrow.circlepath"
    case .actions: return "bolt"
    case .smartActions: return "wand.and.stars"
    case .monitoring: return "gauge.with.dots.needle.33percent"
    case .files: return "folder"
    case .authorizedKeys: return "key.2.on.ring"
    case .web: return "globe"
    case .database: return "cylinder.split.1x2"
    }
  }

  fileprivate var hue: Hue {
    switch self {
    case .animations: return .pink
    case .sessions: return .gray
    case .screen: return .teal
    case .ssh: return .blue
    case .notes: return .orange
    case .history: return .brown
    case .actions: return .purple
    case .smartActions: return .indigo
    case .monitoring: return .green
    case .files: return .blue
    case .authorizedKeys: return .brown
    case .web: return .teal
    case .database: return .indigo
    }
  }
}
