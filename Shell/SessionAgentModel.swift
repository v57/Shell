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
  private(set) var isWorking = false
  /// The last install/start/remove failure, cleared by the next change.
  private(set) var errorMessage: String?

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

  func install() {
    perform { agent in
      try agent.install(
        environment: ProcessInfo.processInfo.environment, bundleIdentifier: Bundle.main.bundleIdentifier)
      try agent.takeOverIdleDaemons()
    }
  }

  func start() { perform { try $0.takeOverIdleDaemons() } }

  func remove() { perform { try $0.remove() } }

  func openLoginItems() { SessionAgent.openLoginItems() }

  /// Before a `session` terminal starts: a stopped agent starts first, so the terminal finds the agent's daemon
  /// instead of starting one that ends with Shell. Blocks; the persistent-session monitor's queue calls it.
  nonisolated static func prepareDaemon() {
    try? agent?.startIfStopped()
  }

  private func perform(_ work: @escaping @Sendable (SessionAgent) throws -> Void) {
    guard let agent = Self.agent else {
      status = nil
      return
    }
    isWorking = true
    queue.async { [weak self] in
      var message: String?
      do { try work(agent) } catch { message = error.localizedDescription }
      let status = agent.status()
      DispatchQueue.main.async {
        guard let self else { return }
        self.status = status
        self.errorMessage = message
        self.isWorking = false
      }
    }
  }
}
#endif
