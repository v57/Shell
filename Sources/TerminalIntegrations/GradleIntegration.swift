import Foundation

/// Detects a Gradle (JVM/Kotlin) project (`build.gradle` / `build.gradle.kts`)
/// and exposes build / test / run smart actions. Active only when `gradle`
/// is installed.
///
/// THIN: the marker/relevance and scan plumbing are delegated to the reusable
/// `ToolIntegrationBase` (this file supplies only the identity, the tool gate,
/// and the command builder), per the framework's per-language REUSE RULE. The
/// Gradle wrapper is honoured at the command level: when the directory carries
/// a top-level non-directory `gradlew`, actions run through `./gradlew`; they
/// fall back to `gradle` otherwise.
public final class GradleIntegration: TerminalIntegration {
  public var id: String { base.id }
  public var displayName: String { base.displayName }
  public var requiredTool: String? { base.requiredTool }
  /// Starts false; the coordinator overwrites from `EnvironmentProbe` at launch.
  public var isAvailable: Bool {
    get { base.isAvailable }
    set { base.isAvailable = newValue }
  }

  private let base: ToolIntegrationBase

  public init(isAvailable: Bool = false) {
    base = ToolIntegrationBase(
      id: "gradle",
      displayName: "Gradle",
      requiredTool: "gradle",
      markerNames: ["build.gradle", "build.gradle.kts"],
      isDirectory: false,
      isAvailable: isAvailable
    ) { _, files in
      GradleIntegration.buildActions(files: files)
    }
  }

  public func relevance(files: [DirectoryEntry]) -> Bool {
    base.relevance(files: files)
  }

  public func scan(directory: URL, files: [DirectoryEntry]) -> [IntegrationAction] {
    base.scan(directory: directory, files: files)
  }

  /// Picks the driver for the actions: `./gradlew` when the directory carries
  /// a top-level non-directory wrapper, else `gradle`.
  static func driver(files: [DirectoryEntry]) -> String {
    files.contains { $0.name == "gradlew" && !$0.isDirectory } ? "./gradlew" : "gradle"
  }

  /// Builds the smart actions for a Gradle directory:
  /// build (`<driver> build`), test (`<driver> test`), and run (`<driver> run`).
  static func buildActions(files: [DirectoryEntry]) -> [IntegrationAction] {
    let driver = driver(files: files)
    return [
      IntegrationAction(kind: .build, title: "Build", target: nil, command: "\(driver) build"),
      IntegrationAction(kind: .test, title: "Test", target: nil, command: "\(driver) test"),
      IntegrationAction(kind: .run, title: "Run", target: nil, command: "\(driver) run"),
    ]
  }
}
