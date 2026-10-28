import CryptoKit
import Foundation
import Observation
import ShellKit
import VaultKit

/// The sidebar's saved SSH connections: the hosts the v57 apps share through the vault (`../Vault`).
///
/// Each `SSHConfig` is a `VaultHost`, so Database tunnel through the same hosts, iCloud
/// syncs them (the app that changes one sends it, merged field by field with edits from other devices),
/// and the list updates live when another app or device changes it. Passwords are `VaultSecrets` items named
/// after the host (`SSHKeychain` maps `SSHConfig.passwordAccount` to them).
@MainActor
@Observable
final class SSHConfigStore {
  /// Configs in sidebar order.
  private(set) var all: [SSHConfig] = []
  /// The most recent persistence failure.
  var storageError: String?

  private static let legacyDefaultsKey = "sshConnections"

  @ObservationIgnored private let vault: Vault
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private var observer: VaultChangeObserver?

  init(vault: Vault = .shared, defaults: UserDefaults = .standard) {
    self.vault = vault
    self.defaults = defaults
    importLegacyIfNeeded()
    reload()
    observer = VaultChangeObserver { [weak self] in
      Task { @MainActor in self?.refreshOnActivation() }
    }
  }

  // MARK: - Persistence API

  func save(_ config: SSHConfig) {
    let id = config.vaultID
    var host =
      vault.hosts.first { $0.id == id } ?? VaultHost(id: id, hostname: config.host, order: nextOrder(), source: "shell")
    Self.copy(config, into: &host)
    vault.save(host)
    storageError = vault.error
    reload()
  }

  func remove(_ id: UUID) {
    let recordID = vaultID(for: id)
    vault.perform { try $0.delete(id: recordID) }
    reload()
  }

  /// Replaces the whole list's order (drag-to-reorder).
  func reorder(_ list: [SSHConfig]) {
    let hosts = vault.hosts
    vault.perform { store in
      for (index, config) in list.enumerated() {
        guard var host = hosts.first(where: { $0.id == config.vaultID }), host.order != index else { continue }
        host.order = index
        try store.save(host)
      }
    }
    reload()
  }

  /// How a host on one of the user's Hubs is reached: the Vault app keeps these hosts current from the Hub's device
  /// directory (overlay address, the host key the device signed, already trusted in `KnownHostsStore`). Nil for a
  /// host the user added.
  func hubRoute(for id: UUID) -> VaultHost.HubRoute? {
    let recordID = vaultID(for: id)
    return vault.hosts.first { $0.id == recordID }?.hub
  }

  /// The Hub's name for the device a saved connection reaches, nil for a host the user added.
  func hubDeviceName(for id: UUID) -> String? { hubRoute(for: id)?.deviceName }

  #if DEBUG
  /// The screenshot demo's Hub devices (`ScreenshotDemo`): a host with the route the Vault app would keep for it.
  func saveDemoHubDevice(_ config: SSHConfig) {
    save(config)
    guard var host = vault.hosts.first(where: { $0.id == config.vaultID }) else { return }
    host.hub = VaultHost.HubRoute(hubID: "demo", deviceID: config.name, deviceName: config.name, platform: "macos")
    vault.save(host)
    reload()
  }
  #endif

  /// Re-reads the shared hosts (another app or device changed them).
  func refreshOnActivation() {
    vault.reload()
    reload()
  }

  // MARK: - Mapping

  static func config(from host: VaultHost) -> SSHConfig {
    SSHConfig(
      id: UUID(uuidString: host.id) ?? stableUUID(host.id), name: host.name, host: host.hostname, user: host.user,
      port: host.port, authMethod: host.auth == .password ? .password : .keychainKey,
      savePassword: host.savePassword, recordID: UUID(uuidString: host.id)?.uuidString == host.id ? nil : host.id)
  }

  static func copy(_ config: SSHConfig, into host: inout VaultHost) {
    host.name = config.name
    host.hostname = config.host
    host.user = config.user
    host.port = config.port
    // A host that signs in with a key imported into Database keeps it; Shell uses this device's key.
    switch config.authMethod {
    case .password: host.auth = .password
    case .keychainKey: if host.auth != .importedKey { host.auth = .deviceKey }
    }
    host.savePassword = config.savePassword
  }

  private func reload() {
    // Not this Mac itself: the Hub lists it, and the host it published is for the other devices.
    let addresses = VaultDevice.addresses
    all = vault.hosts.filter { !vault.isThisDevice($0, addresses: addresses) }.map(Self.config(from:))
  }

  /// The shared record a listed config is: a Hub device's host has an id that isn't a UUID.
  private func vaultID(for id: UUID) -> String {
    all.first { $0.id == id }?.vaultID ?? id.uuidString
  }

  private func nextOrder() -> Int {
    (vault.hosts.map(\.order).max() ?? -1) + 1
  }

  /// One-time import of configs saved by the oldest builds (UserDefaults).
  private func importLegacyIfNeeded() {
    guard let data = defaults.data(forKey: Self.legacyDefaultsKey),
      let legacy = try? JSONDecoder().decode([SSHConfig].self, from: data)
    else { return }
    for config in legacy where !vault.hosts.contains(where: { $0.id == config.id.uuidString }) {
      save(config)
    }
    defaults.removeObject(forKey: Self.legacyDefaultsKey)
  }
}

/// A UUID for a shared record whose id isn't one (made by another app), the same on every launch.
func stableUUID(_ id: String) -> UUID {
  var bytes = Array(SHA256.hash(data: Data(id.utf8)).prefix(16))
  bytes[6] = (bytes[6] & 0x0F) | 0x50
  bytes[8] = (bytes[8] & 0x3F) | 0x80
  return UUID(uuid: (
    bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
    bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
}
