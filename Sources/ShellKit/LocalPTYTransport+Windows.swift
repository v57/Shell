#if os(Windows)
import Foundation
import WinSDK

/// A process id, as the transport reports its child's (Windows has no `pid_t`).
public typealias pid_t = Int32

/// Runs a local executable in a Windows pseudo console (ConPTY) and bridges it to the session, as
/// `forkpty` does on the Mac: the child's output arrives via `onOutput`, its exit via `onExit`, and
/// `write`/`resize`/`close` go to the console's pipes. The pseudo console translates between the
/// child's console API calls and VT sequences, so the parser sees an xterm-like stream.
///
/// Two threads block on the console: one reads its output, one waits for the child to exit (and then
/// closes the console, which ends the output).
public final class LocalPTYTransport: TerminalTransport {
  public var onOutput: ((Data) -> Void)?
  public var onConnected: (() -> Void)?
  public var onTerminated: ((String) -> Void)?
  public var onExit: ((Int32) -> Void)?

  public var childProcessID: pid_t? { processID > 0 ? pid_t(processID) : nil }

  /// The console's size at spawn: wide, as on the Mac (see `LocalPTYTransport.spawnSize` there), and the
  /// parser grid starts at the same size.
  static let spawnSize = TerminalGridSize(rows: 24, columns: 200)
  public var initialGridSize: TerminalGridSize { Self.spawnSize }

  private let executable: String
  private let argv: [String]
  /// The command line after the program, as is (cmd's `/s /c "…"` takes its command unescaped).
  private let verbatimArguments: String?
  private let workingDirectory: String?
  private let lock = NSLock()
  private var console: HPCON?
  private var inputWrite: HANDLE?
  private var outputRead: HANDLE?
  private var process: HANDLE?
  private var processID: DWORD = 0
  private var isRunning = false

  public init(executable: String, argv: [String], workingDirectory: String? = nil) {
    self.executable = executable
    self.argv = argv
    self.verbatimArguments = nil
    self.workingDirectory = workingDirectory
  }

  /// Runs `executable` with `arguments` as its command line's rest, unquoted.
  init(executable: String, verbatimArguments arguments: String, workingDirectory: String? = nil) {
    self.executable = executable
    self.argv = [(executable as NSString).lastPathComponent]
    self.verbatimArguments = arguments
    self.workingDirectory = workingDirectory
  }

  deinit { close() }

  public func start() {
    guard !isRunning else { return }
    isRunning = true
    do {
      try spawn()
    } catch {
      isRunning = false
      onTerminated?("Failed to start \(argv.first ?? executable): \(error.localizedDescription)")
      return
    }
    onConnected?()
  }

  private struct SpawnError: LocalizedError {
    let call: String
    let code: DWORD
    var errorDescription: String? { "\(call) failed (error \(code))" }
  }

  private func spawn() throws {
    var inputRead: HANDLE?
    var inputWrite: HANDLE?
    var outputRead: HANDLE?
    var outputWrite: HANDLE?
    guard CreatePipe(&inputRead, &inputWrite, nil, 0), CreatePipe(&outputRead, &outputWrite, nil, 0) else {
      throw SpawnError(call: "CreatePipe", code: GetLastError())
    }
    var console: HPCON?
    let size = COORD(X: SHORT(Self.spawnSize.columns), Y: SHORT(Self.spawnSize.rows))
    let created = CreatePseudoConsole(size, inputRead, outputWrite, 0, &console)
    guard created == S_OK, let console else {
      for handle in [inputRead, inputWrite, outputRead, outputWrite] { if let handle { CloseHandle(handle) } }
      throw SpawnError(call: "CreatePseudoConsole", code: DWORD(bitPattern: created))
    }

    // The child's startup info carries the pseudo console as an attribute.
    var attributeSize: SIZE_T = 0
    _ = InitializeProcThreadAttributeList(nil, 1, 0, &attributeSize)
    let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(attributeSize), alignment: 16)
    let attributes = LPPROC_THREAD_ATTRIBUTE_LIST(storage)
    defer {
      DeleteProcThreadAttributeList(attributes)
      storage.deallocate()
    }
    guard InitializeProcThreadAttributeList(attributes, 1, 0, &attributeSize),
      UpdateProcThreadAttribute(
        attributes, 0, 0x0002_0016,  // PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE
        UnsafeMutableRawPointer(console), SIZE_T(MemoryLayout<HPCON>.size), nil, nil)
    else {
      ClosePseudoConsole(console)
      throw SpawnError(call: "UpdateProcThreadAttribute", code: GetLastError())
    }
    var startup = STARTUPINFOEXW()
    startup.StartupInfo.cb = DWORD(MemoryLayout<STARTUPINFOEXW>.size)
    startup.lpAttributeList = attributes

    let line = verbatimArguments.map { Self.commandLine([executable]) + " " + $0 }
      ?? Self.commandLine([executable] + argv.dropFirst())
    var commandLine = Array(line.utf16) + [0]
    var environment = Self.environmentBlock(makeEnvironment())
    let directory = workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path
    var information = PROCESS_INFORMATION()
    let launched = directory.withCString(encodedAs: UTF16.self) { directory in
      withUnsafeMutablePointer(to: &startup) { startup in
        startup.withMemoryRebound(to: STARTUPINFOW.self, capacity: 1) { startupInfo in
          CreateProcessW(
            nil, &commandLine, nil, nil, false,
            DWORD(EXTENDED_STARTUPINFO_PRESENT) | DWORD(CREATE_UNICODE_ENVIRONMENT), &environment,
            directory, startupInfo, &information)
        }
      }
    }
    // The console holds its own ends of the pipes.
    CloseHandle(inputRead)
    CloseHandle(outputWrite)
    guard launched else {
      let code = GetLastError()
      ClosePseudoConsole(console)
      CloseHandle(inputWrite)
      CloseHandle(outputRead)
      throw SpawnError(call: "CreateProcess", code: code)
    }
    CloseHandle(information.hThread)

    lock.withLock {
      self.console = console
      self.inputWrite = inputWrite
      self.outputRead = outputRead
      self.process = information.hProcess
      self.processID = information.dwProcessId
    }
    startReading(outputRead!)
    watchExit(information.hProcess!)
  }

  private func startReading(_ output: HANDLE) {
    let thread = Thread { [weak self] in
      var buffer = [UInt8](repeating: 0, count: 8192)
      while true {
        var count: DWORD = 0
        let ok = buffer.withUnsafeMutableBytes { ReadFile(output, $0.baseAddress, DWORD($0.count), &count, nil) }
        guard ok, count > 0 else { break }
        let data = Data(buffer.prefix(Int(count)))
        DispatchQueue.main.async { self?.onOutput?(data) }
      }
    }
    thread.name = "ShellKit.LocalPTYTransport.read"
    thread.start()
  }

  private func watchExit(_ process: HANDLE) {
    let thread = Thread { [weak self] in
      WaitForSingleObject(process, INFINITE)
      var code: DWORD = 0
      GetExitCodeProcess(process, &code)
      // Closing the console after the child ends finishes its output (the reader sees the pipe close).
      self?.closeConsole()
      DispatchQueue.main.async {
        guard let self else { return }
        self.isRunning = false
        self.onExit?(Int32(bitPattern: code))
      }
    }
    thread.name = "ShellKit.LocalPTYTransport.exit"
    thread.start()
  }

  public func write(_ data: Data) {
    guard !data.isEmpty, let input = lock.withLock({ inputWrite }) else { return }
    data.withUnsafeBytes { raw in
      var offset = 0
      while offset < raw.count {
        var written: DWORD = 0
        guard WriteFile(input, raw.baseAddress! + offset, DWORD(raw.count - offset), &written, nil), written > 0
        else { return }
        offset += Int(written)
      }
    }
  }

  public func resize(columns: Int, rows: Int) {
    guard columns > 0, rows > 0, let console = lock.withLock({ console }) else { return }
    _ = ResizePseudoConsole(console, COORD(X: SHORT(columns), Y: SHORT(rows)))
  }

  public func close() {
    let process = lock.withLock { () -> HANDLE? in
      defer { self.process = nil; processID = 0 }
      return self.process
    }
    if let process {
      // Ends the child; its exit watcher then closes the console.
      TerminateProcess(process, 1)
      CloseHandle(process)
    } else {
      closeConsole()
    }
  }

  /// Closes the console and the transport's pipe ends (once).
  private func closeConsole() {
    let (console, input, output) = lock.withLock { () -> (HPCON?, HANDLE?, HANDLE?) in
      defer { self.console = nil; inputWrite = nil; outputRead = nil }
      return (self.console, inputWrite, outputRead)
    }
    if let console { ClosePseudoConsole(console) }
    if let input { CloseHandle(input) }
    if let output { CloseHandle(output) }
  }

  private func makeEnvironment() -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    environment["TERM"] = "xterm-256color"
    environment["COLORTERM"] = "truecolor"
    environment["TERM_PROGRAM"] = "Shell"
    environment["TERM_PROGRAM_VERSION"] = "1.0"
    return environment
  }

  /// A Windows command line for `arguments` (the first is the program), quoted so the C runtime's parser
  /// (`CommandLineToArgvW`) gives them back unchanged.
  static func commandLine(_ arguments: [String]) -> String {
    arguments.map { argument in
      guard argument.isEmpty || argument.contains(where: { " \t\n\"".contains($0) }) else { return argument }
      var quoted = "\""
      var backslashes = 0
      for character in argument {
        if character == "\\" {
          backslashes += 1
        } else if character == "\"" {
          quoted += String(repeating: "\\", count: backslashes * 2 + 1) + "\""
          backslashes = 0
        } else {
          quoted += String(repeating: "\\", count: backslashes) + String(character)
          backslashes = 0
        }
      }
      return quoted + String(repeating: "\\", count: backslashes * 2) + "\""
    }.joined(separator: " ")
  }

  /// `NAME=value\0…\0\0`, sorted case-insensitively as Windows expects.
  static func environmentBlock(_ environment: [String: String]) -> [WCHAR] {
    var block: [WCHAR] = []
    for (key, value) in environment.sorted(by: { $0.key.uppercased() < $1.key.uppercased() }) {
      block += Array("\(key)=\(value)".utf16) + [0]
    }
    return block + [0]
  }
}

// MARK: - Local shell presets

public extension LocalPTYTransport {
  /// The interactive shell: PowerShell 7 when it's installed, else Windows PowerShell. (Named for the Mac's,
  /// so `TerminalSession(session: .zsh)` is the local shell everywhere.)
  static var zsh: LocalPTYTransport {
    LocalPTYTransport(executable: shellPath, argv: [shellName, "-NoLogo"])
  }

  /// The interactive shell starting in `directory` (⌘T's new tab in the current directory).
  static func zsh(in directory: String) -> LocalPTYTransport {
    LocalPTYTransport(executable: shellPath, argv: [shellName, "-NoLogo"], workingDirectory: directory)
  }

  /// Runs `commands` in cmd and exits with their status (actions): the command language Code's actions are written
  /// in on Windows (`cmd /d /s /c`, as Code runs them).
  static func command(_ commands: String, in directory: String? = nil) -> LocalPTYTransport {
    let system = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows"
    let cmd = ProcessInfo.processInfo.environment["ComSpec"] ?? system + "\\System32\\cmd.exe"
    return LocalPTYTransport(executable: cmd, verbatimArguments: "/d /s /c \"\(commands)\"", workingDirectory: directory)
  }

  /// GNU screen has no Windows build: the session reports that it couldn't start.
  static func screen(_ name: String) -> LocalPTYTransport {
    LocalPTYTransport(executable: "screen.exe", argv: ["screen", "-x", name])
  }

  /// tmux and the `session` tool don't run on Windows.
  static func tmux(_ name: String) -> LocalPTYTransport? { nil }
  static func session(_ name: String) -> LocalPTYTransport? { nil }
  nonisolated static func tmuxExecutablePath() -> String? { nil }
  nonisolated static func sessionExecutablePath() -> String? { nil }

  private static var shellName: String { (shellPath as NSString).lastPathComponent }

  private static let shellPath: String = {
    let environment = ProcessInfo.processInfo.environment
    let programFiles = environment["ProgramFiles"] ?? "C:\\Program Files"
    let candidates = [programFiles + "\\PowerShell\\7\\pwsh.exe"]
      + (environment["Path"] ?? environment["PATH"] ?? "").split(separator: ";").map { "\($0)\\pwsh.exe" }
    if let pwsh = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) { return pwsh }
    let system = environment["SystemRoot"] ?? "C:\\Windows"
    return system + "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"
  }()
}
#endif
