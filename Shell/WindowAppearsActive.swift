import SwiftUI

/// Whether the view's window appears active: `appearsActive` on macOS, the
/// scene phase on iOS (`appearsActive` needs iOS 18; Shell runs on iOS 17).
/// Animations freeze while it is false.
@propertyWrapper
struct WindowAppearsActive: DynamicProperty {
  #if os(macOS) || os(Windows) || os(Linux)
  @Environment(\.appearsActive) private var appearsActive
  var wrappedValue: Bool { appearsActive }
  #else
  @Environment(\.scenePhase) private var scenePhase
  var wrappedValue: Bool { scenePhase == .active }
  #endif
}
