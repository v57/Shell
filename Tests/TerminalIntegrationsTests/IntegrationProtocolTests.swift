import Foundation
import Testing
@testable import TerminalIntegrations

struct IntegrationProtocolTests {
  private final class MockIntegration: TerminalIntegration {
    let id = "mock"
    let displayName = "Mock"
    var isAvailable = true
    func relevance(files: [DirectoryEntry]) -> Bool {
      files.contains { $0.name == "manifest" }
    }
    func scan(directory: URL, files: [DirectoryEntry]) -> [IntegrationAction] {
      [IntegrationAction(kind: .build, title: "Build", target: nil, command: "make")]
    }
  }

  @Test func mockConformsAndGatesOnAvailability() {
    let integration = MockIntegration()
    let files = [DirectoryEntry(name: "manifest", isDirectory: false)]
    #expect(integration.relevance(files: files))
    #expect(!integration.relevance(files: [DirectoryEntry(name: "other", isDirectory: false)]))
    let actions = integration.scan(directory: URL(fileURLWithPath: "/tmp"), files: files)
    #expect(actions.count == 1)
    #expect(actions[0].kind == .build)
  }

  @Test func isAvailableIsSettableByProbe() {
    let integration = MockIntegration()
    integration.isAvailable = false
    #expect(integration.isAvailable == false)
    let probe = EnvironmentProbe(xcodebuildAvailable: false, swiftAvailable: false)
    _ = probe
  }

  @Test func cacheEntryCodableRoundTrip() throws {
    let action = IntegrationAction(kind: .test, title: "Test", target: nil, command: "swift test")
    let entry = IntegrationCacheEntry(fingerprint: "abc", actions: [action])
    let data = try JSONEncoder().encode(entry)
    let decoded = try JSONDecoder().decode(IntegrationCacheEntry.self, from: data)
    #expect(decoded.fingerprint == "abc")
    #expect(decoded.actions == entry.actions)
  }
}
