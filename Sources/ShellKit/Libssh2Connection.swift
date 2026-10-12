import CLibssh2
import CryptoKit
import Foundation

/// The outcome of a one-shot remote `exec` on an already-authenticated
/// connection: the captured stdout plus the command's remote exit status.
///
/// The exit status is carried alongside the stdout rather than being fused
/// into `.failure` — a non-zero exit (e.g. `tmux ls` exit 1 on "no server
/// running", command-not-found 127) is a normal result the caller interprets,
/// and only connection/channel-level problems produce `.failure`.
public struct RemoteCommandResult: Sendable {
  public let stdout: String
  public let exitStatus: Int32

  public init(stdout: String, exitStatus: Int32) {
    self.stdout = stdout
    self.exitStatus = exitStatus
  }
}

/// Owns a single libssh2 SSH connection for one remote terminal session.
///
/// All libssh2 work happens on the engine's private serial queue (a dedicated
/// background thread); every callback (`onOutput`, `onConnected`,
/// `onTerminated`, the host-key/password challenges) is invoked on the main
/// thread so the UI can react directly. Nothing here blocks the main thread.
///
/// The socket is non-blocking and the session is driven in non-blocking mode
/// with a `poll()` loop, so no libssh2 call stalls the owning thread.
nonisolated final class Libssh2Connection: @unchecked Sendable {
  /// A request to the UI to verify an unknown or changed host key.
  struct HostKeyChallenge {
    let fingerprint: String
    /// The fingerprint remembered for this host when the server now presents
    /// a different key (possible man-in-the-middle); nil on first contact.
    let previousFingerprint: String?
    /// Call with `true` to accept (and remember) the key, `false` to reject.
    let respond: @Sendable (Bool) -> Void
  }

  /// A request to the UI for a password.
  struct PasswordChallenge {
    let username: String
    /// Call with the password to use it, or `nil` to cancel.
    let respond: @Sendable (String?) -> Void
  }

  enum EngineError: LocalizedError {
    case connectTimedOut
    case hostKeyRejected
    case authenticationCancelled
    case noAvailableAuthenticationMethods
    /// The connection is not open (no live session to multiplex on).
    case notConnected
    /// A one-shot remote exec failed at the connection/channel level.
    case remoteCommandFailed(String)
    case libssh2(Int32, String)

    var errorDescription: String? {
      switch self {
      case .connectTimedOut:
        return "Connection timed out."
      case .hostKeyRejected:
        return "Host key was rejected."
      case .authenticationCancelled:
        return "Authentication was cancelled."
      case .noAvailableAuthenticationMethods:
        return "No supported authentication methods were available."
      case .notConnected:
        return "The connection is not open."
      case .remoteCommandFailed(let message):
        return "Remote command failed: \(message)"
      case .libssh2(let code, let message):
        return "SSH error (\(code)): \(message)"
      }
    }
  }

  /// libssh2's EAGAIN constant is a C macro (not visible to Swift). -37 is the
  /// stable value of `LIBSSH2_ERROR_EAGAIN` for all supported libssh2 versions.
  private static let EAGAIN: Int32 = -37

  // MARK: Callbacks (all delivered on the main thread)

  var onOutput: ((Data) -> Void)?
  var onConnected: (() -> Void)?
  var onTerminated: ((String) -> Void)?
  /// The remote command's exit status (exec/action sessions only).
  var onExit: ((Int32) -> Void)?
  var onHostKeyChallenge: ((HostKeyChallenge) -> Void)?
  var onPasswordChallenge: ((PasswordChallenge) -> Void)?

  // MARK: State

  private let config: SSHConfig
  private let privateKey: SecureEnclave.P256.Signing.PrivateKey?
  /// When non-nil the channel requests PTY + exec instead of a shell
  /// (action sessions); the remote exit status arrives via onExit.
  private let execCommand: String?
  /// When true the connection opens NO session channel — it exists purely to
  /// multiplex `direct-tcpip` (port-forward) channels, so it carries no remote
  /// shell/exec. `onConnected` fires once SSH authentication succeeds.
  private let forwardingOnly: Bool
  private let knownHosts = KnownHostsStore()

  /// The dedicated thread owning the libssh2 session.
  private let queue = DispatchQueue(label: "ShellKit.Libssh2Connection")
  /// Wakes the poll loop when a write is pending.
  private let wake = DispatchSemaphore(value: 0)

  /// The active local port-forward (web session + remote Database tunnel), if
  /// any. `forwardLock` guards access because the tunnel's listener starts on
  /// the main thread while the owner thread's `pump` reads it every tick.
  private let forwardLock = NSLock()
  private var portForward: Libssh2PortForward?

  // All of the following are only accessed on `queue` (the owning thread).
  private var socketFD: Int32 = -1
  private var session: OpaquePointer?
  private var channel: OpaquePointer?

  /// True while the connect/setup/auth/run lifecycle is active. Set true in
  /// start() and false in close()/teardown. Owned by `queue`.
  private var running = false
  /// True once the shell/exec channel has fully closed (after EOF/exit).
  private var channelGone = false
  /// True once an exec channel reported its exit status; a subsequent clean
  /// close must NOT surface as an error.
  private var execExitSeen = false

  /// Pending bytes to write to the channel, guarded by `writeLock` (crosses
  /// from the main thread into `queue`).
  private let writeLock = NSLock()
  private var pendingWrite = Data()

  /// Global libssh2 init guard; libssh2_init runs once per process.
  private static let initOnce: Void = {
    _ = libssh2_init(0)
  }()

  init(config: SSHConfig, privateKey: SecureEnclave.P256.Signing.PrivateKey?, execCommand: String? = nil, forwardingOnly: Bool = false) {
    self.config = config
    self.privateKey = privateKey
    self.execCommand = execCommand
    self.forwardingOnly = forwardingOnly
    _ = Self.initOnce
  }

  deinit {
    teardownSession()
  }

  // MARK: Public API (main thread)

  func start() {
    queue.async { [weak self] in
      self?.runConnect()
    }
  }

  func write(_ data: Data) {
    guard !data.isEmpty else { return }
    writeLock.lock()
    pendingWrite.append(data)
    writeLock.unlock()
    wake.signal()
  }

  func resize(columns: Int, rows: Int) {
    queue.async { [weak self] in
      guard let self, let ch = self.channel else { return }
      // The session is non-blocking, so libssh2_channel_request_pty_size_ex may
      // return EAGAIN while the window-change packet can't be sent yet. Drive
      // the request to completion with the same poll() loop as every other
      // channel op so a resize is never silently dropped (the shell must reflow).
      var rc = libssh2_channel_request_pty_size_ex(ch, Int32(columns), Int32(rows), 0, 0)
      rc = self.driveChannel(rc) {
        libssh2_channel_request_pty_size_ex(ch, Int32(columns), Int32(rows), 0, 0)
      }
      _ = rc
    }
  }

  func close() {
    queue.async { [weak self] in
      self?.teardownSession()
    }
  }

  // MARK: Local port-forward (web session + remote Database tunnel)

  /// Starts a local port-forward over this (already-authenticated) connection.
  /// Binds a local listener on `bindHost:bindPort` (0 = ephemeral) and resolves
  /// to the actually-bound port via `completion` on the main thread. Each
  /// accepted local connection is multiplexed as a fresh `direct-tcpip` channel
  /// over the shared libssh2 session — no new SSH dial or re-authentication.
  /// Only meaningful after `start()` has authenticated.
  func startLocalPortForward(
    bindHost: String = "127.0.0.1",
    bindPort: Int = 0,
    targetHost: String,
    targetPort: Int,
    completion: @escaping @Sendable (Result<Int, Error>) -> Void
  ) {
    forwardLock.lock()
    if portForward != nil {
      forwardLock.unlock()
      DispatchQueue.main.async { completion(.failure(EngineError.remoteCommandFailed("A port-forward is already active on this connection."))) }
      return
    }
    let config = Libssh2PortForward.Config(
      bindHost: bindHost,
      bindPort: bindPort,
      targetHost: targetHost,
      targetPort: targetPort
    )
    let forward = Libssh2PortForward(config: config) { [weak self] message in
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        // Surface a user-facing error (e.g. the remote refused the connect).
        self.onTerminated?(message)
      }
    }
    portForward = forward
    forwardLock.unlock()

    forward.start(completion: completion)
  }

  func stopLocalPortForward() {
    forwardLock.lock()
    let forward = portForward
    portForward = nil
    forwardLock.unlock()
    forward?.stop()
  }

  // MARK: One-shot remote exec (persistent-session scan)

  /// Runs a one-shot `command` on the ALREADY-AUTHENTICATED connection by
  /// opening a second session channel (SSH channels multiplex over one TCP/SSH
  /// connection), leaving the interactive session's channel untouched.
  ///
  /// `completion` is invoked exactly once, on the main thread. A non-zero
  /// REMOTE exec status is not surfaced as a `.failure`: listing commands like
  /// `tmux ls` exit 1 on the normal "no server running" case, and
  /// `command not found` (exit 127) is the absence case — callers interpret the
  /// captured stdout. `.failure` is reserved for connection/channel-level
  /// problems. The remote exit status is delivered in `RemoteCommandResult`.
  func runRemoteCommand(_ command: String, completion: @escaping @Sendable (Result<RemoteCommandResult, Error>) -> Void) {
    queue.async { [weak self] in
      guard let self, let sess = self.session else {
        DispatchQueue.main.async { completion(.failure(EngineError.notConnected)) }
        return
      }
      self.runOneShotCommand(sess, command: command, completion: completion)
    }
  }

  /// Downloads a remote file's raw bytes via the SFTP subsystem over this
  /// ALREADY-AUTHENTICATED connection — no new SSH dial. The bytes are delivered
  /// to `completion` on the main thread. Used to materialize a remote file so it
  /// can be dragged out (Finder) or copied into a session's cwd. Only meaningful
  /// after `start()` has authenticated (callers gate on the connection state);
  /// the server must expose the SFTP subsystem (openssh does by default).
  func downloadFile(remotePath: String, completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
    queue.async { [weak self] in
      guard let self, let sess = self.session else {
        DispatchQueue.main.async { completion(.failure(EngineError.notConnected)) }
        return
      }
      self.runSFTPDownload(sess, remotePath: remotePath, completion: completion)
    }
  }

  /// Uploads a LOCAL file's bytes to `remotePath` via the SFTP subsystem over
  /// this ALREADY-AUTHENTICATED connection — no new SSH dial. Streams the local
  /// file out with the same EAGAIN/poll loop as every other channel op. Only
  /// meaningful after `start()` has authenticated; the server must expose the
  /// SFTP subsystem (openssh does by default).
  func uploadFile(localURL: URL, remotePath: String, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
    queue.async { [weak self] in
      guard let self, let sess = self.session else {
        DispatchQueue.main.async { completion(.failure(EngineError.notConnected)) }
        return
      }
      self.runSFTPUpload(sess, localURL: localURL, remotePath: remotePath, completion: completion)
    }
  }

  // MARK: - Connection lifecycle (running on `queue`)

  /// The full TCP + handshake + hostkey + auth + channel setup, on `queue`.
  private func runConnect() {
    running = true

    do {
      let fd = try openSocket(host: config.host, port: config.port, timeout: 20)
      socketFD = fd
      guard let sess = libssh2_session_init_ex(nil, nil, nil, nil) else {
        throw EngineError.libssh2(-1, "libssh2_session_init_ex returned NULL")
      }
      session = sess

      try handshake(sess, fd: fd)
      try verifyHostKey(sess)
      try authenticate(sess)
      guard libssh2_userauth_authenticated(sess) == 1 else {
        throw EngineError.authenticationCancelled
      }

      if forwardingOnly {
        // No session channel. The connection can now multiplex direct-tcpip
        // channels; signal readiness on the main thread. Watch the socket only
        // so a remote close surfaces as onTerminated (the port-forward helper
        // owns the actual tunnel channels).
        DispatchQueue.main.async { [weak self] in
          self?.onConnected?()
        }
        watchSocket()
        return
      }

      try openSessionChannel(sess)
      DispatchQueue.main.async { [weak self] in
        self?.onConnected?()
      }
      startPump()
    } catch {
      // The connection never became fully usable (setup threw), or an attempt
      // to drive it failed. Tear down any partially-allocated socket/session so
      // we never leak. This MUST NOT run on the SUCCESS path: the cooperative
      // pumps (watchSocket / startPump) return after one iteration and
      // re-schedule themselves, so the connection is still alive after
      // `runConnect` returns — it must stay up for one-shot SFTP/exec ops.
      teardownSession()
      DispatchQueue.main.async { [weak self] in
        self?.onTerminated?(Self.describe(error))
      }
    }
  }

  // MARK: Socket

  /// Opens a non-blocking TCP socket to `host:port`, honoring TCP_NODELAY and a
  /// 20s connect timeout (the same timeout the NIO engine used).
  private func openSocket(host: String, port: Int, timeout: Int) throws -> Int32 {
    var hints = addrinfo()
    hints.ai_flags = 0
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM
    hints.ai_protocol = 0

    var ai: UnsafeMutablePointer<addrinfo>?
    let rc = host.withCString { h in
      getaddrinfo(h, String(port), &hints, &ai)
    }
    guard rc == 0, let addrInfo = ai else {
      throw EngineError.connectTimedOut
    }
    defer { freeaddrinfo(addrInfo) }

    var lastError: EngineError = .connectTimedOut
    var current: UnsafeMutablePointer<addrinfo>? = addrInfo
    while let cand = current {
      let info = cand.pointee
      let s = socket(info.ai_family, info.ai_socktype, info.ai_protocol)
      if s >= 0 {
        // TCP_NODELAY: disable Nagle so keystrokes flush immediately.
        var one: Int32 = 1
        setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        // Non-blocking so the 20s connect timeout is enforced by poll().
        let fl = fcntl(s, F_GETFL, 0)
        if fl >= 0 { _ = fcntl(s, F_SETFL, fl | O_NONBLOCK) }

        let connRc = info.ai_addr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
          connect(s, sp, info.ai_addrlen)
        }
        if connRc == 0 {
          return s
        }
        if errno == EINPROGRESS || errno == EALREADY {
          // Wait for writability with the 20s timeout, then confirm the error.
          if waitForSocket(s, events: Int16(POLLOUT), timeoutMs: timeout * 1000) {
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &len)
            if err == 0 {
              return s
            }
            lastError = .libssh2(err, String(cString: strerror(err)))
          } else {
            lastError = .connectTimedOut
          }
        } else {
          lastError = .connectTimedOut
        }
        Darwin.close(s)
      }
      current = cand.pointee.ai_next
    }
    throw lastError
  }

  /// Polls `fd` for `events`, returning true when ready, false on timeout/error.
  private func waitForSocket(_ fd: Int32, events: Int16, timeoutMs: Int) -> Bool {
    var pfd = pollfd(fd: fd, events: events, revents: 0)
    return poll(&pfd, 1, Int32(timeoutMs)) > 0
  }

  /// Maps libssh2's block-directions bitmask to a poll() event mask.
  private func polevents(_ blockDirs: Int32) -> Int16 {
    var events: Int16 = 0
    if blockDirs & LIBSSH2_SESSION_BLOCK_INBOUND != 0 { events |= Int16(POLLIN) }
    if blockDirs & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0 { events |= Int16(POLLOUT) }
    return events == 0 ? Int16(POLLIN) : events
  }

  // MARK: Handshake

  private func handshake(_ sess: OpaquePointer, fd: Int32) throws {
    libssh2_session_set_blocking(sess, 0)
    let deadline = DispatchTime.now() + .seconds(20)
    var rc = libssh2_session_handshake(sess, fd)
    while rc == Self.EAGAIN {
      if DispatchTime.now() > deadline { throw EngineError.connectTimedOut }
      let dirs = libssh2_session_block_directions(sess)
      var pfd = pollfd(fd: fd, events: polevents(dirs), revents: 0)
      _ = poll(&pfd, 1, 250)
      rc = libssh2_session_handshake(sess, fd)
    }
    guard rc == 0 else { throw EngineError.libssh2(rc, lastErrorText(sess)) }
  }

  // MARK: Host key verification

  private func verifyHostKey(_ sess: OpaquePointer) throws {
    guard let hashPtr = libssh2_hostkey_hash(sess, LIBSSH2_HOSTKEY_HASH_SHA256) else {
      throw EngineError.libssh2(-1, "no host key hash")
    }
    // libssh2_hostkey_hash returns a pointer to a 32-byte SHA256 digest.
    let hashData = Data(bytes: hashPtr, count: 32)
    let base64 = hashData.base64EncodedString().replacingOccurrences(of: "=", with: "")
    let fingerprint = "SHA256:\(base64)"

    let known = knownHosts.fingerprint(for: config.host, port: config.port)
    if known == fingerprint {
      return
    }

    // Unknown or changed host key — ask the UI. The prompt saves (or not) and signals; we
    // then re-check the store to learn the user's decision without a mutable
    // flag racing across threads.
    let sem = DispatchSemaphore(value: 0)
    let respond: @Sendable (Bool) -> Void = { [knownHosts, config] accept in
      if accept {
        knownHosts.save(fingerprint: fingerprint, host: config.host, port: config.port)
      }
      sem.signal()
    }
    DispatchQueue.main.async { [weak self] in
      self?.onHostKeyChallenge?(HostKeyChallenge(fingerprint: fingerprint, previousFingerprint: known, respond: respond))
    }
    _ = sem.wait(timeout: .now() + .seconds(60))
    if knownHosts.fingerprint(for: config.host, port: config.port) != fingerprint {
      throw EngineError.hostKeyRejected
    }
  }

  // MARK: Authentication

  private func authenticate(_ sess: OpaquePointer) throws {
    let username = config.user
    let usernameLen = UInt32(username.utf8.count)

    // 1) Secure Enclave key (publickey with external signer).
    if config.authMethod == .keychainKey, let key = privateKey {
      let pubBlob = SSHKeychain.publicKeyBlob(for: key)
      if authWithPublicKey(sess, username: username, usernameLen: usernameLen, key: key, pubBlob: pubBlob) {
        return
      }
    }

    // 2) Password: saved one from the Keychain first, else prompt.
    let methods = libssh2_userauth_list(sess, username, usernameLen)
    let supportsPassword = methods.map { String(cString: $0).contains("password") } ?? false
    if supportsPassword {
      if config.savePassword,
         let saved = try? SSHKeychain.loadPassword(account: config.passwordAccount) {
        let rc = libssh2_userauth_password_ex(sess, username, usernameLen, saved, UInt32(saved.utf8.count), nil)
        if rc == 0 { return }
        // Fall through to the prompt on failure.
      }

      let sem = DispatchSemaphore(value: 0)
      let boxed = PasswordBox()
      let respond: @Sendable (String?) -> Void = { pw in
        boxed.password = pw
        sem.signal()
      }
      DispatchQueue.main.async { [weak self] in
        self?.onPasswordChallenge?(PasswordChallenge(username: username, respond: respond))
      }
      _ = sem.wait(timeout: .now() + .seconds(120))
      guard let password = boxed.password else {
        throw EngineError.authenticationCancelled
      }
      let rc = libssh2_userauth_password_ex(sess, username, usernameLen, password, UInt32(password.utf8.count), nil)
      if rc == 0 { return }
      throw EngineError.libssh2(rc, lastErrorText(sess))
    }

    throw EngineError.noAvailableAuthenticationMethods
  }

  /// Drives `libssh2_userauth_publickey` with the Secure Enclave sign callback.
  /// Returns true when the server accepted the key.
  private func authWithPublicKey(
    _ sess: OpaquePointer,
    username: String,
    usernameLen: UInt32,
    key: SecureEnclave.P256.Signing.PrivateKey,
    pubBlob: Data
  ) -> Bool {
    // The SE key must be reachable from the C sign callback; `abstract` carries
    // an opaque pointer to a retained SEKeyRef.
    let ref = SEKeyRef(key: key)
    var opaque: UnsafeMutableRawPointer? = Unmanaged.passRetained(ref).toOpaque()
    defer { Unmanaged<SEKeyRef>.fromOpaque(opaque!).release() }

    var rc = username.withCString { uName in
      pubBlob.withUnsafeBytes { blob in
        libssh2_userauth_publickey(
          sess,
          uName,
          blob.baseAddress?.assumingMemoryBound(to: UInt8.self),
          pubBlob.count,
          seSignCallback,
          &opaque
        )
      }
    }
    // Non-blocking sessions may return EAGAIN; retry with a bounded loop so
    // auth eventually completes (or fails) instead of returning early.
    let deadline = DispatchTime.now() + .seconds(20)
    var attempts = 0
    while rc == Self.EAGAIN && DispatchTime.now() < deadline && attempts < 200 {
      let dirs = libssh2_session_block_directions(sess)
      var pfd = pollfd(fd: socketFD, events: polevents(dirs), revents: 0)
      _ = poll(&pfd, 1, 100)
      attempts += 1
      rc = username.withCString { uName in
        pubBlob.withUnsafeBytes { blob in
          libssh2_userauth_publickey(
            sess, uName,
            blob.baseAddress?.assumingMemoryBound(to: UInt8.self),
            pubBlob.count, seSignCallback, &opaque
          )
        }
      }
    }
    return rc == 0
  }

  // MARK: Channel setup

  private func openSessionChannel(_ sess: OpaquePointer) throws {
    guard let ch = openChannel(sess) else {
      throw EngineError.libssh2(libssh2_session_last_errno(sess), lastErrorText(sess))
    }
    channel = ch

    // Request a PTY (needed so remote output renders like a terminal and
    // Ctrl+C ISIG works over the wire) in BOTH shell and exec modes.
    let cols: Int32 = 80
    let rows: Int32 = 24
    let term = "xterm-256color"
    var rc = libssh2_channel_request_pty_ex(ch, term, UInt32(term.utf8.count), nil, 0, cols, rows, 0, 0)
    rc = driveChannel(rc) {
      libssh2_channel_request_pty_ex(ch, term, UInt32(term.utf8.count), nil, 0, cols, rows, 0, 0)
    }
    guard rc == 0 else { throw EngineError.libssh2(rc, lastErrorText(sess)) }

    if let execCommand {
      var erc = channelProcessStartup(ch, request: "exec", command: execCommand)
      erc = driveChannel(erc) { channelProcessStartup(ch, request: "exec", command: execCommand) }
      guard erc == 0 else { throw EngineError.libssh2(erc, lastErrorText(sess)) }
    } else {
      var src = channelProcessStartup(ch, request: "shell", command: nil)
      src = driveChannel(src) { channelProcessStartup(ch, request: "shell", command: nil) }
      guard src == 0 else { throw EngineError.libssh2(src, lastErrorText(sess)) }
    }
  }

  /// `libssh2_channel_process_startup` — the backing function shared by the
  /// `libssh2_channel_shell` / `libssh2_channel_exec` C macros (which are not
  /// imported into Swift). Request is "shell", "exec", or "subsystem".
  private func channelProcessStartup(_ ch: OpaquePointer, request: String, command: String?) -> Int32 {
    let reqLen = UInt32(request.utf8.count)
    if let command {
      return libssh2_channel_process_startup(ch, request, reqLen, command, UInt32(command.utf8.count))
    } else {
      return libssh2_channel_process_startup(ch, request, reqLen, nil, 0)
    }
  }

  /// Opens a session channel with the non-blocking retry loop.
  /// (`libssh2_channel_open_session` is a C macro, so we call
  /// `libssh2_channel_open_ex` directly.)
  private func openChannel(_ sess: OpaquePointer) -> OpaquePointer? {
    var ch = libssh2_channel_open_ex(sess, "session", UInt32("session".utf8.count), 2*1024*1024, 32768, nil, 0)
    let deadline = DispatchTime.now() + .seconds(20)
    var attempts = 0
    while ch == nil && libssh2_session_last_errno(sess) == Self.EAGAIN && attempts < 200 && DispatchTime.now() < deadline {
      let dirs = libssh2_session_block_directions(sess)
      var pfd = pollfd(fd: socketFD, events: polevents(dirs), revents: 0)
      _ = poll(&pfd, 1, 100)
      attempts += 1
      ch = libssh2_channel_open_ex(sess, "session", UInt32("session".utf8.count), 2*1024*1024, 32768, nil, 0)
    }
    return ch
  }

  /// Runs a channel op that may return EAGAIN; retries with the poll loop and
  /// returns the final (non-EAGAIN) result.
  private func driveChannel(_ initial: Int32, _ op: () -> Int32) -> Int32 {
    var rc = initial
    let deadline = DispatchTime.now() + .seconds(20)
    var attempts = 0
    while rc == Self.EAGAIN && attempts < 200 && DispatchTime.now() < deadline {
      let dirs = libssh2_session_block_directions(session!)
      var pfd = pollfd(fd: socketFD, events: polevents(dirs), revents: 0)
      _ = poll(&pfd, 1, 100)
      attempts += 1
      rc = op()
    }
    return rc
  }

  // MARK: Byte-output pump

  /// For a forwarding-only connection (no session channel), watch the socket so
  /// a remote close / hangup surfaces as `onTerminated`. Also drives the local
  /// port-forward's tunnel I/O every tick (on this owner thread, since libssh2
  /// requires a single owning thread). There is no shell/exec channel to read.
  ///
  /// One iteration per call, then re-dispatches itself. Without this the
  /// `while running {}` loop monopolises the serial queue and every later
  /// `queue.async` one-shot op (the drop's `remoteHomeDirectory()` exec +
  /// `uploadFile` SFTP, `downloadFile`, `close()`) deadlocks forever — the
  /// connection would sit connected with the drop stuck at `remoteHomeDirectory`.
  private func watchSocket() {
    guard running else { return }
    pumpPortForward()
    let ready = waitForSocket(socketFD, events: Int16(POLLIN | POLLHUP), timeoutMs: 100)
    if ready {
      var pfd = pollfd(fd: socketFD, events: Int16(POLLIN | POLLHUP), revents: 0)
      _ = poll(&pfd, 1, 0)
      if pfd.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
        running = false
        finishOnMain("Connection closed.")
        return
      }
      // Drain any pending session packets so the SSH session stays healthy.
      _ = libssh2_session_block_directions(session!)
      pumpPortForward()
    }
    pumpPortForward()
    queue.async { [weak self] in self?.watchSocket() }
  }

  /// Drives the active local port-forward on the session's owner thread. This is
  /// the ONLY place the tunnel channels touch libssh2, satisfying libssh2's
  /// one-thread-per-session requirement in the forwarding-only path.
  private func pumpPortForward() {
    forwardLock.lock()
    let forward = portForward
    forwardLock.unlock()
    guard let forward, let sess = session else { return }
    forward.pump(session: sess, socketFD: socketFD, eagain: Self.EAGAIN)
  }

  /// The non-blocking read/write pump. Runs on `queue`. Waits on the socket for
  /// readiness via `poll()`, drains stdout into `onOutput` (main thread), and
  /// flushes pending writes. A short poll so the loop also re-checks for
  /// channel EOF and live-close without ever blocking the owning thread.
  ///
  /// One iteration per call, then re-dispatches itself. Without this the
  /// `while running {}` loop monopolises the serial queue and every later
  /// `queue.async` one-shot op (runCommand for the live SSH cwd refresh, SFTP
  /// upload/download, `close()`) deadlocks forever.
  private func startPump() {
    guard running, !channelGone, let ch = channel else { return }
    pumpOnce(ch)
    if running && !channelGone { queue.async { [weak self] in self?.startPump() } }
  }

  /// A single pump iteration (the old `while running {}` body). May set
  /// `running = false` / `channelGone = true` on terminal conditions; never
  /// loops, so it can run interleaved with one-shot ops on the same queue.
  private func pumpOnce(_ ch: OpaquePointer) {
    guard running, !channelGone else { return }
    // Drive any active local port-forward on this owner thread first, so
    // tunnel I/O is serviced even when the shell channel stays quiet.
    pumpPortForward()

    let socketReady = waitForSocket(socketFD, events: Int16(POLLIN | POLLHUP), timeoutMs: 100)
    let channelReady = libssh2_poll_channel_read(ch, 0) == 1

    if channelReady || socketReady {
      drainOutput(ch)
    }

    if socketReady {
      // POLLHUP/POLLERR means the TCP socket went away.
      var pfd = pollfd(fd: socketFD, events: Int16(POLLIN | POLLHUP), revents: 0)
      _ = poll(&pfd, 1, 0)
      if pfd.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0, !channelGone {
        running = false
        finishOnMain("Connection closed.")
        return
      }
    }

    flushWrites(ch)
    pumpPortForward()
    if libssh2_channel_eof(ch) != 0 {
      handleChannelEOF(ch)
    } else {
      checkLiveClose(ch)
    }
  }

  private func drainOutput(_ ch: OpaquePointer) {
    var buffer = [UInt8](repeating: 0, count: 32768)
    while running {
      let n = libssh2_channel_read_ex(ch, 0, &buffer, buffer.count)
      if n > 0 {
        let data = Data(buffer.prefix(Int(n)))
        DispatchQueue.main.async { [weak self] in
          self?.onOutput?(data)
        }
        continue
      }
      if n == Self.EAGAIN {
        break
      }
      if n == 0 {
        // EOF on the channel. For exec channels, first capture the remote exit
        // status so the subsequent EOF handling knows the command finished
        // cleanly and must NOT blank the terminal.
        completedChannelExitIfNeeded(ch)
        handleChannelEOF(ch)
        break
      }
      // Real error reading.
      finishOnMain(lastErrorText(session!))
      running = false
      break
    }
  }

  private func flushWrites(_ ch: OpaquePointer) {
    writeLock.lock()
    let data = pendingWrite
    pendingWrite.removeAll(keepingCapacity: true)
    writeLock.unlock()
    guard !data.isEmpty else { return }

    var offset = 0
    while offset < data.count {
      let written = data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Int in
        guard let base = buf.baseAddress else { return 0 }
        let ptr = base.assumingMemoryBound(to: UInt8.self).advanced(by: offset)
        return Int(libssh2_channel_write_ex(ch, 0, ptr, data.count - offset))
      }
      if written > 0 {
        offset += written
        continue
      }
      if written == Int(Self.EAGAIN) {
        // Put the unsent remainder back for the next pump iteration.
        writeLock.lock()
        pendingWrite = data.subdata(in: offset..<data.count) + pendingWrite
        writeLock.unlock()
        break
      }
      // Real write error.
      finishOnMain(lastErrorText(session!))
      running = false
      break
    }
  }

  private func handleChannelEOF(_ ch: OpaquePointer) {
    if channelGone { return }
    // For exec channels, capture the remote exit status BEFORE deciding whether
    // to terminate — a command that finished cleanly must NOT blank the
    // terminal. This is called from both drainOutput (EOF) and the pump loop,
    // so it must be idempotent and order-independent.
    if execCommand != nil {
      completedChannelExitIfNeeded(ch)
      if execExitSeen {
        channelGone = true
        return
      }
    }
    channelGone = true
    finishOnMain("Connection closed.")
  }

  private func checkLiveClose(_ ch: OpaquePointer) {
    if libssh2_channel_eof(ch) != 0 && libssh2_channel_wait_closed(ch) == 0 {
      channelGone = true
      finishOnMain("Connection closed.")
    }
  }

  /// For exec channels, once the channel reaches EOF the remote command has
  /// finished; capture the exit status and fire onExit exactly once.
  private func completedChannelExitIfNeeded(_ ch: OpaquePointer) {
    guard execCommand != nil, !execExitSeen else { return }
    execExitSeen = true
    let status = Int32(libssh2_channel_get_exit_status(ch))
    DispatchQueue.main.async { [weak self] in
      self?.onExit?(status)
    }
  }

  // MARK: One-shot exec (second channel)

  private func runOneShotCommand(
    _ sess: OpaquePointer,
    command: String,
    completion: @escaping @Sendable (Result<RemoteCommandResult, Error>) -> Void
  ) {
    let delivered = LockedFlag()

    // Open a second session channel on the same connection.
    guard let ch = openChannel(sess) else {
      DispatchQueue.main.async {
        completion(.failure(EngineError.remoteCommandFailed(self.lastErrorText(sess))))
      }
      return
    }

    let term = "xterm-256color"
    var ptyRc = libssh2_channel_request_pty_ex(ch, term, UInt32(term.utf8.count), nil, 0, 80, 24, 0, 0)
    ptyRc = driveChannel(ptyRc) {
      libssh2_channel_request_pty_ex(ch, term, UInt32(term.utf8.count), nil, 0, 80, 24, 0, 0)
    }
    var execRc = channelProcessStartup(ch, request: "exec", command: command)
    execRc = driveChannel(execRc) { channelProcessStartup(ch, request: "exec", command: command) }
    guard ptyRc == 0, execRc == 0 else {
      DispatchQueue.main.async {
        completion(.failure(EngineError.remoteCommandFailed(self.lastErrorText(sess))))
      }
      _ = libssh2_channel_free(ch)
      return
    }

    var collected = Data()
    let deadline = DispatchTime.now() + .seconds(60)
    var buffer = [UInt8](repeating: 0, count: 32768)
    while DispatchTime.now() < deadline {
      let n = libssh2_channel_read_ex(ch, 0, &buffer, buffer.count)
      if n > 0 {
        collected.append(Data(buffer.prefix(Int(n))))
        continue
      }
      if n == Self.EAGAIN {
        let dirs = libssh2_session_block_directions(sess)
        var pfd = pollfd(fd: socketFD, events: polevents(dirs), revents: 0)
        _ = poll(&pfd, 1, 50)
        continue
      }
      if n == 0 { break }  // EOF
      break
    }

    if libssh2_channel_eof(ch) != 0 {
      _ = libssh2_channel_wait_closed(ch)
    }
    let exitStatus = Int32(libssh2_channel_get_exit_status(ch))
    let out = String(data: collected, encoding: .utf8) ?? ""
    _ = libssh2_channel_free(ch)

    // Deliver exactly once on the main thread. Non-zero remote exit status is
    // NOT a failure (tmux ls exits 1 on "no server running"; command-not-found
    // is 127); the exit status is carried in the payload for callers to
    // interpret, and .failure is reserved for connection/channel problems.
    if delivered.compareAndSet() {
      let result = RemoteCommandResult(stdout: out, exitStatus: exitStatus)
      DispatchQueue.main.async { completion(.success(result)) }
    }
  }

  /// Runs on `queue`. Initializes the SFTP subsystem with the same EAGAIN/poll
  /// retry as every other channel op. In non-blocking mode
  /// `libssh2_sftp_init` opens the "sftp" subsystem channel and can return NULL
  /// with `LIBSSH2_ERROR_EAGAIN` when the channel-open request needs the socket
  /// pumped — especially right after another channel (e.g. the exec used by
  /// `remoteHomeDirectory`) has just opened the same connection. Without the
  /// retry, an SFTP upload right after a remote-home exec fails spuriously with
  /// "Would block starting up channel".
  private func initSFTP(_ sess: OpaquePointer) -> OpaquePointer? {
    var sftp = libssh2_sftp_init(sess)
    let deadline = DispatchTime.now() + .seconds(20)
    while sftp == nil && libssh2_session_last_errno(sess) == Self.EAGAIN && DispatchTime.now() < deadline {
      let dirs = libssh2_session_block_directions(sess)
      var pfd = pollfd(fd: socketFD, events: polevents(dirs), revents: 0)
      _ = poll(&pfd, 1, 50)
      sftp = libssh2_sftp_init(sess)
    }
    return sftp
  }

  /// Runs on `queue`. Opens a remote file for read/write with the EAGAIN/poll
  /// retry. `libssh2_sftp_open_ex` is non-blocking: it can return NULL with a
  /// SESSION-level `LIBSSH2_ERROR_EAGAIN` while the open requests the socket
  /// pumped (this surfaces as `libssh2_sftp_last_error == 0`, which the old code
  /// mis-reported as "SFTP 0"). The EAGAIN is on the session, so retry on
  /// `libssh2_session_last_errno`, not the SFTP error code.
  private func openSFTPFile(_ sftp: OpaquePointer, sess: OpaquePointer, path: String, forWrite: Bool) -> OpaquePointer? {
    let flags: UInt = forWrite
      ? UInt(LIBSSH2_FXF_WRITE) | UInt(LIBSSH2_FXF_CREAT) | UInt(LIBSSH2_FXF_TRUNC)
      : UInt(LIBSSH2_FXF_READ)
    // A mode of 0 would create the file with no permission bits (mode 0000),
    // which then can't be reopened for write on the next drop — a source of
    // spurious LIBSSH2_FX_PERMISSION_DENIED. Use a sane default for creates.
    let mode: Int = forWrite ? 0o644 : 0
    func call() -> OpaquePointer? {
      path.withCString { cstr in
        libssh2_sftp_open_ex(sftp, cstr, UInt32(path.utf8.count), flags, mode, 0)
      }
    }
    var handle = call()
    let deadline = DispatchTime.now() + .seconds(20)
    while handle == nil && libssh2_session_last_errno(sess) == Self.EAGAIN && DispatchTime.now() < deadline {
      let dirs = libssh2_session_block_directions(sess)
      var pfd = pollfd(fd: socketFD, events: polevents(dirs), revents: 0)
      _ = poll(&pfd, 1, 50)
      handle = call()
    }
    return handle
  }

  /// Runs on `queue`. Opens the SFTP subsystem on the authenticated session,
  /// opens `remotePath` for read, streams its bytes with the same EAGAIN/poll
  /// loop every other channel op uses, and delivers the raw bytes on the main
  /// thread. A non-zero libssh2 result is a failure here (unlike one-shot exec,
  /// where a non-zero remote exit status is a normal result).
  private func runSFTPDownload(
    _ sess: OpaquePointer,
    remotePath: String,
    completion: @escaping @Sendable (Result<Data, Error>) -> Void
  ) {
    guard let sftp = initSFTP(sess) else {
      DispatchQueue.main.async {
        completion(.failure(EngineError.remoteCommandFailed(self.lastErrorText(sess))))
      }
      return
    }
    defer { _ = libssh2_sftp_shutdown(sftp) }

    let handle = openSFTPFile(sftp, sess: sess, path: remotePath, forWrite: false)
    guard let handle else {
      let code = libssh2_sftp_last_error(sftp)
      DispatchQueue.main.async {
        completion(.failure(EngineError.remoteCommandFailed("Could not open \(remotePath) (SFTP \(code))")))
      }
      return
    }
    defer { _ = libssh2_sftp_close_handle(handle) }

    var collected = Data()
    var buffer = [UInt8](repeating: 0, count: 32768)
    let deadline = DispatchTime.now() + .seconds(60)
    while DispatchTime.now() < deadline {
      let n = libssh2_sftp_read(handle, &buffer, buffer.count)
      if n > 0 {
        collected.append(Data(buffer.prefix(Int(n))))
        continue
      }
      if n == 0 { break }  // EOF
      if n == Self.EAGAIN {
        // EAGAIN (LIBSSH2_ERROR_EAGAIN = -37). The session is non-blocking and
        // needs a poll before the read can make progress, exactly like the
        // one-shot exec loop above.
        let dirs = libssh2_session_block_directions(sess)
        var pfd = pollfd(fd: socketFD, events: polevents(dirs), revents: 0)
        _ = poll(&pfd, 1, 50)
        continue
      }
      // A negative ssize_t that isn't EAGAIN is a real libssh2 error.
      if n < 0 {
        let code = libssh2_sftp_last_error(sftp)
        DispatchQueue.main.async {
          completion(.failure(EngineError.remoteCommandFailed("SFTP read failed (\(code))")))
        }
        return
      }
      // n is positive but wasn't handled? Treat as unexpected EOF.
      break
    }

    DispatchQueue.main.async { completion(.success(collected)) }
  }

  /// Runs on `queue`. Opens the SFTP subsystem on the authenticated session,
  /// opens `remotePath` for write (create + truncate), streams the local file's
  /// bytes out with the same EAGAIN/poll loop, and completes on the main thread.
  /// A non-zero libssh2 result is a failure here, as in the download path.
  private func runSFTPUpload(
    _ sess: OpaquePointer,
    localURL: URL,
    remotePath: String,
    completion: @escaping @Sendable (Result<Void, Error>) -> Void
  ) {
    guard let sftp = initSFTP(sess) else {
      DispatchQueue.main.async {
        completion(.failure(EngineError.remoteCommandFailed(self.lastErrorText(sess))))
      }
      return
    }
    defer { _ = libssh2_sftp_shutdown(sftp) }

    let handle = openSFTPFile(sftp, sess: sess, path: remotePath, forWrite: true)
    guard let handle else {
      let code = libssh2_sftp_last_error(sftp)
      DispatchQueue.main.async {
        completion(.failure(EngineError.remoteCommandFailed("Could not open \(remotePath) (SFTP \(code))")))
      }
      return
    }
    defer { _ = libssh2_sftp_close_handle(handle) }

    let data: Data
    do {
      data = try Data(contentsOf: localURL)
    } catch {
      DispatchQueue.main.async { completion(.failure(error)) }
      return
    }
    let bytes = [UInt8](data)
    var offset = 0
    let deadline = DispatchTime.now() + .seconds(60)
    while offset < bytes.count && DispatchTime.now() < deadline {
      let written = bytes.withUnsafeBufferPointer { buf -> ssize_t in
        let remaining = bytes.count - offset
        let chunk = Swift.min(32768, remaining)
        return libssh2_sftp_write(handle, buf.baseAddress!.advanced(by: offset), chunk)
      }
      if written > 0 {
        offset += Int(written)
        continue
      }
      if written == Self.EAGAIN {
        let dirs = libssh2_session_block_directions(sess)
        var pfd = pollfd(fd: socketFD, events: polevents(dirs), revents: 0)
        _ = poll(&pfd, 1, 50)
        continue
      }
      if written < 0 {
        let code = libssh2_sftp_last_error(sftp)
        DispatchQueue.main.async {
          completion(.failure(EngineError.remoteCommandFailed("SFTP write failed (\(code))")))
        }
        return
      }
    }

    if offset < bytes.count {
      DispatchQueue.main.async {
        completion(.failure(EngineError.remoteCommandFailed("SFTP write timed out")))
      }
      return
    }
    DispatchQueue.main.async { completion(.success(())) }
  }

  // MARK: Teardown

  /// Idempotent full teardown; must be called on `queue`.
  private func teardownSession() {
    guard let sess = session else { return }

    // Tear down any active local port-forward (its channels are multiplexed on
    // this session, so they MUST be freed before the session is freed).
    forwardLock.lock()
    let forward = portForward
    portForward = nil
    forwardLock.unlock()
    forward?.stop()

    if let ch = channel {
      _ = libssh2_channel_close(ch)
      _ = libssh2_channel_free(ch)
      channel = nil
    }
    libssh2_session_disconnect_ex(sess, SSH_DISCONNECT_BY_APPLICATION, "Application closing", "")
    libssh2_session_free(sess)
    session = nil
    if socketFD >= 0 {
      Darwin.close(socketFD)
      socketFD = -1
    }
    running = false
  }

  // MARK: Helpers

  private func finishOnMain(_ message: String) {
    let m = message
    DispatchQueue.main.async { [weak self] in
      guard let self, self.running || self.channel != nil else { return }
      self.onTerminated?(m)
    }
  }

  private func lastErrorText(_ sess: OpaquePointer) -> String {
    var msg: UnsafeMutablePointer<CChar>?
    var msgLen: Int32 = 0
    _ = libssh2_session_last_error(sess, &msg, &msgLen, 0)
    if let msg { return String(cString: msg) }
    return String(cString: strerror(errno))
  }

  private static func describe(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
  }
}

// MARK: - Secure Enclave sign callback

/// Holds the SE key so the `@convention(c)` sign callback can reach it via
/// `abstract` without capturing a Swift object.
private final class SEKeyRef: @unchecked Sendable {
  let key: SecureEnclave.P256.Signing.PrivateKey
  init(key: SecureEnclave.P256.Signing.PrivateKey) { self.key = key }
}

/// Password box that lets the main-thread prompt write back into the auth loop.
private final class PasswordBox: @unchecked Sendable {
  var password: String?
}

/// A thread-safe exactly-once flag.
private final class LockedFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  func compareAndSet() -> Bool {
    lock.lock(); defer { lock.unlock() }
    if value { return false }
    value = true
    return true
  }
}

/// The `libssh2` external-signer callback. libssh2 hands us the raw bytes to
/// sign (`session_id || userauth request`) and expects a BARE SSH ECDSA sigblob
/// `mpint(r) || mpint(s)` (the algorithm name is added by libssh2's phase-2
/// wrapper). CryptoKit's SecureEnclave signature applies SHA-256 internally.
private let seSignCallback: @convention(c) (
  _ session: OpaquePointer?,
  _ sig: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
  _ sigLen: UnsafeMutablePointer<Int>?,
  _ data: UnsafePointer<UInt8>?,
  _ dataLen: Int,
  _ abstract: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> Int32 = { _, sig, sigLen, data, dataLen, abstract in
  guard let data, dataLen > 0, let sig, let sigLen,
        let abstract, let opaque = abstract.pointee else { return -1 }
  let ref = Unmanaged<SEKeyRef>.fromOpaque(opaque).takeUnretainedValue()
  let msg = Data(bytes: data, count: dataLen)
  do {
    let signature = try ref.key.signature(for: msg)
    let raw = signature.rawRepresentation
    guard raw.count == 64 else { return -1 }
    let r = Data(raw.prefix(32))
    let s = Data(raw.suffix(32))
    var blob = Data()
    blob.append(sshMpint(r))
    blob.append(sshMpint(s))
    let buf = malloc(blob.count)!
    blob.copyBytes(to: buf.assumingMemoryBound(to: UInt8.self), count: blob.count)
    sig.pointee = buf.assumingMemoryBound(to: UInt8.self)
    sigLen.pointee = blob.count
    return 0
  } catch {
    return -1
  }
}

// MARK: - SSH wire helpers

/// Length-prefixed SSH string: UInt32 big-endian length + bytes.
private func sshString(_ data: Data) -> Data {
  var out = Data()
  var length = UInt32(data.count).bigEndian
  out.append(Data(bytes: &length, count: 4))
  out.append(data)
  return out
}

/// SSH mpint (RFC 4251): big-endian two's-complement, minimal length, with a
/// leading 0x00 when the high bit is set so the value stays positive.
private func sshMpint(_ bytes: Data) -> Data {
  // Strip redundant leading zero bytes (keep at least one), then prepend a
  // zero byte when the high bit is set so the signed two's-complement mpint
  // stays positive (RFC 4251 §5). Build the result front-to-back with subdata
  // + an Array — NOT `removeFirst()` + `insert(_:at: 0)` on `Data`: after a
  // `removeFirst()` front-shift, `Data.insert(_, at: 0)` traps in Foundation's
  // `replaceSubrange` (a known Data bug in this SDK), and the Secure Enclave
  // sign callback hits it whenever a stripped ECDSA r/s has its high bit set.
  var start = bytes.startIndex
  let end = bytes.endIndex
  while start < end - 1 && bytes[start] == 0 {
    start += 1
  }
  var payload = [UInt8](bytes.subdata(in: start..<end))
  if let first = payload.first, first & 0x80 != 0 {
    payload.insert(0x00, at: 0)
  }
  return sshString(Data(payload))
}
