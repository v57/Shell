import Foundation

/// A "Developer ID Application" signing identity found in the keychain.
public struct DeveloperIDIdentity: Hashable, Sendable {
  /// The full identity name, e.g. "Developer ID Application: Jane Doe (ABCDE12345)".
  public let name: String
  public let teamID: String

  public init(name: String, teamID: String) {
    self.name = name
    self.teamID = teamID
  }
}

/// Whether a notarytool keychain profile can be used for notarization.
public enum NotaryProfileStatus: Equatable, Sendable {
  case valid
  /// The keychain has no profile with that name.
  case missing
  /// The profile exists but notarytool failed (bad credentials, no network…).
  case failed(String)
}

/// How a new notarytool keychain profile authenticates.
public enum NotaryCredentials: Equatable, Sendable {
  /// An App Store Connect API key: the .p8 file, its key ID and, for team
  /// keys, the issuer ID.
  case apiKey(path: String, keyID: String, issuerID: String?)
  /// An Apple ID with an app-specific password. The password is not part of
  /// the arguments: notarytool asks for it on its terminal.
  case appleID(appleID: String, teamID: String)
}

/// The checks behind the Xcode Export smart action
/// (`IntegrationActionRequirement.notarization`): Developer ID identities in
/// the keychain and the notarytool keychain profile the export notarizes with.
/// notarytool owns its keychain items; this only runs notarytool.
public enum Notarization {
  /// The profile the Export command uses when `NOTARY_PROFILE` is unset.
  public static let defaultProfile = "notary"

  /// The Developer ID Application identities in `security find-identity` output.
  static func parseDeveloperIDIdentities(_ output: String) -> [DeveloperIDIdentity] {
    var identities: [DeveloperIDIdentity] = []
    for line in output.split(separator: "\n") {
      guard let open = line.firstIndex(of: "\""), let close = line.lastIndex(of: "\""), open < close else { continue }
      let name = String(line[line.index(after: open)..<close])
      guard name.hasPrefix("Developer ID Application:"),
            let teamOpen = name.lastIndex(of: "("), name.hasSuffix(")")
      else { continue }
      let teamID = String(name[name.index(after: teamOpen)..<name.index(before: name.endIndex)])
      let identity = DeveloperIDIdentity(name: name, teamID: teamID)
      if !teamID.isEmpty, !identities.contains(identity) { identities.append(identity) }
    }
    return identities
  }

  /// Reads a `notarytool history --keychain-profile` result.
  static func profileStatus(exitCode: Int32, output: String) -> NotaryProfileStatus {
    if exitCode == 0 { return .valid }
    let lowered = output.lowercased()
    if lowered.contains("no keychain password item found") || (lowered.contains("keychain") && lowered.contains("not found")) {
      return .missing
    }
    let message = output.trimmingCharacters(in: .whitespacesAndNewlines)
    return .failed(message.isEmpty ? "notarytool exited with status \(exitCode)." : message)
  }

  /// The notarytool arguments that save `credentials` as `profile`
  /// (notarytool validates them with Apple before saving).
  public static func storeArguments(profile: String, credentials: NotaryCredentials) -> [String] {
    var arguments = ["notarytool", "store-credentials", profile]
    switch credentials {
    case .apiKey(let path, let keyID, let issuerID):
      arguments += ["--key", path, "--key-id", keyID]
      if let issuerID, !issuerID.isEmpty { arguments += ["--issuer", issuerID] }
    case .appleID(let appleID, let teamID):
      arguments += ["--apple-id", appleID, "--team-id", teamID]
    }
    return arguments
  }

  #if os(macOS)
    /// The Developer ID Application identities in the keychain.
    public static func developerIDIdentities() async -> [DeveloperIDIdentity] {
      let result = await run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"])
      return parseDeveloperIDIdentities(result.output)
    }

    /// Checks `profile` by listing its submission history (a network request).
    public static func checkProfile(_ profile: String) async -> NotaryProfileStatus {
      let result = await run("/usr/bin/xcrun", ["notarytool", "history", "--keychain-profile", profile, "--output-format", "json"])
      return profileStatus(exitCode: result.exitCode, output: result.output)
    }

    /// Saves an API-key profile. Apple ID profiles need a terminal for the
    /// password prompt, so the app saves those itself.
    public static func storeAPIKeyProfile(_ profile: String, path: String, keyID: String, issuerID: String?) async -> (exitCode: Int32, output: String) {
      await run("/usr/bin/xcrun", storeArguments(profile: profile, credentials: .apiKey(path: path, keyID: keyID, issuerID: issuerID)))
    }

    /// Runs a tool off the main thread, returning its exit code and combined
    /// stdout + stderr.
    static func run(_ executable: String, _ arguments: [String]) async -> (exitCode: Int32, output: String) {
      await Task.detached(priority: .userInitiated) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
          try process.run()
        } catch {
          return (-1, error.localizedDescription)
        }
        // Read before waiting: a long history would fill the pipe and block
        // the tool before it exits.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
      }.value
    }
  #endif
}
