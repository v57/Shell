import CryptoKit
import Foundation
import Testing
@testable import ShellKit

/// The iPhone and iPad editor's read and save (`RemoteFileEditing`) over Shell's own SSH connection against a real
/// sshd on this machine, set up as for `FolderSyncIntegrationTests` (the same `SHELL_SSH_SYNC_TEST_*` variables; the
/// test works in a folder of its own inside `SHELL_SSH_SYNC_TEST_DIR`; run it apart from that test, as both write the
/// authorized keys file). Never point it at a real server.
@MainActor
struct RemoteFileEditingIntegrationTests {
  static let environment = ProcessInfo.processInfo.environment
  static let configured = FolderSyncIntegrationTests.configured

  @Test(.enabled(if: configured, "needs SHELL_SSH_SYNC_TEST_PORT, SHELL_SSH_SYNC_TEST_KEYS and SHELL_SSH_SYNC_TEST_DIR"))
  func readsAndSavesOverSFTP() async throws {
    let fm = FileManager.default
    // realpath, as the host's SFTP resolves it (URL's resolvingSymlinksInPath keeps /tmp for /private/tmp).
    let resolved = realpath(Self.environment["SHELL_SSH_SYNC_TEST_DIR"]!, nil)!
    defer { free(resolved) }
    let scratch = URL(fileURLWithPath: String(cString: resolved))
    let run = scratch.appendingPathComponent("edit-\(UUID().uuidString.prefix(8))")
    try fm.createDirectory(at: run, withIntermediateDirectories: true)
    defer {
      try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: run.appendingPathComponent("locked").path)
      try? fm.removeItem(at: run)
    }
    let connection = try await Self.connect()
    defer { connection.close() }
    func sftp<T: Sendable>(_ body: @escaping @Sendable (Libssh2SFTP) throws -> T) async throws -> T {
      try await withCheckedThrowingContinuation { continuation in
        connection.sftp(body) { continuation.resume(with: $0) }
      }
    }
    func temporaries(in folder: URL) throws -> [String] {
      try fm.contentsOfDirectory(atPath: folder.path).filter { $0.contains(".shell-save-") }
    }

    // A byte-order mark, CRLF line ends and non-ASCII text come back byte for byte.
    let file = run.appendingPathComponent("config.yml")
    let original = Data([0xEF, 0xBB, 0xBF]) + Data("name: café\r\nport: 22\r\n".utf8)
    try original.write(to: file)
    try fm.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
    let read = try await sftp { try $0.readForEditing(file.path, maxBytes: 512 * 1024) }
    #expect(read.data == original)
    #expect(!read.isTruncated)
    #expect(read.path == file.path)
    #expect(read.stamp.size == UInt64(original.count))

    let edited = original + Data("user: v57\r\n".utf8)
    let stamp = try await sftp { try $0.saveEdited(edited, to: read.path, expecting: read.stamp) }
    #expect(try Data(contentsOf: file) == edited)
    #expect(stamp.size == UInt64(edited.count))
    #expect((try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o640)
    #expect(try temporaries(in: run).isEmpty)

    // The host changed it since: nothing is written, until Save Anyway (no expected stamp).
    let theirs = Data("changed elsewhere, and longer\n".utf8)
    try theirs.write(to: file)
    await #expect(throws: RemoteFileError.changedOnHost(file.path)) {
      _ = try await sftp { try $0.saveEdited(Data("mine\n".utf8), to: file.path, expecting: stamp) }
    }
    #expect(try Data(contentsOf: file) == theirs)
    _ = try await sftp { try $0.saveEdited(Data("mine\n".utf8), to: file.path, expecting: nil) }
    #expect(try Data(contentsOf: file) == Data("mine\n".utf8))

    // Removed since it was read.
    let gone = run.appendingPathComponent("gone.txt")
    try Data("x".utf8).write(to: gone)
    let goneRead = try await sftp { try $0.readForEditing(gone.path, maxBytes: 1024) }
    try fm.removeItem(at: gone)
    await #expect(throws: RemoteFileError.removedFromHost(gone.path)) {
      _ = try await sftp { try $0.saveEdited(Data("y".utf8), to: gone.path, expecting: goneRead.stamp) }
    }

    // A link: the file it points to is read and replaced, and the link stays a link.
    let target = run.appendingPathComponent("target.txt")
    let link = run.appendingPathComponent("link.txt")
    try Data("through a link\n".utf8).write(to: target)
    try fm.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
    let linked = try await sftp { try $0.readForEditing(link.path, maxBytes: 1024) }
    #expect(linked.path == target.path)
    _ = try await sftp { try $0.saveEdited(Data("saved\n".utf8), to: linked.path, expecting: linked.stamp) }
    #expect(try Data(contentsOf: target) == Data("saved\n".utf8))
    #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == target.path)

    // A file longer than the limit: its start, marked truncated.
    let long = run.appendingPathComponent("long.log")
    let longData = Data(String(repeating: "0123456789abcde\n", count: 40_000).utf8)  // 640 KB
    try longData.write(to: long)
    let longRead = try await sftp { try $0.readForEditing(long.path, maxBytes: 512 * 1024) }
    #expect(longRead.isTruncated)
    #expect(longRead.data == longData.prefix(512 * 1024))

    // 512 KB saved in one go.
    let big = Data(String(repeating: "let value = 42 // ü\n", count: 26_000).utf8)
    let bigFile = run.appendingPathComponent("big.swift")
    try Data().write(to: bigFile)
    let empty = try await sftp { try $0.readForEditing(bigFile.path, maxBytes: 512 * 1024) }
    _ = try await sftp { try $0.saveEdited(big, to: bigFile.path, expecting: empty.stamp) }
    #expect(try Data(contentsOf: bigFile) == big)

    // A folder that takes no new file: the file itself is written over.
    let locked = run.appendingPathComponent("locked")
    try fm.createDirectory(at: locked, withIntermediateDirectories: true)
    let inLocked = locked.appendingPathComponent("notes.txt")
    try Data("before\n".utf8).write(to: inLocked)
    try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
    let lockedRead = try await sftp { try $0.readForEditing(inLocked.path, maxBytes: 1024) }
    _ = try await sftp { try $0.saveEdited(Data("after\n".utf8), to: inLocked.path, expecting: lockedRead.stamp) }
    #expect(try Data(contentsOf: inLocked) == Data("after\n".utf8))
    #expect(try temporaries(in: locked).isEmpty)

    // A folder isn't a file.
    await #expect(throws: RemoteFileError.notAFile(locked.path)) {
      _ = try await sftp { try $0.readForEditing(locked.path, maxBytes: 1024) }
    }
  }

  /// Logs in to the test sshd with a throwaway Secure Enclave key it writes to the sshd's authorized keys file.
  static func connect() async throws -> Libssh2Connection {
    let key = try SecureEnclave.P256.Signing.PrivateKey()
    let line = SSHKeychain.publicKeyOpenSSHLine(for: key, comment: "Shell file editing test") + "\n"
    try line.write(toFile: environment["SHELL_SSH_SYNC_TEST_KEYS"]!, atomically: true, encoding: .utf8)
    let config = SSHConfig(
      host: "127.0.0.1", user: environment["SHELL_SSH_SYNC_TEST_USER"] ?? NSUserName(),
      port: Int(environment["SHELL_SSH_SYNC_TEST_PORT"]!)!, authMethod: .keychainKey)
    let knownHosts = KnownHostsStore(defaults: UserDefaults(suiteName: "shell-test-\(UUID().uuidString)")!, store: nil)
    let connection = Libssh2Connection(config: config, privateKey: key, forwardingOnly: true, knownHosts: knownHosts)
    connection.onHostKeyChallenge = { $0.respond(true) }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let once = EditOnce()
      connection.onConnected = { if once.claim() { continuation.resume() } }
      connection.onTerminated = { message in
        if once.claim() { continuation.resume(throwing: Libssh2Connection.EngineError.remoteCommandFailed(message)) }
      }
      connection.start()
    }
    return connection
  }
}

private final class EditOnce: @unchecked Sendable {
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
