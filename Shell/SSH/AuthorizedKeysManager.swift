import CryptoKit
import Foundation
import ShellKit

/// Manages a machine's `~/.ssh/authorized_keys` — either the local Mac's
/// file (direct FileManager access) or a remote machine's, reached through
/// a headless SSH exec (the same `SSHSession` transport the app uses for
/// action sessions; saved passwords are used automatically, host keys are
/// trusted on first use because opening this panel IS the intent to connect;
/// a changed host key is refused).
///
/// The panel never deals in raw lines: entries are key-material-matched
/// (`"type base64"`), so the same key is recognized regardless of its
/// comment.
@MainActor
final class AuthorizedKeysManager {
  enum Target: Hashable {
    case local
    case ssh(SSHConfig)
  }

  /// One key shown in the panel, with its authorized_keys status.
  struct KeyEntry: Identifiable, Equatable {
    enum Source {
      case device   // this device's Secure Enclave key
      case icloud   // another device, published via iCloud
    }

    var id: String { keyMaterial }
    var keyMaterial: String       // "ecdsa-sha2-nistp256 <base64>" — the matchable identity
    var fullLine: String          // with comment
    var displayName: String       // comment, else fingerprint
    var fingerprint: String
    var source: Source
    var added: Bool
  }

  let target: Target
  /// The SSH config for `.ssh` targets (nil for local).
  let sshConfig: SSHConfig?

  private let homeURL: URL  // injectable for tests

  init(target: Target, homeURL: URL = URL(fileURLWithPath: NSHomeDirectory())) {
    self.target = target
    self.homeURL = homeURL
    switch target {
    case .local:
      sshConfig = nil
    case .ssh(let config):
      sshConfig = config
    }
  }

  // MARK: - Reading

  /// The raw authorized_keys lines (empty when the file is missing).
  func readLines() async throws -> [String] {
    switch target {
    case .local:
      return try Self.readLocalLines(homeURL: homeURL)
    case .ssh(let config):
      let output = try await runRemote(config: config, command: Self.readCommand)
      return Self.parseOutput(output)
    }
  }

  /// The key-material set currently in the file ("type base64" lines).
  func readKeyMaterials() async throws -> Set<String> {
    let lines = try await readLines()
    return Set(lines.compactMap(Self.keyMaterial(of:)))
  }

  // MARK: - Mutations (each followed by a re-read in the UI)

  /// Appends one key line. Idempotent-ish: adding an already-present key
  /// is harmless (ssh ignores duplicates), but the panel hides Add when
  /// the key is already added.
  func append(keyLine: String) async throws {
    // Key lines arrive through iCloud: one that carries a newline or
    // options (`command=`, `from=`) would add more than this key.
    guard Self.isPlainKeyLine(keyLine) else { throw AuthorizedKeysError.invalidKeyLine }
    switch target {
    case .local:
      try Self.appendLocal(keyLine: keyLine, homeURL: homeURL)
    case .ssh(let config):
      let command = Self.appendCommand(keyLine: keyLine)
      _ = try await runRemote(config: config, command: command)
    }
  }

  /// Rewrites the file without the given key materials (removes them
  /// wherever they appear, keeps every other line).
  func remove(keyMaterials: Set<String>) async throws {
    let lines = try await readLines()
    let remaining = lines.filter { line in
      guard let material = Self.keyMaterial(of: line) else { return true }
      return !keyMaterials.contains(material)
    }
    switch target {
    case .local:
      try Self.writeLocal(lines: remaining, homeURL: homeURL)
    case .ssh(let config):
      let command = Self.rewriteCommand(lines: remaining)
      _ = try await runRemote(config: config, command: command)
    }
  }

  // MARK: - Local implementation

  static func readLocalLines(homeURL: URL) throws -> [String] {
    let url = homeURL.appendingPathComponent(".ssh/authorized_keys", isDirectory: false)
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    let data = try Data(contentsOf: url)
    let text = String(data: data, encoding: .utf8) ?? ""
    return Self.parseLines(text)
  }

  static func appendLocal(keyLine: String, homeURL: URL) throws {
    let fm = FileManager.default
    let sshDir = homeURL.appendingPathComponent(".ssh", isDirectory: true)
    let url = sshDir.appendingPathComponent("authorized_keys", isDirectory: false)
    try fm.createDirectory(at: sshDir, withIntermediateDirectories: true)
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sshDir.path)
    if !fm.fileExists(atPath: url.path) {
      fm.createFile(atPath: url.path, contents: Data())
    }
    if let handle = FileHandle(forWritingAtPath: url.path) {
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: Data((keyLine + "\n").utf8))
    }
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  static func writeLocal(lines: [String], homeURL: URL) throws {
    let fm = FileManager.default
    let sshDir = homeURL.appendingPathComponent(".ssh", isDirectory: true)
    let url = sshDir.appendingPathComponent("authorized_keys", isDirectory: false)
    try fm.createDirectory(at: sshDir, withIntermediateDirectories: true)
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sshDir.path)
    let data = Data((lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).utf8)
    try data.write(to: url)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  // MARK: - Remote (SSH exec) implementation

  /// Reads the file; missing file → empty output, exit 0.
  static let readCommand = "cat ~/.ssh/authorized_keys 2>/dev/null || true"

  /// Appends one line with correct permissions. Single-quote escaping keeps
  /// device names with apostrophes safe.
  static func appendCommand(keyLine: String) -> String {
    let escaped = keyLine.replacingOccurrences(of: "'", with: "'\\''")
    return "mkdir -p ~/.ssh && chmod 700 ~/.ssh && printf '%s\\n' '\(escaped)' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
  }

  /// Rewrites the file to exactly `lines` (remove path). A random quoted
  /// heredoc delimiter keeps the content verbatim — no interpolation, no
  /// quoting hazards.
  static func rewriteCommand(lines: [String]) -> String {
    let delimiter = "SHELLKEY_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))_EOF"
    var command = "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat > ~/.ssh/authorized_keys <<'\(delimiter)'\n"
    command += lines.joined(separator: "\n")
    if !lines.isEmpty { command += "\n" }
    command += "\(delimiter)\nchmod 600 ~/.ssh/authorized_keys"
    return command
  }

  /// Splits exec output into lines, stripping the CR the PTY's ONLCR adds
  /// and the phantom segment after the final newline.
  static func parseOutput(_ output: String) -> [String] {
    parseLines(
      output
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
    )
  }

  /// Splits text into lines; the segment after a trailing newline is not a
  /// line (so "a\nb\n" is two lines, and a trailing blank line stays real:
  /// "a\n\n" is two lines, the second empty).
  static func parseLines(_ text: String) -> [String] {
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if lines.last == "" { lines.removeLast() }
    return lines
  }

  /// The matchable identity of an authorized_keys line: the first two
  /// whitespace-separated fields when the type looks like a key type.
  static func keyMaterial(of line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
    let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
    guard parts.count >= 2 else { return nil }
    let type = String(parts[0])
    let looksLikeKeyType = type.hasPrefix("ssh-") || type.hasPrefix("ecdsa-") || type.hasPrefix("sk-")
    guard looksLikeKeyType else { return nil }
    return "\(type) \(parts[1])"
  }

  /// One line holding just a key: type, base64 and an optional comment.
  static func isPlainKeyLine(_ line: String) -> Bool {
    !line.contains(where: { $0.isNewline || $0 == "\0" }) && keyMaterial(of: line) != nil
  }

  // MARK: - Headless SSH exec

  private func runRemote(config: SSHConfig, command: String) async throws -> String {
    let runner = HeadlessSSHCommandRunner()
    let result = try await runner.run(config: config, command: command)
    if result.exitCode != 0 {
      let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
      throw AuthorizedKeysError.remoteCommandFailed(
        host: config.host,
        code: result.exitCode,
        output: detail.isEmpty ? nil : detail
      )
    }
    return result.output
  }
}

enum AuthorizedKeysError: LocalizedError {
  case remoteCommandFailed(host: String, code: Int32, output: String?)
  case connectionFailed(String)
  case invalidKeyLine

  var errorDescription: String? {
    switch self {
    case .remoteCommandFailed(let host, let code, let output):
      let detail = output.map { ": \($0)" } ?? ""
      return "The command failed on \(host) (exit \(code))\(detail)."
    case .connectionFailed(let message):
      return "Could not connect: \(message)"
    case .invalidKeyLine:
      return "The key is not a single public key line."
    }
  }
}
