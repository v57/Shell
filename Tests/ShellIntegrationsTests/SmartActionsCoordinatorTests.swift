import Foundation
import Testing
@testable import ShellIntegrations

private final class MemCacheStore: IntegrationCacheStore {
  var store: [String: IntegrationCacheEntry] = [:]
  func entry(forDirectory directory: URL) -> IntegrationCacheEntry? {
    store[directory.standardizedFileURL.path]
  }
  func save(_ entry: IntegrationCacheEntry, forDirectory directory: URL) {
    store[directory.standardizedFileURL.path] = entry
  }
}

/// Counts the scans the coordinator makes; returns one Make scheme.
private final class RecordingScan {
  var calls = 0
  func scan(_ folder: ProjectFolder) -> [ActionScheme] {
    calls += 1
    return [ActionScheme(name: folder.name, toolchain: .make, directory: folder.url, commands: [.build: "make"])]
  }
}

struct SmartActionsCoordinatorTests {
  private func makeDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  @Test func refreshMissScansAndPersists() throws {
    let dir = try makeDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let recorder = RecordingScan()
    let cache = MemCacheStore()
    let coordinator = SmartActionsCoordinator(cacheStore: cache, scan: recorder.scan)

    #expect(coordinator.refresh(directory: dir).count == 1)
    #expect(recorder.calls == 1)
    #expect(cache.store.count == 1)
  }

  @Test func refreshHitUsesCacheWithoutRescan() throws {
    let dir = try makeDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let recorder = RecordingScan()
    let coordinator = SmartActionsCoordinator(cacheStore: MemCacheStore(), scan: recorder.scan)

    _ = coordinator.refresh(directory: dir)
    let second = coordinator.refresh(directory: dir)
    #expect(recorder.calls == 1)
    #expect(second.count == 1)
  }

  @Test func refreshRescansWhenFingerprintChanges() throws {
    let dir = try makeDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let recorder = RecordingScan()
    let coordinator = SmartActionsCoordinator(cacheStore: MemCacheStore(), scan: recorder.scan)

    _ = coordinator.refresh(directory: dir)
    try Data().write(to: dir.appendingPathComponent("new.txt"))
    _ = coordinator.refresh(directory: dir)
    #expect(recorder.calls == 2)
  }

  @Test func refreshIgnoresEntryWithOtherFingerprint() throws {
    let dir = try makeDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let cache = MemCacheStore()
    // An entry from an older detectors revision (or an older Shell) has
    // another fingerprint: it must be scanned again.
    cache.store[dir.standardizedFileURL.path] = IntegrationCacheEntry(
      fingerprint: "stale",
      schemes: [ActionScheme(name: "old", toolchain: .make, directory: dir, commands: [.build: "old"])]
    )
    let recorder = RecordingScan()
    let schemes = SmartActionsCoordinator(cacheStore: cache, scan: recorder.scan).refresh(directory: dir)
    #expect(recorder.calls == 1)
    #expect(schemes.map(\.name) == [dir.lastPathComponent])
  }

  /// The default scan is CodeActions' `ProjectScanner`, for the directory
  /// itself only.
  @Test func scansWithCodeActions() throws {
    let dir = try makeDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try "module example.com/demo\n".write(to: dir.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
    let nested = dir.appendingPathComponent("tool", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try "[package]\nname = \"tool\"\n".write(to: nested.appendingPathComponent("Cargo.toml"), atomically: true, encoding: .utf8)

    let schemes = SmartActionsCoordinator(cacheStore: MemCacheStore()).refresh(directory: dir)
    #expect(schemes.map(\.toolchain) == [.go])
    #expect(schemes.first?.commands[.lint] == "go vet ./...")
  }
}
