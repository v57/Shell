import Foundation

/// Detects a Ruby/Bundler project (`Gemfile`) and exposes install / test /
/// run / lint smart actions. Active only when `bundle` (Bundler) is on PATH.
///
/// Thin: the marker/relevance and scan plumbing are delegated to the reusable
/// `ToolIntegrationBase` (this file supplies only the identity and the command
/// builder), per the framework's per-language REUSE RULE — no duplicated
/// marker/scan boilerplate. The run entry point is resolved from the shared
/// `[DirectoryEntry]` (never re-enumerating the directory), so no manifest
/// reader is needed; the run action appears only when a top-level `.rb`
/// entry point resolves.
public final class RubyIntegration: TerminalIntegration {
  private let base: ToolIntegrationBase

  public var id: String { base.id }
  public var displayName: String { base.displayName }
  /// Bundler is the binary every command below shells through (`bundle exec`),
  /// so availability gates on it; the live PATH probe resolves `bundle`.
  public var requiredTool: String? { base.requiredTool }
  /// Starts false; the coordinator overwrites from `EnvironmentProbe` at launch.
  public var isAvailable: Bool {
    get { base.isAvailable }
    set { base.isAvailable = newValue }
  }

  /// - Parameter isAvailable: Initial availability (overwritten by the coordinator).
  public init(isAvailable: Bool = false) {
    self.base = ToolIntegrationBase(
      id: "ruby",
      displayName: "Ruby",
      requiredTool: "bundle",
      markerNames: ["Gemfile"],
      isDirectory: false,
      isAvailable: isAvailable
    ) { _, files in
      RubyIntegration.buildActions(files: files)
    }
  }

  public func relevance(files: [DirectoryEntry]) -> Bool {
    base.relevance(files: files)
  }

  public func scan(directory: URL, files: [DirectoryEntry]) -> [IntegrationAction] {
    base.scan(directory: directory, files: files)
  }

  /// Builds the smart actions for a Ruby/Bundler directory: install
  /// (`bundle install`), test (`bundle exec rspec`), lint
  /// (`bundle exec rubocop`), and one run per resolved main entry point
  /// (`bundle exec ruby <main>`). The run action is emitted only when
  /// `resolveMainFile` finds a top-level `.rb` file.
  static func buildActions(files: [DirectoryEntry]) -> [IntegrationAction] {
    var actions: [IntegrationAction] = []
    actions.append(IntegrationAction(kind: .build, title: "Install", target: nil, command: "bundle install"))
    actions.append(IntegrationAction(kind: .test, title: "Test", target: nil, command: "bundle exec rspec"))
    actions.append(IntegrationAction(kind: .lint, title: "Lint", target: nil, command: "bundle exec rubocop"))

    if let main = resolveMainFile(from: files) {
      let name = String(main.dropLast(3)) // strip the ".rb" suffix
      actions.append(IntegrationAction(
        kind: .run,
        title: "Run · \(name)",
        target: name,
        command: "bundle exec ruby \(main)"
      ))
    }
    return actions
  }

  /// Resolves the run entry point among the shared top-level entries: the
  /// single non-directory `.rb` file, preferring conventional entry points
  /// (`main.rb`, `app.rb`, `server.rb`, `index.rb`) and falling back to the
  /// lexicographically-first `.rb` file. Returns nil when none resolves.
  static func resolveMainFile(from files: [DirectoryEntry]) -> String? {
    let candidates = files
      .filter { !$0.isDirectory && $0.name.hasSuffix(".rb") }
      .map(\.name)
    guard !candidates.isEmpty else { return nil }

    let preferred = ["main.rb", "app.rb", "server.rb", "index.rb"]
    for name in preferred where candidates.contains(name) {
      return name
    }
    return candidates.sorted().first
  }
}
