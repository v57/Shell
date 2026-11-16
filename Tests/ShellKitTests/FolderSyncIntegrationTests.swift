import CryptoKit
import Foundation
import Testing
@testable import ShellKit

/// The folder sync over Shell's own SSH connection against a real sshd on this machine (a user-level one: see
/// SSH's CLAUDE.md), with a throwaway Secure Enclave key it writes to the sshd's authorized keys file:
/// `SHELL_SSH_SYNC_TEST_PORT`, `SHELL_SSH_SYNC_TEST_KEYS` (that file), `SHELL_SSH_SYNC_TEST_DIR` (a scratch folder
/// the test syncs into and may delete in) and optionally `SHELL_SSH_SYNC_TEST_USER`; skipped otherwise. Host keys go
/// to a scratch defaults suite, never the vault. Never point it at a real server.
@MainActor
struct FolderSyncIntegrationTests {
  static let environment = ProcessInfo.processInfo.environment
  static let configured =
    environment["SHELL_SSH_SYNC_TEST_PORT"] != nil && environment["SHELL_SSH_SYNC_TEST_KEYS"] != nil
    && environment["SHELL_SSH_SYNC_TEST_DIR"] != nil && SecureEnclave.isAvailable

  @Test(.enabled(if: configured, "needs SHELL_SSH_SYNC_TEST_PORT, SHELL_SSH_SYNC_TEST_KEYS and SHELL_SSH_SYNC_TEST_DIR"))
  func syncsOverSFTP() async throws {
    let fm = FileManager.default
    let scratch = URL(fileURLWithPath: Self.environment["SHELL_SSH_SYNC_TEST_DIR"]!).resolvingSymlinksInPath()
    let run = scratch.appendingPathComponent("run-\(UUID().uuidString.prefix(8))")
    let local = run.appendingPathComponent("local")
    let site = run.appendingPathComponent("site")
    let outside = run.appendingPathComponent("outside")
    defer { try? fm.removeItem(at: run) }
    func write(_ text: String, _ url: URL) throws {
      try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try text.write(to: url, atomically: true, encoding: .utf8)
    }
    try write("<h1>new</h1>", local.appendingPathComponent("index.html"))
    try write("body{}", local.appendingPathComponent("css/site.css"))
    try write("same", local.appendingPathComponent("same.txt"))
    try write("SECRET", local.appendingPathComponent(".env"))
    let big = String(repeating: "0123456789abcdef", count: 100_000)  // 1.6 MB: many SFTP writes
    try write(big, local.appendingPathComponent("big.bin"))
    try write("<h1>OLD</h1>", site.appendingPathComponent("index.html"))
    try write("same", site.appendingPathComponent("same.txt"))
    try write("stale", site.appendingPathComponent("stale.html"))
    try write("keep", site.appendingPathComponent(".htaccess"))
    try write("gone", site.appendingPathComponent("old/page.html"))
    try write("precious", outside.appendingPathComponent("data.txt"))
    try fm.createSymbolicLink(atPath: site.appendingPathComponent("escape").path, withDestinationPath: outside.path)

    let key = try SecureEnclave.P256.Signing.PrivateKey()
    let line = SSHKeychain.publicKeyOpenSSHLine(for: key, comment: "Shell folder sync test") + "\n"
    try line.write(toFile: Self.environment["SHELL_SSH_SYNC_TEST_KEYS"]!, atomically: true, encoding: .utf8)
    let config = SSHConfig(
      host: "127.0.0.1", user: Self.environment["SHELL_SSH_SYNC_TEST_USER"] ?? NSUserName(),
      port: Int(Self.environment["SHELL_SSH_SYNC_TEST_PORT"]!)!, authMethod: .keychainKey)
    let knownHosts = KnownHostsStore(defaults: UserDefaults(suiteName: "shell-test-\(UUID().uuidString)")!, store: nil)
    let connection = Libssh2Connection(config: config, privateKey: key, forwardingOnly: true, knownHosts: knownHosts)
    connection.onHostKeyChallenge = { $0.respond(true) }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let once = SyncOnce()
      connection.onConnected = { if once.claim() { continuation.resume() } }
      connection.onTerminated = { message in
        if once.claim() { continuation.resume(throwing: Libssh2Connection.EngineError.remoteCommandFailed(message)) }
      }
      connection.start()
    }
    defer { connection.close() }

    let remote = Libssh2FolderSyncRemote(connection: connection)
    let engine = FolderSyncEngine(
      settings: FolderSyncSettings(localPath: local.path, remotePath: site.path), remote: remote)
    let preparation = try await engine.prepare()
    let plan = preparation.plan
    #expect(plan.comparison == .sha256)
    #expect(Set(plan.uploads.map(\.path)) == ["index.html", "css/site.css", "big.bin"])
    #expect(plan.unchanged == 1)
    #expect(Set(plan.deletions.map(\.path)) == ["stale.html", "old/page.html", "old", "escape"])
    #expect(try String(contentsOf: site.appendingPathComponent("index.html"), encoding: .utf8) == "<h1>OLD</h1>")

    let result = await engine.apply(preparation)
    #expect(result.failures.isEmpty, "\(result.failures)")
    #expect(try String(contentsOf: site.appendingPathComponent("index.html"), encoding: .utf8) == "<h1>new</h1>")
    #expect(try String(contentsOf: site.appendingPathComponent("css/site.css"), encoding: .utf8) == "body{}")
    #expect(try String(contentsOf: site.appendingPathComponent("big.bin"), encoding: .utf8) == big)
    #expect(try String(contentsOf: site.appendingPathComponent(".htaccess"), encoding: .utf8) == "keep")
    #expect(!fm.fileExists(atPath: site.appendingPathComponent(".env").path))
    #expect(!fm.fileExists(atPath: site.appendingPathComponent("stale.html").path))
    #expect(!fm.fileExists(atPath: site.appendingPathComponent("old").path))
    #expect((try? fm.destinationOfSymbolicLink(atPath: site.appendingPathComponent("escape").path)) == nil)
    // The link was removed, never followed.
    #expect(try String(contentsOf: outside.appendingPathComponent("data.txt"), encoding: .utf8) == "precious")
    #expect(try fm.contentsOfDirectory(atPath: site.path).filter { $0.hasSuffix(".part") }.isEmpty)
    // Times match, so a host without a hashing tool would see the files as unchanged too.
    let localDate = try fm.attributesOfItem(atPath: local.appendingPathComponent("index.html").path)[.modificationDate] as! Date
    let remoteDate = try fm.attributesOfItem(atPath: site.appendingPathComponent("index.html").path)[.modificationDate] as! Date
    #expect(Int(localDate.timeIntervalSince1970) == Int(remoteDate.timeIntervalSince1970))

    #expect(try await engine.prepare().plan.isEmpty)

    // Same size, other content: found by SHA-256 alone.
    try write("<h1>NEW</h1>", local.appendingPathComponent("index.html"))
    try fm.setAttributes([.modificationDate: localDate], ofItemAtPath: local.appendingPathComponent("index.html").path)
    let edited = try await engine.prepare()
    #expect(edited.plan.uploads.map(\.path) == ["index.html"])
    #expect(edited.plan.uploads.first?.reason == .content)
  }
}

private final class SyncOnce: @unchecked Sendable {
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
