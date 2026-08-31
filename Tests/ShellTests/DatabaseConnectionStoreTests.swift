import CryptoKit
import Foundation
import SwiftData
import Testing
import Terminal
@testable import Shell

/// Hermetic tests for the iCloud-synced database-connection store, mirroring
/// `SSHConfigStoreTests`: one shared temp SwiftData container + injected
/// generated keys (no real keychain). `.serialized` because Swift Testing
/// doesn't guarantee @MainActor tests run one at a time against shared state.
@Suite(.serialized)
struct DatabaseConnectionStoreTests {
  private static let directory: URL = {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("db-suite-\(UUID().uuidString)", isDirectory: true)
  }()
  private static let sharedContainer: ModelContainer = {
    // swiftlint:disable:next force_try
    try! DatabaseConnectionStore.makeTestContainer(in: directory)
  }()
  private static let iCloudKey = SymmetricKey(size: .bits256)
  private static let deviceKey = SymmetricKey(size: .bits256)

  private func makeStore() -> DatabaseConnectionStore {
    DatabaseConnectionStore(
      container: Self.sharedContainer,
      iCloudKeyProvider: { Self.iCloudKey },
      deviceKeyProvider: { Self.deviceKey }
    )
  }

  private func makeConnection(name: String = "local-dev") -> DatabaseConnection {
    DatabaseConnection(
      engine: .mongodb,
      name: name,
      host: "127.0.0.1",
      port: 27017,
      database: "app",
      username: "admin"
    )
  }

  @Test @MainActor func savePersistsAndEncryptsAcrossInstances() throws {
    let connection = makeConnection()
    let store = makeStore()
    store.save(connection)
    #expect(store.all.first { $0.id == connection.id } == connection)
    #expect(store.storageError == nil)
    #expect(store.all.first { $0.id == connection.id }?.displayName == "local-dev")

    // Fresh store over the same container: the record survives and no
    // plaintext is stored anywhere in it.
    let rereader = makeStore()
    #expect(rereader.all.first { $0.id == connection.id } == connection)

    let records = try Self.sharedContainer.mainContext.fetch(FetchDescriptor<DatabaseConnectionRecord>())
    let record = try #require(records.first { $0.id == connection.id })
    let cipher = try #require(record.payloadCipher)
    #expect(!cipher.contains(Data("127.0.0.1".utf8)))
    #expect(!cipher.contains(Data("admin".utf8)))
    #expect(record.engine == DatabaseEngine.mongodb.rawValue)
    #expect(record.keyId == SSHConfigKey.icloud)
  }

  @Test @MainActor func saveDoesNotPersistPasswordInRecord() throws {
    let connection = makeConnection()
    let store = makeStore()
    // Password supplied as a credential; it must reach the Keychain, never the
    // ciphertext. Keychain may be unavailable in the hermetic runner, so we
    // only assert the record itself carries no password material.
    store.save(connection, password: "s3cret")

    let records = try Self.sharedContainer.mainContext.fetch(FetchDescriptor<DatabaseConnectionRecord>())
    let record = try #require(records.first { $0.id == connection.id })
    let cipher = try #require(record.payloadCipher)
    #expect(!cipher.contains(Data("s3cret".utf8)))
    // The in-memory value never carries a password field either.
    #expect(store.all.first { $0.id == connection.id } == connection)
  }

  @Test @MainActor func saveUpdatesInPlaceAndRemoveDeletes() throws {
    let connection = makeConnection()
    let store = makeStore()
    store.save(connection)
    // Same id → save() updates the existing record in place rather than
    // inserting a second one (a distinct id would be a separate row).
    let updated = DatabaseConnection(
      id: connection.id, engine: connection.engine, name: "edited",
      host: connection.host, port: connection.port)
    store.save(updated)
    #expect(store.all.filter { $0.id == connection.id }.count == 1)
    #expect(store.all.first { $0.id == connection.id }?.name == "edited")

    store.remove(connection.id)
    #expect(store.all.first { $0.id == connection.id } == nil)
  }

  @Test @MainActor func reorderPersistsNewOrder() throws {
    let a = makeConnection(name: "alpha")
    let b = makeConnection(name: "bravo")
    let c = makeConnection(name: "charlie")
    let store = makeStore()
    store.save(a)
    store.save(b)
    store.save(c)
    let names = { store.all.filter { [a.id, b.id, c.id].contains($0.id) }.map { $0.name } }
    #expect(names() == ["alpha", "bravo", "charlie"])

    store.reorder([c, a, b])
    #expect(names() == ["charlie", "alpha", "bravo"])

    let rereader = makeStore()
    #expect(rereader.all.filter { [a.id, b.id, c.id].contains($0.id) }.map { $0.name } == ["charlie", "alpha", "bravo"])
  }

  @Test @MainActor func prefersICloudKeyAndFallsBackToDevice() throws {
    let connection = makeConnection()
    let store = makeStore()
    store.save(connection)
    let records = try Self.sharedContainer.mainContext.fetch(FetchDescriptor<DatabaseConnectionRecord>())
    #expect(records.first { $0.id == connection.id }?.keyId == SSHConfigKey.icloud)

    let store2 = makeStore()
    store2.iCloudKeyProvider = { throw SSHConfigStoreError.unknownKeyID(SSHConfigKey.icloud) }
    let fallback = makeConnection(name: "fallback")
    store2.save(fallback)
    let records2 = try Self.sharedContainer.mainContext.fetch(FetchDescriptor<DatabaseConnectionRecord>())
    #expect(records2.first { $0.id == fallback.id }?.keyId == SSHConfigKey.device)
    #expect(store2.all.contains { $0.id == fallback.id && $0.name == "fallback" })
  }

  @Test @MainActor func renderHelpersAndEngineAvailability() {
    #expect(DatabaseEngine.mongodb.displayName == "MongoDB")
    #expect(DatabaseEngine.postgresql.defaultPort == 5432)
    #expect(DatabaseEngine.redis.systemImage == "bolt.horizontal.fill")
    #expect(DatabaseEngine.sqlite.displayName == "SQLite")
    #expect(DatabaseEngine.allCases.count == 4)
    // Unavailable engines still model as valid; only the session refuses to
    // connect when the module is not linked on this platform.
    let sqlite = DatabaseConnection(engine: .sqlite, name: "local", host: "/tmp/x.db")
    #expect(sqlite.isValid)
    #expect(sqlite.engine == .sqlite)
    let mongo = DatabaseConnection(engine: .mongodb, name: "m", host: "h", port: 27017)
    #expect(mongo.isValid)
  }
}
