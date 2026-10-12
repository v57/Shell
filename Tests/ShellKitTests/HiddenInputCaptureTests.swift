import Foundation
import Testing
@testable import ShellKit

/// Input typed while nothing is echoed is recorded from the keystrokes only
/// when it isn't a secret: a password typed at `sudo`, `ssh` or `read -s`
/// must never reach history or the actions-from-history list.
@MainActor
struct HiddenInputCaptureTests {
  private func submit(_ text: String, prompt: String = "", echoesInput: Bool = true) -> [String] {
    let transport = EchoStubTransport()
    transport.echoesInput = echoesInput
    let session = TerminalSession(transport: transport)
    defer { session.close() }
    var commands: [String] = []
    session.commandSubmittedHandler = { commands.append($0) }

    transport.onOutput?(Data(prompt.utf8))
    session.flushPendingOutput()
    for character in text.map(String.init) {
      session.handleKey(characters: character, charactersIgnoringModifiers: character, keyCode: 0, modifierFlags: [])
    }
    session.handleKey(characters: "\r", charactersIgnoringModifiers: "\r", keyCode: 36, modifierFlags: [])
    return commands
  }

  @Test func unechoedCommandAtAShellPromptIsRecorded() {
    #expect(submit("ls", prompt: "v57@mac ~ % ") == ["ls"])
  }

  @Test func inputWithEchoOffIsNotRecorded() {
    #expect(submit("hunter2", echoesInput: false).isEmpty)
  }

  @Test func inputAtAPasswordPromptIsNotRecorded() {
    #expect(submit("hunter2", prompt: "[sudo] password for v57: ").isEmpty)
    #expect(submit("hunter2", prompt: "user@host's password: ").isEmpty)
  }

  @Test func secretPrompts() {
    #expect(TerminalSession.looksLikeSecretPrompt("Password:"))
    #expect(TerminalSession.looksLikeSecretPrompt("Enter passphrase for key '/Users/v57/.ssh/id_ed25519': "))
    #expect(TerminalSession.looksLikeSecretPrompt("Password for 'https://v57@github.com':"))
    #expect(TerminalSession.looksLikeSecretPrompt("Enter PIN for 'YubiKey':"))
    #expect(!TerminalSession.looksLikeSecretPrompt("v57@mac ~ % "))
    #expect(!TerminalSession.looksLikeSecretPrompt("password-manager %"))
    #expect(!TerminalSession.looksLikeSecretPrompt("Spinning:"))
  }
}

@MainActor
private final class EchoStubTransport: TerminalTransport {
  var onOutput: ((Data) -> Void)?
  var onConnected: (() -> Void)?
  var onTerminated: ((String) -> Void)?
  var onExit: ((Int32) -> Void)?
  var echoesInput = true

  func start() { onConnected?() }
  func write(_ data: Data) {}
  func resize(columns: Int, rows: Int) {}
  func close() {}
}
