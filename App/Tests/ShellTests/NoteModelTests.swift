import Foundation
import Testing
@testable import ShellApp

/// Title and subtitle derivation for the sidebar (the note text itself is never changed).
struct NoteModelTests {
  /// Display-only derivation: a leading markdown prefix on the physical line
  /// is stripped for the sidebar label, but the underlying note text is never
  /// mutated. See NotesStore.stripMarkdownPrefix.
  @Test @MainActor func titleStripsLeadingMarkdownPrefixes() {
    #expect(NotesStore.title(for: "# Foo") == "Foo")
    #expect(NotesStore.title(for: "- Foo") == "Foo")
    #expect(NotesStore.title(for: "* Foo") == "Foo")
    #expect(NotesStore.title(for: "+ Foo") == "Foo")
    #expect(NotesStore.title(for: "> Foo") == "Foo")
  }

  @Test @MainActor func titleIsUntitledWhenEmptyAfterStripping() {
    #expect(NotesStore.title(for: "## ") == "Untitled")
    #expect(NotesStore.title(for: "# ") == "Untitled")
    // Whitespace-only bullet: the marker + single space are stripped, leaving
    // whitespace that trims to empty → "Untitled".
    #expect(NotesStore.title(for: "-   ") == "Untitled")
    #expect(NotesStore.title(for: "- ") == "Untitled")
  }

  @Test @MainActor func subtitleStripsLeadingMarkdownPrefixes() {
    #expect(NotesStore.subtitle(for: "# Title\n- Sub") == "Sub")
    #expect(NotesStore.subtitle(for: "# Title\n* Sub") == "Sub")
    #expect(NotesStore.subtitle(for: "# Title\n> Sub") == "Sub")
    #expect(NotesStore.subtitle(for: "# Title") == nil)
  }

  @Test @MainActor func subtitleIsNilWhenEmptyAfterStripping() {
    #expect(NotesStore.subtitle(for: "# Title\n## ") == nil)
    #expect(NotesStore.subtitle(for: "# Title\n- ") == nil)
  }

  @Test @MainActor func titlePreservesNotesWithoutMarkdownPrefix() {
    #expect(NotesStore.title(for: "Plain note") == "Plain note")
    // A bare '#' with no space is NOT an ATX heading, so it stays as-is.
    #expect(NotesStore.title(for: "#") == "#")
  }
}
