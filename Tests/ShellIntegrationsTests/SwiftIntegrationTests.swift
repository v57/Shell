import Foundation
import Testing
@testable import ShellIntegrations

struct SwiftIntegrationTests {
  private let swift = SwiftIntegration(isAvailable: true)

  @Test func relevanceRequiresPackageSwift() {
    #expect(swift.relevance(files: [DirectoryEntry(name: "Package.swift", isDirectory: false)]))
    #expect(!swift.relevance(files: [DirectoryEntry(name: "main.swift", isDirectory: false)]))
  }

  @Test func scanProducesBuildTestAndPerExecutableRun() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let packageSwift = """
    // swift-tools-version: 5.9
    import PackageDescription
    let package = Package(
      name: "Demo",
      targets: [
        .executableTarget(name: "Server", dependencies: []),
        .target(name: "Core", dependencies: []),
      ]
    )
    """
    try packageSwift.write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

    let files = [DirectoryEntry(name: "Package.swift", isDirectory: false)]
    let actions = swift.scan(directory: dir, files: files)

    #expect(actions.contains { $0.kind == .build && $0.command == "swift build" })
    #expect(actions.contains { $0.kind == .test && $0.command == "swift test" })
    #expect(actions.contains { $0.kind == .run && $0.target == "Server" && $0.command == "swift run Server" })
    // Core is a library (not executable) → no run action for it.
    #expect(!actions.contains { $0.kind == .run && $0.target == "Core" })
  }

  @Test func scanIgnoresDirectoryWithoutPackageSwift() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let actions = swift.scan(directory: dir, files: [])
    #expect(actions.isEmpty)
  }
}
