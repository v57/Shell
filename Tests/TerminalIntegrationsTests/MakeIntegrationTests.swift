import Foundation
import Testing
@testable import TerminalIntegrations

struct MakeIntegrationTests {
  private let make = MakeIntegration(isAvailable: true)

  @Test func relevanceRequiresNonDirectoryMakefile() {
    #expect(make.relevance(files: [DirectoryEntry(name: "Makefile", isDirectory: false)]))
    // A directory literally named `Makefile` is NOT a Make project marker.
    #expect(!make.relevance(files: [DirectoryEntry(name: "Makefile", isDirectory: true)]))
    #expect(!make.relevance(files: [DirectoryEntry(name: "main.go", isDirectory: false)]))
  }

  @Test func scanProducesBuildTestBuildRun() {
    let files = [DirectoryEntry(name: "Makefile", isDirectory: false)]
    let actions = make.scan(directory: URL(fileURLWithPath: "/tmp/MakeDemo"), files: files)

    // Default build target.
    let defaultBuild = actions.first { $0.kind == .build && $0.command == "make" }
    #expect(defaultBuild != nil)
    #expect(defaultBuild?.title == "Build")

    // Explicit `make build`.
    let build = actions.first { $0.kind == .build && $0.command == "make build" }
    #expect(build != nil)
    #expect(build?.title == "Build")

    // Test / Run.
    #expect(actions.contains { $0.kind == .test && $0.title == "Test" && $0.command == "make test" })
    #expect(actions.contains { $0.kind == .run && $0.title == "Run" && $0.command == "make run" })

    // Every command keys off `make`.
    #expect(actions.allSatisfy { $0.command.contains("make") })
    // No project target: Makefile exports no discoverable target name.
    #expect(actions.allSatisfy { $0.target == nil })
  }

  @Test func scanIgnoresDirectoryWithoutMakefile() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let actions = make.scan(directory: dir, files: [])
    #expect(actions.isEmpty)
  }
}
