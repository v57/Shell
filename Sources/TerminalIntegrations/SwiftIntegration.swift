import Foundation

/// Detects a Swift Package Manager project (`Package.swift`) and exposes
/// build / run / test smart actions. Active only when `swift` is installed.
public final class SwiftIntegration: TerminalIntegration {
  public let id = "swift"
  public let displayName = "Swift Package"
  /// Gate: availability requires `swift` on PATH.
  public let requiredTool: String? = "swift"
  public var isAvailable: Bool

  public init(isAvailable: Bool) {
    self.isAvailable = isAvailable
  }

  public func relevance(files: [DirectoryEntry]) -> Bool {
    files.contains { $0.name == Self.packageFileName && !$0.isDirectory }
  }

  private static let packageFileName = "Package.swift"
  /// Matches `.executableTarget(name: "X")`, `.target(name: "X")`,
  /// `.library(name: "X", ...)`. Group 1 = kind, group 2 = target name.
  private static let targetPattern =
    #"\.(executableTarget|target|library)\s*\(\s*name:\s*"([^"]+)""#

  public func scan(directory: URL, files: [DirectoryEntry]) -> [IntegrationAction] {
    guard relevance(files: files) else { return [] }
    let packageURL = directory.appendingPathComponent(Self.packageFileName)
    guard let source = try? String(contentsOf: packageURL, encoding: .utf8) else { return [] }

    let executables = extractTargets(from: source, kinds: ["executableTarget"])

    var actions: [IntegrationAction] = []
    actions.append(IntegrationAction(kind: .build, title: "Build", target: nil, command: "swift build"))
    actions.append(IntegrationAction(kind: .test, title: "Test", target: nil, command: "swift test"))
    for name in executables {
      actions.append(IntegrationAction(
        kind: .run,
        title: "Run · \(name)",
        target: name,
        command: "swift run \(name)"
      ))
    }
    return actions
  }

  private func extractTargets(from source: String, kinds: [String]) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: Self.targetPattern) else { return [] }
    let range = NSRange(source.startIndex..<source.endIndex, in: source)
    var targets: [String] = []
    for match in regex.matches(in: source, range: range) {
      guard let kindRange = Range(match.range(at: 1), in: source),
            let nameRange = Range(match.range(at: 2), in: source) else { continue }
      let kind = String(source[kindRange])
      if kinds.contains(kind) {
        let name = String(source[nameRange])
        if !targets.contains(name) { targets.append(name) }
      }
    }
    return targets
  }
}
