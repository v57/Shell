import Testing
@testable import ShellKit

/// Linux and Windows report the PC's Ctrl key as `.command`; in a terminal Ctrl+key belongs to the program.
struct TerminalPCKeysTests {
  private func map(
    _ key: Character, _ flags: TerminalModifierFlags, selection: Bool = false, windows: Bool = false
  ) -> TerminalModifierFlags? {
    TerminalKeyMapper.pcModifiers(key: key, modifierFlags: flags, hasSelection: selection, windowsStyle: windows)
  }

  @Test func ctrlLetterGoesToTheProgram() {
    for key: Character in ["c", "d", "r", "a", "k", "v", "l", "z"] {
      #expect(map(key, .command) == .control)
      #expect(map(key, .command, selection: true) == .control)
    }
    let bytes = TerminalKeyMapper.bytes(
      characters: "\u{3}", charactersIgnoringModifiers: "c", keyCode: 0, modifierFlags: map("c", .command)!)
    #expect(bytes.map(Array.init) == [0x03])
  }

  @Test func ctrlShiftCopiesPastesAndClears() {
    #expect(map("c", [.command, .shift]) == .command)
    #expect(map("C", [.command, .shift]) == .command)
    #expect(map("v", [.command, .shift]) == .command)
    #expect(map("k", [.command, .shift]) == .command)
    // Another Ctrl+Shift letter is a menu shortcut, not the terminal's.
    #expect(map("n", [.command, .shift]) == nil)
  }

  @Test func windowsTerminalDefaults() {
    #expect(map("v", .command, windows: true) == .command)
    #expect(map("c", .command, selection: true, windows: true) == .command)
    #expect(map("c", .command, windows: true) == .control)
  }

  @Test func otherKeysPassThrough() {
    #expect(map("x", []) == [])
    #expect(map("x", .option) == .option)
    #expect(map("[", .command) == .control)
    #expect(map("_", [.command, .shift]) == [.control, .shift])
  }
}
