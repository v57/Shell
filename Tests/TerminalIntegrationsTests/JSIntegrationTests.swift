import Foundation
import Testing
@testable import TerminalIntegrations

struct JSIntegrationTests {
  private let manifest = #"""
  {
    "name": "demo",
    "scripts": {
      "dev": "vite",
      "test": "vitest run",
      "build": "tsc"
    }
  }
  """#

  private let pkg = DirectoryEntry(name: "package.json", isDirectory: false)

  private func makeJS(isAvailable: Bool = true, tool: String? = "bun") -> JSIntegration {
    JSIntegration(
      isAvailable: isAvailable,
      resolveTool: { tool },
      readManifest: { _ in manifest }
    )
  }

  @Test func relevanceRequiresPackageJson() {
    let js = makeJS()
    #expect(js.relevance(files: [pkg]))
    #expect(!js.relevance(files: [DirectoryEntry(name: "main.ts", isDirectory: false)]))
    // A package.json directory entry is NOT a marker (must be a file).
    #expect(!js.relevance(files: [DirectoryEntry(name: "package.json", isDirectory: true)]))
  }

  @Test func availabilityStartsFalse() {
    let js = makeJS(isAvailable: false)
    #expect(!js.isAvailable)
  }

  @Test func scanBunFirstEmitsBunCommands() {
    let actions = makeJS(tool: "bun")
      .scan(directory: URL(fileURLWithPath: "/tmp/Demo"), files: [pkg])

    #expect(actions.contains { $0.kind == .build && $0.command == "bun install" })
    #expect(actions.contains { $0.kind == .test && $0.command == "bun test" })
    #expect(actions.contains { $0.kind == .run && $0.target == "dev" && $0.command == "bun run dev" })
    #expect(actions.contains { $0.kind == .run && $0.target == "build" && $0.command == "bun run build" })
    // Every command drives bun on the bun-first path.
    #expect(actions.allSatisfy { $0.command.contains("bun") })
  }

  @Test func scanFallsBackToNpmWhenBunAbsent() {
    let actions = makeJS(tool: "npm")
      .scan(directory: URL(fileURLWithPath: "/tmp/Demo"), files: [pkg])

    #expect(actions.contains { $0.kind == .build && $0.command == "npm ci" })
    #expect(actions.contains { $0.kind == .test && $0.command == "npm test" })
    #expect(actions.contains { $0.kind == .run && $0.target == "dev" && $0.command == "npm run dev" })
    // No bun anywhere when the npm fallback path is chosen.
    #expect(actions.allSatisfy { !$0.command.contains("bun") })
  }

  @Test func scanExposesDriverInTitle() {
    let bunBuild = makeJS(tool: "bun")
      .scan(directory: URL(fileURLWithPath: "/tmp/Demo"), files: [pkg])
      .first { $0.kind == .build }
    #expect(bunBuild?.title == "Install · bun")

    let npmBuild = makeJS(tool: "npm")
      .scan(directory: URL(fileURLWithPath: "/tmp/Demo"), files: [pkg])
      .first { $0.kind == .build }
    #expect(npmBuild?.title == "Install · npm")
  }

  @Test func scanIgnoresDirectoryWithoutPackageJson() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let js = makeJS()
    #expect(js.scan(directory: dir, files: []).isEmpty)
    #expect(js.scan(directory: dir, files: [DirectoryEntry(name: "README.md", isDirectory: false)]).isEmpty)
  }

  @Test func scanEmptyWhenNoDriverPresent() {
    let actions = makeJS(tool: nil)
      .scan(directory: URL(fileURLWithPath: "/tmp/Demo"), files: [pkg])
    #expect(actions.isEmpty)
  }

  @Test func scriptsExtractsSortedKeys() {
    #expect(JSIntegration.scripts(from: manifest) == ["build", "dev", "test"])
  }

  @Test func scriptsRejectsGarbage() {
    #expect(JSIntegration.scripts(from: "not json").isEmpty)
  }
}
