import Foundation
import Testing
@testable import TerminalIntegrations

struct GoIntegrationTests {
  private let go = GoIntegration(isAvailable: true)

  @Test func relevanceRequiresGoMod() {
    #expect(go.relevance(files: [DirectoryEntry(name: "go.mod", isDirectory: false)]))
    // A directory literally named `go.mod` is NOT a Go module marker.
    #expect(!go.relevance(files: [DirectoryEntry(name: "go.mod", isDirectory: true)]))
    #expect(!go.relevance(files: [DirectoryEntry(name: "main.go", isDirectory: false)]))
  }

  @Test func scanProducesBuildRunTestLint() {
    let files = [DirectoryEntry(name: "go.mod", isDirectory: false)]
    let actions = go.scan(directory: URL(fileURLWithPath: "/tmp/GoDemo"), files: files)

    #expect(actions.contains { $0.kind == .build && $0.command == "go build ./..." })
    #expect(actions.contains { $0.kind == .run && $0.command == "go run ./..." })
    #expect(actions.contains { $0.kind == .test && $0.command == "go test ./..." })
    #expect(actions.contains { $0.kind == .lint && $0.command == "go vet ./..." })
  }

  @Test func scanIgnoresDirectoryWithoutGoMod() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let actions = go.scan(directory: dir, files: [])
    #expect(actions.isEmpty)
  }
}
