#if os(macOS)
import SwiftUI
import AppKit
import Monitoring

/// Applies the sidebar stats policy to the hosting window: sampling runs
/// while the window is key, stops 10 minutes after it resigns key (or
/// immediately on close), and resumes when it becomes key again.
///
/// Rendered as a pass-through background view inside the sidebar so it can
/// reach the hosting NSWindow. All observation happens on the main queue
/// with `Task { @MainActor }` hops (the app target compiles with default
/// MainActor isolation).
struct WindowStatsObserver: NSViewRepresentable {
  let monitor: SystemStatsMonitor

  func makeCoordinator() -> Coordinator {
    Coordinator(monitor: monitor)
  }

  func makeNSView(context: Context) -> NSView {
    let view = PassThroughView()
    view.onWindowChange = { [weak coordinator = context.coordinator] window in
      Task { @MainActor in
        guard let coordinator else { return }
        if let window {
          coordinator.attach(to: window)
        } else {
          coordinator.detach()
        }
      }
    }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {}

  func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    Task { @MainActor in
      coordinator.detach()
    }
  }

  /// An invisible view that never intercepts mouse events (it sits in the
  /// sidebar's background and must not swallow clicks meant for rows). It
  /// reports when it moves into/out of a window (`viewDidMoveToWindow`).
  private final class PassThroughView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      onWindowChange?(window)
    }
  }

  @MainActor
  final class Coordinator {
    private let monitor: SystemStatsMonitor
    /// Arms when the window resigns key; fires after 10 minutes of
    /// continuous inactivity to stop sampling.
    private var inactivityTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private weak var window: NSWindow?

    init(monitor: SystemStatsMonitor) {
      self.monitor = monitor
    }

    /// Starts sampling and observes the window's key/close lifecycle.
    /// Idempotent; re-attaching to the same window is a no-op.
    func attach(to window: NSWindow) {
      guard self.window !== window else { return }
      detach()
      self.window = window
      monitor.start()
      let center = NotificationCenter.default
      let observe: (Notification.Name) -> NSObjectProtocol = { name in
        center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
          Task { @MainActor in
            self?.handle(name)
          }
        }
      }
      observers.append(observe(NSWindow.didResignKeyNotification))
      observers.append(observe(NSWindow.didBecomeKeyNotification))
      observers.append(observe(NSWindow.willCloseNotification))
    }

    /// Stops sampling and tears down all observation (window closed or
    /// the view left the hierarchy).
    func detach() {
      monitor.stop()
      inactivityTimer?.invalidate()
      inactivityTimer = nil
      observers.forEach { NotificationCenter.default.removeObserver($0) }
      observers.removeAll()
      window = nil
    }

    private func handle(_ name: Notification.Name) {
      switch name {
      case NSWindow.didResignKeyNotification: windowResignedKey()
      case NSWindow.didBecomeKeyNotification: windowBecameKey()
      case NSWindow.willCloseNotification: detach()
      default: break
      }
    }

    private func windowResignedKey() {
      guard inactivityTimer == nil else { return }
      inactivityTimer = Timer.scheduledTimer(withTimeInterval: 10 * 60, repeats: false) { [weak self] _ in
        Task { @MainActor in
          self?.monitor.stop()
        }
      }
    }

    private func windowBecameKey() {
      inactivityTimer?.invalidate()
      inactivityTimer = nil
      monitor.start()
    }
  }
}
#endif
