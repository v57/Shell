import CryptoKit
import Foundation
import ShellIntegrations

/// Encrypted per-directory storage for smart-action scan results, layered over
/// `SecureFileStore` (Secure Enclave AES-GCM). One ciphertext file per
/// directory; the filename is a SHA-256 of the canonical directory path so it
/// is filesystem-safe regardless of the path's characters. Keying on the
/// standardized URL matches the coordinator's cache keying.
struct SmartActionsStore: IntegrationCacheStore {
  private let baseDirectory: URL

  init(directory: URL? = nil) {
    let base = directory ?? FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Shell", isDirectory: true)
      .appendingPathComponent("SmartActions", isDirectory: true)
    self.baseDirectory = base
  }

  func entry(forDirectory directory: URL) -> IntegrationCacheEntry? {
    let url = fileURL(forDirectory: directory)
    guard let data = try? SecureFileStore.read(from: url, domain: .smartActions) else { return nil }
    return try? JSONDecoder().decode(IntegrationCacheEntry.self, from: data)
  }

  func save(_ entry: IntegrationCacheEntry, forDirectory directory: URL) {
    let url = fileURL(forDirectory: directory)
    guard let data = try? JSONEncoder().encode(entry) else { return }
    try? SecureFileStore.write(data, to: url, domain: .smartActions)
  }

  private func fileURL(forDirectory directory: URL) -> URL {
    let path = directory.standardizedFileURL.path
    let hash = SHA256.hash(data: Data(path.utf8))
      .map { String(format: "%02x", $0) }.joined()
    return baseDirectory.appendingPathComponent("\(hash).smart")
  }
}
