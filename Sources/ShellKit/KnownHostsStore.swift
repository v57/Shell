import Foundation

/// Stores accepted SSH host keys (as SHA256 fingerprints) in UserDefaults,
/// mirroring the role of ~/.ssh/known_hosts.
final class KnownHostsStore {
  private static let key = "knownHosts"
  private let defaults: UserDefaults
  
  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }
  
  private func storeKey(for host: String, port: Int) -> String {
    "\(host):\(port)"
  }
  
  func fingerprint(for host: String, port: Int) -> String? {
    let dict = defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
    return dict[storeKey(for: host, port: port)]
  }
  
  func save(fingerprint: String, host: String, port: Int) {
    var dict = defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
    dict[storeKey(for: host, port: port)] = fingerprint
    defaults.set(dict, forKey: Self.key)
  }
}
