#if os(macOS)
import Foundation
import Testing
@testable import ShellKit

/// The `session` tool from local terminals: its folder goes on PATH, and a new
/// session can start its shell in a folder even though the daemon splits the
/// command on whitespace.
struct SessionToolTests {
  @Test func pathGetsTheToolFolderInFront() {
    #expect(LocalPTYTransport.path("/usr/bin:/bin", adding: "/Users/me/.local/bin/session")
            == "/Users/me/.local/bin:/usr/bin:/bin")
  }

  @Test func pathKeepsAFolderItAlreadyHas() {
    #expect(LocalPTYTransport.path("/usr/bin:/Users/me/.local/bin", adding: "/Users/me/.local/bin/session")
            == "/usr/bin:/Users/me/.local/bin")
  }

  @Test func pathWithoutTheToolIsUnchanged() {
    #expect(LocalPTYTransport.path("/usr/bin", adding: nil) == "/usr/bin")
    #expect(LocalPTYTransport.path(nil, adding: nil) == nil)
  }

  @Test func emptyPathGetsTheSystemFolders() {
    #expect(LocalPTYTransport.path(nil, adding: "/opt/homebrew/bin/session")
            == "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin")
  }

  /// Splits the command the way the daemon does, runs it with `pwd` in place
  /// of the login shell, and checks it landed in the folder.
  @Test(arguments: ["plain", "with space", "it's \"quoted\" $HOME `x` \\ 01", "ünï 🙂", "tab\there"])
  func shellCommandStartsInTheFolder(name: String) throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("SessionToolTests-\(UUID().uuidString)")
      .appendingPathComponent(name)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

    let command = LocalPTYTransport.sessionShellCommand(in: folder.path)
    let words = command.joined(separator: " ").split(whereSeparator: \.isWhitespace).map(String.init)
    #expect(words == command)

    let script = command[2].replacingOccurrences(of: "exec${IFS}/bin/zsh${IFS}-l${IFS}-i", with: "pwd")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: command[0])
    process.arguments = [command[1], script]
    process.currentDirectoryURL = URL(fileURLWithPath: "/")
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    process.waitUntilExit()
    let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(URL(fileURLWithPath: String(printed.dropLast())).resolvingSymlinksInPath().path
            == folder.resolvingSymlinksInPath().path)
  }
}
#endif
