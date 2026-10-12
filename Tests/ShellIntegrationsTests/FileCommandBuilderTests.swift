import Foundation
import Testing
@testable import ShellIntegrations

/// A tiny fake executor: records the directory and command it was given and
/// returns a configurable result, without spawning any process.
private actor FakeCommandExecutor: FileCommandExecutor {
  var calls: [(dir: String, command: String)] = []
  let result: CommandResult

  init(result: CommandResult = CommandResult(output: "", exitCode: 0)) {
    self.result = result
  }

  func run(inDirectory dir: String, _ command: String) async throws -> CommandResult {
    calls.append((dir, command))
    return result
  }
}

struct FileCommandBuilderTests {
  // MARK: - list

  @Test func listCdAndLs() {
    #expect(FileCommandBuilder.list(directory: "/Users/me") == "cd '/Users/me' && ls -la")
    #expect(FileCommandBuilder.list(directory: "~/Projects") == "cd '~/Projects' && ls -la")
  }

  @Test func listQuotesSpaces() {
    #expect(FileCommandBuilder.list(directory: "/Users/me/My Project")
      == "cd '/Users/me/My Project' && ls -la")
  }

  // MARK: - shellQuote escaping (exercised through public builders)

  @Test func listEscapesApostrophe() {
    #expect(FileCommandBuilder.list(directory: "it's")
      == "cd 'it'\\''s' && ls -la")
  }

  // MARK: - open

  @Test func openDirectoryCds() {
    #expect(FileCommandBuilder.open(path: "/Users/me/SomeDir", isDirectory: true, remotePlatform: .macOS)
      == "cd '/Users/me/SomeDir'")
  }

  @Test func openFileMacOS() {
    #expect(FileCommandBuilder.open(path: "/tmp/file.txt", isDirectory: false, remotePlatform: .macOS)
      == "open '/tmp/file.txt'")
  }

  @Test func openFileLinux() {
    #expect(FileCommandBuilder.open(path: "/tmp/file.txt", isDirectory: false, remotePlatform: .linux)
      == "xdg-open '/tmp/file.txt'")
  }

  // MARK: - delete

  @Test func deleteFile() {
    #expect(FileCommandBuilder.delete(path: "/tmp/file.txt", isDirectory: false)
      == "rm '/tmp/file.txt'")
  }

  @Test func deleteDirectory() {
    #expect(FileCommandBuilder.delete(path: "/tmp/SomeDir", isDirectory: true)
      == "rm -rf '/tmp/SomeDir'")
  }

  // MARK: - moveCopy

  @Test func copyUsesRsyncOnly() {
    #expect(FileCommandBuilder.moveCopy(source: "/a/src", destination: "/b/dest", mode: .copy)
      == "rsync -a '/a/src' '/b/dest'")
  }

  @Test func moveRunsRsyncThenRemoveSource() {
    #expect(FileCommandBuilder.moveCopy(source: "/a/src", destination: "/b/dest", mode: .move)
      == "rsync -a '/a/src' '/b/dest' && rm -rf '/a/src'")
  }

  // MARK: - executor

  @Test func fakeExecutorRecordsRunCall() async throws {
    let executor = FakeCommandExecutor(result: CommandResult(output: "hello", exitCode: 0))
    let result = try await executor.run(inDirectory: "/tmp", "ls -la")
    #expect(result.output == "hello")
    #expect(result.exitCode == 0)

    let calls = await executor.calls
    #expect(calls.count == 1)
    #expect(calls[0].dir == "/tmp")
    #expect(calls[0].command == "ls -la")
  }

  @Test func builderCommandsRunThroughExecutor() async throws {
    let executor = FakeCommandExecutor()
    let command = FileCommandBuilder.list(directory: "/tmp")
    _ = try await executor.run(inDirectory: "/tmp", command)
    let calls = await executor.calls
    #expect(calls[0].command == "cd '/tmp' && ls -la")
  }
}
