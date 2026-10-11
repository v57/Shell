import Darwin
import Foundation

// MARK: - Auth prompts

/// Shown when an SSH server presents an unknown host key, or a different key
/// than the one remembered for it.
public struct TerminalHostKeyPrompt: Identifiable {
  public let id = UUID()
  public let host: String
  public let port: Int
  public let fingerprint: String
  /// The fingerprint remembered for this host when the server now presents a
  /// different key: someone may be intercepting the connection. Nil on first
  /// contact.
  public let previousFingerprint: String?
  /// Call with `true` to accept (and remember) the key, `false` to reject.
  public let respond: (Bool) -> Void

  public init(host: String, port: Int, fingerprint: String, previousFingerprint: String? = nil, respond: @escaping (Bool) -> Void) {
    self.host = host
    self.port = port
    self.fingerprint = fingerprint
    self.previousFingerprint = previousFingerprint
    self.respond = respond
  }

  /// Answers for connections that run without a visible prompt (file
  /// browser, tunnels, the authorized-keys panel): trusts a host on first
  /// contact, rejects a changed key. A changed key must never be accepted
  /// silently: the saved password would go to whoever answered, and the
  /// remembered key would be replaced.
  public func respondTrustingFirstUse() {
    respond(previousFingerprint == nil)
  }
}

/// Shown when an SSH server asks for a password.
public struct TerminalPasswordPrompt: Identifiable {
  public let id = UUID()
  public let host: String
  public let username: String
  /// Password + whether to save it in the Keychain.
  public let respond: (String?, Bool) -> Void

  public init(host: String, username: String, respond: @escaping (String?, Bool) -> Void) {
    self.host = host
    self.username = username
    self.respond = respond
  }
}

// MARK: - Transport protocol

/// The I/O backbone of a `TerminalSession`: an interactive byte stream with
/// a child process (local pty) or a remote channel (SSH).
///
/// All callbacks are delivered on the main thread.
public protocol TerminalTransport: AnyObject {
  /// Raw bytes from the child (terminal output). Feeds the parser.
  var onOutput: ((Data) -> Void)? { get set }
  /// The session is ready to accept input (pty spawned / SSH channel open).
  var onConnected: (() -> Void)? { get set }
  /// The transport failed or the connection dropped (shows an error).
  var onTerminated: ((String) -> Void)? { get set }
  /// The child process / remote exec exited with this code.
  var onExit: ((Int32) -> Void)? { get set }
  /// The server presented an unknown host key (SSH transports only).
  var onHostKeyPrompt: ((TerminalHostKeyPrompt) -> Void)? { get set }
  /// The server asked for a password (SSH transports only).
  var onPasswordPrompt: ((TerminalPasswordPrompt) -> Void)? { get set }

  func start()
  func write(_ data: Data)
  func resize(columns: Int, rows: Int)
  func close()

  /// The pty/channel size the transport STARTS with, before the view's first
  /// layout resizes it. The session seeds its parser grid with this so the
  /// first bytes are parsed at the SAME width the child believes it has —
  /// the two must never disagree, or every width-sensitive escape breaks:
  /// zsh's PROMPT_SP padding then wraps on a different row than the CR that
  /// is supposed to erase it, stranding its reverse-video "%" marker above
  /// the first prompt.
  var initialGridSize: TerminalGridSize { get }

  /// The OS process id of the transport's child process, when it owns one
  /// (local pty). Nil for network transports (SSH) and test doubles. Lets
  /// the session read live child state — e.g. the current working
  /// directory via `proc_pidinfo`.
  var childProcessID: pid_t? { get }
}

/// Non-SSH transports never produce auth prompts — default no-ops so
/// conformance only needs the four I/O callbacks.
public extension TerminalTransport {
  /// Default start size: the classic 80x24. SSH requests exactly this from
  /// the server at channel open (`libssh2_channel_request_pty_ex`), so its
  /// parser grid starts here too — the child's size and the parser's must
  /// always agree (see `initialGridSize`).
  var initialGridSize: TerminalGridSize { TerminalGridSize(rows: 24, columns: 80) }

  var onHostKeyPrompt: ((TerminalHostKeyPrompt) -> Void)? {
    get { nil }
    set {}
  }
  var onPasswordPrompt: ((TerminalPasswordPrompt) -> Void)? {
    get { nil }
    set {}
  }

  /// Transports without a child process (SSH, test doubles) report nil.
  var childProcessID: pid_t? { nil }
}

// MARK: - Local pty transport

#if os(macOS)
/// Spawns a local executable in a pty (forkpty) and bridges it to the
/// session: the child's output arrives via `onOutput`, its exit via
/// `onExit`, and `write`/`resize`/`close` go straight to the master fd.
///
/// The pty IS the child's controlling terminal (forkpty = openpty + fork +
/// login_tty in the child: setsid + TIOCSCTTY + dup2 slave onto 0/1/2),
/// which is what lets ^C (ISIG/VINTR) deliver SIGINT to the foreground
/// process group.
///
/// macOS only: forkpty does not exist on iOS, and local terminals are not
/// a supported iOS feature (the iOS app ships SSH + notes).
public final class LocalPTYTransport: TerminalTransport {
  public var onOutput: ((Data) -> Void)?
  public var onConnected: (() -> Void)?
  public var onTerminated: ((String) -> Void)?
  public var onExit: ((Int32) -> Void)?

  /// The child process's PID once spawned (nil before start and after
  /// exit/close). The session uses it to read live child state such as
  /// the current working directory.
  public var childProcessID: pid_t? { childPID >= 0 ? childPID : nil }

  /// The pty's size at spawn. WIDE (not 80 cols): output can arrive before
  /// the view lays out and resizes the pty to the real size, and a wider
  /// start keeps that first output from wrapping early. The parser grid
  /// starts at this SAME size (`initialGridSize`) — zsh's startup blanking
  /// is width-sensitive, and a grid narrower than the pty strands its
  /// reverse-video "%" marker above the erase. The view resizes the pty
  /// and the grid together to the real size on first layout.
  static let spawnSize = TerminalGridSize(rows: 24, columns: 200)
  public var initialGridSize: TerminalGridSize { Self.spawnSize }

  private let executable: String
  private let argv: [String]
  /// Directory the child starts in (nil = the home directory). Set by the
  /// ⌘T "open terminal in same directory" path so a new tab inherits the
  /// current shell's cwd instead of always starting in home.
  private let workingDirectory: String?
  private let queue = DispatchQueue(label: "Terminal.LocalPTYTransport")
  private let queueIdentity = DispatchSpecificKey<UInt8>()
  private var masterFD: Int32 = -1
  private var childPID: pid_t = -1
  private var processWatch: DispatchSourceProcess?
  private var readSource: DispatchSourceRead?
  private var isRunning = false
  /// Internal regression-test probe; not part of the public transport API.
  var onReadEventForTesting: (() -> Void)?

  public init(executable: String, argv: [String], workingDirectory: String? = nil) {
    self.executable = executable
    self.argv = argv
    self.workingDirectory = workingDirectory
    queue.setSpecific(key: queueIdentity, value: 1)
  }

  public func start() {
    guard !isRunning else { return }
    isRunning = true

    // Build argv/envp in the parent, BEFORE fork: between fork and exec
    // the child may only run async-signal-safe code (no allocation).
    let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
    // The child starts in the working directory when one is given (⌘T
    // reopens a terminal in the current directory), else the home directory.
    let launchDirectory = workingDirectory ?? homeDirectory
    let executableCString = executable.withCString { strdup($0) }
    var argvPointers: [UnsafeMutablePointer<CChar>?] = argv.map {
      $0.withCString { strdup($0) }
    }
    argvPointers.append(nil)
    var envp: [UnsafeMutablePointer<CChar>?] = makeEnvironment()
      .map { "\($0.key)=\($0.value)" }
      .sorted()
      .map { $0.withCString { strdup($0) } }
    envp.append(nil)
    let launchCString = launchDirectory.withCString { strdup($0) }

    // The pty starts at the SAME size the parser grid starts at (see
    // `spawnSize` / `initialGridSize`): a grid narrower than the pty makes
    // zsh's width-sensitive startup blanking wrap on the wrong row and
    // strand its reverse-video "%" marker on the first screen.
    // The view resizes the pty to the real size on first layout.
    var windowSize = winsize(
      ws_row: UInt16(Self.spawnSize.rows),
      ws_col: UInt16(Self.spawnSize.columns),
      ws_xpixel: 0,
      ws_ypixel: 0
    )

    var master: Int32 = -1
    let pid = forkpty(&master, nil, nil, &windowSize)
    if pid == 0 {
      // Child — async-signal-safe only from here on.
      Darwin.close(master)
      if chdir(launchCString) != 0 {
        _exit(127)
      }
      execve(executableCString, argvPointers, envp)
      _exit(127)
    }

    // Parent.
    defer {
      free(executableCString)
      for ptr in argvPointers { ptr.map { free($0) } }
      for ptr in envp { ptr.map { free($0) } }
      free(launchCString)
    }
    guard pid > 0 else {
      let message = "Failed to start \(argv[0]): \(String(cString: strerror(errno)))"
      isRunning = false
      onTerminated?(message)
      return
    }

    masterFD = master
    // forkpty closed the slave side in the parent.

    let flags = fcntl(masterFD, F_GETFL, 0)
    if flags >= 0 {
      _ = fcntl(masterFD, F_SETFL, flags | O_NONBLOCK)
    }
    childPID = pid

    let source = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: queue)
    source.setEventHandler { [weak self] in
      self?.onReadEventForTesting?()
      self?.readFromPTY()
    }
    source.setCancelHandler { }
    source.resume()
    readSource = source

    let exitSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
    exitSource.setEventHandler { [weak self] in
      guard let self else { return }
      var status: Int32 = 0
      var waitResult: pid_t
      repeat {
        waitResult = waitpid(pid, &status, 0)
      } while waitResult == -1 && errno == EINTR
      self.processWatch?.cancel()
      self.processWatch = nil
      if waitResult == pid {
        self.childPID = -1
      }
      DispatchQueue.main.async {
        self.isRunning = false
        // Wait status: exit code in bits 8-15, signal in low 7. Normal
        // exits read their code directly; signal deaths (e.g. ^C) get
        // the shell convention 128+signal so an interrupted action
        // shows as a failure (exit 130), not a clean exit.
        let signal = status & 0x7F
        let code = (status >> 8) & 0xFF
        self.onExit?((signal != 0 && code == 0) ? Int32(128 + signal) : code)
      }
    }
    exitSource.resume()
    processWatch = exitSource

    onConnected?()
  }

  public func write(_ data: Data) {
    guard masterFD >= 0, !data.isEmpty else { return }

    data.withUnsafeBytes { rawBuffer in
      guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
      var remaining = rawBuffer.count
      var offset = 0

      while remaining > 0 {
        let written = Darwin.write(masterFD, base.advanced(by: offset), remaining)
        if written > 0 {
          remaining -= written
          offset += written
          continue
        }
        if written == -1, errno == EINTR {
          continue
        }
        break
      }
    }
  }

  public func resize(columns: Int, rows: Int) {
    guard columns > 0, rows > 0, masterFD >= 0 else { return }
    var ws = winsize(ws_row: UInt16(rows), ws_col: UInt16(columns), ws_xpixel: 0, ws_ypixel: 0)
    _ = ioctl(masterFD, TIOCSWINSZ, &ws)
  }

  public func close() {
    if DispatchQueue.getSpecific(key: queueIdentity) != nil {
      closeOnTransportQueue()
    } else {
      queue.sync { closeOnTransportQueue() }
    }
  }

  /// All descriptors and dispatch sources are owned by `queue`; serializing
  /// teardown prevents close from racing a pending read/exit handler.
  private func closeOnTransportQueue() {
    readSource?.cancel()
    readSource = nil

    if childPID > 0 {
      // The child is a session leader, so -childPID covers the whole
      // process group (shell + its children).
      _ = kill(-childPID, SIGTERM)
      _ = kill(childPID, SIGTERM)
      childPID = -1
    }
    processWatch?.cancel()
    processWatch = nil

    if masterFD >= 0 {
      Darwin.close(masterFD)
      masterFD = -1
    }
  }

  private func readFromPTY() {
    guard masterFD >= 0 else { return }

    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = Darwin.read(masterFD, &buffer, buffer.count)
      if count > 0 {
        let data = Data(buffer.prefix(count))
        DispatchQueue.main.async { [weak self] in
          self?.onOutput?(data)
        }
        continue
      }
      if count == 0 {
        stopReadingFromPTY()
        break
      }
      if count == -1, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { break }
      // PTYs commonly report EIO rather than a zero-byte read when the
      // slave disappears. Any other permanent read error is terminal too.
      stopReadingFromPTY()
      break
    }
  }

  /// EOF is level-triggered for a dispatch read source. Leaving the source
  /// active would immediately invoke `readFromPTY` again forever, spinning a
  /// core after an attached screen/tmux client exits.
  private func stopReadingFromPTY() {
    readSource?.cancel()
    readSource = nil
  }

  private func makeEnvironment() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    // Always advertise a full xterm-256color terminal. Inheriting TERM (or
    // terminfo-polluting variables) from the launching process can carry a
    // broken value that makes curses apps like nano fail with
    // "Incomplete terminfo entry".
    env["TERM"] = "xterm-256color"
    env["COLORTERM"] = "truecolor"
    env["TERM_PROGRAM"] = "Shell"
    env["TERM_PROGRAM_VERSION"] = "1.0"
    // Guarantee a sane home dir regardless of how the app was launched,
    // so zsh finds ~/.zshrc and starts in the right place.
    env["HOME"] = NSHomeDirectory()
    env.removeValue(forKey: "TERMINFO")
    env.removeValue(forKey: "TERMINFO_DIRS")
    env.removeValue(forKey: "TERMCAP")
    return env
  }
}

// MARK: - Local pty presets

public extension LocalPTYTransport {
  /// Interactive zsh login shell — the default local terminal.
  /// Use via the short form: `TerminalSession(session: .zsh)`.
  static var zsh: LocalPTYTransport {
    LocalPTYTransport(executable: "/bin/zsh", argv: ["zsh", "-l", "-i"])
  }

  /// Interactive zsh login shell that starts in `directory` — used by
  /// ⌘T to open a new terminal tab in the current directory. The default
  /// `.zsh` starts in the home directory.
  static func zsh(in directory: String) -> LocalPTYTransport {
    LocalPTYTransport(executable: "/bin/zsh", argv: ["zsh", "-l", "-i"], workingDirectory: directory)
  }

  /// Attach to a named GNU screen session (`screen -x`, multi-attaches).
  /// screen ships with macOS. Use via `TerminalSession(session: .screen(name))`.
  static func screen(_ name: String) -> LocalPTYTransport {
    LocalPTYTransport(executable: "/usr/bin/screen", argv: ["screen", "-x", name])
  }

  /// Attach to a named tmux session (`tmux attach -t`). Returns nil when
  /// tmux is not installed — callers fall back to `.screen(name)`.
  static func tmux(_ name: String) -> LocalPTYTransport? {
    guard let executable = tmuxExecutablePath() else { return nil }
    return LocalPTYTransport(executable: executable, argv: ["tmux", "attach", "-t", name])
  }

  /// Resolves the tmux executable: common install locations first, then
  /// PATH. Returns nil when tmux is not installed. (tmux has no fixed
  /// macOS location — Homebrew installs it under /opt/homebrew or
  /// /usr/local, and GUI launches inherit a minimal PATH.)
  /// Resolved once and cached: an executable's install path can't change
  /// mid-run, so the ScreenSessions monitor's 5s refresh (and the attach
  /// path) reuse the first answer instead of re-probing the filesystem
  /// every tick.
  private static let tmuxExecutable: String? = {
    for candidate in ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"] {
      if FileManager.default.isExecutableFile(atPath: candidate) {
        return candidate
      }
    }
    guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
    for dir in path.split(separator: ":") {
      let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("tmux").path
      if FileManager.default.isExecutableFile(atPath: candidate) {
        return candidate
      }
    }
    return nil
  }()
  static func tmuxExecutablePath() -> String? { tmuxExecutable }

  /// Attach-or-create a named persistent `session`-tool session
  /// (`session <name>`, create-or-attach): attaches when a session of that
  /// name is already live, else creates one running the default shell and
  /// attaches. Returns nil when `session` is not on PATH — callers fall back
  /// to `.tmux(name)` / `.screen(name)`, keeping screen/tmux as the
  /// persistent-session backends. Use via `TerminalSession(session:
  /// .session(name))`. Spawned from PATH; managed-path resolution
  /// (SessionBinaryManager) is a separate card.
  static func session(_ name: String) -> LocalPTYTransport? {
    guard let executable = sessionExecutablePath() else { return nil }
    return LocalPTYTransport(executable: executable, argv: ["session", name])
  }

  /// Resolves the `session` tool executable: common install locations first,
  /// then PATH. Returns nil when it is not installed. (The SessionBinaryManager
  /// card later resolves the managed path; common locations + PATH is the
  /// contract for now.) Unlike tmux there is no fixed macOS location, so the
  /// probe mirrors tmuxExecutablePath() — GUI launches inherit a minimal PATH
  /// that omits ~/.local/bin and the Homebrew dirs, so the common install
  /// locations are checked first.
  /// Resolved once and cached: an executable's install path can't change
  /// mid-run, so the ScreenSessions monitor's 5s refresh (and the attach
  /// path) reuse the first answer instead of re-probing the filesystem
  /// every tick.
  private static let sessionExecutable: String? = {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    for candidate in ["\(home)/.local/bin/session", "\(home)/.cargo/bin/session",
                      "/usr/local/bin/session", "/opt/homebrew/bin/session"] {
      if FileManager.default.isExecutableFile(atPath: candidate) {
        return candidate
      }
    }
    guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
    for dir in path.split(separator: ":") {
      let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("session").path
      if FileManager.default.isExecutableFile(atPath: candidate) {
        return candidate
      }
    }
    return nil
  }()
  static func sessionExecutablePath() -> String? { sessionExecutable }
}
#endif // os(macOS)
