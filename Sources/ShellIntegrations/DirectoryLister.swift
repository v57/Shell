import Foundation

/// A pure listing service that turns a directory enumerator's raw `ls -la` output
/// into `[FileRow]` values.
///
/// It sits above `FileCommandExecutor` (which knows how to run the command) and
/// `LSOutputParser` (which turns the raw text into rows). It performs no
/// filesystem access and never spawns a process — it only coordinates an executor
/// with a parser, which keeps the whole pipeline unit-testable with a fake
/// executor.
public struct DirectoryLister {
  /// Runs `ls -la` for `directory` through `executor`, then parses the captured
  /// output into rows.
  ///
  /// - Parameters:
  ///   - directory: The directory to list.
  ///   - executor: The runner that executes the `ls -la` command.
  ///   - parser: Turns the command's output lines into rows. Defaults to
  ///     `LSOutputParser.parse`, joining the lines back into the whole listing
  ///     blob the parser expects (a single `String`).
  /// - Returns: The parsed file rows, in the order they appeared in the listing.
  /// - Throws: `DirectoryListingError.commandFailed` when the command exits
  ///   non-zero, carrying the captured output so any error text is surfaced to
  ///   callers. Also throws whatever the executor throws if the command could not
  ///   be executed at all.
  public static func list(
    directory: String, executor: any FileCommandExecutor,
    parser: ([String]) -> [FileRow] = { LSOutputParser.parse($0.joined(separator: "\n")) }
  ) async throws -> [FileRow] {
    let command = FileCommandBuilder.list(directory: directory)
    let result = try await executor.run(inDirectory: directory, command)
    guard result.exitCode == 0 else {
      throw DirectoryListingError.commandFailed(
        command: command, exitCode: result.exitCode, output: result.output)
    }
    let lines = result.output.split(whereSeparator: { $0.isNewline }).map(String.init)
    return parser(lines)
  }
}

/// Errors thrown by `DirectoryLister`.
public enum DirectoryListingError: Error, LocalizedError, Sendable {
  /// The listing command exited non-zero.
  ///
  /// `output` carries the captured output text so callers can surface why the
  /// listing failed (e.g. an inaccessible directory). The executor abstraction
  /// does not split stdout/stderr, so this is the combined captured message.
  case commandFailed(command: String, exitCode: Int32, output: String)

  public var errorDescription: String? {
    switch self {
    case .commandFailed(let command, let exitCode, let output):
      let detail = output.isEmpty ? "" : " \(output)"
      return "Directory listing failed (exit \(exitCode)) for `\(command)`:\(detail)"
    }
  }
}
