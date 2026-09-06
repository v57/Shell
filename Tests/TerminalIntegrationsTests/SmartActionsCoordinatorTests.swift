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

private final class MultiActionIntegration: TerminalIntegration {
  let id: String
  let displayName: String
  var isAvailable = true
  let produced: [IntegrationAction]
  init(id: String, produced: [IntegrationAction]) {
    self.id = id
    self.displayName = id
    self.produced = produced
  }
  func relevance(files: [DirectoryEntry]) -> Bool { true }
  func scan(directory: URL, files: [DirectoryEntry]) -> [IntegrationAction] { produced }
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

  @Test func refreshIgnoresEntryFromOlderCacheVersion() throws {
    let dir = try makeDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let integration = RecordingIntegration(id: "swift")
    let cache = MemCacheStore()
    // Seed a cache entry written by an OLD build, whose fingerprint is the
    // bare top-level hash (no `cacheVersion` prefix). The coordinator now
    // computes "2:" + hash, so this legacy entry must be treated as a MISS and
    // re-scanned — the regression that showed stale actions after adding a new
    // action kind without a directory-content change.
    let legacy = IntegrationFingerprint.hash(entries: IntegrationFileLister.list(directory: dir))
    cache.store[dir.standardizedFileURL.path] = IntegrationCacheEntry(
      fingerprint: legacy,
      actions: [IntegrationAction(kind: .build, title: "stale", target: nil, command: "old")]
    )
    let coordinator = coordinator(integrations: [integration], cache: cache, swiftAvailable: true)
    coordinator.probeEnvironment()

    let actions = coordinator.refresh(directory: dir)
    #expect(integration.scanCalls == 1)
    #expect(actions.count == 1)
    #expect(cache.store[dir.standardizedFileURL.path]?.fingerprint != legacy)
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

  @Test func refreshOrdersByKindThenIntegration() throws {
    let dir = try makeDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let xcode = MultiActionIntegration(id: "xcode", produced: [
      IntegrationAction(kind: .build, title: "XB", target: nil, command: "b"),
      IntegrationAction(kind: .test, title: "XT", target: nil, command: "t"),
      IntegrationAction(kind: .run, title: "XR", target: nil, command: "r"),
    ])
    let swift = MultiActionIntegration(id: "swift", produced: [
      IntegrationAction(kind: .run, title: "SRun", target: nil, command: "sr"),
      IntegrationAction(kind: .build, title: "SBuild", target: nil, command: "sb"),
    ])
    let coordinator = SmartActionsCoordinator(
      integrations: [xcode, swift],
      cacheStore: MemCacheStore(),
      probe: { EnvironmentProbe(xcodebuildAvailable: true, swiftAvailable: true) }
    )
    coordinator.probeEnvironment()

    let titles = coordinator.refresh(directory: dir).map(\.title)
    // Kind order Run, Build, Test; within a kind, Xcode (index 0) before Swift.
    #expect(titles == ["XR", "SRun", "XB", "SBuild", "XT"])
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

  @Test func probeEnablesJSIntegrationOnAnyAvailabilityTool() {
    // JS/TS is bun-first with an npm fallback (user directive): the integration
    // must be available when bun OR npm OR node is on PATH — not only when bun
    // is present — even though its requiredTool is "bun". This is the OR rule
    // that availabilityTools expresses for an integration whose coordinator
    // gate would otherwise be a single-tool requiredTool check.
    func availability(with tools: Set<String>) -> Bool {
      let integration = JSIntegration(isAvailable: false)
      let coordinator = SmartActionsCoordinator(
        integrations: [integration],
        cacheStore: MemCacheStore(),
        probe: { EnvironmentProbe(availableTools: tools) }
      )
      coordinator.probeEnvironment()
      return integration.isAvailable
    }
    #expect(availability(with: ["bun", "npm", "node"]))
    #expect(availability(with: ["npm", "node"]))  // bun absent -> npm fallback still on
    #expect(availability(with: ["node"]))
    #expect(availability(with: ["bun"]))
    #expect(!availability(with: []))              // no JS toolchain
  }
}
