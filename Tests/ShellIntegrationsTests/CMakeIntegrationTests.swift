import Foundation
import Testing
@testable import ShellIntegrations

struct CMakeIntegrationTests {
  private func makeCMake(_ manifest: String) -> CMakeIntegration {
    CMakeIntegration(isAvailable: true) { _ in manifest }
  }

  @Test func relevanceRequiresCMakeLists() {
    let cmake = CMakeIntegration(isAvailable: true) { _ in "" }
    #expect(cmake.relevance(files: [DirectoryEntry(name: "CMakeLists.txt", isDirectory: false)]))
    // A directory literally named CMakeLists.txt is NOT a CMake marker.
    #expect(!cmake.relevance(files: [DirectoryEntry(name: "CMakeLists.txt", isDirectory: true)]))
    #expect(!cmake.relevance(files: [DirectoryEntry(name: "Makefile", isDirectory: false)]))
    #expect(!cmake.relevance(files: [DirectoryEntry(name: "package.json", isDirectory: false)]))
  }

  @Test func scanProducesBuildTestAndPerTargetRun() {
    let manifest = """
    cmake_minimum_required(VERSION 3.20)
    project(hello VERSION 1.0)
    add_executable(server server.c)
    add_executable(worker worker.c)
    """
    let actions = makeCMake(manifest).scan(
      directory: URL(fileURLWithPath: "/tmp/cmake"),
      files: [DirectoryEntry(name: "CMakeLists.txt", isDirectory: false)]
    )

    #expect(actions.contains { $0.kind == .build && $0.title == "Build" && $0.command == "cmake -B build && cmake --build build" })
    #expect(actions.contains { $0.kind == .test && $0.title == "Test" && $0.command == "ctest --test-dir build" })
    #expect(actions.contains { $0.kind == .run && $0.target == "server" && $0.command == "cmake --build build && ./build/server" })
    #expect(actions.contains { $0.kind == .run && $0.target == "worker" && $0.command == "cmake --build build && ./build/worker" })

    // Every command keys off the CMake/CTest toolchain.
    #expect(actions.allSatisfy { $0.command.contains("cmake") || $0.command.contains("ctest") })
  }

  @Test func scanParsesMultilineAddExecutable() {
    let manifest = """
    add_executable(
      complex
      a.c
      b.c
    )
    """
    let actions = makeCMake(manifest).scan(
      directory: URL(fileURLWithPath: "/tmp/cmake"),
      files: [DirectoryEntry(name: "CMakeLists.txt", isDirectory: false)]
    )
    #expect(actions.contains { $0.kind == .run && $0.target == "complex" })
  }

  @Test func scanSkipsAliasAndImportedExecutables() {
    let manifest = """
    add_executable(app app.c)
    add_executable(ref ALIAS app)
    add_executable(extern IMPORTED)
    """
    let actions = makeCMake(manifest).scan(
      directory: URL(fileURLWithPath: "/tmp/cmake"),
      files: [DirectoryEntry(name: "CMakeLists.txt", isDirectory: false)]
    )
    #expect(actions.contains { $0.kind == .run && $0.target == "app" })
    // ALIAS / IMPORTED references aren't runnable binaries in `build/`.
    #expect(!actions.contains { $0.kind == .run && $0.target == "ref" })
    #expect(!actions.contains { $0.kind == .run && $0.target == "extern" })
  }

  @Test func scanOmitsRunWhenNoExecutableTarget() {
    let manifest = """
    project(helper VERSION 1.0)
    add_library(helper STATIC helper.c)
    """
    let actions = makeCMake(manifest).scan(
      directory: URL(fileURLWithPath: "/tmp/cmake"),
      files: [DirectoryEntry(name: "CMakeLists.txt", isDirectory: false)]
    )
    #expect(actions.contains { $0.kind == .build })
    #expect(actions.contains { $0.kind == .test })
    // No add_executable → no run action.
    #expect(!actions.contains { $0.kind == .run })
  }

  @Test func scanEmptyWhenManifestUnreadable() {
    let cmake = CMakeIntegration(isAvailable: true) { _ in nil }
    let files = [DirectoryEntry(name: "CMakeLists.txt", isDirectory: false)]
    #expect(cmake.scan(directory: URL(fileURLWithPath: "/tmp/cmake"), files: files).isEmpty)
  }

  @Test func scanIgnoresDirectoryWithoutCMakeLists() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let actions = makeCMake("add_executable(x x.c)").scan(directory: dir, files: [])
    #expect(actions.isEmpty)
  }

  @Test func parseExecutablesCollectsAndDeduplicates() {
    let parsed = CMakeIntegration.parseExecutables(from: """
    add_executable(app app.c)
    add_executable(app app.c)
    """)
    #expect(parsed == ["app"])
  }

  @Test func requiredToolSurfacesAsCMake() {
    // Default isAvailable is false; the coordinator overwrites it from the probe.
    let cmake = CMakeIntegration { _ in "" }
    #expect(cmake.id == "cmake")
    #expect(cmake.displayName == "C/C++")
    #expect(cmake.requiredTool == "cmake")
    #expect(!cmake.isAvailable)  // starts false until the probe overrides it
  }
}
