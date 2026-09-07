import SwiftUI

// Key event -> byte sequence mapping for the terminal child.
// Extracted from the Shell app (TerminalView.swift) into the Terminal library.

// MARK: - Key mapping

enum TerminalKeyMapper {
  /// Maps the structured key event (from the pure-SwiftUI onKeyPress path)
  /// to the byte sequence the child expects. Identical logic to the old
  /// NSEvent-based version — ctrl+key control sequences first, then special
  /// keys by keyCode, then plain characters (option = ESC prefix).
  static func bytes(characters: String?, charactersIgnoringModifiers: String?, keyCode: UInt16, modifierFlags: TerminalModifierFlags) -> Data? {
    if modifierFlags.contains(.control), let characters = charactersIgnoringModifiers, characters.count == 1 {
      return controlSequence(for: characters)
    }
    
    switch keyCode {
    case 123:
      return Data("\u{1b}[D".utf8)
    case 124:
      return Data("\u{1b}[C".utf8)
    case 125:
      return Data("\u{1b}[B".utf8)
    case 126:
      return Data("\u{1b}[A".utf8)
    case 115:
      return Data("\u{1b}[H".utf8)
    case 119:
      return Data("\u{1b}[F".utf8)
    case 116:
      return Data("\u{1b}[5~".utf8)
    case 121:
      return Data("\u{1b}[6~".utf8)
    case 51:
      return Data([0x7f])
    case 117:
      return Data("\u{1b}[3~".utf8)
    case 48:
      return Data([0x09])
    case 36, 76:
      return Data([0x0d])
    case 53:
      return Data([0x1b])
    // F1-F12 (xterm CSI sequences). The macOS .onKeyPress path never
    // produces these keyCodes (KeyEquivalent has no F-key cases), so these
    // only fire for the iOS special-keys bar's F-row.
    case 122:
      return Data("\u{1b}[11~".utf8)  // F1
    case 120:
      return Data("\u{1b}[12~".utf8)  // F2
    case 99:
      return Data("\u{1b}[13~".utf8)  // F3
    case 118:
      return Data("\u{1b}[14~".utf8)  // F4
    case 96:
      return Data("\u{1b}[15~".utf8)  // F5
    case 97:
      return Data("\u{1b}[17~".utf8)  // F6
    case 98:
      return Data("\u{1b}[18~".utf8)  // F7
    case 100:
      return Data("\u{1b}[19~".utf8)  // F8
    case 101:
      return Data("\u{1b}[20~".utf8)  // F9
    case 109:
      return Data("\u{1b}[21~".utf8)  // F10
    case 103:
      return Data("\u{1b}[23~".utf8)  // F11
    case 111:
      return Data("\u{1b}[24~".utf8)  // F12
    default:
      break
    }
    
    guard let characters, !characters.isEmpty else { return nil }
    
    if modifierFlags.contains(.option) {
      return Data(("\u{1b}" + characters).utf8)
    }
    
    return Data(characters.utf8)
  }
  
  private static func controlSequence(for characters: String) -> Data? {
    guard let scalar = characters.unicodeScalars.first else { return nil }
    let value = scalar.value
    if value >= 0x61 && value <= 0x7a {
      return Data([UInt8(value - 0x60)])
    }
    if value >= 0x41 && value <= 0x5a {
      return Data([UInt8(value - 0x40)])
    }
    switch scalar {
    case " ":
      return Data([0x00])
    case "[":
      return Data([0x1b])
    case "\\":
      return Data([0x1c])
    case "]":
      return Data([0x1d])
    case "^":
      return Data([0x1e])
    case "_":
      return Data([0x1f])
    case "?":
      return Data([0x7f])
    default:
      return nil
    }
  }
}
