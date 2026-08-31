import Foundation
import Terminal

/// The transport behind an opened database session. A database session has NO
/// terminal I/O — its content is the `DatabaseBrowserView` driven by a
/// `DatabaseSession`. This transport reports an immediate `.connected` state
/// (so the app treats the database session as a live session, keeping the
/// sidebar dot, toolbar, and ⌘W/⌘N navigation sane) and is otherwise inert.
final class DatabaseTransport: TerminalTransport {
  var onOutput: ((Data) -> Void)?
  var onConnected: (() -> Void)?
  var onTerminated: ((String) -> Void)?
  var onExit: ((Int32) -> Void)?

  func start() {
    // Report connected synchronously: the detail switch keys off `kind(of:)`,
    // so the real transport state is irrelevant — but a live-looking session
    // keeps any status UI, toolbar, and ⌘W/⌘N navigation sane.
    onConnected?()
  }

  func write(_ data: Data) {
    // No terminal to write to (content is the database browser).
  }

  func resize(columns: Int, rows: Int) {
    // No terminal grid to resize.
  }

  func close() {
    // Nothing to tear down here; the DatabaseSession is torn down by the
    // app model when the session is removed.
  }
}
