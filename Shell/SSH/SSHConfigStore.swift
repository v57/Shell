import Crypto
import Foundation
import Observation
import SwiftData
import Terminal

/// Persists the sidebar's saved SSH connections, synced through iCloud.
///
/// Every config is one `SSHConfigRecord` in a dedicated CloudKit-synced
/// store (`SSHConfigs`, private database of `iCloud.dev.v57.sh`). The store
/// is created unconditionally — with no iCloud account it behaves as a
/// plain local store and syncs silently when an account appears (verified:
/// a CloudKit-configured store loads fine without an account). No push or
/// background modes: changes arrive at launch/activation
/// (`refreshOnActivation`), exactly like notes.
///
/// The whole config travels as ONE AES-GCM ciphertext (name, host, user,
/// port, auth method, flags) — CloudKit never sees plaintext connection
/// data. Decryption is eager but bounded (a handful of configs; the notes
/// lazy pattern exists for unbounded note lists).
///
/// Saved PASSWORDS never sync — they stay in the device Keychain
/// (`SSHConfig.passwordAccount`), so a synced connection keeps its auth
/// method but needs the password entered once on each device.
@MainActor
@Observable
final class SSHConfigStore {
  /// Decrypted configs in sidebar order.
  private(set) var all: [SSHConfig] = []
  /// The most recent encryption/persistence failure.
  var storageError: String?

  private static let legacyDefaultsKey = "sshConnections"

  private let context: ModelContext
  private let defaults: UserDefaults

  // MARK: Test seam — hermetic keys (the real keychain needs an unlocked
  // screen / iCloud session; tests inject generated keys).
  var iCloudKeyProvider: () throws -> SymmetricKey = {
    try SSHConfigKey.key(for: SSHConfigKey.icloud)
  }
  var deviceKeyProvider: () throws -> SymmetricKey = {
    try SSHConfigKey.key(for: SSHConfigKey.device)
  }

  init(
    container: ModelContainer? = nil,
    defaults: UserDefaults = .standard,
    iCloudKeyProvider: (() throws -> SymmetricKey)? = nil,
    deviceKeyProvider: (() throws -> SymmetricKey)? = nil
  ) {
    // The CloudKit schema (all models) must be initialized before ANY
    // CloudKit-configured store opens. Idempotent; DEBUG-only.
    NoteStores.initializeCloudKitSchemaForDevelopment()
    let resolved: ModelContainer
    if let container {
      resolved = container
    } else if let made = try? SSHConfigStore.makeContainer() {
      resolved = made
    } else {
      // CloudKit setup failed — degrade to a plain local store rather
      // than crash. The plain SQLite store is effectively infallible.
      resolved = try! ModelContainer(
        for: SSHConfigRecord.self,
        configurations: ModelConfiguration("SSHConfigs", cloudKitDatabase: .none)
      )
    }
    context = resolved.mainContext
    self.defaults = defaults
    // Providers must be in place before the import + first reload run
    // (tests inject hermetic keys here so import stays off the real
    // keychain).
    if let iCloudKeyProvider { self.iCloudKeyProvider = iCloudKeyProvider }
    if let deviceKeyProvider { self.deviceKeyProvider = deviceKeyProvider }
    importLegacyIfNeeded()
    reload()
  }

  /// The synced store (works as a local-only store without an account).
  /// Holds the SSH-config, device-key, AND database-connection models: sharing
  /// one container keeps the process's SwiftData container count low — the
  /// hosted-runner instability (SIGTRAP inside SwiftData's fetch after several
  /// containers for the same model exist) is triggered by container CHURN, so
  /// the app deliberately uses as few containers as possible. The database
  /// connections live in this same container (via DatabaseConnectionStore)
  /// rather than in a second one.
  static func makeContainer() throws -> ModelContainer {
    try ModelContainer(
      for: SSHConfigRecord.self, DeviceKeyRecord.self, DatabaseConnectionRecord.self,
      configurations: ModelConfiguration(
        "SSHConfigs",
        cloudKitDatabase: .private("iCloud.dev.v57.sh")
      )
    )
  }

  /// Hermetic test container: plain SQLite in a temp directory. Uses a
  /// config name that never collides with the app's real "SSHConfigs"
  /// store (a CloudKit-mirroring store with the same config name in the
  /// same process traps SwiftData's predicate fetches — verified).
  static func makeTestContainer(in directory: URL) throws -> ModelContainer {
    try ModelContainer(
      for: SSHConfigRecord.self,
      configurations: ModelConfiguration(
        "SSHConfigsTests",
        url: directory.appendingPathComponent("ssh.store"),
        cloudKitDatabase: .none
      )
    )
  }

  // MARK: - Persistence API (same shape as the old UserDefaults store)

  func save(_ config: SSHConfig) {
    do {
      let (keyId, cipher) = try seal(config)
      if let record = fetch(config.id) {
        record.payloadCipher = cipher
        record.keyId = keyId
        record.updatedAt = Date()
      } else {
        context.insert(SSHConfigRecord(
          id: config.id,
          order: nextOrder(),
          keyId: keyId,
          updatedAt: Date(),
          payloadCipher: cipher
        ))
      }
      try context.save()
      storageError = nil
    } catch {
      storageError = error.localizedDescription
      NSLog("SSHConfigStore: could not save config: \(error)")
    }
    reload()
  }

  func remove(_ id: UUID) {
    if let record = fetch(id) {
      context.delete(record)
      try? context.save()
    }
    reload()
  }

  /// Replaces the whole list's order (drag-to-reorder). `updatedAt` is not
  /// bumped — reordering is not a content change.
  func reorder(_ list: [SSHConfig]) {
    for (index, config) in list.enumerated() {
      if let record = fetch(config.id) {
        record.order = index
      }
    }
    try? context.save()
    reload()
  }

  /// Re-fetches + re-decrypts — the no-push sync trigger (called when the
  /// scene becomes active, like notes).
  func refreshOnActivation() {
    reload()
  }

  // MARK: - Import from the legacy UserDefaults store

  /// One-time import of configs saved by the old UserDefaults store; the
  /// defaults key is removed only when everything imported cleanly.
  private func importLegacyIfNeeded() {
    guard let data = defaults.data(forKey: Self.legacyDefaultsKey) else { return }
    let legacy = (try? JSONDecoder().decode([SSHConfig].self, from: data)) ?? []
    var imported = 0
    for config in legacy where fetch(config.id) == nil {
      do {
        let (keyId, cipher) = try seal(config)
        context.insert(SSHConfigRecord(
          id: config.id,
          order: nextOrder(),
          keyId: keyId,
          updatedAt: Date(),
          payloadCipher: cipher
        ))
        imported += 1
      } catch {
        NSLog("SSHConfigStore: could not import \(config.displayName): \(error)")
      }
    }
    if imported == legacy.count {
      try? context.save()
      defaults.removeObject(forKey: Self.legacyDefaultsKey)
    }
  }

  // MARK: - Encryption

  /// Seals a config, preferring the iCloud Keychain sync key and falling
  /// back to the device-bound key when the sync key cannot be served.
  private func seal(_ config: SSHConfig) throws -> (keyId: String, cipher: Data) {
    let data = try JSONEncoder().encode(config)
    if let key = try? iCloudKeyProvider() {
      return (SSHConfigKey.icloud, try SecureFileStore.seal(data, using: key))
    }
    let key = try deviceKeyProvider()
    return (SSHConfigKey.device, try SecureFileStore.seal(data, using: key))
  }

  private func unseal(_ record: SSHConfigRecord) throws -> SSHConfig? {
    guard let payloadCipher = record.payloadCipher else { return nil }
    let key = try (record.keyId == SSHConfigKey.device ? deviceKeyProvider() : iCloudKeyProvider())
    let data = try SecureFileStore.open(payloadCipher, using: key)
    return try JSONDecoder().decode(SSHConfig.self, from: data)
  }

  // MARK: - Store access

  private func reload() {
    let records = (try? context.fetch(
      FetchDescriptor<SSHConfigRecord>(sortBy: [SortDescriptor(\.order)])
    )) ?? []
    // Dedup on reload: iCloud sync can deliver the same connection as two
    // separate records (one UUID per device, since each device generates a
    // fresh `SSHConfig.id`). The connection identity is the endpoint
    // (host + port) — the `user` field is NOT usable because it defaults to
    // each device's own `NSUserName()`, so two devices naming the same host
    // store different users. For each endpoint keep only the record with the
    // most recent `updatedAt` and delete the rest. This is convergent across
    // devices: every device runs the same "newest updatedAt wins" rule, so
    // the same survivor is chosen and the losers are removed everywhere (the
    // delete propagates through CloudKit).
    var winnerByKey: [String: (record: SSHConfigRecord, config: SSHConfig)] = [:]
    var losers: [SSHConfigRecord] = []
    for record in records {
      let config: SSHConfig
      do {
        guard let unsealed = try unseal(record) else { continue }
        config = unsealed
      } catch {
        // Undecryptable here (e.g. a device-keyed record synced from
        // another machine) — skip it rather than break the list.
        NSLog("SSHConfigStore: could not decrypt a config record: \(error)")
        continue
      }
      let key = duplicateKey(for: config)
      if let winner = winnerByKey[key] {
        if record.updatedAt > winner.record.updatedAt {
          losers.append(winner.record)
          winnerByKey[key] = (record, config)
        } else {
          losers.append(record)
        }
      } else {
        winnerByKey[key] = (record, config)
      }
    }
    // Drop the losing duplicates so the dedup holds (and propagates) rather
    // than merely hiding them for this list.
    if !losers.isEmpty {
      for loser in losers {
        context.delete(loser)
      }
      try? context.save()
    }
    // Emit the survivors in store order; a winner's record may be the one
    // from a later (winning) entry, so re-join against the winning configs.
    var configs: [SSHConfig] = []
    for record in records {
      if let winner = winnerByKey.values.first(where: { $0.record === record }) {
        configs.append(winner.config)
      }
    }
    all = configs
  }

  /// Identity of a connection for duplicate detection: the endpoint
  /// (lowercased host + port). `user`/`name` are excluded because they are
  /// device-local and can legitimately differ across synced devices.
  private func duplicateKey(for config: SSHConfig) -> String {
    "\(config.host.lowercased()):\(config.port)"
  }

  private func fetch(_ id: UUID) -> SSHConfigRecord? {
    // Plain fetch + Swift filter instead of a #Predicate. The predicate
    // form worked for notes, but this store is created unconditionally as a
    // CloudKit store and lives alongside the app's other containers in the
    // hosted test runner, where SwiftData's predicate machinery proved
    // unstable (SIGTRAP inside SwiftData during test runs). The list is
    // bounded, so filtering in Swift costs nothing.
    let records = (try? context.fetch(FetchDescriptor<SSHConfigRecord>())) ?? []
    return records.first { $0.id == id }
  }

  private func nextOrder() -> Int {
    let orders = (try? context.fetch(FetchDescriptor<SSHConfigRecord>()).map(\.order)) ?? []
    return (orders.max() ?? -1) + 1
  }
}

enum SSHConfigStoreError: LocalizedError {
  case unknownKeyID(String?)

  var errorDescription: String? {
    switch self {
    case .unknownKeyID(let keyId):
      return "The config's key identifier is unknown (\(keyId ?? "nil"))."
    }
  }
}
