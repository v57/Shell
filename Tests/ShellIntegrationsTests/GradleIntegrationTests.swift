import Foundation
import Testing
@testable import ShellIntegrations

struct GradleIntegrationTests {
  private let gradle = GradleIntegration(isAvailable: true)

  @Test func relevanceRequiresBuildFile() {
    #expect(gradle.relevance(files: [DirectoryEntry(name: "build.gradle", isDirectory: false)]))
    #expect(gradle.relevance(files: [DirectoryEntry(name: "build.gradle.kts", isDirectory: false)]))
    // A directory literally named build.gradle is NOT a Gradle marker.
    #expect(!gradle.relevance(files: [DirectoryEntry(name: "build.gradle", isDirectory: true)]))
    #expect(!gradle.relevance(files: [DirectoryEntry(name: "settings.gradle", isDirectory: false)]))
  }

  @Test func scanProducesBuildTestRun() {
    let files = [DirectoryEntry(name: "build.gradle", isDirectory: false)]
    let actions = gradle.scan(directory: URL(fileURLWithPath: "/tmp/GradleDemo"), files: files)

    #expect(actions.contains { $0.kind == .build && $0.title == "Build" && $0.command == "gradle build" })
    #expect(actions.contains { $0.kind == .test && $0.title == "Test" && $0.command == "gradle test" })
    #expect(actions.contains { $0.kind == .run && $0.title == "Run" && $0.command == "gradle run" })

    // Every command keys off the tool; Gradle exports no parsed run target.
    #expect(actions.allSatisfy { $0.command.contains("gradle") })
    #expect(actions.allSatisfy { $0.target == nil })
  }

  @Test func scanPrefersGradlewWrapperWhenPresent() {
    let files = [
      DirectoryEntry(name: "build.gradle.kts", isDirectory: false),
      DirectoryEntry(name: "gradlew", isDirectory: false),
    ]
    let actions = gradle.scan(directory: URL(fileURLWithPath: "/tmp/GradleDemo"), files: files)

    #expect(actions.contains { $0.kind == .build && $0.command == "./gradlew build" })
    #expect(actions.contains { $0.kind == .test && $0.command == "./gradlew test" })
    #expect(actions.contains { $0.kind == .run && $0.command == "./gradlew run" })
  }

  @Test func scanIgnoresDirectoryWithoutBuildFile() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let actions = gradle.scan(directory: dir, files: [])
    #expect(actions.isEmpty)
  }

  @Test func requiredToolSurfacesAsGradle() {
    // Default isAvailable is false; the coordinator overwrites it from the probe.
    let gradle = GradleIntegration()
    #expect(gradle.id == "gradle")
    #expect(gradle.displayName == "Gradle")
    #expect(gradle.requiredTool == "gradle")
    #expect(!gradle.isAvailable)  // starts false until the probe overrides it
  }
}
