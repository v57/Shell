import Foundation
import TerminalIntegrations

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
public actor LocalProcessCommandRunner: FileCommandExecutor {

  /// Seconds a command may run before it is terminated. `0` disables the timer.
  public let timeout: TimeInterval

  public init(timeout: TimeInterval = 30) {
    self.timeout = timeout
  }

  public func run(inDirectory dir: String, _ command: String) async throws -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-lc", command]
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
  }

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
}
