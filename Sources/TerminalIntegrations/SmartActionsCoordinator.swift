import Foundation

/// Orchestrates the smart-action pipeline for the active directory:
/// list files once → fingerprint → encrypted cache lookup (short-circuit) →
/// scan only relevant + available integrations → persist.
///
/// Not MainActor-bound: it is pure logic driven by the app (which calls it
/// from the main actor). `probeEnvironment()` is called once at startup.
public final class SmartActionsCoordinator {
  public let integrations: [any TerminalIntegration]
  private let cacheStore: any IntegrationCacheStore
  private let probe: () -> EnvironmentProbe

  public init(
    integrations: [any TerminalIntegration],
    cacheStore: any IntegrationCacheStore,
    probe: @escaping () -> EnvironmentProbe = EnvironmentProbe.probe
  ) {
    self.integrations = integrations
    self.cacheStore = cacheStore
    self.probe = probe
  }

  /// Probe installed toolchains ONCE and set each integration's availability.
  public func probeEnvironment() {
    let result = probe()
    for integration in integrations {
      switch integration.id {
      case "xcode": integration.isAvailable = result.xcodebuildAvailable
      case "swift": integration.isAvailable = result.swiftAvailable
      default: break
      }
    }
  }

  /// Probe (idempotent) then refresh — the app's startup entry point.
  @discardableResult
  public func probeAndRefresh(directory: URL) -> [IntegrationAction] {
    probeEnvironment()
    return refresh(directory: directory)
  }

  /// Returns the smart actions for `directory`, reading from the encrypted
  /// cache when the fingerprint is unchanged and scanning otherwise.
  public func refresh(directory: URL) -> [IntegrationAction] {
    let canonical = directory.standardizedFileURL
    let entries = IntegrationFileLister.list(directory: canonical)
    let fingerprint = IntegrationFingerprint.hash(entries: entries)

    if let cached = cacheStore.entry(forDirectory: canonical),
       cached.fingerprint == fingerprint {
      return cached.actions
    }

    var actions: [IntegrationAction] = []
    // Keep each action's integration index so the final list can be ordered
    // (kind first, integration as tiebreaker: Run/Build/Test, Xcode before
    // SwiftPM before other integrations).
    var tagged: [(integration: Int, action: IntegrationAction)] = []
    for (index, integration) in integrations.enumerated()
    where integration.isAvailable && integration.relevance(files: entries) {
      for action in integration.scan(directory: canonical, files: entries) {
        tagged.append((index, action))
      }
    }
    actions = tagged
      .sorted { lhs, rhs in
        if lhs.action.kind.toolbarOrder != rhs.action.kind.toolbarOrder {
          return lhs.action.kind.toolbarOrder < rhs.action.kind.toolbarOrder
        }
        return lhs.integration < rhs.integration
      }
      .map(\.action)

    cacheStore.save(
      IntegrationCacheEntry(fingerprint: fingerprint, actions: actions),
      forDirectory: canonical
    )
    return actions
  }
}
