import Foundation
import Testing
@testable import ShellIntegrations

struct ZigIntegrationTests {
  private func makeZig(_ mainFile: String?) -> ZigIntegration {
    ZigIntegration(isAvailable: true) { _ in mainFile }
  }

  @Test func relevanceRequiresNonDirectoryBuildManifest() {
    let zig = ZigIntegration(isAvailable: true) { _ in nil }
    #expect(zig.relevance(files: [DirectoryEntry(name: "build.zig.zon", isDirectory: false)]))
    #expect(zig.relevance(files: [DirectoryEntry(name: "build.zig", isDirectory: false)]))
    // A directory literally named `build.zig` is NOT a Zig project marker.
    #expect(!zig.relevance(files: [DirectoryEntry(name: "build.zig", isDirectory: true)]))
    // Other manifests are not ours.
    #expect(!zig.relevance(files: [DirectoryEntry(name: "package.json", isDirectory: false)]))
  }

  @Test func scanEmitsBuildAndTest() {
    let actions = makeZig(nil).scan(
      directory: URL(fileURLWithPath: "/tmp/zig"),
      files: [DirectoryEntry(name: "build.zig", isDirectory: false)]
    )
    #expect(actions.contains { $0.kind == .build && $0.title == "Build" && $0.command == "zig build" })
    #expect(actions.contains { $0.kind == .test && $0.title == "Test" && $0.command == "zig build test" })
    // Every emitted command keys off the Zig toolchain.
    #expect(actions.allSatisfy { $0.command.contains("zig") })
  }

  @Test func scanEmitsRunWhenMainResolves() {
    let actions = makeZig("src/main.zig").scan(
      directory: URL(fileURLWithPath: "/tmp/zig"),
      files: [DirectoryEntry(name: "build.zig", isDirectory: false)]
    )
    #expect(actions.contains { $0.kind == .run && $0.title == "Run · main" && $0.target == "main" && $0.command == "zig run src/main.zig" })
  }

  @Test func scanOmitsRunWhenNoMainResolves() {
    let actions = makeZig(nil).scan(
      directory: URL(fileURLWithPath: "/tmp/zig"),
      files: [DirectoryEntry(name: "build.zig.zon", isDirectory: false)]
    )
    #expect(!actions.contains { $0.kind == .run })
  }

  @Test func scanIgnoresDirectoryWithoutManifest() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let actions = makeZig(nil).scan(directory: dir, files: [])
    #expect(actions.isEmpty)
  }

  @Test func requiredToolSurfacesAsZig() {
    // Default isAvailable is false; the coordinator overwrites it from the probe.
    let zig = ZigIntegration { _ in nil }
    #expect(zig.id == "zig")
    #expect(zig.displayName == "Zig")
    #expect(zig.requiredTool == "zig")
    #expect(!zig.isAvailable) // starts false until the probe overrides it
  }
}
