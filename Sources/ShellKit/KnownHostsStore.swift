import Foundation
import VaultKit

/// Accepted SSH host keys (SHA256 fingerprints), the role of ~/.ssh/known_hosts, shared by the v57 apps
/// through the vault: a server trusted in Shell is trusted in Database, on every device. A connection that's a saved
/// host goes by the host's route (`VaultHost.pinRoute`), so a Hub's device has its own pin.
/// Keys accepted before the vault (in UserDefaults) move there when first looked up.
final class KnownHostsStore {
  private static let legacyKey = "knownHosts"
  private let defaults: UserDefaults
  private let store: VaultStore?

  init(defaults: UserDefaults = .standard, store: VaultStore? = VaultStore.shared) {
    self.defaults = defaults
    self.store = store
  }

  func fingerprint(for config: SSHConfig) -> String? {
    if let shared = shared(config) { return shared }
    let legacy = defaults.dictionary(forKey: Self.legacyKey) as? [String: String] ?? [:]
    guard let fingerprint = legacy["\(config.host):\(config.port)"] else { return nil }
    save(fingerprint: fingerprint, for: config)
    return fingerprint
  }

  func save(fingerprint: String, for config: SSHConfig) {
    guard let store else {
      var legacy = defaults.dictionary(forKey: Self.legacyKey) as? [String: String] ?? [:]
      legacy["\(config.host):\(config.port)"] = fingerprint
      defaults.set(legacy, forKey: Self.legacyKey)
      return
    }
    if let host = host(of: config) {
      try? store.trust(fingerprint: fingerprint, for: host)
    } else {
      try? store.trust(fingerprint: fingerprint, host: config.host, port: config.port)
    }
  }

  private func shared(_ config: SSHConfig) -> String? {
    guard let store else { return nil }
    if let host = host(of: config) { return (try? store.knownFingerprint(for: host)) ?? nil }
    return (try? store.knownFingerprint(host: config.host, port: config.port)) ?? nil
  }

  /// The saved host a connection is, at the address the connection names.
  private func host(of config: SSHConfig) -> VaultHost? {
    guard var host = try? store?.record(VaultHost.self, id: config.vaultID) else { return nil }
    host.hostname = config.host
    host.port = config.port
    return host
  }
}
