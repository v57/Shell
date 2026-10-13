import Foundation
import Testing
@testable import ShellKit

/// End-to-end reconnect against a real, disposable SSH host (a colima VM):
/// the remote is rebooted from inside the session, and later made silent
/// with a firewall rule, and the session must come back on its own both
/// times. Needs a host with password auth and passwordless sudo, named by
/// `SHELL_SSH_TEST_PORT`, `SHELL_SSH_TEST_USER` and `SHELL_SSH_TEST_PASSWORD`
/// (host `SHELL_SSH_TEST_HOST`, default 127.0.0.1); skipped otherwise.
///
///     colima start
///     SHELL_SSH_TEST_PORT=$(colima ssh-config | awk '/Port/{print $2}') \
///     SHELL_SSH_TEST_USER=$USER SHELL_SSH_TEST_PASSWORD=… \
///       swift test --filter SSHReconnectIntegrationTests
// Serialized: both tests share the one host, and the reboot would cut the
// other test's session (Swift Testing runs tests in parallel by default).
@Suite(.serialized)
@MainActor
struct SSHReconnectIntegrationTests {
  private struct Host {
    let config: SSHConfig
    let password: String

    static var fromEnvironment: Host? {
      let env = ProcessInfo.processInfo.environment
      guard let port = env["SHELL_SSH_TEST_PORT"].flatMap(Int.init),
            let user = env["SHELL_SSH_TEST_USER"],
            let password = env["SHELL_SSH_TEST_PASSWORD"] else { return nil }
      let config = SSHConfig(
        host: env["SHELL_SSH_TEST_HOST"] ?? "127.0.0.1",
        user: user,
        port: port,
        authMethod: .password,
        savePassword: false
      )
      return Host(config: config, password: password)
    }
  }

  /// A session over the test host that answers its own prompts: trusts the
  /// host key, supplies the password. Reconnect waits are shortened.
  private func open(_ host: Host) -> TerminalSession {
    let session = TerminalSession(
      transport: SSHSession(config: host.config),
      startupMessage: "Connecting to \(host.config.host)…",
      reconnect: { SSHSession(config: host.config) }
    )
    session.reconnectDelay = { _ in 1 }
    return session
  }

  /// Polls `condition` on the main actor, answering prompts as they
  /// appear, until it holds or `timeout` passes.
  private func wait(
    _ session: TerminalSession,
    _ host: Host,
    timeout: TimeInterval,
    for condition: () -> Bool
  ) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let prompt = session.hostKeyPrompt {
        session.hostKeyPrompt = nil
        prompt.respond(true)
      }
      if let prompt = session.passwordPrompt {
        session.passwordPrompt = nil
        prompt.respond(host.password, false)
      }
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return condition()
  }

  private func text(_ session: TerminalSession) -> String {
    session.flushPendingOutput()
    return session.snapshot.fullPlainText
  }

  private func isReconnecting(_ session: TerminalSession) -> Bool {
    if case .reconnecting = session.connectionState { return true }
    return false
  }

  /// The remote kernel's boot id, read through the session: tells a host
  /// that really rebooted from one that is still shutting down.
  private var bootQueries = 0
  private mutating func remoteBootID(_ session: TerminalSession, _ host: Host) async -> String? {
    bootQueries += 1
    let tag = "BOOT\(bootQueries)"
    session.send("echo \(tag)-$(cat /proc/sys/kernel/random/boot_id)-END\n")
    let pattern = try! Regex("\(tag)-([0-9a-f-]{36})-END")
    var id: String?
    _ = await wait(session, host, timeout: 15) {
      id = text(session).firstMatch(of: pattern).map { String($0.output[1].substring!) }
      return id != nil
    }
    return id
  }

  @Test(.timeLimit(.minutes(4)))
  mutating func sessionSurvivesARebootOfTheHost() async throws {
    guard let host = Host.fromEnvironment else { return }
    let session = open(host)
    defer { session.close() }

    #expect(await wait(session, host, timeout: 30) { session.connectionState == .connected })
    session.send("echo before-$((20+22))\n")
    #expect(await wait(session, host, timeout: 10) { text(session).contains("before-42") })
    let bootBefore = await remoteBootID(session, host)
    #expect(bootBefore != nil)

    // Reboot from inside the session, as a user would.
    session.send("sudo reboot\n")
    let rebootSent = Date()
    #expect(await wait(session, host, timeout: 60) { isReconnecting(session) })
    print("noticed the loss after \(Date().timeIntervalSince(rebootSent))s: \(session.snapshot.message ?? "")")
    let message = session.snapshot.message ?? ""
    #expect(message.contains("Connection lost"), "message: \(message)")

    // The session keeps dialing until the host is back. A dial can still
    // land on the old instance while it shuts down, so a connection only
    // counts once the kernel reports a new boot id.
    var bootAfter: String?
    let deadline = Date().addingTimeInterval(150)
    while Date() < deadline, bootAfter == nil {
      guard await wait(session, host, timeout: 150, for: { session.connectionState == .connected }) else { break }
      print("connected after \(Date().timeIntervalSince(rebootSent))s")
      if let id = await remoteBootID(session, host), id != bootBefore {
        bootAfter = id
      } else {
        _ = await wait(session, host, timeout: 60) { session.connectionState != .connected }
      }
    }
    #expect(bootAfter != nil, "connected to a host with a new boot id")
    print("back on the rebooted host after \(Date().timeIntervalSince(rebootSent))s")

    session.send("echo after-$((20+23))\n")
    #expect(await wait(session, host, timeout: 10) { text(session).contains("after-43") })
    let full = text(session)
    #expect(full.contains("before-42"), "scrollback survived the reconnect")
    #expect(full.contains("reconnected"))
  }

  /// Seconds since the remote kernel booted, read through the session.
  private mutating func remoteUptime(_ session: TerminalSession, _ host: Host) async -> Double? {
    bootQueries += 1
    let tag = "UP\(bootQueries)"
    session.send("echo \(tag)-$(cut -d' ' -f1 /proc/uptime)-END\n")
    let pattern = try! Regex("\(tag)-([0-9.]+)-END")
    var uptime: Double?
    _ = await wait(session, host, timeout: 15) {
      uptime = text(session).firstMatch(of: pattern).flatMap { Double($0.output[1].substring!) }
      return uptime != nil
    }
    return uptime
  }

  @Test(.timeLimit(.minutes(5)))
  mutating func sessionNoticesASilentHostAndComesBack() async throws {
    guard let host = Host.fromEnvironment else { return }
    let session = open(host)
    defer { session.close() }

    #expect(await wait(session, host, timeout: 30) { session.connectionState == .connected })
    // A host that only just booted may reboot once more on its own (lima's
    // boot script does, right after the reboot test): wait until it has
    // been up for a minute, riding out any reconnect in the meantime.
    while let uptime = await remoteUptime(session, host), uptime < 60 {
      _ = await wait(session, host, timeout: 65 - uptime) { false }
      _ = await wait(session, host, timeout: 60) { session.connectionState == .connected }
    }
    session.send("echo ready\n")
    #expect(await wait(session, host, timeout: 10) { text(session).contains("ready") })

    // Make sshd's packets vanish for 75s: the TCP link stays up but nothing
    // answers, which only the keepalive timeout can notice. The rule also
    // blocks the SYN-ACKs of the first reconnect dials, so they time out
    // until the rule is lifted.
    session.send("sudo sh -c 'iptables -I OUTPUT -p tcp --sport 22 -j DROP; sleep 75; iptables -D OUTPUT -p tcp --sport 22 -j DROP' >/dev/null 2>&1 &\n")
    let started = Date()
    #expect(await wait(session, host, timeout: 90) { isReconnecting(session) })
    let noticedAfter = Date().timeIntervalSince(started)
    print("noticed the silent host after \(noticedAfter)s: \(session.snapshot.message ?? "")")
    #expect(noticedAfter < 75, "noticed after \(noticedAfter)s")
    #expect(session.snapshot.message?.contains("stopped responding") == true, "message: \(session.snapshot.message ?? "")")

    #expect(await wait(session, host, timeout: 150) { session.connectionState == .connected })
    print("back after \(Date().timeIntervalSince(started))s")
    session.send("echo back-$((40+2))\n")
    #expect(await wait(session, host, timeout: 10) { text(session).contains("back-42") })
  }
}
