import Testing
@testable import ShellKit

/// Connections without a visible prompt (file browser, tunnels, the
/// authorized-keys panel) trust a host on first contact only: a changed key
/// would hand the saved password to whoever answered and replace the
/// remembered key.
@MainActor
struct HostKeyPromptTests {
  private func answer(previous: String?) -> Bool? {
    var answer: Bool?
    let prompt = TerminalHostKeyPrompt(
      host: "example.com",
      port: 22,
      fingerprint: "SHA256:new",
      previousFingerprint: previous,
      respond: { answer = $0 }
    )
    prompt.respondTrustingFirstUse()
    return answer
  }

  @Test func firstContactIsTrusted() {
    #expect(answer(previous: nil) == true)
  }

  @Test func changedKeyIsRejected() {
    #expect(answer(previous: "SHA256:old") == false)
  }
}
