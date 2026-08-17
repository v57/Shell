import Foundation
import Testing
@testable import TerminalIntegrations

private final class MemCacheStore: IntegrationCacheStore {
  var store: [String: IntegrationCacheEntry] = [:]
  func entry(forDirectory directory: URL) -> IntegrationCacheEntry? {
    store[directory.standardizedFileURL.path]
  }
  func save(_ entry: IntegrationCacheEntry, forDirectory directory: URL) {
    store[directory.standardizedFileURL.path] = entry
  }
}

private final class RecordingIntegration: TerminalIntegration {
  let id: String
  let displayName: String
  var isAvailable = true
  var scanCalls = 0
  let relevant: Bool
  private let action: IntegrationAction

  init(id: String, relevant: Bool = true,
       action: IntegrationAction = IntegrationAction(kind: .build, title: "Build", target: nil, command: "make")) {
    self.id = id
    self.displayName = id
    self.relevant = relevant
    self.action = action
  }

  func relevance(files: [DirectoryEntry]) -> Bool { relevant }
  func scan(directory: URL, files: [DirectoryEntry]) -> [IntegrationAction] {
    scanCalls += 1
    return [action]
  }
}

struct SmartActionsCoordinatorTests {
  private func makeDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func coordinator(
    integrations: [any TerminalIntegration],
    cache: MemCacheStore,
    swiftAvailable: Bool
  ) -> SmartActionsCoordinator {
    SmartActionsCoordinator(
      integrations: integrations,
      cacheStore: cache,
      probe: { EnvironmentProbe(xcodebuildAvailable: false, swiftAvailable: swiftAvailable) }
    )
  }

  @Test func refreshMissRescansAndPersists() throws {
    let dir = try makeDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let integration = RecordingIntegration(id: "swift")
    let cache = MemCacheStore()
    let coordinator = coordinator(integrations: [integration], cache: cache, swiftAvailable: true)
    coordinator.probeEnvironment()

    let actions = coordinator.refresh(directory: dir)
    #expect(actions.count == 1)
    #expect(integration.scanCalls == 1)
    #expect(cache.store.count == 1)
  }

  @Test func refreshHitUsesCacheWithoutRescan() throws {
    let dir = try makeDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let integration = RecordingIntegration(id: "swift")
    let cache = MemCacheStore()
    let coordinator = coordinator(integrations: [integration], cache: cache, swiftAvailable: true)
    coordinator.probeEnvironment()

    _ = coordinator.refresh(directory: dir)   // miss → scan once
    let second = coordinator.refresh(directory: dir) // same fingerprint → cache hit
    #expect(integration.scanCalls == 1)
    #expect(second.count == 1)
  }

  @Test func refreshRescansWhenFingerprintChanges() throws {
    let dir = try makeDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let integration = RecordingIntegration(id: "swift")
    let cache = MemCacheStore()
    let coordinator = coordinator(integrations: [integration], cache: cache, swiftAvailable: true)
    coordinator.probeEnvironment()

    _ = coordinator.refresh(directory: dir)              // miss, scan 1
    try Data().write(to: dir.appendingPathComponent("new.txt")) // change fingerprint
    _ = coordinator.refresh(directory: dir)              // miss again, scan 2
    #expect(integration.scanCalls == 2)
  }

  @Test func probeDisablesUnavailableIntegration() throws {
    let dir = try makeDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let integration = RecordingIntegration(id: "swift")
    let cache = MemCacheStore()
    let coordinator = coordinator(integrations: [integration], cache: cache, swiftAvailable: false)
    coordinator.probeEnvironment()

    #expect(integration.isAvailable == false)
    let actions = coordinator.refresh(directory: dir)
    #expect(integration.scanCalls == 0)
    #expect(actions.isEmpty)
  }

  @Test func irrelevantIntegrationIsNotScanned() throws {
    let dir = try makeDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let integration = RecordingIntegration(id: "swift", relevant: false)
    let cache = MemCacheStore()
    let coordinator = coordinator(integrations: [integration], cache: cache, swiftAvailable: true)
    coordinator.probeEnvironment()

    let actions = coordinator.refresh(directory: dir)
    #expect(actions.isEmpty)
    #expect(integration.scanCalls == 0)
  }
}
