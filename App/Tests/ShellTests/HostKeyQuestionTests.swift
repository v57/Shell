import Foundation
import ShellKit
import Testing
import VaultUI

@testable import ShellApp

/// Connections without a terminal used to trust a host on first contact: the saved password went to whoever answered,
/// and their key was remembered. Now nobody says yes for the user.
@MainActor
struct HostKeyQuestionTests {
  private func answer(previous: String?) async -> Bool? {
    await withCheckedContinuation { continuation in
      let prompt = TerminalHostKeyPrompt(
        host: "example.com", port: 22, fingerprint: "SHA256:new", previousFingerprint: previous,
        respond: { continuation.resume(returning: $0) })
      prompt.askInWindow(VaultHostKeyRequest())
    }
  }

  @Test func withNoWindowToAskFirstContactIsRefused() async {
    #expect(await answer(previous: nil) == false)
  }

  @Test func aChangedKeyIsRefusedWithoutAsking() async {
    #expect(await answer(previous: "SHA256:old") == false)
  }
}
