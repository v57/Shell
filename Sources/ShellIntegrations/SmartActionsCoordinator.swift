// The smart actions are Code's: its CodeActions library finds a folder's
// schemes and their commands. Shell adds none of its own.
@_exported import CodeActions
import Foundation

/// Finds the smart actions for the active directory: the schemes CodeActions
/// finds in the directory itself (not its subfolders), read from the
/// encrypted cache while the directory's fingerprint is unchanged.
///
/// Not MainActor-bound: it is pure logic driven by the app (which calls it
/// off the main actor: `xcodebuild -list` takes a while).
public final class SmartActionsCoordinator {
  private let cacheStore: any IntegrationCacheStore
  private let scan: (ProjectFolder) -> [ActionScheme]

  public init(
    cacheStore: any IntegrationCacheStore,
    scan: @escaping (ProjectFolder) -> [ActionScheme] = ProjectScanner.schemes(in:)
  ) {
    self.cacheStore = cacheStore
    self.scan = scan
  }

  /// Returns the schemes for `directory`, reading from the encrypted cache
  /// when the fingerprint is unchanged and scanning otherwise.
  public func refresh(directory: URL) -> [ActionScheme] {
    let canonical = directory.standardizedFileURL
    let folder = ProjectFolder(listing: canonical)
    let fingerprint = ProjectScanner.fingerprint(of: folder)
    if let cached = cacheStore.entry(forDirectory: canonical), cached.fingerprint == fingerprint {
      return cached.schemes
    }
    let schemes = scan(folder)
    cacheStore.save(IntegrationCacheEntry(fingerprint: fingerprint, schemes: schemes), forDirectory: canonical)
    return schemes
  }
}
