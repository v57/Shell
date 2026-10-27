import Foundation
import ShellIntegrations
import ShellKit

/// Runs a single shell command locally and invisibly, capturing its output.
///
/// The local counterpart to `HeadlessSSHCommandRunner`: it starts `/bin/zsh -lc`
/// with the working directory set to the requested directory and returns the
/// combined stdout+stderr along with the exit status.
///
/// Both pipes are drained concurrently so a command producing more than the
/// kernel pipe buffer (~64KB) does not deadlock the subprocess while we wait
/// for it to exit. Execution is off the main thread: the `actor`'s method runs
/// on its own executor, and the pipe reads run concurrently in child tasks.
///
/// The type exists on every platform so `DirectoryContext` can build a runner
/// uniformly, but the actual execution is macOS-only (it uses `Process`/`Pipe`);
/// on iOS, where the app ships SSH + notes only and there is no local shell,
/// `run` throws instead of referencing those macOS-only APIs.
public actor LocalProcessCommandRunner: FileCommandExecutor {

  /// Seconds a command may run before it is terminated. `0` disables the timer.
  public let timeout: TimeInterval

  public init(timeout: TimeInterval = 30) {
    self.timeout = timeout
  }

  public func run(inDirectory dir: String, _ command: String) async throws -> CommandResult {
    #if os(macOS) || os(Windows) || os(Linux)
      let process = Process()
      #if os(Linux)
      // The user's login shell (bash, usually): -l reads the profile, which
      // reads ~/.bashrc; -i without a terminal would only add job-control
      // warnings to the output.
      process.executableURL = URL(fileURLWithPath: LocalPTYTransport.loginShell)
      process.arguments = ["-lc", command]
      #else
      process.executableURL = URL(fileURLWithPath: "/bin/zsh")
      // -lic sources ~/.zshrc so the user's interactive PATH (e.g. bun) is
      // available, not just login-level env. -c keeps it one-shot/headless.
      process.arguments = ["-lic", command]
      #endif
      process.currentDirectoryURL = URL(fileURLWithPath: dir)
      process.environment = ProcessInfo.processInfo.environment

      let stdoutPipe = Pipe()
      let stderrPipe = Pipe()
      process.standardOutput = stdoutPipe
      process.standardError = stderrPipe

      try process.run()

      // Drain both pipes concurrently so neither fills its buffer and blocks the
      // subprocess while we wait for it to exit.
      async let stdoutData = drain(stdoutPipe.fileHandleForReading)
      async let stderrData = drain(stderrPipe.fileHandleForReading)

      let exitCode = await waitForExit(process, timeout: timeout)

      var combined = await stdoutData
      let stderr = await stderrData
      if !stderr.isEmpty {
        combined.append(stderr)
      }
      return CommandResult(output: String(decoding: combined, as: UTF8.self), exitCode: exitCode)
    #else
      // iOS ships SSH + notes only (no local shell), so a local runner is never
      // actually exercised here; fail clearly rather than referencing the
      // macOS-only Process/Pipe types.
      throw LocalProcessCommandRunnerError.localUnsupported
    #endif
  }

  #if os(macOS) || os(Windows) || os(Linux)
    /// Reads a pipe to EOF. Marked `nonisolated` so the two pipe drains run on the
    /// cooperative pool instead of serializing on this actor's executor.
    private nonisolated func drain(_ handle: FileHandle) -> Data {
      var data = Data()
      while true {
        do {
          guard let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty else {
            break
          }
          data.append(chunk)
        } catch {
          break
        }
      }
      return data
    }

    /// Waits for `process` to exit, terminating it after `timeout` seconds.
    private func waitForExit(_ process: Process, timeout: TimeInterval) async -> Int32 {
      await withCheckedContinuation { continuation in
        guard process.isRunning else {
          continuation.resume(returning: process.terminationStatus)
          return
        }
        process.terminationHandler = { proc in
          continuation.resume(returning: proc.terminationStatus)
        }
        guard timeout > 0 else { return }
        let watchdog = Task { [weak process] in
          try? await Task.sleep(for: .seconds(timeout))
          guard let process, process.isRunning else { return }
          process.terminate()
        }
        _ = watchdog
      }
    }
  #endif
}

#if !os(macOS) && !os(Windows) && !os(Linux)
/// Shown when a local command run is requested on a platform that has no local
/// shell (iOS). iOS is SSH + notes only, so this path is never taken at runtime.
enum LocalProcessCommandRunnerError: Error {
  case localUnsupported
}
#endif
