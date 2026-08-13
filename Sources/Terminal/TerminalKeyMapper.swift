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
