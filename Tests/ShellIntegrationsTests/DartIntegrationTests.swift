import Foundation
import Testing
@testable import ShellIntegrations

private let pubspecWithName = """
name: demo_app
description: A demo Dart package.
version: 1.0.0
environment:
  sdk: ^3.0.0
"""

private let pubspecUnquotedName = """
name: demo_app
version: 1.0.0
"""

struct DartIntegrationTests {
  private func makeDart(_ manifest: String?) -> DartIntegration {
    DartIntegration(isAvailable: true) { _ in manifest }
  }

  @Test func relevanceRequiresNonDirectoryPubspec() {
    let dart = DartIntegration(isAvailable: true) { _ in "" }
    #expect(dart.relevance(files: [DirectoryEntry(name: "pubspec.yaml", isDirectory: false)]))
    // A directory literally named `pubspec.yaml` is NOT a Dart project marker.
    #expect(!dart.relevance(files: [DirectoryEntry(name: "pubspec.yaml", isDirectory: true)]))
    // Other manifest/source files are not ours.
    #expect(!dart.relevance(files: [DirectoryEntry(name: "package.json", isDirectory: false)]))
    #expect(!dart.relevance(files: [DirectoryEntry(name: "main.dart", isDirectory: false)]))
  }

  @Test func scanProducesGetTestAndRun() {
    let actions = makeDart(pubspecWithName).scan(
      directory: URL(fileURLWithPath: "/tmp/demo"),
      files: [DirectoryEntry(name: "pubspec.yaml", isDirectory: false)]
    )

    #expect(actions.contains { $0.kind == .build && $0.title == "Build" && $0.command == "dart pub get" })
    #expect(actions.contains { $0.kind == .test && $0.title == "Test" && $0.command == "dart test" })
    #expect(actions.contains { $0.kind == .run && $0.title == "Run" && $0.command == "dart run" })
    // Every emitted command keys off the Dart toolchain.
    #expect(actions.allSatisfy { $0.command.contains("dart") })
  }

  @Test func scanUsesPackageNameAsRunTarget() {
    let actions = makeDart(pubspecWithName).scan(
      directory: URL(fileURLWithPath: "/tmp/demo"),
      files: [DirectoryEntry(name: "pubspec.yaml", isDirectory: false)]
    )

    let run = actions.first { $0.kind == .run }
    #expect(run?.target == "demo_app")
    #expect(run?.command == "dart run")
  }

  @Test func scanStillEmitsActionsWhenPubspecUnreadable() {
    // A Dart project is relevant even without a parseable `name:` — `dart`
    // reads pubspec.yaml itself, so get/test/run stay available, just
    // target-less for run.
    let actions = makeDart(nil).scan(
      directory: URL(fileURLWithPath: "/tmp/demo"),
      files: [DirectoryEntry(name: "pubspec.yaml", isDirectory: false)]
    )

    #expect(actions.contains { $0.kind == .build && $0.command == "dart pub get" })
    #expect(actions.contains { $0.kind == .test && $0.command == "dart test" })
    let run = actions.first { $0.kind == .run }
    #expect(run?.command == "dart run")
    #expect(run?.target == nil)
  }

  @Test func scanIgnoresDirectoryWithoutPubspec() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let actions = makeDart(pubspecWithName).scan(directory: dir, files: [])
    #expect(actions.isEmpty)
  }

  @Test func parseNameExtractsTopLevelName() {
    // Quoted and unquoted values both resolve; a trailing comment is stripped.
    #expect(DartIntegration.parseName(from: pubspecWithName) == "demo_app")
    #expect(DartIntegration.parseName(from: pubspecUnquotedName) == "demo_app")
    #expect(DartIntegration.parseName(from: "name: \"my_pkg\" # the app\nversion: 0.1.0") == "my_pkg")
  }

  @Test func parseNameIgnoresNestedNameKeys() {
    // A `name:` nested under dependencies / dev_dependencies is not the
    // package name, so it must never be returned.
    let source = """
    name: demo_app
    dependencies:
      name: nested_dep
    dev_dependencies:
      name: nested_dev_dep
    """
    #expect(DartIntegration.parseName(from: source) == "demo_app")
  }

  @Test func parseNameReturnsNilWhenAbsent() {
    #expect(DartIntegration.parseName(from: "") == nil)
    #expect(DartIntegration.parseName(from: "version: 1.0.0\nenvironment:\n  sdk: ^3.0.0") == nil)
  }

  @Test func requiredToolSurfacesAsDart() {
    // Default isAvailable is false; the coordinator overwrites it from the probe.
    let dart = DartIntegration { _ in "" }
    #expect(dart.id == "dart")
    #expect(dart.displayName == "Dart")
    #expect(dart.requiredTool == "dart")
    #expect(!dart.isAvailable) // starts false until the probe overrides it
  }
}
