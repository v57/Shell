import Foundation
import Terminal

/// Which multiplexer a persistent session belongs to. The app prefers
/// tmux when installed (see `PersistentSessionTool`); screen sessions
/// created by the older backend keep working.
enum PersistentSessionKind: Hashable {
  case screen
  case tmux
}

/// A persistent terminal session found on the local machine: either a GNU
/// screen session (`screen -ls`) or a tmux session (`tmux ls`). `name` is
/// the full reattach spec — "26040.hermes-test" for screen, "hermes-test"
/// for tmux (tmux has no pid prefix).
struct ScreenSessionInfo: Identifiable, Hashable {
  let name: String
  let pid: Int
  /// Raw state column: screen's "Detached"/"Attached"/"Multi, detached",
  /// or tmux's session_attached flag (0/1).
  let state: String
  let kind: PersistentSessionKind
  
  var id: String { "\(kind):\(name)" }
  
  /// The session name without the "pid." prefix, e.g. "swiftui-optimization".
  /// For screen this is what `screen -X sessionname` operates on; for
  /// tmux `name` already is the plain session name.
  var shortName: String {
    if let dot = name.firstIndex(of: ".") {
      return String(name[name.index(after: dot)...])
    }
    return name
  }
  
  var isAttached: Bool {
    if kind == .tmux {
      return state == "1"
    }
    return state.localizedCaseInsensitiveContains("attached")
  }
  
  /// Deterministic UUID derived from the name so List selection tags stay
  /// stable across monitor refreshes (screen sessions have no UUIDs).
  var tagID: UUID {
    let data = Array(name.utf8)
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

/// Error surfaced for create/rename actions, shown as an alert.
struct ScreenActionError: Identifiable, Equatable {
  let id = UUID()
  let title: String
  let message: String
}

#if os(macOS)
/// Polls the local multiplexers (`tmux ls` and `screen -ls`) and publishes
/// the merged list of persistent sessions. When tmux is installed, tmux is
/// the preferred backend for creating/renaming; screen sessions created by
/// the older backend still appear and keep working.
///
/// macOS only: persistent local sessions (screen/tmux) need local process
/// management; the iOS app ships SSH + notes only.
@MainActor
@Observable
final class ScreenSessionsMonitor {
  /// The multiplexer backend to use for new sessions. tmux wins when
  /// installed; otherwise GNU screen (which macOS ships with).
  static var preferredKind: PersistentSessionKind {
    tmuxInstalled() ? .tmux : .screen
  }
  
  /// Resolves the tmux executable, checking common install locations and
  /// then PATH. Returns nil when tmux is not installed.
  static func tmuxInstalled() -> Bool {
    tmuxPath() != nil
  }
  
  /// Resolves the tmux executable (delegates to the Terminal library's
  /// preset resolver: common install locations, then PATH).
  static func tmuxPath() -> String? {
    LocalPTYTransport.tmuxExecutablePath()
  }
  
  private(set) var sessions: [ScreenSessionInfo] = []
  private(set) var errorMessage: String?
  /// Set when a create/rename action fails; cleared by the UI on dismiss.
  var actionError: ScreenActionError?
  
  private let queue = DispatchQueue(label: "ScreenSessionsMonitor.list")
  private var timer: Timer?
  
  init() {
    refresh()
    timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.refresh()
      }
    }
  }
  
  func refresh() {
    queue.async { [weak self] in
      let (sessions, message) = Self.runList()
      DispatchQueue.main.async {
        guard let self else { return }
        if let message {
          self.errorMessage = message
        } else {
          self.sessions = sessions
          self.errorMessage = nil
        }
      }
    }
  }
  
  /// Lists sessions from every available multiplexer and merges them.
  /// With neither tmux nor screen installed, reports the reason.
  private static func runList() -> ([ScreenSessionInfo], String?) {
    var sessions: [ScreenSessionInfo] = []
    var messages: [String] = []
    if let tmux = tmuxPath() {
      let (tmuxSessions, tmuxError) = runTmuxList(tmux: tmux)
      sessions.append(contentsOf: tmuxSessions)
      if let tmuxError { messages.append(tmuxError) }
    }
    // screen is bundled with macOS; only skip it when tmux already covered
    // the "no multiplexer" case.
    if !(tmuxPath() == nil) || sessions.isEmpty {
      let (screenSessions, screenError) = runScreenList()
      sessions.append(contentsOf: screenSessions)
      if let screenError { messages.append(screenError) }
    }
    if sessions.isEmpty, !messages.isEmpty {
      return ([], messages.joined(separator: "\n"))
    }
    return (sessions, nil)
  }
  
  /// Creates a new detached persistent session running an interactive zsh.
  /// Uses tmux when installed (`tmux new-session -d`), else screen
  /// (`screen -dmS <name>`). Updates the list and calls `onCreated` with
  /// the new session's info so the caller can immediately open a terminal
  /// attached to it.
  func createSession(onCreated: ((ScreenSessionInfo) -> Void)? = nil) {
    let kind = Self.preferredKind
    let name = nextSessionName()
    queue.async { [weak self] in
      let message: String?
      if kind == .tmux, let tmux = Self.tmuxPath() {
        message = Self.runTmuxCreate(tmux: tmux, name: name)
      } else {
        message = Self.runCreate(name: name)
      }
      // Re-list right away so the new session's state is known.
      // `screen -dm` (and tmux new-session) can return a hair before the
      // socket is listed, so retry briefly instead of handing back a
      // guessed identity.
      var created: ScreenSessionInfo?
      var listSessions: [ScreenSessionInfo] = []
      var listMessage: String?
      if message == nil {
        for _ in 0..<10 {
          (listSessions, listMessage) = Self.runList()
          if let found = listSessions.first(where: { $0.shortName == name }) {
            created = found
            break
          }
          Thread.sleep(forTimeInterval: 0.1)
        }
      }
      DispatchQueue.main.async {
        guard let self else { return }
        if let message {
          self.actionError = ScreenActionError(
            title: "Could not create persistent session",
            message: message
          )
          self.refresh()
          return
        }
        self.sessions = listSessions
        self.errorMessage = listMessage
        if let created {
          onCreated?(created)
        } else {
          // Didn't show up yet; the 5s poller will pick it up.
          self.refresh()
        }
      }
    }
  }

  /// Kills a persistent session: `screen -S <name> -X quit` for screen
  /// sessions, `tmux kill-session -t <name>` for tmux sessions. This
  /// terminates the session and every client attached to it (including
  /// our own), then refreshes the list.
  func quit(_ info: ScreenSessionInfo) {
    let name = info.name
    let kind = info.kind
    queue.async { [weak self] in
      let message: String?
      if kind == .tmux, let tmux = Self.tmuxPath() {
        message = Self.runTmuxQuit(tmux: tmux, name: name)
      } else {
        message = Self.runQuit(name: name)
      }
      DispatchQueue.main.async {
        guard let self else { return }
        if let message {
          self.actionError = ScreenActionError(
            title: "Could not close persistent session",
            message: message
          )
        }
        self.refresh()
      }
    }
  }
  
  /// A unique session name for createSession: "zsh", "zsh-1", "zsh-2", …
  /// screen does NOT uniquify `-dm` names itself (two sessions can share a
  /// name, which would break sidebar row identity), so we must.
  private func nextSessionName() -> String {
    let existing = Set(sessions.map(\.shortName))
    if !existing.contains("zsh") { return "zsh" }
    var n = 1
    while existing.contains("zsh-\(n)") { n += 1 }
    return "zsh-\(n)"
  }
  
  // MARK: - screen -dmS
  
  private static func runCreate(name: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/screen")
    // screen starts the window in ITS cwd, and the app's cwd is "/"
    // when launched via Finder — cd home explicitly inside the shell.
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    process.arguments = ["-dmS", name, "/bin/sh", "-c", "cd '\(home)' && exec /bin/zsh -l -i"]
    let err = Pipe()
    process.standardOutput = Pipe()
    process.standardError = err
    do {
      try process.run()
    } catch {
      return "screen not available: \(error.localizedDescription)"
    }
    process.waitUntilExit()
    guard process.terminationStatus != 0 else { return nil }
    let message = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Failed to create session (exit \(process.terminationStatus))"
    return message
  }
  
  /// Renames a session via `screen -S <name> -X sessionname <new>` or
  /// `tmux rename-session -t <name> <new>`. Sets `actionError` on
  /// failure, then refreshes the list.
  func rename(_ info: ScreenSessionInfo, to newName: String) {
    let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      actionError = ScreenActionError(
        title: "Could not rename persistent session",
        message: "Name must not be empty."
      )
      return
    }
    guard trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
      actionError = ScreenActionError(
        title: "Could not rename persistent session",
        message: "Session names can't contain spaces."
      )
      return
    }
    // screen -S prefix-matches (and tmux -t exact-matches), so a duplicate
    // name would make later attach/rename commands ambiguous (and break
    // sidebar row identity).
    guard !sessions.contains(where: { $0.id != info.id && $0.shortName == trimmed }) else {
      actionError = ScreenActionError(
        title: "Could not rename persistent session",
        message: "A session named '\(trimmed)' already exists."
      )
      return
    }
    let oldName = info.name
    let kind = info.kind
    queue.async { [weak self] in
      let message: String?
      if kind == .tmux, let tmux = Self.tmuxPath() {
        message = Self.runTmuxRename(tmux: tmux, oldName: oldName, newName: trimmed)
      } else {
        message = Self.runRename(oldName: oldName, newName: trimmed)
      }
      DispatchQueue.main.async {
        guard let self else { return }
        if let message {
          self.actionError = ScreenActionError(
            title: "Could not rename persistent session",
            message: message
          )
        }
        self.refresh()
      }
    }
  }
  
  // MARK: - tmux commands

  /// Creates a detached tmux session running an interactive zsh. The
  /// session starts in its own cwd; the shell is exec'd so the tmux
  /// process tree holds one shell per window.
  private static func runTmuxCreate(tmux: String, name: String) -> String? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tmux)
    process.arguments = ["new-session", "-d", "-s", name, "-c", home, "exec /bin/zsh -l -i"]
    let err = Pipe()
    process.standardOutput = Pipe()
    process.standardError = err
    do {
      try process.run()
    } catch {
      return "tmux not available: \(error.localizedDescription)"
    }
    process.waitUntilExit()
    guard process.terminationStatus != 0 else { return nil }
    let message = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Failed to create session (exit \(process.terminationStatus))"
    return message
  }
  
  private static func runTmuxRename(tmux: String, oldName: String, newName: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tmux)
    process.arguments = ["rename-session", "-t", oldName, newName]
    process.standardOutput = Pipe()
    let err = Pipe()
    process.standardError = err
    do {
      try process.run()
    } catch {
      return "tmux not available: \(error.localizedDescription)"
    }
    process.waitUntilExit()
    guard process.terminationStatus != 0 else { return nil }
    let message = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Rename failed (exit \(process.terminationStatus))"
    return message
  }
  
  private static func runTmuxQuit(tmux: String, name: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tmux)
    process.arguments = ["kill-session", "-t", name]
    process.standardOutput = Pipe()
    let err = Pipe()
    process.standardError = err
    do {
      try process.run()
    } catch {
      return "tmux not available: \(error.localizedDescription)"
    }
    process.waitUntilExit()
    guard process.terminationStatus != 0 else { return nil }
    let message = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Failed to close session (exit \(process.terminationStatus))"
    // Closing is idempotent from the UI's perspective. A stale row may be
    // acted on after the shell already ended and took down the tmux server.
    if isTmuxMissingTarget(message) { return nil }
    return message
  }

  /// `tmux ls -F '#{session_name} #{session_attached}'` — one line per
  /// session: name, then 0 (detached) or 1 (attached). The command exits
  /// 1 with "no server running" when no sessions exist.
  private static func runTmuxList(tmux: String) -> ([ScreenSessionInfo], String?) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tmux)
    process.arguments = ["ls", "-F", "#{session_name} #{session_attached}"]
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    do {
      try process.run()
    } catch {
      return ([], "tmux not available: \(error.localizedDescription)")
    }
    process.waitUntilExit()
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    let text = String(data: outData, encoding: .utf8) ?? ""
    guard !text.isEmpty else {
      let rawMessage = String(data: errData, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      // `tmux ls` uses exit 1 for the normal empty state. Returning success
      // here is essential: refresh replaces the old rows with an empty list.
      if isTmuxEmptyState(rawMessage) { return ([], nil) }
      let message = rawMessage.isEmpty ? "tmux ls failed" : rawMessage
      return ([], message)
    }
    return (parseTmux(text), nil)
  }

  static func isTmuxEmptyState(_ message: String) -> Bool {
    let normalized = message.lowercased()
    return normalized.contains("no server running")
      || normalized.contains("no sessions")
  }

  static func isTmuxMissingTarget(_ message: String) -> Bool {
    let normalized = message.lowercased()
    return isTmuxEmptyState(normalized)
      || normalized.contains("can't find session")
      || normalized.contains("cannot find session")
      || normalized.contains("session not found")
  }
  
  /// Parses `tmux ls -F` output ("name 0"/"name 1" per line) into
  /// session infos with a zero pid.
  private static func parseTmux(_ text: String) -> [ScreenSessionInfo] {
    var result: [ScreenSessionInfo] = []
    for line in text.components(separatedBy: .newlines) {
      let parts = line.split(separator: " ", maxSplits: 1)
      guard parts.count == 2, let name = parts.first, let attached = parts.last else { continue }
      result.append(ScreenSessionInfo(name: String(name), pid: 0, state: String(attached), kind: .tmux))
    }
    return result
  }

  // MARK: - screen -X sessionname
  
  private static func runRename(oldName: String, newName: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/screen")
    process.arguments = ["-S", oldName, "-X", "sessionname", newName]
    process.standardOutput = Pipe()
    let err = Pipe()
    process.standardError = err
    do {
      try process.run()
    } catch {
      return "screen not available: \(error.localizedDescription)"
    }
    process.waitUntilExit()
    guard process.terminationStatus != 0 else { return nil }
    let message = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Rename failed (exit \(process.terminationStatus))"
    return message
  }
  
  // MARK: - screen -S <name> -X quit

  private static func runQuit(name: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/screen")
    process.arguments = ["-S", name, "-X", "quit"]
    process.standardOutput = Pipe()
    let err = Pipe()
    process.standardError = err
    do {
      try process.run()
    } catch {
      return "screen not available: \(error.localizedDescription)"
    }
    process.waitUntilExit()
    guard process.terminationStatus != 0 else { return nil }
    let message = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Failed to close session (exit \(process.terminationStatus))"
    return message
  }

  // MARK: - screen -ls
  
  private static func runScreenList() -> ([ScreenSessionInfo], String?) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/screen")
    process.arguments = ["-ls"]
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    do {
      try process.run()
    } catch {
      return ([], "screen not available: \(error.localizedDescription)")
    }
    process.waitUntilExit()
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    // `screen -ls` exits 1 even when sessions exist (and prints "No
    // Sockets found" to stdout when there are none), so the exit code
    // is useless: parse stdout whenever it has any content.
    guard !outData.isEmpty else {
      let message = String(data: errData, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "screen -ls failed"
      return ([], message)
    }
    let text = String(data: outData, encoding: .utf8) ?? ""
    return (parse(text), nil)
  }
  
  /// Parses `screen -ls` output:
  ///   \t26040.hermes-test\t(Detached)
  ///   \t23539.swiftui-optimization\t(Attached)
  private static let lineRegex = try! NSRegularExpression(
    pattern: #"^\s*(\d+)\.(\S+)\s+\(([^)]+)\)\s*$"#
  )
  
  private static func parse(_ text: String) -> [ScreenSessionInfo] {
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
}
#endif // os(macOS)
