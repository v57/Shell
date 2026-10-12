import Foundation
import Testing
@testable import ShellIntegrations

struct ToolIntegrationBaseTests {
  @Test func relevanceMatchesMarkerNameAndDirectoryExpectation() {
    let base = ToolIntegrationBase(
      id: "node", displayName: "Node",
      requiredTool: "node",
      markerNames: ["package.json"], isDirectory: false
    ) { _, _ in [] }

    #expect(base.relevance(files: [DirectoryEntry(name: "package.json", isDirectory: false)]))
    #expect(!base.relevance(files: [DirectoryEntry(name: "package.json", isDirectory: true)]))
    #expect(!base.relevance(files: [DirectoryEntry(name: "Cargo.toml", isDirectory: false)]))
  }

  @Test func scanCallsBuilderOnlyWhenRelevant() {
    let action = IntegrationAction(kind: .lint, title: "Lint", target: nil, command: "eslint .")
    let base = ToolIntegrationBase(
      id: "node", displayName: "Node",
      markerNames: ["package.json"]
    ) { _, _ in [action] }

    let dir = URL(fileURLWithPath: "/tmp")
    // Not relevant -> builder not called.
    #expect(base.scan(directory: dir, files: [DirectoryEntry(name: "README.md", isDirectory: false)]).isEmpty)
    // Relevant -> builder output returned.
    #expect(base.scan(directory: dir, files: [DirectoryEntry(name: "package.json", isDirectory: false)]) == [action])
  }

  @Test func requiredToolIsSurfaceable() throws {
    let base = ToolIntegrationBase(
      id: "rust", displayName: "Rust",
      requiredTool: "cargo",
      markerNames: ["Cargo.toml"]
    ) { _, _ in [] }
    #expect(base.requiredTool == "cargo")
    #expect(base.relevance(files: [DirectoryEntry(name: "Cargo.toml", isDirectory: false)]))
    #expect(!base.relevance(files: [DirectoryEntry(name: "Cargo.lock", isDirectory: false)]))
  }
}
