import Foundation

/// Detects an Xcode project (`.xcodeproj` / `.xcworkspace`) and exposes
/// build / run / test smart actions per scheme. Active only when `xcodebuild`
/// is installed.
///
/// Target/scheme discovery runs `xcodebuild -list -json` once per directory;
/// the subprocess runner is injectable so tests don't need a real project.
public final class XcodeIntegration: TerminalIntegration {
  public let id = "xcode"
  public let displayName = "Xcode"
  public var isAvailable: Bool

  /// Runs `xcodebuild -list -json` for a project file URL, returning stdout.
  public typealias BuildListRunner = (URL) -> String?

  private let buildList: BuildListRunner

  public init(isAvailable: Bool, buildList: @escaping BuildListRunner = XcodeIntegration.liveBuildList) {
    self.isAvailable = isAvailable
    self.buildList = buildList
  }

  public func relevance(files: [DirectoryEntry]) -> Bool {
    // .xcodeproj / .xcworkspace are directory bundles — deliberately no
    // isDirectory guard.
    files.contains { $0.name.hasSuffix(".xcodeproj") || $0.name.hasSuffix(".xcworkspace") }
  }

  public func scan(directory: URL, files: [DirectoryEntry]) -> [IntegrationAction] {
    guard relevance(files: files) else { return [] }
    guard let projectFile = projectFile(in: files) else { return [] }
    let projectURL = directory.appendingPathComponent(projectFile)
    guard let json = buildList(projectURL),
          let schemes = Self.parseSchemes(from: json), !schemes.isEmpty
    else { return [] }

    let flag = projectURL.pathExtension == "xcworkspace" ? "-workspace" : "-project"
    // Runs build into a stable temp-derived path so the project dir stays clean,
    // then opens the built .app when one is produced (Q1 decision).
    let buildDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("shell-smart-build", isDirectory: true)
      .appendingPathComponent(projectFile, isDirectory: true)

    var actions: [IntegrationAction] = []
    for scheme in schemes {
      let projectArg = Self.quote(projectURL.path)
      let schemeArg = Self.quote(scheme)
      let derivedArg = Self.quote(buildDir.path)
      actions.append(IntegrationAction(
        kind: .build,
        title: "Build · \(scheme)",
        target: scheme,
        command: "xcodebuild \(flag) \(projectArg) -scheme \(schemeArg) build"
      ))
      actions.append(IntegrationAction(
        kind: .test,
        title: "Test · \(scheme)",
        target: scheme,
        command: "xcodebuild \(flag) \(projectArg) -scheme \(schemeArg) test"
      ))
      let appPath = Self.quote("\(buildDir.path)/Build/Products/Debug/\(scheme).app")
      actions.append(IntegrationAction(
        kind: .run,
        title: "Run · \(scheme)",
        target: scheme,
        command: "xcodebuild \(flag) \(projectArg) -scheme \(schemeArg) -derivedDataPath \(derivedArg) build && open \(appPath)"
      ))
      // Distribute actions: Install (archive + ditto the built .app into
      // /Applications) and Upload to App Store (archive + exportArchive with
      // a generated exportOptions.plist using method app-store-connect). Both
      // run `xcodebuild ... archive` internally as their first step.
      let archivePath = Self.quote("build/\(scheme)/\(scheme).xcarchive")
      let installAppPath = Self.quote("/Applications/\(scheme).app")
      let installSourcePath = Self.quote("build/\(scheme)/\(scheme).xcarchive/Products/Applications/\(scheme).app")
      let exportPlist = Self.quote("exportOptions.plist")
      let exportPath = Self.quote("build/\(scheme)/Upload")
      actions.append(IntegrationAction(
        kind: .distribute,
        title: "Install · \(scheme)",
        target: scheme,
        command: "xcodebuild \(flag) \(projectArg) -scheme \(schemeArg) -archivePath \(archivePath) archive && rm -rf \(installAppPath) && ditto \(installSourcePath) \(installAppPath)"
      ))
      actions.append(IntegrationAction(
        kind: .distribute,
        title: "Upload to App Store · \(scheme)",
        target: scheme,
        command: "xcodebuild \(flag) \(projectArg) -scheme \(schemeArg) -archivePath \(archivePath) archive -allowProvisioningUpdates && echo '{\"method\":\"app-store-connect\"}' | plutil -convert xml1 -o \(exportPlist) - && xcodebuild -exportArchive -archivePath \(archivePath) -exportOptionsPlist \(exportPlist) -exportPath \(exportPath) -allowProvisioningUpdates"
      ))
    }
    return actions
  }

  private func projectFile(in files: [DirectoryEntry]) -> String? {
    files.first { $0.name.hasSuffix(".xcodeproj") || $0.name.hasSuffix(".xcworkspace") }?.name
  }

  /// Parses the `xcodebuild -list -json` output into a scheme/target list.
  /// Prefers top-level `schemes`, then `workspace.schemes`, then `project.targets`.
  static func parseSchemes(from json: String) -> [String]? {
    struct Payload: Decodable {
      struct Workspace: Decodable { let schemes: [String]? }
      struct Project: Decodable { let targets: [String]? }
      let workspace: Workspace?
      let project: Project?
      let schemes: [String]?
    }
    guard let data = json.data(using: .utf8),
          let payload = try? JSONDecoder().decode(Payload.self, from: data)
    else { return nil }
    if let schemes = payload.schemes, !schemes.isEmpty { return schemes }
    if let schemes = payload.workspace?.schemes, !schemes.isEmpty { return schemes }
    return payload.project?.targets
  }

  private static func quote(_ path: String) -> String {
    "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  public static func liveBuildList(_ projectURL: URL) -> String? {
    #if os(macOS)
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
      var arguments = ["xcodebuild", "-list"]
      if projectURL.pathExtension == "xcworkspace" {
        arguments += ["-workspace", projectURL.path]
      } else {
        arguments += ["-project", projectURL.path]
      }
      arguments += ["-json"]
      process.arguments = arguments
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
      return String(data: data, encoding: .utf8)
    #else
      return nil
    #endif
  }
}
