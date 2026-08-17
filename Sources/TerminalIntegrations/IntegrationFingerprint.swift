import CryptoKit
import Foundation

/// A deterministic fingerprint of a directory's entry list.
///
/// Changing any entry's name or type (file↔directory) changes the fingerprint,
/// which invalidates the per-directory cache and triggers a re-scan. The hash
/// is order-independent (entries are sorted first) so a re-enumeration in a
/// different order yields the same fingerprint and hits the cache.
public enum IntegrationFingerprint {
  public static func hash(entries: [DirectoryEntry]) -> String {
    let sorted = entries
      .map { "\($0.isDirectory ? "d" : "f"):\($0.name)" }
      .sorted()
    let joined = sorted.joined(separator: "\n")
    let digest = SHA256.hash(data: Data(joined.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}
