import Foundation
import VaultKit

/// Accepted SSH host keys (SHA256 fingerprints), the role of ~/.ssh/known_hosts, shared by the v57 apps
/// through the vault: a server trusted in Shell is trusted in Database, on every device.
/// Keys accepted before the vault (in UserDefaults) move there when first looked up.
final class KnownHostsStore {
  private static let legacyKey = "knownHosts"
  private let defaults: UserDefaults
  private let store: VaultStore?

  init(defaults: UserDefaults = .standard, store: VaultStore? = VaultStore.shared) {
    self.defaults = defaults
    self.store = store
  }

  func fingerprint(for host: String, port: Int) -> String? {
    if let shared = try? store?.knownFingerprint(host: host, port: port) { return shared }
    let legacy = defaults.dictionary(forKey: Self.legacyKey) as? [String: String] ?? [:]
    guard let fingerprint = legacy["\(host):\(port)"] else { return nil }
    save(fingerprint: fingerprint, host: host, port: port)
    return fingerprint
  }

  func save(fingerprint: String, host: String, port: Int) {
    guard let store else {
      var legacy = defaults.dictionary(forKey: Self.legacyKey) as? [String: String] ?? [:]
      legacy["\(host):\(port)"] = fingerprint
      defaults.set(legacy, forKey: Self.legacyKey)
      return
    }
    try? store.trust(fingerprint: fingerprint, host: host, port: port)
  }
}
