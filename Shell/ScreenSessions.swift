import Foundation
import Terminal
import TerminalIntegrations

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

  /// Resolves the `session` binary from PATH (the session-tool multiplexer).
  /// Returns nil when it isn't installed or isn't executable, in which case
  /// the local scanner simply contributes no `session` rows.
  static func sessionPath() -> String? {
    let env = ProcessInfo.processInfo.environment
    guard let path = env["PATH"] else { return nil }
    for dir in path.split(separator: ":") {
      let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("session").path
      if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return nil
  }
  
  private(set) var sessions: [ScreenSessionInfo] = []
  private(set) var errorMessage: String?
  /// Set when a create/rename action fails; cleared by the UI on dismiss.
  var actionError: ScreenActionError?
  
  private let queue = DispatchQueue(label: "ScreenSessionsMonitor.list")
  private var timer: Timer?
  /// The feature-flag source of truth. Injected so tests can gate on a
  /// hermetic store; production uses the shared store.
  private let features: FeatureFlagsStore

  /// `features == nil` falls back to the app-wide shared store.
  init(features: FeatureFlagsStore? = nil) {
    self.features = features ?? .shared
  }

  /// The Screen feature must be enabled for any subprocess work.
  private var featureEnabled: Bool {
    features.isEnabled(.screen)
  }

  /// Whether the 5s poller is currently armed.
  var isPolling: Bool { timer != nil }

  /// Starts the poller (immediate refresh + 5s repeats). Idempotent; no-op
  /// when the Screen feature is disabled.
  func start() {
    guard featureEnabled, timer == nil else { return }
    refresh()
    timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.refresh()
      }
    }
  }

  /// Stops the poller and clears the published rows. Idempotent.
  func stop() {
    timer?.invalidate()
    timer = nil
    sessions = []
    errorMessage = nil
  }

  func refresh() {
    guard featureEnabled else { return }
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
    // session-tool is the new backend; list it alongside tmux and screen so
    // reattachable local session rows render without removing either. A
    // non-running daemon resolves to no rows (runSessionList returns `[]` silently).
    if let session = sessionPath() {
      let (sessionSessions, sessionError) = runSessionList(session: session)
      sessions.append(contentsOf: sessionSessions)
      if let sessionError { messages.append(sessionError) }
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
    guard featureEnabled else { return }
    let kind = Self.preferredKind
    let name = ScreenSessionsParser.nextSessionName(existing: Set(sessions.map(\.shortName)))
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
    guard featureEnabled else { return }
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
    guard featureEnabled else { return }
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
    return (ScreenSessionsParser.parseTmuxOutput(text), nil)
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
    return (ScreenSessionsParser.parseScreenOutput(text), nil)
  }

  // MARK: - session list

  /// `session list` — JSON listing of live reattachable sessions. The daemon
  /// prints `[]` (or nothing, when its socket isn't reachable) when nothing is
  /// live; both resolve to "no sessions" so a non-running daemon never blanks
  /// the whole Local section. Only stdout is consumed; stderr details are
  /// dropped because a down daemon isn't an error worth surfacing here.
  private static func runSessionList(session: String) -> ([ScreenSessionInfo], String?) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: session)
    process.arguments = ["list"]
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    do {
      try process.run()
    } catch {
      return ([], "session not available: " + error.localizedDescription)
    }
    process.waitUntilExit()
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    let text = String(data: outData, encoding: .utf8) ?? ""
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return ([], nil)
    }
    return (ScreenSessionsParser.parseSessionOutput(text), nil)
  }
}

// MARK: - Remote persistent session scanner

/// Scans GNU screen/tmux sessions on the currently-connected SSH connections
/// and publishes them as `ScreenSessionInfo` rows tagged with each session's
/// remote origin (its SSH config id + display label).
///
/// The scan only touches hosts that already have a connected SSH terminal
/// (kind `.ssh` AND `connectionState == .connected`) and reuses that session's
/// live exec channel — it never dials a throwaway SSH connection just to list
/// a host (confirmed scope decision 3). A host without tmux or screen simply
/// contributes nothing; a per-host failure is swallowed to an empty list
/// rather than folded into an error that blanks the whole remote section.
///
/// tmux/screen are macOS-only concern (the iOS app ships SSH + notes only).
@MainActor
@Observable
final class RemoteScreenSessionsScanner {
  /// The latest remote persistent session list. The UI (SidebarView) renders
  /// these rows in the merged Local section; empty until the first scan.
  private(set) var sessions: [ScreenSessionInfo] = []
  /// The feature-flag source of truth. Injected so tests can gate on a
  /// hermetic store; production uses the shared store.
  private let features: FeatureFlagsStore

  /// `features == nil` falls back to the app-wide shared store.
  init(features: FeatureFlagsStore? = nil) {
    self.features = features ?? .shared
  }

  /// The remote list commands are the package's canonical strings (the tmux
  /// format matches the local poller, so both reuse `ScreenSessionsParser`).

  /// Lists screen/tmux sessions on every currently-connected SSH connection.
  /// Safe to call on the main thread: each remote exec is scheduled on the
  /// connection's NIO event loop (a background queue), so the main thread is
  /// never blocked waiting on a host. The @Sendable completions only stash
  /// raw stdout; all ScreenSessionInfo construction happens back on the main
  /// actor, which is the only safe place to touch these MainActor-default
  /// types.
  func scan(using model: AppModel) {
    // A scan dials the connected SSH transports — that is background work.
    // Never run it while the Screen feature is disabled.
    guard features.isEnabled(.screen) else { return }
    let hostEntries: [(transport: SSHSession, origin: ScreenRemoteOrigin)] =
      model.connectedSSHSessions.compactMap { session in
        // Only kind .ssh, and only sessions that are connected.
        guard case .ssh(let config) = model.kind(of: session),
              let transport = session.sshTransport
        else { return nil }
        return (transport, ScreenRemoteOrigin(sshConfigID: config.id, displayName: config.displayName))
      }

    let commands = Self.listCommands
    Task { @MainActor [weak self] in
      guard let self else { return }
      var collected: [ScreenSessionInfo] = []
      var seen = Set<String>()
      for (transport, origin) in hostEntries {
        for command in commands {
          let output = await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            transport.runCommand(command) { result in
              if case .success(let r) = result { cont.resume(returning: r.stdout) }
              else { cont.resume(returning: nil) }
            }
          }
          guard let output else { continue }
          for info in ScreenSessionsParser.parse(command: command, text: output, origin: origin)
          where seen.insert(info.id).inserted {
            collected.append(info)
          }
        }
      }
      self.sessions = collected
    }
  }

  static var listCommands: [String] { [ScreenSessionsParser.tmuxListCommand, ScreenSessionsParser.screenListCommand, ScreenSessionsParser.sessionListCommand] }
}
#endif // os(macOS)
