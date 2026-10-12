import Foundation

/// The result of probing which toolchain binaries are available on PATH.
///
/// Previously this probe spawned `xcrun -f <tool>` subprocesses, which is
/// macOS-only and only knows about the Apple toolchain. It now resolves the
/// same question with a generic PATH lookup (`FileManager.isExecutableFile`
/// at each PATH entry) over a FIXED tool set — including cross-language
/// toolchains (cargo, bun, npm, go, make, python3, cmake, docker, dotnet,
/// dart, ruby, mix, php, composer, zig, ...) — so any `TerminalIntegration`
/// can gate on a required tool without Apple-specific plumbing.
public struct EnvironmentProbe: Sendable, Equatable {
  /// The set of tool names that resolved to an executable on PATH.
  public let availableTools: Set<String>

  /// Whether `xcodebuild` is on PATH.
  public var xcodebuildAvailable: Bool { availableTools.contains("xcodebuild") }
  /// Whether `swift` is on PATH.
  public var swiftAvailable: Bool { availableTools.contains("swift") }

  /// Builds a probe from an explicit tool set. The primary init.
  public init(availableTools: Set<String>) {
    self.availableTools = availableTools
  }

  /// Convenience init preserved for existing call sites/tests that know only
  /// the two classic Apple tools. Seeds the tool set with whichever are set.
  public init(xcodebuildAvailable: Bool, swiftAvailable: Bool) {
    var tools = Set<String>()
    if xcodebuildAvailable { tools.insert("xcodebuild") }
    if swiftAvailable { tools.insert("swift") }
    self.init(availableTools: tools)
  }

  /// Whether `name` is a tool resolved on PATH.
  public func toolAvailable(_ name: String) -> Bool {
    availableTools.contains(name)
  }

  /// The fixed set of tool names probed on every launch.
  public static let toolNames: [String] = [
    "xcodebuild", "swift",
    "cargo", "bun", "npm", "node", "go", "make",
    "python3", "uv", "poetry", "gradle", "gradlew", "mvn", "cmake",
    "docker", "dotnet", "dart", "ruby", "bundle", "mix", "php", "composer", "zig",
  ]

  /// Probes PATH once and returns the set of available tools.
  public static func probe() -> EnvironmentProbe {
    EnvironmentProbe(availableTools: resolveAvailableTools())
  }

  /// Looks each known tool up against every PATH entry without spawning a
  /// subprocess. A tool is available when any `$PATH/<tool>` is executable.
  private static func resolveAvailableTools() -> Set<String> {
    var found = Set<String>()
    guard let path = ProcessInfo.processInfo.environment["PATH"] else { return found }
    let fm = FileManager.default
    for dir in path.split(separator: ":") {
      let dirString = String(dir)
      for tool in toolNames where !found.contains(tool) {
        let candidate = URL(fileURLWithPath: dirString).appendingPathComponent(tool).path
        if fm.isExecutableFile(atPath: candidate) {
          found.insert(tool)
        }
      }
    }
    return found
  }
}
