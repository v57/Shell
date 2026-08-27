import Foundation
import Testing
@testable import TerminalIntegrations

struct OpenPathTargetTests {
  /// Creates a uniquely-named temp directory, runs `body`, and removes it.
  private func withTempDir(_ body: (URL) throws -> Void) throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("OpenPathTargetTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try body(dir)
    try? FileManager.default.removeItem(at: dir)
  }

  private func write(_ url: URL, _ text: String) throws {
    try Data(text.utf8).write(to: url)
  }

  @Test func directoryReturnsTerminalFolder() throws {
    try withTempDir { dir in
      #expect(OpenPathResolver.target(for: dir) == .terminal(folder: dir))
    }
  }

  @Test func directoryWithTextExtensionStillReturnsTerminalFolder() throws {
    try withTempDir { dir in
      let named = dir.appendingPathComponent("folder.md", isDirectory: true)
      try FileManager.default.createDirectory(at: named, withIntermediateDirectories: true)
      #expect(OpenPathResolver.target(for: named) == .terminal(folder: named))
    }
  }

  @Test func allTextExtensionsReturnTextFile() throws {
    try withTempDir { dir in
      for ext in ["txt", "conf", "md", "yml", "yaml"] {
        let file = dir.appendingPathComponent("file.\(ext)")
        try write(file, "hello")
        #expect(OpenPathResolver.target(for: file) == .textFile(url: file))
      }
    }
  }

  @Test func uppercaseTextExtensionsAreCaseInsensitive() throws {
    try withTempDir { dir in
      for ext in ["TXT", "Conf", "MD", "YML", "YAML"] {
        let file = dir.appendingPathComponent("file.\(ext)")
        try write(file, "hello")
        #expect(OpenPathResolver.target(for: file) == .textFile(url: file))
      }
    }
  }

  @Test func otherExtensionsAreIgnored() throws {
    try withTempDir { dir in
      for ext in ["swift", "png", "json", "log", "pdf", "go"] {
        let file = dir.appendingPathComponent("file.\(ext)")
        try write(file, "x")
        #expect(OpenPathResolver.target(for: file) == .ignored)
      }
    }
  }

  @Test func noExtensionIsIgnored() throws {
    try withTempDir { dir in
      let file = dir.appendingPathComponent("README")
      try write(file, "x")
      #expect(OpenPathResolver.target(for: file) == .ignored)
    }
  }

  @Test func nonRegularFileWithTextExtensionIsIgnored() throws {
    try withTempDir { dir in
      // A named pipe is a non-regular file bearing a text extension.
      let pipe = dir.appendingPathComponent("pipe.txt")
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/mkfifo")
      process.arguments = [pipe.path]
      try process.run()
      process.waitUntilExit()
      guard FileManager.default.fileExists(atPath: pipe.path) else { return }
      #expect(OpenPathResolver.target(for: pipe) == .ignored)
    }
  }

  @Test func nonExistentPathIsIgnored() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("does-not-exist-\(UUID().uuidString).txt")
    #expect(OpenPathResolver.target(for: url) == .ignored)
  }
}
