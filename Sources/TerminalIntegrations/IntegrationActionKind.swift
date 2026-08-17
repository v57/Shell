import Foundation

/// The kind of smart action a terminal integration can produce.
public enum IntegrationActionKind: String, Hashable, Sendable, Codable, CaseIterable {
  case build
  case run
  case test

  /// Toolbar/display order: Run first, then Build, then Test.
  public var toolbarOrder: Int {
    switch self {
    case .run: return 0
    case .build: return 1
    case .test: return 2
    }
  }
}
