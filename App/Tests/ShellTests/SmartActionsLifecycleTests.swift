import Foundation
import ShellIntegrations
import Testing
@testable import ShellApp

/// Smart-action lifecycle on the shared AppModel. Runs in the hosted test
/// environment (GUI); skipped implicitly if the app can't bootstrap.
@Suite(.serialized)
struct SmartActionsLifecycleTests {
  @MainActor @Test func refreshSmartActionsDetectsSwiftPackage() async throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let packageSwift = """
    // swift-tools-version: 5.9
    import PackageDescription
    let package = Package(name: "Demo", targets: [.executableTarget(name: "Demo")])
    """
    try packageSwift.write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

    let model = AppModel.shared
    model.refreshSmartActions(for: dir)
    // The scan runs off the main actor; wait for it to publish.
    for _ in 0..<100 where model.smartActionSchemes.isEmpty {
      try await Task.sleep(for: .milliseconds(50))
    }
    let scheme = try #require(model.smartActionSchemes.first)
    #expect(scheme.name == "Demo")
    #expect(scheme.terminalCommand(for: .run) == "swift run Demo")
    #expect(model.isSmartActionRunning(.run, scheme: scheme, in: dir) == false)

    // Clearing the active directory empties the actions.
    model.refreshSmartActions(for: nil)
    #expect(model.smartActionSchemes.isEmpty)
  }
}
