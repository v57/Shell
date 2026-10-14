import Foundation
import ShellIntegrations
import Testing
@testable import Shell

struct SmartActionsStoreTests {
  /// Hosted test (real keychain): writes an encrypted per-directory entry
  /// and reads it back, and confirms the cache keys are isolated per
  /// directory. Skips when the Secure Enclave is unavailable (locked screen).
  @Test func storeRoundTripsPerDirectory() throws {
    guard SecureFileStore.isAvailable else { return }
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let store = SmartActionsStore(directory: base)
    let dir1 = URL(fileURLWithPath: "/tmp/project-alpha")
    let dir2 = URL(fileURLWithPath: "/tmp/project-beta")
    let scheme = ActionScheme(name: "alpha", toolchain: .swiftPM, directory: dir1, commands: [.build: "swift build"])
    let entry = IntegrationCacheEntry(fingerprint: "fp1", schemes: [scheme])

    store.save(entry, forDirectory: dir1)
    let read = store.entry(forDirectory: dir1)
    #expect(read?.fingerprint == "fp1")
    #expect(read?.schemes == [scheme])
    // A different directory does not collide with dir1's cached entry.
    #expect(store.entry(forDirectory: dir2) == nil)
  }
}
