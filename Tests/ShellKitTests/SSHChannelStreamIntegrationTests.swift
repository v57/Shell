import CryptoKit
import Foundation
import Testing
import WireKit
@testable import ShellKit

/// The database browser's path: a client talks to SSH channels of Shell's own connection in-process, with no
/// local port. Needs an sshd that reaches Redis on its own 127.0.0.1:6379 and reads its authorized keys from a
/// file this test may write (it adds a throwaway Secure Enclave key): `SHELL_SSH_CHANNEL_TEST_PORT`,
/// `SHELL_SSH_CHANNEL_TEST_KEYS` (that file) and optionally `SHELL_SSH_CHANNEL_TEST_USER`; skipped otherwise.
/// Host keys go to a scratch defaults suite, never the vault.
@MainActor
struct SSHChannelStreamIntegrationTests {
  static let environment = ProcessInfo.processInfo.environment
  static let configured =
    environment["SHELL_SSH_CHANNEL_TEST_PORT"] != nil && environment["SHELL_SSH_CHANNEL_TEST_KEYS"] != nil
    && SecureEnclave.isAvailable

  @Test(.enabled(if: configured, "needs SHELL_SSH_CHANNEL_TEST_PORT and SHELL_SSH_CHANNEL_TEST_KEYS"))
  func carriesAClientOverAChannel() async throws {
    let key = try SecureEnclave.P256.Signing.PrivateKey()
    let line = SSHKeychain.publicKeyOpenSSHLine(for: key, comment: "Shell channel test") + "\n"
    try line.write(toFile: Self.environment["SHELL_SSH_CHANNEL_TEST_KEYS"]!, atomically: true, encoding: .utf8)
    let config = SSHConfig(
      host: "127.0.0.1", user: Self.environment["SHELL_SSH_CHANNEL_TEST_USER"] ?? NSUserName(),
      port: Int(Self.environment["SHELL_SSH_CHANNEL_TEST_PORT"]!)!, authMethod: .keychainKey)
    let knownHosts = KnownHostsStore(defaults: UserDefaults(suiteName: "shell-test-\(UUID().uuidString)")!, store: nil)
    let connection = Libssh2Connection(config: config, privateKey: key, forwardingOnly: true, knownHosts: knownHosts)
    connection.onHostKeyChallenge = { $0.respond(true) }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let once = Once()
      connection.onConnected = { if once.claim() { continuation.resume() } }
      connection.onTerminated = { message in
        if once.claim() { continuation.resume(throwing: Libssh2Connection.EngineError.remoteCommandFailed(message)) }
      }
      connection.start()
    }

    let redis = try await connection.dialer.connect(host: "127.0.0.1", port: 6379)
    try await redis.send(Array("PING\r\n".utf8))
    #expect(try await redis.readLine() == "+PONG")
    // More than one SSH window and more than a channel buffers for the app.
    let big = String(repeating: "0123456789abcdef", count: 200_000)
    try await redis.send(Array("*2\r\n$4\r\nECHO\r\n$\(big.utf8.count)\r\n\(big)\r\n".utf8))
    #expect(try await redis.readLine() == "$\(big.utf8.count)")
    #expect(try await redis.read(exactly: big.utf8.count) == Array(big.utf8))

    // A second client shares the login.
    let second = try await connection.dialer.connect(host: "127.0.0.1", port: 6379)
    try await second.send(Array("PING\r\n".utf8))
    #expect(try await second.readLine().hasSuffix("PONG"))
    second.close()

    // Closing ends the clients' streams (the teardown runs on the SSH thread).
    connection.close()
    try await Task.sleep(for: .milliseconds(500))
    await #expect(throws: (any Error).self) {
      try await redis.send(Array("PING\r\n".utf8))
      _ = try await redis.readLine()
    }
  }
}

private final class Once: @unchecked Sendable {
  private let lock = NSLock()
  private var done = false
  func claim() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if done { return false }
    done = true
    return true
  }
}
