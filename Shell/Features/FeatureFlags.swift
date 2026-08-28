import Foundation
import Observation

/// The single registry of toggleable features in Shell.
///
/// A feature that is disabled is removed from BOTH the UI and from background
/// activity, but disabling NEVER deletes that feature's persisted data —
/// re-enabling restores the prior state. This enum enumerates every flag the
/// app can turn on/off; `FeatureFlagsStore` is the sole persistence/read layer
/// for it.
enum FeatureID: String, CaseIterable, Identifiable {
  case sessions
  case screen
  case ssh
  case notes
  case history
  case actions
  case smartActions
  case monitoring
  case files
  case themes
  case authorizedKeys
  case settings
  /// Reserved for a future built-in web-session/browser feature.
  case web
  /// Reserved for a future embedded database feature.
  case database

  var id: String { rawValue }

  /// Human-readable name, for surfacing a toggle in settings/UI.
  var label: String {
    switch self {
    case .sessions: return "Sessions"
    case .screen: return "Screen sessions"
    case .ssh: return "SSH"
    case .notes: return "Notes"
    case .history: return "History"
    case .actions: return "Actions"
    case .smartActions: return "Smart Actions"
    case .monitoring: return "Monitoring"
    case .files: return "Files"
    case .themes: return "Themes"
    case .authorizedKeys: return "Authorized Keys"
    case .settings: return "Settings"
    case .web: return "Web"
    case .database: return "Database"
    }
  }
}

/// Persists which features are disabled, backed by `UserDefaults`.
///
/// Every feature defaults to ON; only a deliberate opt-out is ever stored. A
/// `FeatureID` is written to the disabled set when turned off and removed when
/// turned back on. This store never touches anything else — in particular it
/// never deletes or mutates a feature's own persisted data (notes, sessions,
/// history, ...), so disabling a feature and re-enabling it restores the exact
/// prior state.
///
/// `@Observable` so UI observing the store re-evaluates `isEnabled` on every
/// flip. It is maintained on the main actor to match the app target's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; background work should hop to
/// the main actor to read feature state.
@MainActor
@Observable
final class FeatureFlagsStore {
  /// The shared instance used by UI and background work alike.
  static let shared = FeatureFlagsStore()

  private static let disabledKey = "featureFlags.disabled"
  private let defaults: UserDefaults

  /// Raw values of the features currently disabled. Stored (not derived) so
  /// the `@Observable` machinery notifies on every flip.
  private(set) var disabledRaw: Set<String> = []

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    reload()
  }

  /// The single public read point for feature state. True unless the feature
  /// has been explicitly disabled.
  func isEnabled(_ feature: FeatureID) -> Bool {
    !disabledRaw.contains(feature.rawValue)
  }

  /// Turns a feature on/off. Only the flag changes — never the feature's data.
  func setEnabled(_ enabled: Bool, for feature: FeatureID) {
    var next = disabledRaw
    if enabled {
      next.remove(feature.rawValue)
    } else {
      next.insert(feature.rawValue)
    }
    guard next != disabledRaw else { return }
    disabledRaw = next
    persist()
  }

  private func reload() {
    disabledRaw = Set(defaults.stringArray(forKey: Self.disabledKey) ?? [])
  }

  private func persist() {
    defaults.set(disabledRaw.sorted(), forKey: Self.disabledKey)
  }
}
