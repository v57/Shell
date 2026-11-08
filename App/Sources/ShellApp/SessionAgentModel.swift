#if os(macOS)
import Foundation
import ShellIntegrations
import ShellKit

/// Shell's view of the `session` daemon's LaunchAgent (`SessionAgent`): whether persistent sessions outlive Shell,
/// and the Settings row and terminal banner that install, start or remove it. The `launchctl` work runs on its own
/// queue.
@MainActor
@Observable
final class SessionAgentModel {
  /// nil until the first check, and while `session` isn't installed.
  private(set) var status: SessionAgent.Status?
  /// Whether a `session` daemon runs, whoever started it.
  private(set) var daemonIsRunning = false
  private(set) var isWorking = false
  /// The last install/start/remove failure, cleared by the next change.
  private(set) var errorMessage: String?
  /// The `session` tool itself is downloading (`installTool`).
  private(set) var isInstallingTool = false
  /// Why the last `installTool` failed.
  private(set) var toolErrorMessage: String?

  private static let tipDismissedKey = "sessionAgentTipDismissed"
  /// The terminal banner was dismissed; Settings still shows the row.
  var tipDismissed = UserDefaults.standard.bool(forKey: tipDismissedKey) {
    didSet { UserDefaults.standard.set(tipDismissed, forKey: Self.tipDismissedKey) }
  }

  private let queue = DispatchQueue(label: "SessionAgentModel")

  /// The agent for the `session` installed now, nil without one.
  nonisolated static var agent: SessionAgent? {
    LocalPTYTransport.sessionExecutablePath().map { SessionAgent(executable: $0) }
  }

  var isAvailable: Bool { Self.agent != nil }

  /// The `session` tool's sessions end when Shell quits: its daemon isn't the agent's.
  var sessionsEndWithShell: Bool { status != nil && status != .running }

  func refresh() { perform { _ in } }

  /// Installs the `session` tool to ~/.local/bin with its official installer. Only on the user's click: it downloads
  /// the latest release from GitHub. `done` runs once it's there.
  func installTool(done: @escaping @MainActor () -> Void) {
    isInstallingTool = true
    toolErrorMessage = nil
    queue.async { [weak self] in
      let message = Self.runToolInstaller()
      DispatchQueue.main.async {
        guard let self else { return }
        self.isInstallingTool = false
        self.toolErrorMessage = message
        self.refresh()
        done()
      }
    }
  }

  /// Runs the installer; returns what it reported when it failed.
  private nonisolated static func runToolInstaller() -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", "set -o pipefail; curl -fsSL https://raw.githubusercontent.com/v57/session/main/install/session.sh | bash"]
    let errors = Pipe()
    process.standardError = errors
    process.standardOutput = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      return error.localizedDescription
    }
    let output = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus != 0 else { return nil }
    let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? String(localized: "The installer stopped with status \(process.terminationStatus)") : text
  }

  func install() {
    perform { agent in
      try agent.install(
        environment: ProcessInfo.processInfo.environment, bundleIdentifier: Bundle.main.bundleIdentifier)
      try agent.takeOverIdleDaemons()
    }
  }

  func start() { perform { try $0.takeOverIdleDaemons() } }

  func remove() { perform { try $0.remove() } }

  /// Ends the daemon and every persistent session in it. `done` runs once the daemon is gone.
  func stopDaemon(done: @escaping @MainActor () -> Void) { perform({ try $0.stopDaemons() }, done: done) }

  func openLoginItems() { SessionAgent.openLoginItems() }

  /// Before a `session` terminal starts: a stopped agent starts first, so the terminal finds the agent's daemon
  /// instead of starting one that ends with Shell. Blocks; the persistent-session monitor's queue calls it.
  nonisolated static func prepareDaemon() {
    try? agent?.startIfStopped()
  }

  private func perform(
    _ work: @escaping @Sendable (SessionAgent) throws -> Void, done: (@MainActor () -> Void)? = nil
  ) {
    guard let agent = Self.agent else {
      status = nil
      daemonIsRunning = false
      return
    }
    isWorking = true
    queue.async { [weak self] in
      var message: String?
      do { try work(agent) } catch { message = error.localizedDescription }
      let status = agent.status()
      let daemonIsRunning = agent.isDaemonRunning()
      DispatchQueue.main.async {
        guard let self else { return }
        self.status = status
        self.daemonIsRunning = daemonIsRunning
        self.errorMessage = message
        self.isWorking = false
        done?()
      }
    }
  }
}
#endif
