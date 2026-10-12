import Foundation

/// The kind of smart action a terminal integration can produce.
public enum IntegrationActionKind: String, Hashable, Sendable, Codable, CaseIterable {
  case build
  case run
  case test
  case distribute
  case lint

  /// Toolbar/display order: Run first, then Build, then Test, then
  /// Distribute, then Lint.
  public var toolbarOrder: Int {
    switch self {
    case .run: return 0
    case .build: return 1
    case .test: return 2
    case .distribute: return 3
    case .lint: return 4
    }
  }
}
