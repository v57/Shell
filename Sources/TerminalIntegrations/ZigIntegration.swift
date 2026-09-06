import Foundation

/// Detects a Zig project (`build.zig` / `build.zig.zon`) and exposes build /
/// test / run smart actions. Active only when `zig` is installed.
///
/// Thin: the marker/relevance and scan plumbing are delegated to the reusable
/// `ToolIntegrationBase` (this file supplies only the identity, the run-entry
/// resolver, and the command builder), per the framework's per-language REUSE
/// RULE. The run-entry resolver is injectable so tests don't need a real
/// project on disk (mirrors `SwiftIntegration`'s available-gate and
/// `XcodeIntegration`'s injectable build-list runner).
public final class ZigIntegration: TerminalIntegration {
  /// Resolves the run entry point relative to a Zig project directory; nil
  /// when none can be found. Injectable so headless tests don't need a real
  /// `src/main.zig` on disk.
  public typealias MainFileResolver = (URL) -> String?

  private let base: ToolIntegrationBase

  public var id: String { base.id }
  public var displayName: String { base.displayName }
  /// Gate: availability requires `zig` on PATH.
  public var requiredTool: String? { base.requiredTool }
  /// Starts false; the coordinator overwrites from `EnvironmentProbe` at launch.
  public var isAvailable: Bool {
    get { base.isAvailable }
    set { base.isAvailable = newValue }
  }

  /// - Parameters:
  ///   - isAvailable: Initial availability (overwritten by the coordinator).
  ///   - resolveMainFile: Resolves the `main.zig` run entry point for a
  ///     directory; injectable for headless tests.
  public init(
    isAvailable: Bool = false,
    resolveMainFile: @escaping MainFileResolver = ZigIntegration.liveResolveMainFile
  ) {
    self.base = ToolIntegrationBase(
      id: "zig",
      displayName: "Zig",
      requiredTool: "zig",
      markerNames: ["build.zig.zon", "build.zig"],
      isDirectory: false,
      isAvailable: isAvailable
    ) { directory, _ in
      ZigIntegration.buildActions(directory: directory, resolveMainFile: resolveMainFile)
    }
  }

  public func relevance(files: [DirectoryEntry]) -> Bool {
    base.relevance(files: files)
  }

  public func scan(directory: URL, files: [DirectoryEntry]) -> [IntegrationAction] {
    base.scan(directory: directory, files: files)
  }

  /// Live default: resolves the run entry point on disk, preferring the
  /// conventional `src/main.zig` layout, then a top-level `main.zig`. Returns
  /// the path relative to the directory (usable directly as `zig run <path>`),
  /// or nil when neither resolves.
  public static func liveResolveMainFile(_ directory: URL) -> String? {
    let candidates = ["src/main.zig", "main.zig"]
    for relative in candidates {
      let fileURL = directory.appendingPathComponent(relative)
      var isDirectory: ObjCBool = false
      if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
         !isDirectory.boolValue {
        return relative
      }
    }
    return nil
  }

  /// Builds the smart actions for a Zig directory: build (`zig build`), test
  /// (`zig build test`), and run (`zig run <main>`). The run action is emitted
  /// only when `resolveMainFile` resolves a main entry point.
  static func buildActions(directory: URL, resolveMainFile: MainFileResolver) -> [IntegrationAction] {
    var actions: [IntegrationAction] = []
    actions.append(IntegrationAction(kind: .build, title: "Build", target: nil, command: "zig build"))
    actions.append(IntegrationAction(kind: .test, title: "Test", target: nil, command: "zig build test"))

    if let main = resolveMainFile(directory) {
      let name = URL(fileURLWithPath: main).deletingPathExtension().lastPathComponent
      actions.append(IntegrationAction(
        kind: .run,
        title: "Run · \(name)",
        target: name,
        command: "zig run \(main)"
      ))
    }
    return actions
  }
}
