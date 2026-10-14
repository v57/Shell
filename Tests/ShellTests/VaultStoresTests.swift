import Foundation
import Testing
import ShellKit
import VaultKit
@testable import Shell

/// A vault in a temporary folder with in-memory keys: the stores run without the shared container, the
/// keychain or iCloud.
enum TestVault {
  @MainActor static func make() -> Vault {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("shell-vault-\(UUID().uuidString)", isDirectory: true)
    let store = try? VaultStore(directory: directory, keys: MemoryKeyProvider(), deviceID: "test", notifier: nil, owner: "test")
    return Vault(store: store)
  }
}

struct SSHConfigStoreTests {
  @Test @MainActor func savesUpdatesAndRemovesSharedHosts() {
    let vault = TestVault.make()
    let store = SSHConfigStore(vault: vault, defaults: UserDefaults(suiteName: UUID().uuidString)!)
    var config = SSHConfig(name: "prod", host: "prod.example.com", user: "deploy", port: 22)
    store.save(config)
    #expect(store.all.map(\.name) == ["prod"])
    // Another app's view of the same vault sees the host.
    #expect(vault.hosts.first?.hostname == "prod.example.com")
    #expect(vault.hosts.first?.auth == .deviceKey)

    config.port = 2222
    config.authMethod = .password
    store.save(config)
    #expect(store.all.count == 1)
    #expect(store.all.first?.port == 2222)
    #expect(vault.hosts.first?.auth == .password)

    store.remove(config.id)
    #expect(store.all.isEmpty)
  }

  @Test @MainActor func reorderKeepsTheNewOrder() {
    let store = SSHConfigStore(vault: TestVault.make(), defaults: UserDefaults(suiteName: UUID().uuidString)!)
    let a = SSHConfig(name: "a", host: "a")
    let b = SSHConfig(name: "b", host: "b")
    store.save(a)
    store.save(b)
    store.reorder([b, a])
    #expect(store.all.map(\.name) == ["b", "a"])
  }

  @Test @MainActor func importsLegacyUserDefaultsOnce() throws {
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    let legacy = [SSHConfig(name: "old", host: "old.example.com")]
    defaults.set(try JSONEncoder().encode(legacy), forKey: "sshConnections")
    let store = SSHConfigStore(vault: TestVault.make(), defaults: defaults)
    #expect(store.all.map(\.name) == ["old"])
    #expect(defaults.data(forKey: "sshConnections") == nil)
  }

  @Test @MainActor func keepsAKeyImportedInDatabasePro() {
    let vault = TestVault.make()
    vault.save(VaultHost(id: UUID().uuidString, name: "bastion", hostname: "b.example.com", auth: .importedKey, keyID: "k1"))
    let store = SSHConfigStore(vault: vault, defaults: UserDefaults(suiteName: UUID().uuidString)!)
    var config = try! #require(store.all.first)
    #expect(config.authMethod == .keychainKey)
    config.name = "Bastion"
    store.save(config)
    #expect(vault.hosts.first?.auth == .importedKey)
    #expect(vault.hosts.first?.keyID == "k1")
  }
}

struct DatabaseConnectionStoreTests {
  @Test @MainActor func savesSharedConnections() {
    let vault = TestVault.make()
    let store = DatabaseConnectionStore(vault: vault)
    var connection = DatabaseConnection(
      engine: .postgres, name: "shop", host: "db.local", port: 5432, database: "shop", username: "app")
    store.save(connection)
    #expect(vault.databases.first?.engine == VaultDatabase.Engine.postgres)
    #expect(vault.databases.first?.user == "app")
    connection.name = "Shop"
    store.save(connection)
    #expect(store.all.map(\.name) == ["Shop"])
    store.remove(connection.id)
    #expect(store.all.isEmpty)
    #expect(vault.databases.isEmpty)
  }

  @Test @MainActor func keepsFieldsShellDoesntShow() {
    let vault = TestVault.make()
    // Database Pro saved it with a replica set and a color.
    let id = UUID()
    vault.save(VaultDatabase(
      id: id.uuidString, name: "Atlas", engine: VaultDatabase.Engine.mongodb, host: "cluster.example.com", port: 27017,
      options: ["replicaSet": "rs0", "authSource": "admin"], color: "purple"))
    let store = DatabaseConnectionStore(vault: vault)
    var connection = try! #require(store.all.first)
    #expect(connection.authSource == "admin")
    connection.name = "Atlas (prod)"
    store.save(connection)
    let saved = try! #require(vault.databases.first)
    #expect(saved.options["replicaSet"] == "rs0")
    #expect(saved.color == "purple")
    #expect(saved.name == "Atlas (prod)")
  }

  @Test @MainActor func attachesToTheSSHHostItRunsOn() {
    let vault = TestVault.make()
    let hostID = UUID()
    vault.save(VaultHost(id: hostID.uuidString, name: "prod", hostname: "prod.example.com", user: "deploy"))
    let store = DatabaseConnectionStore(vault: vault)
    let connection = DatabaseConnection(engine: .redis, name: "cache", host: "prod.example.com", port: 6379)
    store.save(connection)
    #expect(store.all.first?.sshConfigID == hostID)
    #expect(store.all.first?.requiresTunnel == true)
    // Saving again keeps the attachment automatic (it follows the host list).
    store.save(try! #require(store.all.first))
    #expect(vault.databases.first?.sshHostID == nil)
  }

  @Test @MainActor func listsEveryEngineButDuckDB() {
    let vault = TestVault.make()
    vault.save(VaultDatabase(engine: VaultDatabase.Engine.duckdb, port: 0, filePath: "/tmp/a.duckdb"))
    vault.save(VaultDatabase(engine: VaultDatabase.Engine.cassandra, host: "c", port: 9042))
    let store = DatabaseConnectionStore(vault: vault)
    #expect(store.all.map(\.engine) == [.cassandra])
    #expect(!DatabaseEngine.allCases.map(\.rawValue).contains("duckdb"))
    #expect(DatabaseEngine.postgres.defaultPort == 5432)
    #expect(DatabaseEngine.mysql.displayName == "MySQL")
  }
}

struct NotesStoreTests {
  @Test @MainActor func newNotesAreEncryptedAndNamedAfterTheirTitle() throws {
    let vault = TestVault.make()
    let store = NotesStore(vault: vault)
    let note = store.addNote()
    #expect(note.isEncrypted)
    #expect(store.isEmptyNote(note.id))
    store.updateText("# Groceries\nmilk", for: note.id)
    #expect(store.title(for: note.id) == "Groceries")
    store.flush()
    let saved = try #require(try vault.store?.records(VaultNote.self).first)
    #expect(saved.name == "Groceries")
    #expect(saved.path == "Groceries.mdenc")
    #expect(saved.text == "# Groceries\nmilk")
  }

  @Test @MainActor func notesFromMarkdownAppearAndCanBeDecrypted() throws {
    let vault = TestVault.make()
    vault.save(VaultNote(folder: "Work", name: "Plan", encrypted: false, text: "Plan\nsteps"))
    let store = NotesStore(vault: vault)
    let note = try #require(store.notes.first)
    #expect(!note.isEncrypted)
    #expect(store.subtitle(for: note.id) == "steps")
    store.setEncrypted(true, for: note.id)
    #expect(try vault.store?.records(VaultNote.self).first?.path == "Work/Plan.mdenc")
    store.deleteNote(note.id)
    #expect(store.notes.isEmpty)
    #expect(try vault.store?.records(VaultNote.self).isEmpty == true)
  }

  @Test @MainActor func editedNotesMoveUpAndUnchangedTextIsNoEdit() throws {
    let vault = TestVault.make()
    vault.save(VaultNote(name: "old", text: "old"))
    vault.save(VaultNote(name: "new", text: "new"))
    let store = NotesStore(vault: vault)
    #expect(store.notes.map { store.title(for: $0.id) } == ["new", "old"])
    let old = try #require(store.notes.last)
    let before = old.lastUpdate
    store.updateText("old", for: old.id)
    #expect(store.notes.last?.lastUpdate == before)
    store.updateText("old, edited", for: old.id)
    #expect(store.notes.first?.id == old.id)
  }

  @Test @MainActor func untitledNotesGetFreeNames() throws {
    let vault = TestVault.make()
    vault.save(VaultNote(name: "Ideas", text: "Ideas"))
    let store = NotesStore(vault: vault)
    let note = store.addNote()
    store.updateText("Ideas\nmore", for: note.id)
    store.flush()
    let names = try vault.store?.records(VaultNote.self).map(\.name).sorted()
    #expect(names == ["Ideas", "Ideas 2"])
  }
}
