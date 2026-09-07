import Foundation

/// Which multiplexer a persistent session belongs to. The app prefers
/// tmux when installed (see `PersistentSessionTool`); screen sessions
/// created by the older backend keep working.
public enum PersistentSessionKind: Hashable {
  case screen
  case tmux
  case session
}

/// The remote SSH origin of a persistent session: which saved SSH
/// connection it lives on (its config id) and that connection's display
/// label. `nil` on a `ScreenSessionInfo` means the session is local — the
/// pre-existing case.
public struct ScreenRemoteOrigin: Hashable {
  public let sshConfigID: UUID
  public let displayName: String

  public init(sshConfigID: UUID, displayName: String) {
    self.sshConfigID = sshConfigID
    self.displayName = displayName
  }
}

/// A persistent terminal session found on a machine: either a GNU screen
/// session (`screen -ls`) or a tmux session (`tmux ls`). `name` is the full
/// reattach spec — "26040.hermes-test" for screen, "hermes-test" for tmux
/// (tmux has no pid prefix). Local sessions have a nil `remoteOrigin`;
/// sessions found on a connected SSH host carry one so rows can be grouped
/// and identified by their connection.
///
/// Lives in the shared `TerminalIntegrations` target (not the app module) so
/// the pure SwiftPM test target can drive the same parsers the app uses.
public struct ScreenSessionInfo: Identifiable, Hashable {
  public let name: String
  public let pid: Int
  /// Raw state column: screen's "Detached"/"Attached"/"Multi, detached",
  /// or tmux's session_attached flag (0/1).
  public let state: String
  public let kind: PersistentSessionKind
  /// The SSH host this session lives on, nil for local. Defaults to nil so
  /// the existing local parsing (which produces local rows) is unchanged.
  public var remoteOrigin: ScreenRemoteOrigin? = nil

  public init(name: String, pid: Int, state: String, kind: PersistentSessionKind,
              remoteOrigin: ScreenRemoteOrigin? = nil) {
    self.name = name
    self.pid = pid
    self.state = state
    self.kind = kind
    self.remoteOrigin = remoteOrigin
  }

  public var isRemote: Bool { remoteOrigin != nil }

  /// "kind:name" for local sessions; for remote ones the ssh config id is
  /// added so two hosts that each have a session named the same don't
  /// collide (a List row identity must be globally unique).
  public var id: String {
    if let origin = remoteOrigin {
      return "\(kind):\(name)@\(origin.sshConfigID.uuidString)"
    }
    return "\(kind):\(name)"
  }

  /// The session name without the "pid." prefix, e.g. "swiftui-optimization".
  /// For screen this is what `screen -X sessionname` operates on; for
  /// tmux `name` already is the plain session name.
  public var shortName: String {
    if let dot = name.firstIndex(of: ".") {
      return String(name[name.index(after: dot)...])
    }
    return name
  }

  public var isAttached: Bool {
    if kind == .tmux {
      return state == "1"
    }
    return state.localizedCaseInsensitiveContains("attached")
  }

  /// Deterministic UUID derived from the name (plus the ssh config id for
  /// remote sessions) so List selection tags stay stable across monitor
  /// refreshes (screen sessions have no UUIDs). Local rows keep the exact
  /// same UUID as before — the seed is unchanged when `remoteOrigin` is nil.
  public var tagID: UUID {
    let data: [UInt8]
    if let origin = remoteOrigin {
      data = Array(name.utf8) + Array(origin.sshConfigID.uuidString.utf8)
    } else {
      data = Array(name.utf8)
    }
    var bytes = [UInt8](repeating: 0, count: 16)
    for (i, byte) in data.enumerated() {
      bytes[i % 16] ^= byte
    }
    bytes[6] = (bytes[6] & 0x0F) | 0x40  // version 4
    bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 4122 variant
    return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                       bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
  }
}

/// Pure, nonisolated parsers shared by the app's local poller
/// (`ScreenSessionsMonitor`) and its remote scanner
/// (`RemoteScreenSessionsScanner`). Kept in the shared target so the
/// SwiftPM test target drives the exact parsing the app uses.
public enum ScreenSessionsParser {
  /// The remote list commands, run via the existing SSH exec path. The tmux
  /// format matches the local poller so both reuse `parseTmuxOutput`.
  public static let tmuxListCommand = "tmux ls -F '#{session_name} #{session_attached}'"
  public static let screenListCommand = "screen -ls"
  /// `session list` — the session-tool multiplexer's listing of live
  /// reattachable sessions. Output is JSON (not the line-oriented text tmux
  /// and screen emit); spawn the `session` binary from PATH (or the managed
  /// path once SessionBinaryManager lands) and give the stdout straight to
  /// `parseSessionOutput`.
  public static let sessionListCommand = "session list"

  private static let lineRegex = try! NSRegularExpression(
    pattern: #"^\s*(\d+)\.(\S+)\s+\(([^)]+)\)\s*$"#
  )

  /// The JSON shape the `session` tool serializes for `session list`. `title`
  /// and `attached` are emitted with `#[serde(default)]`, so an absent field
  /// must not fail the decode.
  private struct SessionListEntry: Decodable {
    let id: String
    let title: String?
    let attached: Int?
  }

  /// Parses `tmux ls -F` output ("name 0"/"name 1" per line) into
  /// session infos with a zero pid.
  public static func parseTmuxOutput(_ text: String) -> [ScreenSessionInfo] {
    var result: [ScreenSessionInfo] = []
    for line in text.components(separatedBy: .newlines) {
      let parts = line.split(separator: " ", maxSplits: 1)
      guard parts.count == 2, let name = parts.first, let attached = parts.last else { continue }
      result.append(ScreenSessionInfo(name: String(name), pid: 0, state: String(attached), kind: .tmux))
    }
    return result
  }

  /// Parses `screen -ls` output:
  ///   \t26040.hermes-test\t(Detached)
  ///   \t23539.swiftui-optimization\t(Attached)
  public static func parseScreenOutput(_ text: String) -> [ScreenSessionInfo] {
    var result: [ScreenSessionInfo] = []
    for line in text.components(separatedBy: .newlines) {
      let nsLine = line as NSString
      guard let match = lineRegex.firstMatch(in: line, options: [], range: NSRange(location: 0, length: nsLine.length)) else {
        continue
      }
      let pid = Int(nsLine.substring(with: match.range(at: 1))) ?? 0
      let rest = nsLine.substring(with: match.range(at: 2))  // e.g. "pts-0.host"
      let state = nsLine.substring(with: match.range(at: 3))
      result.append(ScreenSessionInfo(name: "\(pid).\(rest)", pid: pid, state: state, kind: .screen))
    }
    return result
  }

  /// Parses `session list` JSON output into session infos. The session-tool
  /// daemon reaps finished sessions before listing, so every entry is a
  /// session the user can actually reattach. `name` is the session's
  /// caller-supplied id (the `session attach <name>` / `session <name>`
  /// reattach spec); `state` is derived from the live attached-client count so
  /// `isAttached` reads "attached"/"detached" the same way screen does. Any
  /// non-JSON or empty payload yields no rows (the daemon was down or not
  /// installed), never a throw.
  public static func parseSessionOutput(_ text: String) -> [ScreenSessionInfo] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    guard let data = trimmed.data(using: .utf8),
          let entries = try? JSONDecoder().decode([SessionListEntry].self, from: data)
    else { return [] }
    return entries.map { entry in
      let attached = entry.attached ?? 0
      return ScreenSessionInfo(
        name: entry.id,
        pid: 0,
        state: attached > 0 ? "attached" : "detached",
        kind: .session
      )
    }
  }

  /// Reuses the same parsers as the local poller, tagging every parsed row
  /// with the SSH origin the command was run against.
  public static func parse(command: String, text: String, origin: ScreenRemoteOrigin) -> [ScreenSessionInfo] {
    let base: [ScreenSessionInfo]
    if command == tmuxListCommand {
      base = parseTmuxOutput(text)
    } else if command == sessionListCommand {
      base = parseSessionOutput(text)
    } else {
      base = parseScreenOutput(text)
    }
    return base.map { info in
      ScreenSessionInfo(name: info.name, pid: info.pid, state: info.state, kind: info.kind, remoteOrigin: origin)
    }
  }

  /// A unique session name for createSession: "zsh", "zsh-1", "zsh-2", …
  /// screen does NOT uniquify `-dm` names itself (two sessions can share a
  /// name, which would break sidebar row identity), so we must.
  public static func nextSessionName(existing: Set<String>) -> String {
    if !existing.contains("zsh") { return "zsh" }
    var n = 1
    while existing.contains("zsh-\(n)") { n += 1 }
    return "zsh-\(n)"
  }
}
