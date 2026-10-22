#if os(macOS)
import Foundation
import Testing

@testable import ShellIntegrations

/// The `session` daemon's LaunchAgent: its plist, the environment its sessions inherit, reading `launchctl print`,
/// and the statuses that need no launchd.
struct SessionAgentTests {
  private let executable = "/Users/me/.local/bin/session"

  @Test func plistRunsTheDaemonAndKeepsItAlive() {
    let plist = SessionAgent.plist(executable: executable, environment: ["TERM": "xterm-256color"],
                                   bundleIdentifier: "dev.v57.sh")
    #expect(plist["Label"] as? String == "dev.v57.session")
    #expect(plist["ProgramArguments"] as? [String] == [executable, "--daemon"])
    #expect(plist["RunAtLoad"] as? Bool == true)
    #expect(plist["KeepAlive"] as? Bool == true)
    #expect(plist["AssociatedBundleIdentifiers"] as? [String] == ["dev.v57.sh"])
    #expect(plist["EnvironmentVariables"] as? [String: String] == ["TERM": "xterm-256color"])
  }

  @Test func environmentGivesSessionsATerminalLanguageAndPath() {
    let environment = SessionAgent.environment(
      from: ["PATH": "/usr/bin:/bin", "LANG": "de_DE.UTF-8", "LC_CTYPE": "UTF-8", "SECRET": "x"],
      executable: executable)
    #expect(environment == [
      "TERM": "xterm-256color", "COLORTERM": "truecolor", "LANG": "de_DE.UTF-8", "LC_CTYPE": "UTF-8",
      "PATH": "/Users/me/.local/bin:/usr/bin:/bin",
    ])
  }

  @Test func environmentFallsBackWithoutLanguageOrPath() {
    let environment = SessionAgent.environment(from: [:], executable: executable)
    #expect(environment["LANG"] == "en_US.UTF-8")
    #expect(environment["PATH"] == "/Users/me/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
  }

  @Test func environmentKeepsAPathThatHasTheFolder() {
    let environment = SessionAgent.environment(from: ["PATH": "/usr/bin:/Users/me/.local/bin"], executable: executable)
    #expect(environment["PATH"] == "/usr/bin:/Users/me/.local/bin")
  }

  @Test func readsLaunchctlPrint() {
    let running = "gui/501/dev.v57.session = {\n\tactive count = 1\n\tstate = running\n\tpid = 4242\n}"
    #expect(SessionAgent.isRunning(printOutput: running))
    #expect(SessionAgent.processID(printOutput: running) == 4242)
    let waiting = "gui/501/dev.v57.session = {\n\tstate = not running\n\tlast exit code = 0\n}"
    #expect(!SessionAgent.isRunning(printOutput: waiting))
    #expect(SessionAgent.processID(printOutput: waiting) == nil)
  }

  @Test func statusWithoutAPlistIsNotInstalled() {
    let agent = SessionAgent(executable: executable, plistURL: temporaryPlist())
    #expect(agent.status() == .notInstalled)
  }

  @Test func statusForAnotherSessionIsOutdated() throws {
    let url = temporaryPlist()
    defer { try? FileManager.default.removeItem(at: url) }
    let plist = SessionAgent.plist(executable: "/opt/old/session", environment: [:], bundleIdentifier: nil)
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
    #expect(SessionAgent(executable: executable, plistURL: url).status() == .outdated)
  }

  private func temporaryPlist() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("SessionAgentTests-\(UUID().uuidString).plist")
  }
}
#endif
