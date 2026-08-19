import Foundation
import TerminalIntegrations
import Testing
@testable import Shell

/// Smart-action lifecycle on the shared AppModel. Runs in the hosted test
/// environment (GUI); skipped implicitly if the app can't bootstrap.
@Suite(.serialized)
struct SmartActionsLifecycleTests {
  @Test func refreshSmartActionsDetectsSwiftPackage() throws {
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
    #expect(!model.smartActionActions.isEmpty)
    #expect(model.smartActionActions.contains { $0.kind == .build })
    #expect(model.smartActionActions.contains { $0.kind == .run && $0.target == "Demo" })
    #expect(model.isSmartActionRunning(UUID(), in: dir) == false)

    // Clearing the active directory empties the actions.
    model.refreshSmartActions(for: nil)
    #expect(model.smartActionActions.isEmpty)
  }
}
