import Foundation
import Testing

@testable import ShellIntegrations

/// A fake executor that records the directory and command it was given and
/// returns a configurable result, without spawning any process.
private actor FakeExecutor: FileCommandExecutor {
  var calls: [(dir: String, command: String)] = []
  let result: CommandResult

  init(result: CommandResult) { self.result = result }

  func run(inDirectory dir: String, _ command: String) async throws -> CommandResult {
    calls.append((dir, command))
    return result
  }
}

/// Captures the lines handed to a custom parser so tests can prove the `[String]`
/// contract of `DirectoryLister.list`.
private final class LineRecorder { var lines: [String] = [] }

struct DirectoryListerTests {
  static let bsdFixture = """
    total 24
    drwxr-xr-x@ 14 v57  staff   448 Aug 26 20:06 .
    drwxr-xr-x   4 v57  staff   128 Aug 26 20:06 ..
    drwxr-xr-x   5 v57  staff   160 Aug 26 20:06 Apps
    drwxr-xr-x   6 v57  staff   192 Aug 26 20:06 Documents
    -rw-r--r--   1 v57  staff  20480 Aug 26 20:06 release notes.txt
    -rw-r--r--   1 v57  staff  14340 Aug 26 20:06 .DS_Store
    lrwxr-xr-x   1 v57  staff    21 Aug 26 20:06 current -> Documents/Archive 2025
    lrwxr-xr-x   1 v57  staff    21 Aug 26 20:06 my link -> ../src
    """

  static let gnuFixture = """
    total 48
    drwxr-xr-x 5 root root 4096 Aug 26 20:06 .
    drwxr-xr-x 4 root root 4096 Aug 26 20:06 ..
    -rw-r--r-- 1 root root 14340 Aug 26 20:06 .config
    drwxr-xr-x 3 root root 4096 Aug 26 20:06 src
    -rw-r--r-- 1 root root 20480 Aug 26 20:06 release notes.txt
    lrwxrwxrwx 1 root root 21 Aug 26 20:06 current -> ../src/main
    drwxr-xr-x 2 root root 4096 Nov 12 2024 old-archive
    -rw-r--r-- 1 root root 512 Jan  3 2020 deprecated.txt
    """

  static let blankAndTotalFixture = """
    total 32

    drwxr-xr-x   4 v57  staff   128 Aug 26 20:06 Docs

    -rw-r--r--   1 v57  staff   512 Aug 26 20:06 notes.txt
    """

  @Test func listsBsdOutput() async throws {
    let executor = FakeExecutor(result: CommandResult(output: Self.bsdFixture, exitCode: 0))
    let rows = try await DirectoryLister.list(directory: "/Users/me", executor: executor)

    #expect(rows.count == 6)
    #expect(
      rows.map(\.name) == [
        "Apps", "Documents", "release notes.txt", ".DS_Store", "current", "my link",
      ])
    #expect(rows[0].isDirectory)  // Apps is a directory.
    #expect(!rows[2].isDirectory)  // release notes.txt is a regular file.
  }

  @Test func listsGnuOutput() async throws {
    let executor = FakeExecutor(result: CommandResult(output: Self.gnuFixture, exitCode: 0))
    let rows = try await DirectoryLister.list(directory: "/srv", executor: executor)

    #expect(rows.count == 6)
    #expect(
      rows.map(\.name) == [
        ".config", "src", "release notes.txt", "current", "old-archive", "deprecated.txt",
      ])
    #expect(rows[4].isDirectory)  // old-archive is a directory.
    #expect(!rows[5].isDirectory)  // deprecated.txt is a regular file.
  }

  @Test func usesDirectoryBasedListCommand() async throws {
    let executor = FakeExecutor(result: CommandResult(output: Self.bsdFixture, exitCode: 0))
    _ = try await DirectoryLister.list(directory: "/Users/me", executor: executor)

    let calls = await executor.calls
    #expect(calls.count == 1)
    #expect(calls[0].dir == "/Users/me")
    #expect(calls[0].command == FileCommandBuilder.list(directory: "/Users/me"))
    #expect(calls[0].command == "cd '/Users/me' && ls -la")
  }

  @Test func nonZeroExitThrowsErrorIncludingOutput() async throws {
    let errorOutput = "ls: cannot open directory '/nope': No such file or directory\n"
    let executor = FakeExecutor(result: CommandResult(output: errorOutput, exitCode: 1))

    await #expect(throws: DirectoryListingError.self) {
      _ = try await DirectoryLister.list(directory: "/nope", executor: executor)
    }
  }

  @Test func nonZeroExitErrorDescriptionSurfacesOutput() async throws {
    let errorOutput = "ls: cannot open directory '/nope': No such file or directory\n"
    let executor = FakeExecutor(result: CommandResult(output: errorOutput, exitCode: 1))

    do {
      _ = try await DirectoryLister.list(directory: "/nope", executor: executor)
      Issue.record("Expected a non-zero exit to throw.")
    } catch {
      #expect(error.localizedDescription.contains("exit 1"))
      #expect(error.localizedDescription.contains("cannot open directory '/nope'"))
    }
  }

  @Test func defaultParserStripsTotalAndBlankLines() async throws {
    let executor = FakeExecutor(
      result: CommandResult(output: Self.blankAndTotalFixture, exitCode: 0))
    let rows = try await DirectoryLister.list(directory: "/d", executor: executor)

    #expect(rows.count == 2)
    #expect(rows.map(\.name) == ["Docs", "notes.txt"])
  }

  @Test func passesOutputLinesToParser() async throws {
    let recorder = LineRecorder()
    let executor = FakeExecutor(result: CommandResult(output: Self.bsdFixture, exitCode: 0))

    let rows = try await DirectoryLister.list(directory: "/d", executor: executor) { lines in
      recorder.lines = lines
      return lines.map { FileRow(name: $0, isDirectory: false) }
    }

    // The output is split into individual lines — not handed over as one blob.
    #expect(recorder.lines.count == 9)
    #expect(recorder.lines.first == "total 24")
    #expect(recorder.lines.contains(where: { $0.hasSuffix("Apps") }))
    #expect(rows.count == recorder.lines.count)
  }
}
