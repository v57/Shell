#if os(macOS)
import Foundation
import ServiceManagement

/// The `session` tool's daemon as a LaunchAgent, so persistent sessions outlive Shell.
///
/// macOS ends the processes an app started when the app quits, unless the app may run in the background (System
/// Settings › General › Login Items & Extensions). A daemon that `session` starts from a Shell terminal is one of
/// them, so its sessions end with Shell. launchd owns a LaunchAgent's daemon instead, and it keeps running.
///
/// The agent is a plain plist in ~/Library/LaunchAgents (`SMAppService.agent` only runs programs inside the app's
/// bundle, and `session` is installed apart from Shell). It runs `session --daemon` at login and again whenever it
/// stops: a daemon already running (one a terminal started) makes it exit, and launchd retries until that one is
/// gone, so the agent takes over by itself. Every call that runs `launchctl` blocks: call it off the main thread.
public struct SessionAgent: Sendable {
  public static let label = "dev.v57.session"

  public enum Status: Equatable, Sendable {
    /// No plist.
    case notInstalled
    /// The plist runs a `session` that isn't the one installed now (moved or reinstalled elsewhere).
    case outdated
    /// Installed, but switched off in Login Items & Extensions.
    case needsApproval
    /// Installed and allowed, but no daemon of its own is running.
    case stopped
    /// Installed and allowed, but a daemon a terminal started still runs (with sessions, or `takeOverIdleDaemons`
    /// would have ended it): the agent's starts once that one is gone, when Shell quits.
    case waiting
    case running
  }

  public struct Failure: LocalizedError, Sendable {
    public let errorDescription: String?
  }

  /// The `session` binary the agent runs.
  public let executable: String
  public let plistURL: URL
  private let userID: uid_t

  public init(executable: String, plistURL: URL = SessionAgent.defaultPlistURL, userID: uid_t = getuid()) {
    self.executable = executable
    self.plistURL = plistURL
    self.userID = userID
  }

  public static var defaultPlistURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/LaunchAgents/\(label).plist")
  }

  private var domain: String { "gui/\(userID)" }
  private var service: String { "\(domain)/\(Self.label)" }

  // MARK: Plist

  /// The agent's plist. `bundleIdentifier` lists it under that app in Login Items.
  public static func plist(executable: String, environment: [String: String], bundleIdentifier: String?)
    -> [String: Any]
  {
    var plist: [String: Any] = [
      "Label": label,
      "ProgramArguments": [executable, "--daemon"],
      "EnvironmentVariables": environment,
      "RunAtLoad": true,
      "KeepAlive": true,
      // The sessions run builds and editors: no background throttling.
      "ProcessType": "Interactive",
    ]
    if let bundleIdentifier { plist["AssociatedBundleIdentifiers"] = [bundleIdentifier] }
    return plist
  }

  /// The daemon's environment, which every session's shell inherits. launchd starts agents with almost none, so it
  /// gets what a Shell terminal has: a full terminal type, the user's language and a PATH with `session` on it.
  public static func environment(from environment: [String: String], executable: String) -> [String: String] {
    var result = ["TERM": "xterm-256color", "COLORTERM": "truecolor"]
    result["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
    for (key, value) in environment where key.hasPrefix("LC_") { result[key] = value }
    let folder = (executable as NSString).deletingLastPathComponent
    let path = environment["PATH"].flatMap { $0.isEmpty ? nil : $0 } ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    result["PATH"] = path.split(separator: ":").contains(Substring(folder)) ? path : "\(folder):\(path)"
    return result
  }

  /// Whether `launchctl print` output describes a running job.
  public static func isRunning(printOutput: String) -> Bool {
    printOutput.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "state = running" }
  }

  /// The pid `launchctl print` reports for the job, if it runs.
  public static func processID(printOutput: String) -> Int32? {
    for line in printOutput.split(separator: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("pid = ") { return Int32(trimmed.dropFirst("pid = ".count)) }
    }
    return nil
  }

  // MARK: State

  public func status() -> Status {
    guard let data = try? Data(contentsOf: plistURL),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    else { return .notInstalled }
    guard (plist["ProgramArguments"] as? [String])?.first == executable else { return .outdated }
    if SMAppService.statusForLegacyPlist(at: plistURL) == .requiresApproval { return .needsApproval }
    let print = Self.launchctl(["print", service])
    if print.status == 0, Self.isRunning(printOutput: print.output) { return .running }
    return otherDaemons(agentPID: nil).isEmpty ? .stopped : .waiting
  }

  // MARK: Changes

  /// Writes the plist and loads it, replacing an older one.
  public func install(environment: [String: String], bundleIdentifier: String?) throws {
    let plist = Self.plist(
      executable: executable, environment: Self.environment(from: environment, executable: executable),
      bundleIdentifier: bundleIdentifier)
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try FileManager.default.createDirectory(
      at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: plistURL, options: .atomic)
    _ = Self.launchctl(["bootout", service])
    try bootstrap()
  }

  /// Starts the agent's daemon when it is installed and allowed but not running.
  public func startIfStopped() throws {
    guard status() == .stopped else { return }
    if Self.launchctl(["print", service]).status != 0 {
      try bootstrap()
    } else {
      let kick = Self.launchctl(["kickstart", service])
      if kick.status != 0 { throw Failure(errorDescription: kick.output) }
    }
  }

  /// Unloads the agent, which ends its daemon and the sessions in it, and deletes the plist.
  public func remove() throws {
    _ = Self.launchctl(["bootout", service])
    if FileManager.default.fileExists(atPath: plistURL.path) {
      try FileManager.default.removeItem(at: plistURL)
    }
  }

  /// When the running daemon holds no sessions, ends the `session` daemons launchd doesn't own (ones a terminal
  /// started) and starts the agent's, so it takes over now instead of when they die. With sessions it leaves them:
  /// ending a daemon ends its sessions.
  public func takeOverIdleDaemons() throws {
    guard ScreenSessionsParser.parseSessionOutput(Self.run(executable, ["list"]).output).isEmpty else { return }
    let others = otherDaemons(agentPID: Self.processID(printOutput: Self.launchctl(["print", service]).output))
    for pid in others { kill(pid, SIGTERM) }
    // The agent's daemon can only start once they let go of the daemon's lock.
    for _ in 0..<20 where others.contains(where: { kill($0, 0) == 0 }) {
      Thread.sleep(forTimeInterval: 0.05)
    }
    try startIfStopped()
  }

  /// Opens Login Items & Extensions, where the agent is switched on or off.
  public static func openLoginItems() {
    SMAppService.openSystemSettingsLoginItems()
  }

  /// The `session` daemons running for this user, but `agentPID`. Any binary: a terminal may have started one
  /// through another path to `session`.
  private func otherDaemons(agentPID: Int32?) -> [Int32] {
    let found = Self.run("/usr/bin/pgrep", ["-U", "\(userID)", "-f", "(^|/)session --daemon$"])
    return found.output.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
      .filter { $0 != agentPID }
  }

  private func bootstrap() throws {
    let result = Self.launchctl(["bootstrap", domain, plistURL.path])
    // Switched off in Login Items: loading fails, and the status says why.
    if result.status != 0, status() != .needsApproval {
      throw Failure(errorDescription: result.output.isEmpty ? "launchctl bootstrap failed" : result.output)
    }
  }

  private static func launchctl(_ arguments: [String]) -> (status: Int32, output: String) {
    run("/bin/launchctl", arguments)
  }

  private static func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
      try process.run()
    } catch {
      return (-1, error.localizedDescription)
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return (process.terminationStatus, output)
  }
}
#endif
