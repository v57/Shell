import Foundation

/// Detects a CMake (C/C++) project (`CMakeLists.txt`) and exposes build /
/// test / run smart actions. Active only when `cmake` is installed.
///
/// Thin: the marker/relevance and scan plumbing are delegated to the reusable
/// `ToolIntegrationBase` (this file supplies only the identity, the manifest
/// reader, and the command builder), per the framework's per-language REUSE
/// RULE. The manifest reader is injectable so tests don't need a real project
/// on disk (mirrors `CargoIntegration`'s injectable manifest reader, and
/// `XcodeIntegration`'s injectable build-list runner).
public final class CMakeIntegration: TerminalIntegration {
  /// Reads the `CMakeLists.txt` manifest text for a directory; nil when unreadable.
  public typealias ManifestReader = (URL) -> String?

  private let base: ToolIntegrationBase

  public var id: String { base.id }
  public var displayName: String { base.displayName }
  public var requiredTool: String? { base.requiredTool }
  /// Starts false; the coordinator overwrites from `EnvironmentProbe` at launch.
  public var isAvailable: Bool {
    get { base.isAvailable }
    set { base.isAvailable = newValue }
  }

  /// - Parameters:
  ///   - isAvailable: Initial availability (overwritten by the coordinator).
  ///   - readManifest: Reads `CMakeLists.txt`; injectable for headless tests.
  public init(
    isAvailable: Bool = false,
    readManifest: @escaping ManifestReader = CMakeIntegration.liveReadManifest
  ) {
    self.base = ToolIntegrationBase(
      id: "cmake",
      displayName: "C/C++",
      requiredTool: "cmake",
      markerNames: ["CMakeLists.txt"],
      isDirectory: false,
      isAvailable: isAvailable
    ) { directory, _ in
      CMakeIntegration.buildActions(directory: directory, readManifest: readManifest)
    }
  }

  public func relevance(files: [DirectoryEntry]) -> Bool {
    base.relevance(files: files)
  }

  public func scan(directory: URL, files: [DirectoryEntry]) -> [IntegrationAction] {
    base.scan(directory: directory, files: files)
  }

  /// Reads the `CMakeLists.txt` from disk. The live default for tests to override.
  public static func liveReadManifest(_ url: URL) -> String? {
    try? String(contentsOf: url, encoding: .utf8)
  }

  /// Builds the smart actions for a CMake directory:
  /// build (`cmake -B build && cmake --build build`), test
  /// (`ctest --test-dir build`), and one run per `add_executable` target
  /// (`cmake --build build && ./build/<target>`). The run action is emitted
  /// only when a buildable executable target is declared in `CMakeLists.txt`.
  static func buildActions(directory: URL, readManifest: ManifestReader) -> [IntegrationAction] {
    let manifestURL = directory.appendingPathComponent("CMakeLists.txt")
    guard let source = readManifest(manifestURL) else { return [] }

    var actions: [IntegrationAction] = []
    actions.append(IntegrationAction(kind: .build, title: "Build", target: nil, command: "cmake -B build && cmake --build build"))
    actions.append(IntegrationAction(kind: .test, title: "Test", target: nil, command: "ctest --test-dir build"))

    for name in parseExecutables(from: source) {
      actions.append(IntegrationAction(
        kind: .run,
        title: "Run · \(name)",
        target: name,
        command: "cmake --build build && ./build/\(name)"
      ))
    }
    return actions
  }

  /// Extracts each buildable executable target name defined by
  /// `add_executable(<name> ...)`. The `ALIAS` / `IMPORTED` marker forms
  /// (e.g. `add_executable(app ALIAS target)`, `add_executable(foo IMPORTED)`)
  /// describe a reference to a binary elsewhere, not a target that lands in
  /// `build` under `<name>`, so they are skipped. Repeated targets collapse to
  /// the first occurrence.
  static func parseExecutables(from source: String) -> [String] {
    guard let regex = try? NSRegularExpression(
      pattern: #"add_executable\s*\(\s*([A-Za-z0-9_.+-]+)(?:\s+(ALIAS|IMPORTED))?"#
    ) else { return [] }
    let range = NSRange(source.startIndex..<source.endIndex, in: source)
    var names: [String] = []
    for match in regex.matches(in: source, range: range) {
      guard let nameRange = Range(match.range(at: 1), in: source),
            match.range(at: 2).location == NSNotFound else { continue }
      let name = String(source[nameRange])
      if !names.contains(name) { names.append(name) }
    }
    return names
  }
}
