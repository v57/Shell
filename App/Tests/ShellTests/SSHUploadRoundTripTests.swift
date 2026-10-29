import Foundation
import Testing
import ShellKit

/// App-hosted (TEST_HOST = Shell.app) regression check for the local→SSH drop
/// machinery: `SSHSession.connect` (Secure-Enclave key, forwarding-only) →
/// `remoteHomeDirectory` → `uploadFile` → byte check via `downloadFile`.
///
/// This is the ONLY reliable place to run it: the Secure-Enclave identity key
/// is usable only inside the app's signed process, so a bare `swift test`
/// binary can't authenticate. We connect to a `localhost` config (this Mac) as
/// the current user, so uploads land under the real home directory and are
/// directly readable back.
///
/// The host key is auto-accepted so a not-yet-trusted `localhost` fingerprint
/// can't reject the connection — this verifies the auth + remoteHome + SFTP
/// machinery, not key-trust bookkeeping.
///
/// Gate on RUN_SECURE_ENCLAVE_TESTS=1 (same convention as SSHKeychainTests) so
/// a bare/locked-mac run skips instead of failing.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["RUN_SECURE_ENCLAVE_TESTS"] == "1"))
struct SSHUploadRoundTripTests {
  private enum RoundTripError: LocalizedError {
    case connectFailed(String)
    var errorDescription: String? {
      switch self {
      case .connectFailed(let m): return "SSH connect failed: \(m)"
      }
    }
  }

  /// A once-only reservation so a connect that succeeds then reports a late
  /// termination never double-resumes the continuation. All callbacks arrive on
  /// the main thread, so a lock is belt-and-suspenders.
  private final class ResumeOnce {
    private let lock = NSLock()
    private var done = false
    func tryOnce() -> Bool {
      lock.lock(); defer { lock.unlock() }
      if done { return false }
      done = true
      return true
    }
  }

  @Test @MainActor func remoteHomeAndUploadRoundTrip() async throws {
    let config = SSHConfig(name: "localhost", host: "localhost", user: NSUserName(), port: 22, authMethod: .keychainKey)

    let session = SSHSession(config: config, forwardingOnly: true)
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
      let once = ResumeOnce()
      session.onHostKeyPrompt = { $0.respond(true) }
      session.onConnected = {
        if once.tryOnce() { cont.resume() }
      }
      session.onTerminated = { msg in
        if once.tryOnce() { cont.resume(throwing: RoundTripError.connectFailed(msg)) }
      }
      session.start()
    }
    defer { session.close() }

    // 1) The exact call that used to hang: resolve the remote home.
    let home = try await session.remoteHomeDirectory()
    #expect(home.hasPrefix("/"), "remoteHomeDirectory() resolved to: \(home)")

    // 2) Known bytes → SFTP upload → read back via downloadFile.
    let marker = Data("shell-dnd-roundtrip-\(UUID().uuidString)".utf8)
    let localURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("shell-dnd-src-\(UUID().uuidString).txt")
    try marker.write(to: localURL)
    defer { try? FileManager.default.removeItem(at: localURL) }

    let remotePath = home + "/shell-dnd-test.txt"
    defer {
      // Remove the remote temp file through a second exec channel.
      session.runCommand("rm -f \(remotePath)") { _ in }
    }
    try await session.uploadFile(localURL: localURL, remotePath: remotePath)

    let roundTripped = try await session.downloadFile(remotePath: remotePath)
    #expect(roundTripped == marker, "upload→download byte mismatch (got \(roundTripped.count) bytes)")
  }
}
