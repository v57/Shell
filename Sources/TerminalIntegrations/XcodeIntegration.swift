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
  /// Gate: availability requires `xcodebuild` on PATH.
  public let requiredTool: String? = "xcodebuild"
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
      // /Applications), Export (notarized zip, below) and Upload to App Store (archive + exportArchive with
      // a generated exportOptions.plist using method app-store-connect). Both
      // run `xcodebuild ... archive` internally as their first step.
      // Install and Export MUST pin -destination 'generic/platform=macOS': a MULTIPLATFORM
      // app target (SUPPORTED_PLATFORMS = "iphoneos iphonesimulator macosx",
      // e.g. the sibling Database project) archives for iOS by default when no
      // destination is given, and ditto would copy that iOS .app into
      // /Applications. macOS-only targets are unaffected by the pin.
      // When the keychain holds a "Developer ID Application" identity for the
      // archive's team (read from the archive's Info.plist), Install exports
      // the archive with method developer-id and installs that copy, so the
      // app can be shared with other Macs. Otherwise it installs the archived
      // (development-signed) .app as before. Checked when the action runs,
      // not at scan time, so a newly added certificate needs no re-scan.
      let archivePath = Self.quote("build/\(scheme)/\(scheme).xcarchive")
      let installAppPath = Self.quote("/Applications/\(scheme).app")
      let installSourcePath = Self.quote("build/\(scheme)/\(scheme).xcarchive/Products/Applications/\(scheme).app")
      let archiveInfoPlist = Self.quote("build/\(scheme)/\(scheme).xcarchive/Info.plist")
      let developerIDPlist = Self.quote("build/\(scheme)/DeveloperID.plist")
      let developerIDPath = Self.quote("build/\(scheme)/DeveloperID")
      let developerIDAppPath = Self.quote("build/\(scheme)/DeveloperID/\(scheme).app")
      let hasDeveloperID = "security find-identity -v -p codesigning | grep -q \"Developer ID Application: .*($(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:Team' \(archiveInfoPlist)))\""
      let developerIDExport = "echo '{\"method\":\"developer-id\"}' | plutil -convert xml1 -o \(developerIDPlist) - && rm -rf \(developerIDPath) && xcodebuild -exportArchive -archivePath \(archivePath) -exportOptionsPlist \(developerIDPlist) -exportPath \(developerIDPath) -allowProvisioningUpdates"
      // Export: the Developer ID copy, notarized and stapled, zipped into
      // build/<scheme>/Export and revealed in Finder, ready to send to another
      // Mac. Requires the Developer ID identity (never lets Xcode create one)
      // and a notarytool keychain profile, "notary" unless NOTARY_PROFILE is
      // set (the convention of the v57 release scripts), created once with
      // `xcrun notarytool store-credentials notary --apple-id <id> --team-id <team>`.
      let notarizeZip = Self.quote("build/\(scheme)/Export/notarize.zip")
      let exportZip = Self.quote("build/\(scheme)/Export/\(scheme).zip")
      let exportDir = Self.quote("build/\(scheme)/Export")
      let notarize = "rm -rf \(exportDir) && mkdir -p \(exportDir) && ditto -c -k --keepParent \(developerIDAppPath) \(notarizeZip) && xcrun notarytool submit \(notarizeZip) --keychain-profile \"${NOTARY_PROFILE:-notary}\" --wait && xcrun stapler staple \(developerIDAppPath) && rm \(notarizeZip) && ditto -c -k --keepParent \(developerIDAppPath) \(exportZip) && open -R \(exportZip)"
      let exportPlist = Self.quote("exportOptions.plist")
      let exportPath = Self.quote("build/\(scheme)/Upload")
      actions.append(IntegrationAction(
        kind: .distribute,
        title: "Install · \(scheme)",
        target: scheme,
        command: "xcodebuild \(flag) \(projectArg) -scheme \(schemeArg) -destination 'generic/platform=macOS' -archivePath \(archivePath) archive && if \(hasDeveloperID); then \(developerIDExport) && rm -rf \(installAppPath) && ditto \(developerIDAppPath) \(installAppPath); else rm -rf \(installAppPath) && ditto \(installSourcePath) \(installAppPath); fi"
      ))
      actions.append(IntegrationAction(
        kind: .distribute,
        title: "Export · \(scheme)",
        target: scheme,
        command: "xcodebuild \(flag) \(projectArg) -scheme \(schemeArg) -destination 'generic/platform=macOS' -archivePath \(archivePath) archive && if \(hasDeveloperID); then \(developerIDExport) && \(notarize); else echo 'Export needs a Developer ID Application certificate for the archive team in the keychain.' && false; fi",
        requirement: .notarization
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
