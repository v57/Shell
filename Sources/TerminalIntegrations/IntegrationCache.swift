import Foundation

/// Cached per-directory scan result, persisted by the app (encrypted at rest).
public struct IntegrationCacheEntry: Codable, Sendable, Equatable {
  /// File-list fingerprint this entry was generated from.
  public let fingerprint: String
  /// The smart actions computed for the directory.
  public let actions: [IntegrationAction]
  /// When the entry was (re)generated.
  public let generatedAt: Date

  public init(
    fingerprint: String,
    actions: [IntegrationAction],
    generatedAt: Date = Date()
  ) {
    self.fingerprint = fingerprint
    self.actions = actions
    self.generatedAt = generatedAt
  }
}

/// Persists per-directory scan results. The concrete implementation lives in
/// the app (reusing the Secure Enclave encrypted file store); the coordinator
/// depends only on this narrow protocol.
public protocol IntegrationCacheStore {
  /// The cached entry for a canonical directory path, or nil when absent.
  func entry(forDirectory directory: URL) -> IntegrationCacheEntry?
  /// Persist an entry for a directory.
  func save(_ entry: IntegrationCacheEntry, forDirectory directory: URL)
}
