import SwiftUI

/// The forced color scheme (nil = follow the system). Persisted rawValue in
/// UserDefaults; drives `.preferredColorScheme` at the ContentView root.
enum AppearanceMode: String, CaseIterable, Identifiable {
  case system
  case dark
  case light

  var id: String { rawValue }

  var label: String {
    switch self {
    case .system: return "System"
    case .dark: return "Dark"
    case .light: return "Light"
    }
  }

  /// nil = .system (don't override the OS appearance).
  var colorScheme: ColorScheme? {
    switch self {
    case .system: return nil
    case .dark: return .dark
    case .light: return .light
    }
  }
}