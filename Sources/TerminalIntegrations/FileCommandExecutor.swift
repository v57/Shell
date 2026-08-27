import Foundation

/// The result of running a shell command.
///
/// Carries the captured standard output and the process exit code so callers
/// can interpret success/failure without reaching into a live process.
public struct CommandResult: Sendable {
  public let output: String
  public let exitCode: Int32

  public init(output: String, exitCode: Int32) {
    self.output = output
    self.exitCode = exitCode
  }
}

/// Executes a shell command in a given directory.
///
/// This is an abstraction over spawning processes (a local `Process`, an SSH
/// session, or any future runner) so callers can express file operations as
/// pure command strings built by `FileCommandBuilder` without coupling to how
/// they are actually run.
public protocol FileCommandExecutor: Sendable {
  /// Runs `command` in the directory `dir`, returning its captured output and
  /// exit code. Throws if the command could not be executed at all.
  func run(inDirectory dir: String, _ command: String) async throws -> CommandResult
}
