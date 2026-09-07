import CryptoKit
import Foundation

/// Main-actor SSH transport over `Libssh2Connection`. Exposes the
/// connection lifecycle and UI-facing prompts (host-key verification,
/// password entry) to the terminal session.
@MainActor
public final class SSHSession: TerminalTransport {
  public let config: SSHConfig
  /// When non-nil the connection runs this command via PTY + exec
  /// instead of an interactive shell (action sessions).
  private let execCommand: String?
  /// When true the connection carries no shell/exec session channel and exists
  /// purely to multiplex `direct-tcpip` port-forward channels.
  private let forwardingOnly: Bool

  /// All callbacks are delivered on the main thread.
  public var onOutput: ((Data) -> Void)?
  public var onConnected: (() -> Void)?
  public var onTerminated: ((String) -> Void)?
  /// The exec command's remote exit status (action sessions only).
  public var onExit: ((Int32) -> Void)?
  public var onHostKeyPrompt: ((TerminalHostKeyPrompt) -> Void)?
  public var onPasswordPrompt: ((TerminalPasswordPrompt) -> Void)?

  private var engine: Libssh2Connection?
  private var started = false

  public init(config: SSHConfig, execCommand: String? = nil, forwardingOnly: Bool = false) {
    self.config = config
    self.execCommand = execCommand
    self.forwardingOnly = forwardingOnly
  }

  public func start() {
    guard !started else { return }
    started = true

    // The identity key lives in the Secure Enclave; it never touches disk.
    let key = try? SSHKeychain.loadOrCreateDefaultKey()
    let engine = Libssh2Connection(
      config: config,
      privateKey: key,
      execCommand: execCommand,
      forwardingOnly: forwardingOnly
    )

    engine.onOutput = { [weak self] data in
      self?.onOutput?(data)
    }
    engine.onConnected = { [weak self] in
      self?.onConnected?()
    }
    engine.onTerminated = { [weak self] message in
      self?.onTerminated?(message)
    }
    engine.onExit = { [weak self] status in
      self?.onExit?(status)
    }
    engine.onHostKeyChallenge = { [weak self] challenge in
      guard let self else { return }
      self.onHostKeyPrompt?(TerminalHostKeyPrompt(
        host: self.config.host,
        port: self.config.port,
        fingerprint: challenge.fingerprint,
        respond: challenge.respond
      ))
    }
    engine.onPasswordChallenge = { [weak self] challenge in
      guard let self else { return }
      self.onPasswordPrompt?(TerminalPasswordPrompt(
        host: self.config.host,
        username: challenge.username,
        respond: { password, save in
          if save, let password {
            try? SSHKeychain.savePassword(password, account: self.config.passwordAccount)
          }
          challenge.respond(password)
        }
      ))
    }

    self.engine = engine
    engine.start()
  }

  public func write(_ data: Data) {
    engine?.write(data)
  }

  public func resize(columns: Int, rows: Int) {
    engine?.resize(columns: columns, rows: rows)
  }

  public func close() {
    engine?.close()
    engine = nil
  }

  /// Runs a one-shot `command` on the ALREADY-CONNECTED connection — no new
  /// SSH dial is made (the remote persistent-session scanner's whole point).
  /// The captured stdout is delivered to `completion` on the main thread; a
  /// non-zero remote exec status is carried back as the stdout the command
  /// produced (list commands like `tmux ls` exit non-zero on the normal "no
  /// server" case), so callers interpret the text rather than treat non-zero
  /// as a failure. Only meaningful after `start()` has connected — the
  /// scanner gates on `connectionState == .connected` before calling.
  public func runCommand(_ command: String, completion: @escaping @Sendable (Result<RemoteCommandResult, Error>) -> Void) {
    guard let engine else {
      completion(.failure(Libssh2Connection.EngineError.notConnected))
      return
    }
    engine.runRemoteCommand(command, completion: completion)
  }

  // MARK: - SFTP download (materialize a remote file)

  /// Downloads a remote file's raw bytes over this ALREADY-CONNECTED session via
  /// the SFTP subsystem — no new SSH dial. Used to materialize a remote file so
  /// it can be dragged out, or copied into a session's cwd. Only meaningful after
  /// `start()` has connected (the call gates on the connection state).
  public func downloadFile(remotePath: String) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      guard let engine else {
        continuation.resume(throwing: Libssh2Connection.EngineError.notConnected)
        return
      }
      engine.downloadFile(remotePath: remotePath) { result in
        continuation.resume(with: result)
      }
    }
  }

  /// Uploads a LOCAL file's bytes to `remotePath` over this ALREADY-CONNECTED
  /// session via the SFTP subsystem — no new SSH dial. Only meaningful after
  /// `start()` has authenticated (the caller gates on the connection state).
  public func uploadFile(localURL: URL, remotePath: String) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      guard let engine else {
        continuation.resume(throwing: Libssh2Connection.EngineError.notConnected)
        return
      }
      engine.uploadFile(localURL: localURL, remotePath: remotePath) { result in
        continuation.resume(with: result)
      }
    }
  }

  /// Resolves the remote login directory (`$HOME`) via a one-shot exec on the
  /// already-connected session. SFTP does NOT shell-expand `~`, so dropping on a
  /// saved connection needs the absolute home path. Only meaningful after
  /// `start()` has authenticated.
  public func remoteHomeDirectory() async throws -> String {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
      runCommand("printf '%s' \"$HOME\"") { result in
        switch result {
        case .success(let remote):
          let line = remote.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
          if line.isEmpty {
            continuation.resume(throwing: SSHDownloadError.emptyHome)
          } else {
            continuation.resume(returning: line)
          }
        case .failure(let error):
          continuation.resume(throwing: error)
        }
      }
    }
  }

  /// One-shot download: dial a fresh `forwardingOnly` (auth-only, no shell
  /// channel) connection, wait for it to authenticate, SFTP-download `remotePath`
  /// to memory, then close. Used by the file browser to fetch a remote file for a
  /// drag-out (Finder) or a copy into a session's cwd. Auth mirrors interactive
  /// sessions (Secure Enclave key, saved-password fallback, host-key trust).
  @MainActor
  public static func downloadFile(config: SSHConfig, remotePath: String) async throws -> Data {
    let session = SSHSession(config: config, forwardingOnly: true)
    try await session.waitForConnected()
    defer { session.close() }
    return try await session.downloadFile(remotePath: remotePath)
  }

  /// Dial a fresh forwarding-only (auth-only) connection and wait for it to
  /// authenticate, returning the LIVE session for a batch of one-shot SFTP ops
  /// (remote `$HOME` resolution + uploads) without re-authing per file. The
  /// caller must `close()` the returned session.
  @MainActor
  public static func connect(config: SSHConfig) async throws -> SSHSession {
    let session = SSHSession(config: config, forwardingOnly: true)
    try await session.waitForConnected()
    return session
  }

  /// Awaits the forwarding-only connection's `onConnected` (or surfaces
  /// `onTerminated`). Resumes exactly once, so a connect-only session that fails
  /// right after authentication never double-resumes the caller.
  @MainActor
  private func waitForConnected() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let once = _OnceFlag()
      onConnected = { if once.tryClaim() { continuation.resume() } }
      onTerminated = { message in
        if once.tryClaim() { continuation.resume(throwing: SSHDownloadError.connectionFailed(message)) }
      }
      start()
    }
  }

  // MARK: - Local port-forward (web / remote tunnel)

  /// Starts a local port-forward over this ALREADY-CONNECTED connection — no
  /// new SSH dial/auth. Resolves to the bound local port once the listener is
  /// up. Only meaningful after `start()` has authenticated (the web session
  /// calls this from `onConnected`).
  public func startLocalPortForward(
    bindHost: String = "127.0.0.1",
    bindPort: Int = 0,
    targetHost: String,
    targetPort: Int,
    completion: @escaping @Sendable (Result<Int, Error>) -> Void
  ) {
    guard let engine else {
      completion(.failure(Libssh2Connection.EngineError.notConnected))
      return
    }
    engine.startLocalPortForward(
      bindHost: bindHost,
      bindPort: bindPort,
      targetHost: targetHost,
      targetPort: targetPort,
      completion: completion
    )
  }

  /// Closes the local port-forward (if any); the SSH connection itself is left
  /// open.
  public func stopLocalPortForward() {
    engine?.stopLocalPortForward()
  }
}

/// A thread-safe one-shot claim: used so a connect-only session's `onConnected`
/// and `onTerminated` cannot both resume the same continuation. Made
/// `@unchecked Sendable` so it can be captured by the transport's `@Sendable`
/// callbacks without a non-Sendable-capture warning.
private final class _OnceFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var claimed = false
  func tryClaim() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if claimed { return false }
    claimed = true
    return true
  }
}

/// Failure surfaced when a one-shot SFTP download cannot establish its
/// connection (as opposed to a transfer error, which comes back through the
/// engine's `remoteCommandFailed`).
private enum SSHDownloadError: LocalizedError {
  case connectionFailed(String)
  case emptyHome
  var errorDescription: String? {
    switch self {
    case .connectionFailed(let message):
      return "Could not connect: \(message)"
    case .emptyHome:
      return "Could not resolve the remote home directory"
    }
  }
}
