#if os(iOS)
  import UIKit
#endif
import SwiftUI

extension View {
  /// Calls `action` with how much of this view the docked on-screen keyboard (with an input accessory such as the
  /// terminal's special-keys bar) covers from the bottom, in points: 0 while it's down, when the view already ends
  /// above it (SwiftUI made room), for a floating or split iPad keyboard, and off iOS.
  ///
  /// Measured by UIKit in the view's own coordinates (`keyboardLayoutGuide`), not from the keyboard's notifications
  /// in screen or window coordinates, and kept in the caller's `@State`: the notification frame, read through an
  /// observable inside a `GeometryReader`, sized the terminal's grid on the simulator but not on a real iPhone,
  /// where `tput lines` stayed 35 with ~22 rows above the keys bar (S-008).
  public func onKeyboardOverlap(_ action: @escaping (CGFloat) -> Void) -> some View {
    #if os(iOS)
      background { KeyboardOverlapReader(onChange: action).allowsHitTesting(false).accessibilityHidden(true) }
    #else
      self
    #endif
  }

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
      // The reader measures the padded frame, whose bottom doesn't move with the inset.
      content
        .padding(.bottom, inset)
        .onKeyboardOverlap { inset = $0 }
    #else
      content
    #endif
  }
}

#if os(iOS)
  private struct KeyboardOverlapReader: UIViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeUIView(context: Context) -> KeyboardOverlapView {
      let view = KeyboardOverlapView(frame: .zero)
      view.onChange = onChange
      return view
    }

    func updateUIView(_ view: KeyboardOverlapView, context: Context) {
      view.onChange = onChange
    }
  }

  /// An empty view laid over the measured one, whose `keyboardLayoutGuide` gives the keyboard's top in its own
  /// coordinates. A hidden probe pinned to the guide makes the view lay out again whenever the keyboard (or its
  /// accessory) moves or resizes, and the keyboard's notifications and the keys bar's own layout ask for one too.
  ///
  /// The terminal's keys bar (`accessory`) is measured as well, where it really is on screen: the covered part is
  /// whichever reaches higher. The system can report a keyboard shorter than the one showing (on the simulator, the
  /// software keyboard raised again after a hardware key left the guide 68 pt short, the bar's height), and on a real
  /// iPhone the grid kept the rows of the keys bar alone (35, as with a hardware keyboard) under the software keyboard.
  final class KeyboardOverlapView: UIView {
    var onChange: ((CGFloat) -> Void)?
    private var reported: CGFloat?
    private var observers: [NSObjectProtocol] = []

    /// The input accessory showing above the keyboard (the terminal's keys bar), while it's in a window.
    static weak var accessory: UIView? {
      didSet { NotificationCenter.default.post(name: accessoryMoved, object: nil) }
    }
    /// The accessory was laid out again (it moved, resized, came or went).
    static let accessoryMoved = Notification.Name("ShellKit.KeyboardOverlap.accessoryMoved")

    override init(frame: CGRect) {
      super.init(frame: frame)
      isUserInteractionEnabled = false
      backgroundColor = .clear
      // A floating or split iPad keyboard covers no fixed strip: the guide then drops to the bottom.
      keyboardLayoutGuide.followsUndockedKeyboard = false
      // With the keyboard down the guide's top is the view's own bottom, not the home indicator's top.
      keyboardLayoutGuide.usesBottomSafeArea = false
      let probe = UIView()
      probe.isHidden = true
      probe.translatesAutoresizingMaskIntoConstraints = false
      addSubview(probe)
      NSLayoutConstraint.activate([
        probe.leadingAnchor.constraint(equalTo: leadingAnchor),
        probe.widthAnchor.constraint(equalToConstant: 1),
        probe.topAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
        probe.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.bottomAnchor),
      ])
      let names = [
        UIResponder.keyboardDidChangeFrameNotification, UIResponder.keyboardDidShowNotification,
        UIResponder.keyboardDidHideNotification, Self.accessoryMoved,
      ]
      observers = names.map { name in
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated {
            self?.setNeedsLayout()
            self?.layoutIfNeeded()
          }
        }
      }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
      for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    override func didMoveToWindow() {
      super.didMoveToWindow()
      setNeedsLayout()
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      report()
    }

    private func report() {
      let overlap: CGFloat
      if window == nil || bounds.height <= 0 {
        overlap = 0
      } else {
        // Whichever reaches higher: the keyboard as the guide has it, or the keys bar where it is.
        let top = min(keyboardLayoutGuide.layoutFrame.minY, accessoryTop ?? .infinity)
        overlap = (min(bounds.height, max(0, bounds.maxY - top)) * 2).rounded() / 2
      }
      guard overlap != reported else { return }
      reported = overlap
      // Out of the layout pass: the caller sets SwiftUI state.
      DispatchQueue.main.async { [weak self] in self?.onChange?(overlap) }
    }

    /// The top of the keys bar in this view's coordinates, through the screen (it sits in the keyboard's window):
    /// nil when there's none, or it's off screen or beside this view.
    private var accessoryTop: CGFloat? {
      guard let accessory = Self.accessory, let barWindow = accessory.window, !accessory.isHidden,
        let window, let screen = window.windowScene?.screen, barWindow.windowScene?.screen === screen
      else { return nil }
      let inScreen = barWindow.convert(accessory.convert(accessory.bounds, to: barWindow), to: screen.coordinateSpace)
      let local = convert(inScreen, from: screen.coordinateSpace)
      guard local.height > 0, local.minY < bounds.maxY, local.maxY > bounds.minY, local.minX < bounds.maxX,
        local.maxX > bounds.minX
      else { return nil }
      return local.minY
    }
  }
#endif
