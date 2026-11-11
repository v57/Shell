import Foundation
import Testing
@testable import ShellKit

/// A host that doesn't answer at its address is reached at a fallback (`SSHConfig.fallbacks`, then the vault's
/// `automaticFallbacks`). Needs any sshd on 127.0.0.1: `SHELL_SSH_FALLBACK_TEST_PORT` (skipped otherwise). The test
/// stops at the host key, which it refuses: nothing logs in and no key is remembered (a scratch defaults suite).
@MainActor
struct SSHFallbackAddressTests {
  static let port = ProcessInfo.processInfo.environment["SHELL_SSH_FALLBACK_TEST_PORT"].flatMap(Int.init)

  @Test func addressesAreTheHostThenItsFallbacksOnce() {
    let config = SSHConfig(
      host: "studio.example", fallbacks: ["Studio.local", "studio.example"], automaticFallbacks: ["studio.local", "100.64.0.7"])
    #expect(config.addresses == ["studio.example", "Studio.local", "100.64.0.7"])
  }

  @Test func decodesConfigsSavedBeforeFallbacks() throws {
    let json = """
      {"id":"6D28B4C5-2F7A-4E3B-9C1D-0A5B8E6F2C41","name":"box","host":"example.com","user":"me","port":22,"authMethod":"keychainKey","savePassword":true}
      """
    let config = try JSONDecoder().decode(SSHConfig.self, from: Data(json.utf8))
    #expect(config.fallbacks.isEmpty)
    #expect(config.automaticFallbacks.isEmpty)
    let again = try JSONDecoder().decode(SSHConfig.self, from: JSONEncoder().encode(SSHConfig(host: "a", fallbacks: ["b"])))
    #expect(again.fallbacks == ["b"])
  }

  /// A key accepted at one address of a machine is known at its others: the host, its fallbacks and the vault's.
  @Test func keysAreTheMachinesAtEveryAddress() {
    let knownHosts = KnownHostsStore(defaults: UserDefaults(suiteName: "shell-test-\(UUID().uuidString)")!, store: nil)
    let config = SSHConfig(host: "192.0.2.1", fallbacks: ["studio.local"], automaticFallbacks: ["100.64.0.7"])
    knownHosts.save(fingerprint: "SHA256:studio", for: config, at: "studio.local")
    #expect(knownHosts.fingerprint(for: config, at: "192.0.2.1") == nil)
    #expect(knownHosts.fingerprint(for: config, at: "studio.local") == "SHA256:studio")
    #expect(knownHosts.fingerprints(for: config) == ["SHA256:studio"])
    #expect(knownHosts.fingerprints(for: SSHConfig(host: "192.0.2.1")).isEmpty)
  }

  @Test(.enabled(if: port != nil, "needs SHELL_SSH_FALLBACK_TEST_PORT"))
  func reachesTheHostAtAFallback() async throws {
    #expect(await hostKeyShown(SSHConfig(host: "unreachable.invalid", fallbacks: ["127.0.0.1"], port: Self.port!)) == "127.0.0.1")
    #expect(await hostKeyShown(SSHConfig(host: "unreachable.invalid", automaticFallbacks: ["127.0.0.1"], port: Self.port!)) == "127.0.0.1")
    #expect(await hostKeyShown(SSHConfig(host: "unreachable.invalid", port: Self.port!)) == nil)
  }

  /// A fallback answering with a key accepted at the host's other address asks nothing.
  @Test(.enabled(if: port != nil, "needs SHELL_SSH_FALLBACK_TEST_PORT"))
  func aKeyAcceptedAtAnotherAddressIsKnown() async throws {
    let knownHosts = KnownHostsStore(defaults: UserDefaults(suiteName: "shell-test-\(UUID().uuidString)")!, store: nil)
    let first = SSHConfig(host: "127.0.0.1", port: Self.port!)
    #expect(await hostKeyShown(first, knownHosts: knownHosts, accept: true) == "127.0.0.1")
    #expect(knownHosts.fingerprint(for: first, at: "127.0.0.1") != nil)
    let fallback = SSHConfig(host: "unreachable.invalid", fallbacks: ["127.0.0.1"], port: Self.port!)
    #expect(await hostKeyShown(fallback, knownHosts: knownHosts) == nil)
  }

  /// The address the connection asked about when it got as far as the server's host key (it answered), refusing it
  /// unless `accept`; nil when nothing asked.
  private func hostKeyShown(
    _ base: SSHConfig,
    knownHosts: KnownHostsStore = KnownHostsStore(defaults: UserDefaults(suiteName: "shell-test-\(UUID().uuidString)")!, store: nil),
    accept: Bool = false
  ) async -> String? {
    var config = base
    config.authMethod = .password
    config.savePassword = false
    let connection = Libssh2Connection(config: config, privateKey: nil, forwardingOnly: true, knownHosts: knownHosts)
    defer { connection.close() }
    return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
      let once = FallbackOnce()
      connection.onHostKeyChallenge = { challenge in
        challenge.respond(accept)
        if once.claim() { continuation.resume(returning: challenge.address) }
      }
      connection.onPasswordChallenge = { challenge in
        challenge.respond(nil)
        if once.claim() { continuation.resume(returning: nil) }
      }
      connection.onConnected = { if once.claim() { continuation.resume(returning: nil) } }
      connection.onTerminated = { _ in if once.claim() { continuation.resume(returning: nil) } }
      connection.onConnectionLost = { _ in if once.claim() { continuation.resume(returning: nil) } }
      connection.start()
    }
  }
}

/// Lets the first of the connection's callbacks resume the test.
private final class FallbackOnce: @unchecked Sendable {
  private let lock = NSLock()
  private var claimed = false

  func claim() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if claimed { return false }
    claimed = true
    return true
  }
}
