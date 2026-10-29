import Foundation
import Observation
import ShellKit
import VaultKit

/// A public key in the registry: a device's (published by the v57 apps on it) or one added by hand.
struct DeviceKeyRecord: Identifiable, Hashable {
  var id: String
  /// SHA256 fingerprint of the key.
  var fingerprint: String?
  /// The full OpenSSH authorized_keys line (type, base64, comment).
  var keyLine: String?
  /// The device's name, or the name given to a key added by hand.
  var deviceName: String?
  var updatedAt: Date
  /// Whether a device published it (rather than someone adding it by hand).
  var isDeviceKey: Bool
}

/// The registry of public SSH keys: every device's key (the Secure Enclave key the v57 apps on it share,
/// `VaultIdentity`) and keys added by hand, shared through the vault (`../Vault`) so each device can add
/// the others' keys to a server's `authorized_keys`. Public keys are public; they're encrypted anyway, like
/// everything in the vault.
@MainActor
@Observable
final class DeviceKeyStore {
  /// Every key, newest first.
  private(set) var all: [DeviceKeyRecord] = []
  /// The most recent publish/read failure (nil when fine).
  var storageError: String?

  @ObservationIgnored private let vault: Vault
  @ObservationIgnored private var observer: VaultChangeObserver?
  private static let customPlatform = "custom"

  init(vault: Vault = .shared) {
    self.vault = vault
    reload()
    observer = VaultChangeObserver { [weak self] in
      Task { @MainActor in self?.refreshOnActivation() }
    }
  }

  // MARK: - Publishing

  /// Publishes this device's key (made on first use). Writes only when something changed, so it runs at
  /// every launch. Fails when the Secure Enclave key isn't reachable (locked screen); retried on panel open.
  @discardableResult
  func publishThisDevice() -> Bool {
    guard let store = vault.store else { return false }
    do {
      // Shell's key from before the vault becomes the shared one (`SSHKeychain`).
      _ = try SSHKeychain.loadOrCreateDefaultKey()
      try store.publishDeviceKey()
      storageError = nil
      refreshOnActivation()
      return true
    } catch {
      storageError = error.localizedDescription
      return false
    }
  }

  // MARK: - Custom keys

  /// Saves a public key added by hand (another machine's or a hardware key's), so every device can add it to
  /// its servers. `name` falls back to the line's comment.
  @discardableResult
  func addCustomKey(line: String, name: String?) throws -> DeviceKeyRecord {
    let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard AuthorizedKeysManager.isPlainKeyLine(line),
      let fingerprint = SSHKeychain.publicKeyFingerprint(forKeyLine: line), let store = vault.store
    else {
      throw AuthorizedKeysError.invalidKeyLine
    }
    if let existing = all.first(where: { $0.fingerprint == fingerprint }), existing.isDeviceKey {
      return existing
    }
    let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let displayName = trimmedName.isEmpty ? (Self.comment(of: line) ?? fingerprint) : trimmedName
    let id = try store.derivedID("customKey|" + fingerprint)
    try store.save(VaultDeviceKey(id: id, deviceName: displayName, publicKey: line, platform: Self.customPlatform))
    refreshOnActivation()
    return all.first { $0.id == id } ?? DeviceKeyRecord(
      id: id, fingerprint: fingerprint, keyLine: line, deviceName: displayName, updatedAt: .now, isDeviceKey: false)
  }

  /// Removes a key from the registry. Servers that already have it keep it. A device still in use publishes
  /// itself again on its next launch.
  func forget(fingerprint: String) throws {
    for record in all where record.fingerprint == fingerprint {
      try vault.store?.delete(id: record.id)
    }
    refreshOnActivation()
  }

  /// The comment of a key line (everything after the base64), if any.
  static func comment(of line: String) -> String? {
    let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
    guard fields.count == 3 else { return nil }
    let comment = fields[2].trimmingCharacters(in: .whitespaces)
    return comment.isEmpty ? nil : comment
  }

  /// Re-reads the registry (another app or device changed it).
  func refreshOnActivation() {
    vault.reload()
    reload()
  }

  private func reload() {
    all = vault.deviceKeys
      .map { key in
        DeviceKeyRecord(
          id: key.id, fingerprint: key.fingerprint, keyLine: key.publicKey, deviceName: key.deviceName,
          updatedAt: key.updated ?? .distantPast, isDeviceKey: key.platform != Self.customPlatform)
      }
      .sorted { $0.updatedAt > $1.updatedAt }
  }
}
