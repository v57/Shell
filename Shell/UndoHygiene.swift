import Foundation
#if os(macOS)
import AppKit
#endif

/// Undo hygiene for the app's short-lived text editors.
///
/// `NSUndoManager` does NOT retain the target of a selector-based registration,
/// and that is exactly how `NSTextView` posts its text edits — the crash report
/// for this bug dies on the main thread in
/// `objc_msgSend` <- `-[_NSUndoStack popAndInvoke]` <-
/// `-[NSUndoManager undoNestedGroup]`, with the text-undo selector
/// `_undoRedoTextOperation:` in a register.
///
/// Shell swaps its text editors out constantly (a note, an opened text file,
/// the Action / Insert overlays), so an editor can be deallocated while its
/// edits are still on the window's undo stack. The next ⌘Z then messages that
/// freed memory: `SIGSEGV`, `KERN_INVALID_ADDRESS` at a pointer-authentication
/// -signed address ("possible pointer authentication failure").
///
/// A registration whose target is already gone cannot be addressed by target
/// any more, so the only reliable cleanup is dropping the stack. Call this as
/// an editor surface goes away — undo inside a LIVE editor is untouched, since
/// the purge runs only while an editor is being replaced or dismissed.
enum UndoHygiene {
  /// Drops the undo stacks of every app window (a detached item has its own).
  ///
  /// Shell presents no undo UI of its own, so the only history this costs is the
  /// outgoing editor's — the one that is going away.
  static func discardStaleTextUndo() {
    #if os(macOS)
    for window in NSApp.windows {
      window.undoManager?.removeAllActions()
    }
    #else
    // UIKit: an editor's undo manager comes from its view controller chain, not
    // a shared per-window manager, and this crash is AppKit-only.
    #endif
  }
}
