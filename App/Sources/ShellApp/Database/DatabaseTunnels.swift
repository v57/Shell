import Foundation
import ShellDatabaseEngines
import ShellKit
import VaultKit

/// How the database interface's connections open in Shell (`DatabaseModel.opener`): directly, or through one of
/// Shell's saved SSH hosts on Shell's own login (its keys, saved passwords, jump hosts and Hub routes), whose
/// `direct-tcpip` channels the engine talks to in-process: nothing listens on this device.
///
/// A connection goes through a host when it names one (`profile.ssh`, matched to a saved host by address, port and
/// user) or, with none named, when a saved host serves its server's address, as the sidebar groups it
/// (`VaultDatabase.tunnelHost`). SSH settings no saved host matches are left to DatabaseKit's own tunnel.
@MainActor
enum DatabaseTunnels {
  static func open(
    _ profile: ConnectionProfile, credentials: Credentials, configs: [SSHConfig], hosts: [VaultHost],
    tunnelClosed: @escaping @MainActor (String?) -> Void
  ) async throws -> OpenedSession {
    guard let config = sshConfig(for: profile, configs: configs, hosts: hosts) else {
      let (session, report) = try await Connector.connect(profile, credentials: credentials)
      session.onTunnelClosed { reason in Task { @MainActor in tunnelClosed(reason) } }
      return OpenedSession(session: session, report: report)
    }
    // The database as the SSH server sees it: its own loopback when the database runs there.
    let target =
      DatabaseConnection(engine: DatabaseEngine(rawValue: profile.engine.rawValue) ?? .postgres, host: profile.host,
        port: UInt16(clamping: profile.port), sshConfigID: config.id)
      .tunnelTarget(through: config)?.host ?? "127.0.0.1"
    let ssh = SSHSession(config: config, forwardingOnly: true)
    let dialer: WireDialer
    do {
      dialer = try await login(ssh, config: config)
    } catch {
      ssh.close()
      throw error
    }
    var direct = profile
    direct.ssh.enabled = false
    direct.host = target
    // One server behind the tunnel: no replica set discovery, and a certificate that names the server as the
    // database knows it, not as the SSH server reaches it.
    if direct.engine == .mongodb { direct.options["directConnection"] = "true" }
    direct.allowUntrustedCertificate = true
    do {
      let (session, report) = try await Connector.connect(direct, credentials: credentials, dialer: dialer)
      ssh.onTerminated = { message in Task { @MainActor in tunnelClosed(message) } }
      return OpenedSession(session: session, report: report) { ssh.close() }
    } catch {
      ssh.close()
      throw error
    }
  }

  /// The saved host a connection goes through, if any.
  static func sshConfig(for profile: ConnectionProfile, configs: [SSHConfig], hosts: [VaultHost]) -> SSHConfig? {
    guard !profile.engine.isFileBased else { return nil }
    let host: VaultHost?
    if profile.ssh.enabled {
      host = hosts.first {
        $0.hostname.caseInsensitiveCompare(profile.ssh.host) == .orderedSame && $0.port == profile.ssh.port
          && $0.user == profile.ssh.user
      }
    } else if !VaultDatabase.isLocal(profile.host) {
      host = hosts.first { $0.serves(profile.host) }
    } else {
      host = nil
    }
    guard let host else { return nil }
    let id = UUID(uuidString: host.id) ?? stableUUID(host.id)
    return configs.first { $0.id == id }
  }

  /// Logs in to the host in forwarding-only mode (no remote shell) and resolves to a dialer for its channels: one
  /// authenticated connection carries every connection the engine makes.
  private static func login(_ session: SSHSession, config: SSHConfig) async throws -> WireDialer {
    // Trust on first use, never a changed key: opening a database connection bound to a host IS the intent to
    // connect (same policy as the web card and the file browser).
    session.onHostKeyPrompt = { prompt in
      prompt.respondTrustingFirstUse()
    }
    session.onPasswordPrompt = { [config] prompt in
      // No saved SSH password and key auth failed: cancelling the prompt fails the login, which surfaces through
      // onTerminated.
      let saved = (try? SSHKeychain.loadPassword(account: config.passwordAccount)) ?? nil
      prompt.respond(saved, false)
    }
    return try await withCheckedThrowingContinuation { continuation in
      let gate = TunnelContinuationGate()
      session.onConnected = { [weak session] in
        gate.resume(continuation) { continuation in
          if let dialer = session?.dialer {
            continuation.resume(returning: dialer)
          } else {
            continuation.resume(throwing: DatabaseTunnelError.tunnelFailed("The SSH connection closed."))
          }
        }
      }
      session.onTerminated = { message in
        gate.resume(continuation) { $0.resume(throwing: DatabaseTunnelError.tunnelFailed(message)) }
      }
      session.start()
    }
  }
}

/// Why a database connection's SSH tunnel didn't open.
enum DatabaseTunnelError: LocalizedError {
  case tunnelFailed(String)

  var errorDescription: String? {
    switch self {
    case .tunnelFailed(let message): message
    }
  }
}

/// Guards a checked continuation against a double resume. The tunnel's `onConnected` and `onTerminated` can race
/// (the SSH connection drops right after it connects), so only the first resumer wins.
private final class TunnelContinuationGate: @unchecked Sendable {
  private let lock = NSLock()
  private var resumed = false

  func resume(
    _ continuation: CheckedContinuation<WireDialer, Error>,
    _ body: (CheckedContinuation<WireDialer, Error>) -> Void
  ) {
    lock.lock()
    if resumed {
      lock.unlock()
      return
    }
    resumed = true
    lock.unlock()
    body(continuation)
  }
}
