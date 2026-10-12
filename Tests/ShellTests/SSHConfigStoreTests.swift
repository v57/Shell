import CryptoKit
import Foundation
import SwiftData
import Testing
import ShellKit
@testable import Shell

/// Hermetic tests for the iCloud-synced SSH config store: a shared temp
/// SwiftData container + injected generated keys (no real keychain needed).
///
/// Notes on this suite's shape:
/// - SHARED container: creating a fresh ModelContainer per test made
///   SwiftData's fetch machinery TRAP (SIGTRAP inside SwiftData) after ~2
///   tests in the hosted runner — a process-global instability when several
///   containers for the same model are created and torn down while the host
///   app's own stores are live. One container for the whole suite sidesteps
///   it; assertions are id-scoped so tests stay isolated.
/// - `.serialized`: Swift Testing does not guarantee @MainActor tests run
///   one at a time against shared state — a rereader saw stale records
///   without it. Serializing makes the suite deterministic.
@Suite(.serialized)
struct SSHConfigStoreTests {
  /// One container for the whole process (created once, never torn down).
  private static let directory: URL = {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("ssh-suite-\(UUID().uuidString)", isDirectory: true)
  }()
  private static let sharedContainer: ModelContainer = {
    // swiftlint:disable:next force_try
    try! SSHConfigStore.makeTestContainer(in: directory)
  }()
  /// Shared keys: records sealed by one store instance must be readable by
  /// another (a fresh random key per store would make cross-instance reads
  /// fail, since reload() silently skips undecryptable records).
  private static let iCloudKey = SymmetricKey(size: .bits256)
  private static let deviceKey = SymmetricKey(size: .bits256)

  /// A fresh store over the shared container with hermetic keys injected
  /// through init (so the import step also uses them).
  private func makeStore(defaults: UserDefaults = .standard) -> SSHConfigStore {
    SSHConfigStore(
      container: Self.sharedContainer,
      defaults: defaults,
      iCloudKeyProvider: { Self.iCloudKey },
      deviceKeyProvider: { Self.deviceKey }
    )
  }

  private func makeConfig(name: String = "prod") -> SSHConfig {
    SSHConfig(name: name, host: "\(name).example.com", user: "deploy", port: 2202)
  }

  @Test @MainActor func savePersistsAndEncryptsAcrossInstances() throws {
    let config = makeConfig()
    let store = makeStore()
    store.save(config)
    #expect(store.all.first { $0.id == config.id } == config)
    #expect(store.storageError == nil)
    #expect(store.all.first { $0.id == config.id }?.displayName == "prod")

    // Fresh store over the same container: the record survives and no
    // plaintext is stored anywhere in it.
    let rereader = makeStore()
    #expect(rereader.all.first { $0.id == config.id } == config)

    let records = try Self.sharedContainer.mainContext.fetch(FetchDescriptor<SSHConfigRecord>())
    let record = try #require(records.first { $0.id == config.id })
    let cipher = try #require(record.payloadCipher)
    #expect(!cipher.contains(Data("prod.example.com".utf8)))
    #expect(!cipher.contains(Data("deploy".utf8)))
    #expect(record.keyId == SSHConfigKey.icloud)
  }

  @Test @MainActor func saveUpdatesInPlaceAndRemoveDeletes() throws {
    let config = makeConfig()
    let store = makeStore()
    store.save(config)
    // Same id → save() updates the existing record in place rather than
    // inserting a second one (a distinct id would now be deduped as a
    // same-endpoint duplicate).
    let updated = SSHConfig(id: config.id, name: "prod", host: config.host, user: config.user, port: config.port)
    store.save(updated)
    #expect(store.all.filter { $0.id == config.id }.count == 1)
    #expect(store.all.first { $0.id == config.id }?.name == "prod")

    store.remove(config.id)
    #expect(store.all.first { $0.id == config.id } == nil)
  }

  @Test @MainActor func reorderPersistsNewOrder() throws {
    let a = makeConfig(name: "alpha")
    let b = makeConfig(name: "bravo")
    let c = makeConfig(name: "charlie")
    let store = makeStore()
    store.save(a)
    store.save(b)
    store.save(c)
    let names = { store.all.filter { [a.id, b.id, c.id].contains($0.id) }.map(\.name) }
    #expect(names() == ["alpha", "bravo", "charlie"])

    store.reorder([c, a, b])
    #expect(names() == ["charlie", "alpha", "bravo"])

    // Fresh store over the same container: order survived.
    let rereader = makeStore()
    #expect(rereader.all.filter { [a.id, b.id, c.id].contains($0.id) }.map(\.name) == ["charlie", "alpha", "bravo"])
  }

  @Test @MainActor func importsLegacyUserDefaultsOnce() throws {
    let legacy = [makeConfig(name: "legacy-one"), makeConfig(name: "legacy-two")]
    let suiteName = "ssh-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.set(try JSONEncoder().encode(legacy), forKey: "sshConnections")
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = makeStore(defaults: defaults)
    let imported = store.all.filter { legacy.contains($0) }
    #expect(imported.map(\.name).sorted() == ["legacy-one", "legacy-two"])
    // The legacy key is removed only after a clean import.
    #expect(defaults.data(forKey: "sshConnections") == nil)
  }

  @Test @MainActor func prefersICloudKeyAndFallsBackToDevice() throws {
    let config = makeConfig()
    let store = makeStore()
    store.save(config)
    let records = try Self.sharedContainer.mainContext.fetch(FetchDescriptor<SSHConfigRecord>())
    #expect(records.first { $0.id == config.id }?.keyId == SSHConfigKey.icloud)

    // Sync key unavailable → device-keyed fallback (still usable here).
    let store2 = makeStore()
    store2.iCloudKeyProvider = { throw SSHConfigStoreError.unknownKeyID(SSHConfigKey.icloud) }
    let fallback = makeConfig(name: "fallback")
    store2.save(fallback)
    let records2 = try Self.sharedContainer.mainContext.fetch(FetchDescriptor<SSHConfigRecord>())
    #expect(records2.first { $0.id == fallback.id }?.keyId == SSHConfigKey.device)
    #expect(store2.all.contains { $0.id == fallback.id && $0.name == "fallback" })
  }

  @Test @MainActor func dedupsSameEndpointKeepsNewest() throws {
    // Two devices each saving the same connection produce distinct UUIDs but
    // the same endpoint (host + port). The most recently edited record must
    // win and the older one must be deleted so the dedup propagates back to
    // CloudKit (not just hidden for this list).
    let context = Self.sharedContainer.mainContext
    let oldCfg = SSHConfig(name: "old", host: "dup.example.com", user: "deploy", port: 2202)
    let newCfg = SSHConfig(name: "new", host: "dup.example.com", user: "deploy", port: 2202)
    let oldCipher = try SecureFileStore.seal(JSONEncoder().encode(oldCfg), using: Self.iCloudKey)
    let newCipher = try SecureFileStore.seal(JSONEncoder().encode(newCfg), using: Self.iCloudKey)
    context.insert(SSHConfigRecord(id: oldCfg.id, order: 0, keyId: SSHConfigKey.icloud, updatedAt: Date(timeIntervalSince1970: 100), payloadCipher: oldCipher))
    context.insert(SSHConfigRecord(id: newCfg.id, order: 1, keyId: SSHConfigKey.icloud, updatedAt: Date(timeIntervalSince1970: 200), payloadCipher: newCipher))
    try context.save()

    // A fresh store's reload dedups: only the newest record survives.
    let rereader = makeStore()
    #expect(rereader.all.filter { $0.id == oldCfg.id }.isEmpty)
    #expect(rereader.all.contains { $0.id == newCfg.id && $0.name == "new" })
    #expect(rereader.all.first { $0.id == newCfg.id }?.displayName == "new")
  }
}
