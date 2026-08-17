import Foundation

/// The kind of smart action a terminal integration can produce.
public enum IntegrationActionKind: String, Hashable, Sendable, Codable, CaseIterable {
  case build
  case run
  case test
}
