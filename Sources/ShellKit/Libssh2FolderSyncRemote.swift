import Foundation

/// The folder sync's host over Shell's own SSH connection (`SSHSession.folderSyncRemote`): SFTP on its login and a
/// hashing command on a second channel of it. Nothing is handed to another process: the host's key or password
/// stays with the connection.
nonisolated final class Libssh2FolderSyncRemote: FolderSyncRemote, @unchecked Sendable {
  private let connection: Libssh2Connection

  init(connection: Libssh2Connection) {
    self.connection = connection
  }

  private func sftp<T: Sendable>(_ body: @escaping @Sendable (Libssh2SFTP) throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
      connection.sftp(body) { continuation.resume(with: $0) }
    }
  }

  func realPath(_ path: String) async throws -> String { try await sftp { try $0.realPath(path) } }
  func info(_ path: String) async throws -> FolderSyncRemoteItem? { try await sftp { try $0.info(path) } }
  func list(_ path: String) async throws -> [FolderSyncRemoteItem] { try await sftp { try $0.list(path) } }

  func makeDirectory(_ path: String, permissions: UInt32) async throws {
    try await sftp { try $0.makeDirectory(path, permissions: permissions) }
  }

  func upload(_ local: URL, to path: String, permissions: UInt32) async throws {
    try await sftp { try $0.upload(local, to: path, permissions: permissions) }
  }

  func rename(_ source: String, to destination: String) async throws {
    try await sftp { try $0.rename(source, to: destination) }
  }

  func removeFile(_ path: String) async throws { try await sftp { try $0.removeFile(path) } }
  func removeDirectory(_ path: String) async throws { try await sftp { try $0.removeDirectory(path) } }

  func setModified(_ path: String, to date: Date) async throws {
    try await sftp { try $0.setModified(path, to: date) }
  }

  /// `sha256sum` (or `shasum -a 256`) on the host, the paths on its standard input separated by NULs, so no path
  /// is ever part of a command line. The command itself is a constant.
  static let hashCommand =
    "sh -c 'if command -v sha256sum >/dev/null 2>&1; then exec xargs -0 sha256sum --; elif command -v shasum >/dev/null 2>&1; then exec xargs -0 shasum -a 256 --; else echo \(noHashTool); exit 127; fi'"
  static let noHashTool = "shell-folder-sync-no-sha256"

  func sha256(_ paths: [String]) async throws -> [String: String]? {
    if paths.isEmpty { return [:] }
    var input = Data()
    for path in paths {
      input.append(contentsOf: Array(path.utf8))
      input.append(0)
    }
    let result = try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<RemoteCommandResult, Error>) in
      connection.runRemoteCommand(Self.hashCommand, terminal: false, input: input, timeout: 600) {
        continuation.resume(with: $0)
      }
    }
    if result.stdout.contains(Self.noHashTool) { return nil }
    return Self.parseHashes(result.stdout)
  }

  /// `sha256sum`'s lines: `<64 hex>  <path>` (`*` instead of the second space in binary mode); a line starting
  /// with `\` has its path escaped (`\\`, `\n`, `\r`), for a name holding those.
  static func parseHashes(_ output: String) -> [String: String] {
    var hashes: [String: String] = [:]
    for raw in output.split(separator: "\n", omittingEmptySubsequences: true) {
      var line = Substring(raw)
      let escaped = line.hasPrefix("\\")
      if escaped { line = line.dropFirst() }
      guard line.count > 66 else { continue }
      let hash = line.prefix(64)
      guard hash.allSatisfy(\.isHexDigit) else { continue }
      let rest = line.dropFirst(64)
      guard rest.hasPrefix("  ") || rest.hasPrefix(" *") else { continue }
      var name = String(rest.dropFirst(2))
      if escaped { name = unescape(name) }
      hashes[name] = hash.lowercased()
    }
    return hashes
  }

  private static func unescape(_ text: String) -> String {
    var result = ""
    var iterator = text.makeIterator()
    while let c = iterator.next() {
      guard c == "\\", let next = iterator.next() else {
        result.append(c)
        continue
      }
      switch next {
      case "n": result.append("\n")
      case "r": result.append("\r")
      default: result.append(next)
      }
    }
    return result
  }
}
