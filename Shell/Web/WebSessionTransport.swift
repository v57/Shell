import Foundation
import Terminal

/// The transport behind an opened web session. A web session has NO terminal
/// I/O — its content is a SwiftUI WebView. This transport reports an
/// immediate `.connected` state (so the app treats the web session as a live
/// session) and is otherwise inert: nothing ever writes to it, no output ever
/// arrives, and closing is a no-op. SSH-owned web sessions receive their
/// port-forward from the dedicated tunnel utility, not from this transport.
final class WebSessionTransport: TerminalTransport {
  var onOutput: ((Data) -> Void)?
  var onConnected: (() -> Void)?
  var onTerminated: ((String) -> Void)?
  var onExit: ((Int32) -> Void)?

  func start() {
    // Report connected synchronously: the terminal-detail switch keys off
    // `kind(of:)`, so the actual state is irrelevant — but a live-looking
    // session keeps any status UI, toolbar, and ⌘W/⌘N navigation sane.
    onConnected?()
  }

  func write(_ data: Data) {
    // No terminal to write to (content is the WebView).
  }

  func resize(columns: Int, rows: Int) {
    // No terminal grid to resize.
  }

  func close() {
    // Nothing to tear down; the WebView is released with the view.
  }

  // `childProcessID` (nil) and the auth-prompt no-ops come from the
  // `TerminalTransport` protocol extension.
}
