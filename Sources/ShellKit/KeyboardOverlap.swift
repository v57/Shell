#if os(iOS)
  import UIKit
#endif
import Observation
import SwiftUI

/// The docked on-screen keyboard (with the terminal's special-keys bar above it) in the key window's coordinates,
/// SwiftUI's `.global` space; nil while it's down. Read from the keyboard's own notifications, so a view knows how
/// much of it the keyboard covers even where SwiftUI's keyboard avoidance doesn't shrink it: on iPhone the terminal
/// sized its grid as if the keyboard weren't there (`tput lines` 35 with ~22 rows above the keys bar) and the Files
/// panel's last rows stayed under it (S-008). Off iOS there is no on-screen keyboard and the frame stays nil.
@MainActor
@Observable
public final class KeyboardOverlap {
  public static let shared = KeyboardOverlap()

  public private(set) var frame: CGRect?

  private init() {
    #if os(iOS)
      let center = NotificationCenter.default
      center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) {
        note in
        let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        MainActor.assumeIsolated { KeyboardOverlap.shared.update(screenFrame: end) }
      }
      center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { KeyboardOverlap.shared.frame = nil }
      }
    #endif
  }

  #if os(iOS)
    /// The keyboard's end frame (screen coordinates) in the key window's; nil when it isn't docked at the window's
    /// bottom (a floating or split iPad keyboard covers no fixed strip) or is off screen.
    private func update(screenFrame: CGRect?) {
      guard let screenFrame, screenFrame.height > 0,
        let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
          .flatMap(\.windows).first(where: \.isKeyWindow)
      else {
        frame = nil
        return
      }
      guard let screen = window.windowScene?.screen else {
        frame = nil
        return
      }
      let local = window.convert(screenFrame, from: screen.coordinateSpace)
      let docked = local.maxY >= window.bounds.maxY - 1 && local.minY < window.bounds.maxY
      frame = docked ? local : nil
    }
  #endif

  /// How much of `rect` (in `.global` coordinates) the keyboard covers from the bottom: 0 when it's down or the view
  /// already ends above it (SwiftUI moved it out of the way).
  public func overlap(with rect: CGRect) -> CGFloat {
    guard let frame, rect.height > 0, frame.minX < rect.maxX, frame.maxX > rect.minX else { return 0 }
    return min(rect.height, max(0, rect.maxY - frame.minY))
  }
}

extension View {
  /// Keeps the content above the on-screen keyboard: a bottom inset of what the keyboard covers of it, none when
  /// SwiftUI already made room or there's no on-screen keyboard (macOS, Linux, Windows).
  public func keepsAboveKeyboard() -> some View {
    modifier(KeepsAboveKeyboard())
  }
}

private struct KeepsAboveKeyboard: ViewModifier {
  @State private var inset: CGFloat = 0

  func body(content: Content) -> some View {
    #if os(iOS)
      content
        .padding(.bottom, inset)
        .background {
          GeometryReader { geo in
            let overlap = KeyboardOverlap.shared.overlap(with: geo.frame(in: .global))
            Color.clear
              .onAppear { inset = overlap }
              .onChange(of: overlap) { _, value in inset = value }
          }
        }
    #else
      content
    #endif
  }
}
