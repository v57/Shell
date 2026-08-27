import Foundation

/// Results of probing the installed developer toolchain once, at startup.
///
/// `smartActions` availability depends on `xcodebuild`/`swift` being present.
/// Probing spawns `xcrun -f <tool>` subprocesses, so the app does it a single
/// time at startup and hands the flags to the integrations (see
/// `TerminalIntegration.isAvailable`).
public struct EnvironmentProbe: Sendable, Equatable {
  public let xcodebuildAvailable: Bool
  public let swiftAvailable: Bool

  public init(xcodebuildAvailable: Bool, swiftAvailable: Bool) {
    self.xcodebuildAvailable = xcodebuildAvailable
    self.swiftAvailable = swiftAvailable
  }

  /// Locates the toolchain binaries via `xcrun -f`. A tool is "available" only
  /// when xcrun resolves a real path (exit 0, non-empty output). Falls back to
  /// false on any failure rather than throwing.
  ///
  /// `xcrun` is a macOS-only tool, so on iOS/other platforms no tool is ever
  /// resolvable (smart actions are inherently macOS-only).
  public static func probe() -> EnvironmentProbe {
    #if os(macOS)
      return EnvironmentProbe(
        xcodebuildAvailable: locateXCRunTool("xcodebuild") != nil,
        swiftAvailable: locateXCRunTool("swift") != nil
      )
    #else
      return EnvironmentProbe(xcodebuildAvailable: false, swiftAvailable: false)
    #endif
  }

  private static func locateXCRunTool(_ tool: String) -> String? {
    #if os(macOS)
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
      process.arguments = ["-f", tool]
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = Pipe()
      do {
        try process.run()
        process.waitUntilExit()
      } catch {
        return nil
      }
      guard process.terminationStatus == 0 else { return nil }
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      let output = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return (output?.isEmpty == false) ? output : nil
    #else
      return nil
    #endif
  }
}
