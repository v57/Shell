import CryptoKit
import Foundation
import Observation
import SwiftData
import ShellKit
#if os(iOS)
import UIKit
#endif

/// The iCloud-synced registry of per-device public keys.
///
/// Every device publishes its Secure Enclave identity key's public line on
/// launch (and when the authorized-keys panel opens). Other devices read
/// the registry to grant that key access to their servers. Plaintext by
/// design — public keys are meant to be shared.
///
/// Same storage pattern as `SSHConfigStore`: a dedicated CloudKit store
/// (`DeviceKeys`, private database of `iCloud.dev.v57.sh`), created
/// unconditionally (loads as a local store without an account, syncs when
/// one appears), no push — changes arrive at launch/activation.
@MainActor
@Observable
final class DeviceKeyStore {
  /// All published device keys, newest first.
  private(set) var all: [DeviceKeyRecord] = []
  /// The most recent publish/read failure (nil when fine).
  var storageError: String?

  private let context: ModelContext

  // MARK: Test seam — the device key normally comes from the Secure
  // Enclave keychain; tests inject a generator.
  var defaultKeyProvider: () throws -> SecureEnclave.P256.Signing.PrivateKey = {
    try SSHKeychain.loadOrCreateDefaultKey()
  }
  /// The device's display name (comment in the published key line).
  var deviceNameProvider: () -> String = {
    #if os(macOS)
    Host.current().localizedName ?? "Mac"
    #else
    UIDevice.current.name
    #endif
  }

  init(
    container: ModelContainer? = nil,
    defaultKeyProvider: (() throws -> SecureEnclave.P256.Signing.PrivateKey)? = nil
  ) {
    // The CloudKit schema (all models) must be initialized before ANY
    // CloudKit-configured store opens. Idempotent; DEBUG-only.
    NoteStores.initializeCloudKitSchemaForDevelopment()
    let resolved: ModelContainer
    if let container {
      resolved = container
    } else if let made = try? DeviceKeyStore.makeContainer() {
      resolved = made
    } else {
      // CloudKit setup failed — degrade to a plain local store rather
      // than crash.
      resolved = try! ModelContainer(
        for: DeviceKeyRecord.self,
        configurations: ModelConfiguration("DeviceKeys", cloudKitDatabase: .none)
      )
    }
    context = resolved.mainContext
    if let defaultKeyProvider { self.defaultKeyProvider = defaultKeyProvider }
    reload()
  }

  /// The synced store (works as a local-only store without an account).
  /// Shares SSHConfigStore's container — one store for both models keeps
  /// the process's SwiftData container count low (see SSHConfigStore).
  static func makeContainer() throws -> ModelContainer {
    try SSHConfigStore.makeContainer()
  }

  /// Hermetic test container: plain SQLite in a temp directory. Unique
  /// config name so it never collides with the app's real store.
  static func makeTestContainer(in directory: URL) throws -> ModelContainer {
    try ModelContainer(
      for: DeviceKeyRecord.self,
      configurations: ModelConfiguration(
        "DeviceKeysTests",
        url: directory.appendingPathComponent("device-keys.store"),
        cloudKitDatabase: .none
      )
    )
  }

  // MARK: - Publishing

  /// Publishes this device's identity key: upserts one record keyed by
  /// fingerprint (the key material IS the device identity), leaving other
  /// devices' records untouched. Fails silently when the Secure Enclave
  /// key isn't reachable (locked screen) — retried on panel open.
  @discardableResult
  func publishThisDevice() -> Bool {
    do {
      let key = try defaultKeyProvider()
      let fingerprint = SSHKeychain.publicKeyFingerprint(for: key)
      let comment = "Shell (\(NSUserName())@\(deviceNameProvider()))"
      let line = SSHKeychain.publicKeyOpenSSHLine(for: key, comment: comment)
      if let record = fetch(byFingerprint: fingerprint) {
        record.keyLine = line
        record.deviceName = deviceNameProvider()
        record.updatedAt = Date()
      } else {
        context.insert(DeviceKeyRecord(
          fingerprint: fingerprint,
          keyLine: line,
          deviceName: deviceNameProvider(),
          updatedAt: Date()
        ))
      }
      try context.save()
      storageError = nil
      reload()
      return true
    } catch {
      storageError = error.localizedDescription
      NSLog("DeviceKeyStore: could not publish this device's key: \(error)")
      return false
    }
  }

  // MARK: - Custom keys

  /// Saves a public key added by hand (another machine's or a hardware
  /// key's), so every device can add it to its servers. Upserts by
  /// fingerprint like device keys; `name` falls back to the line's comment.
  @discardableResult
  func addCustomKey(line: String, name: String?) throws -> DeviceKeyRecord {
    let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard AuthorizedKeysManager.isPlainKeyLine(line),
          let fingerprint = SSHKeychain.publicKeyFingerprint(forKeyLine: line) else {
      throw AuthorizedKeysError.invalidKeyLine
    }
    let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let displayName = trimmedName.isEmpty ? Self.comment(of: line) : trimmedName
    let record: DeviceKeyRecord
    if let existing = fetch(byFingerprint: fingerprint) {
      record = existing
      // Re-adding a device's own key by hand keeps its device line.
      if !existing.isDeviceKey { existing.keyLine = line }
      if let displayName { existing.deviceName = displayName }
      existing.updatedAt = Date()
    } else {
      record = DeviceKeyRecord(fingerprint: fingerprint, keyLine: line, deviceName: displayName, updatedAt: Date())
      context.insert(record)
    }
    try context.save()
    storageError = nil
    reload()
    return record
  }

  /// Removes a key from the registry (every record with that fingerprint).
  /// Servers that already have it keep it. A device that is still in use
  /// publishes itself again on its next launch.
  func forget(fingerprint: String) throws {
    let records = (try? context.fetch(FetchDescriptor<DeviceKeyRecord>())) ?? []
    records.filter { $0.fingerprint == fingerprint }.forEach(context.delete)
    try context.save()
    reload()
  }

  /// The comment of a key line (everything after the base64), if any.
  static func comment(of line: String) -> String? {
    let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
    guard fields.count == 3 else { return nil }
    let comment = fields[2].trimmingCharacters(in: .whitespaces)
    return comment.isEmpty ? nil : comment
  }

  /// Re-fetches — the no-push sync trigger (scene activation).
  func refreshOnActivation() {
    reload()
  }

  // MARK: - Store access

  private func reload() {
    let records = (try? context.fetch(
      FetchDescriptor<DeviceKeyRecord>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
    )) ?? []
    all = removingDuplicates(records)
  }

  /// Collapses records that share a fingerprint into one, deleting the rest.
  ///
  /// CloudKit can't enforce uniqueness: a device that publishes before its
  /// earlier record has synced down (a reinstall, a reset store, two devices
  /// publishing at once) inserts a second record for the same key. Every
  /// device keeps the same survivor — the newest `updatedAt`, then the
  /// highest `id` — so concurrent clean-ups never delete each other's pick.
  private func removingDuplicates(_ records: [DeviceKeyRecord]) -> [DeviceKeyRecord] {
    let groups = Dictionary(grouping: records.filter { $0.fingerprint != nil }) { $0.fingerprint! }
    var duplicates: [DeviceKeyRecord] = []
    for group in groups.values where group.count > 1 {
      let survivor = group.max { lhs, rhs in
        (lhs.updatedAt, lhs.id.uuidString) < (rhs.updatedAt, rhs.id.uuidString)
      }!
      duplicates += group.filter { $0 !== survivor }
    }
    guard !duplicates.isEmpty else { return records }
    duplicates.forEach(context.delete)
    do {
      try context.save()
    } catch {
      storageError = error.localizedDescription
      NSLog("DeviceKeyStore: could not remove duplicate keys: \(error)")
    }
    let removed = Set(duplicates.map(ObjectIdentifier.init))
    return records.filter { !removed.contains(ObjectIdentifier($0)) }
  }

  private func fetch(byFingerprint fingerprint: String) -> DeviceKeyRecord? {
    // Plain fetch + Swift filter (see SSHConfigStore.fetch — bounded list,
    // avoids SwiftData's predicate machinery in the hosted runner).
    let records = (try? context.fetch(FetchDescriptor<DeviceKeyRecord>())) ?? []
    return records.first { $0.fingerprint == fingerprint }
  }
}
