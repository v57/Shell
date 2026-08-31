import Crypto
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSH

/// Owns a single NIO SSH connection for one remote terminal session.
///
/// All NIO work happens on the engine's private event loop; every callback
/// (`onOutput`, `onConnected`, `onTerminated`, the host-key/password
/// challenges) is invoked on the main thread so the UI can react directly.
nonisolated final class SSHConnectionEngine: @unchecked Sendable {
  /// A request to the UI to verify an unknown host key.
  struct HostKeyChallenge {
    let hostKey: NIOSSHPublicKey
    let fingerprint: String
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
    /// The connection is not open (no live parent channel to multiplex on).
    case notConnected
    /// A one-shot remote exec (persistent-session scan) failed at the
    /// connection/channel level. The remote command's own non-zero exit is
    /// NOT folded into this — callers interpret the captured stdout.
    case remoteCommandFailed(String)

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
      }
    }
  }
  
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
  /// multiplex `direct-tcpip` (port-forward) channels, so it carries no
  /// remote shell/exec. `onConnected` fires once SSH authentication succeeds.
  private let forwardingOnly: Bool
  private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  private let knownHosts = KnownHostsStore()

  private let channelBox = NIOLockedValueBox<Channel?>(nil)
  private let childChannelBox = NIOLockedValueBox<Channel?>(nil)
  private let sizeBox = NIOLockedValueBox<(columns: Int, rows: Int)>((columns: 80, rows: 24))
  /// Set once an exec channel reports its exit status; the channel then
  /// closes on its own, and that close must NOT surface as an error.
  private let execExitSeen = NIOLockedValueBox(false)
  /// The active local port-forward (web / remote tunnel), if any. Kept here so
  /// teardown is tied to this engine's lifecycle.
  private let localPortForward = NIOLockedValueBox<SSHLocalPortForward?>(nil)

  init(config: SSHConfig, privateKey: SecureEnclave.P256.Signing.PrivateKey?, execCommand: String? = nil, forwardingOnly: Bool = false) {
    self.config = config
    self.privateKey = privateKey
    self.execCommand = execCommand
    self.forwardingOnly = forwardingOnly
  }
  
  deinit {
    // Best-effort cleanup if close() was never called.
    let group = self.group
    group.shutdownGracefully { _ in }
  }
  
  // MARK: Public API (main thread)
  
  func start() {
    let isForwarding = forwardingOnly
    let userAuth = UserAuthDelegate(
      username: config.user,
      privateKey: privateKey,
      preferKey: config.authMethod == .keychainKey,
      savedPassword: config.savePassword
      ? (try? SSHKeychain.loadPassword(account: config.passwordAccount)) ?? nil
      : nil,
      onPasswordChallenge: { [weak self] challenge in
        DispatchQueue.main.async {
          self?.onPasswordChallenge?(challenge)
        }
      }
    )
    let serverAuth = ServerAuthDelegate(
      host: config.host,
      port: config.port,
      knownHosts: knownHosts,
      onChallenge: { [weak self] challenge in
        DispatchQueue.main.async {
          self?.onHostKeyChallenge?(challenge)
        }
      }
    )
    
    let bootstrap = ClientBootstrap(group: group)
      .channelInitializer { channel in
        channel.eventLoop.makeCompletedFuture {
          let sshHandler = NIOSSHHandler(
            role: .client(
              .init(
                userAuthDelegate: userAuth,
                serverAuthDelegate: serverAuth
              )
            ),
            allocator: channel.allocator,
            inboundChildChannelInitializer: nil
          )
          try channel.pipeline.syncOperations.addHandler(sshHandler)
          try channel.pipeline.syncOperations.addHandler(ParentErrorHandler(
            onError: { [weak self] message in
              DispatchQueue.main.async {
                self?.fail(message)
              }
            },
            // A forwarding session has no session channel, so a clean parent
            // close must still surface the connection as gone.
            onInactive: isForwarding ? { [weak self] in
              DispatchQueue.main.async {
                self?.fail("Connection closed.")
              }
            } : nil
          ))
          // Port-forward-only sessions open no session channel, so there is no
          // `openChannel -> onConnected` path; signal readiness instead once
          // SSH authentication completes (the moment the connection can
          // multiplex direct-tcpip channels).
          if isForwarding {
            try channel.pipeline.syncOperations.addHandler(ForwardingReadyHandler(onReady: { [weak self] in
              DispatchQueue.main.async {
                self?.onConnected?()
              }
            }))
          }
        }
      }
      .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
    
    let eventLoop = group.next()
    let result = eventLoop.makePromise(of: Channel.self)
    let timeoutTask = eventLoop.scheduleTask(in: .seconds(20)) {
      result.fail(EngineError.connectTimedOut)
    }
    bootstrap.connect(host: config.host, port: config.port).cascade(to: result)
    result.futureResult.whenComplete { [weak self] outcome in
      timeoutTask.cancel()
      switch outcome {
      case .success(let channel):
        self?.channelBox.withLockedValue { $0 = channel }
        if self?.forwardingOnly == true {
          // No session channel for a port-forward-only connection. The
          // ForwardingReadyHandler fires onConnected once auth completes.
          return
        }
        self?.openChannel(on: channel, execCommand: self?.execCommand)
      case .failure(let error):
        DispatchQueue.main.async {
          self?.fail(error.localizedDescription)
        }
      }
    }
  }
  
  func write(_ data: Data) {
    guard !data.isEmpty else { return }
    guard let child = childChannelBox.withLockedValue({ $0 }) else { return }
    let buffer = ByteBuffer(bytes: data)
    child.writeAndFlush(buffer, promise: nil)
  }
  
  func resize(columns: Int, rows: Int) {
    sizeBox.withLockedValue { $0 = (columns, rows) }
    guard let child = childChannelBox.withLockedValue({ $0 }) else { return }
    let request = SSHChannelRequestEvent.WindowChangeRequest(
      terminalCharacterWidth: columns,
      terminalRowHeight: rows,
      terminalPixelWidth: 0,
      terminalPixelHeight: 0
    )
    child.triggerUserOutboundEvent(request, promise: nil)
  }
  
  func close() {
    stopLocalPortForward()
    let child = childChannelBox.withLockedValue { channel in
      let value = channel
      channel = nil
      return value
    }
    let parent = channelBox.withLockedValue { channel in
      let value = channel
      channel = nil
      return value
    }
    child?.close(promise: nil)
    parent?.close(promise: nil)
    group.shutdownGracefully { _ in }
  }

  // MARK: Local port-forward (web session + remote Database tunnel)
  //
  // Reuses the SAME authenticated connection — no new SSH dial or
  // authentication. The reusable `SSHLocalPortForward` bridges an in-app
  // local port to remote `targetHost:targetPort` over `direct-tcpip`
  // channels multiplexed on the parent channel, independent of this engine's
  // shell/exec session channel.

  /// Starts a local port-forward over this (already-authenticated) connection.
  /// Resolves to the bound LOCAL port once the listener is up; on failure the
  /// error is surfaced on the main thread via `completion` AND `onTerminated`
  /// (so a dropping tunnel still replaces a blank page with a message).
  func startLocalPortForward(
    bindHost: String = "127.0.0.1",
    bindPort: Int = 0,
    targetHost: String,
    targetPort: Int,
    completion: @escaping @Sendable (Result<Int, Error>) -> Void
  ) {
    guard let parent = channelBox.withLockedValue({ $0 }) else {
      DispatchQueue.main.async { completion(.failure(EngineError.notConnected)) }
      return
    }
    // A reconnect may start a fresh tunnel over the same live connection.
    localPortForward.withLockedValue { $0 }?.close()
    let tunnel = SSHLocalPortForward(parentChannel: parent) { [weak self] message in
      DispatchQueue.main.async { self?.fail(message) }
    }
    localPortForward.withLockedValue { $0 = tunnel }
    let config = SSHLocalPortForward.Config(
      bindHost: bindHost,
      bindPort: bindPort,
      targetHost: targetHost,
      targetPort: targetPort
    )
    tunnel.start(config: config).whenComplete { result in
      DispatchQueue.main.async {
        switch result {
        case .success(let port):
          completion(.success(port))
        case .failure(let error):
          completion(.failure(error))
        }
      }
    }
  }

  /// Closes the local port-forward (if any). The connection's session channel
  /// is not affected.
  func stopLocalPortForward() {
    localPortForward.withLockedValue { $0 }?.close()
    localPortForward.withLockedValue { $0 = nil }
  }

  // MARK: One-shot remote exec (persistent-session scan)

  /// Runs a one-shot `command` on the ALREADY-OPEN connection by opening a
  /// second session channel (SSH channels multiplex over one TCP/SSH
  /// connection), leaving the interactive session's channel untouched. This
  /// is the remote persistent-session scanner path: it reuses the live
  /// connection so no throwaway SSH dial is made just to list a host's
  /// screen/tmux sessions.
  ///
  /// `completion` is invoked exactly once, on the main thread. A non-zero
  /// REMOTE exec status is not surfaced as a `.failure`: listing commands
  /// like `tmux ls` exit 1 on the normal "no server running" case, and
  /// `command not found` (exit 127) is the absence case — callers interpret
  /// the captured stdout. `.failure` is reserved for connection/channel-level
  /// problems (e.g. the connection closed under us, or no live channel).
  func runRemoteCommand(_ command: String, completion: @escaping @Sendable (Result<String, Error>) -> Void) {
    guard let parent = channelBox.withLockedValue({ $0 }) else {
      DispatchQueue.main.async { completion(.failure(EngineError.notConnected)) }
      return
    }
    parent.eventLoop.execute {
      guard let sshHandler = try? parent.pipeline.syncOperations.handler(type: NIOSSHHandler.self) else {
        DispatchQueue.main.async { completion(.failure(EngineError.remoteCommandFailed("SSH handler not found on channel."))) }
        return
      }
      let promise = parent.eventLoop.makePromise(of: Channel.self)
      let finished = NIOLockedValueBox(false)
      let collected = NIOLockedValueBox(Data())
      // Deliver exactly once, on the main thread. Both the exit-status and
      // the close paths race (the channel sends exit status then closes);
      // whichever fires first wins, and it has the full stdout by then
      // (channel data is ordered ahead of the exit-status event).
      let deliverOnce: @Sendable (Result<String, Error>) -> Void = { result in
        var shouldDeliver = false
        finished.withLockedValue { flag in
          if !flag { flag = true; shouldDeliver = true }
        }
        if shouldDeliver {
          DispatchQueue.main.async { completion(result) }
        }
      }
      sshHandler.createChannel(promise, channelType: .session) { childChannel, _ in
        childChannel.eventLoop.makeCompletedFuture {
          let handler = ShellDataHandler(
            onData: { data in
              collected.withLockedValue { $0.append(data) }
            },
            onClose: {
              deliverOnce(.success(String(data: collected.withLockedValue { $0 }, encoding: .utf8) ?? ""))
            },
            onError: { message in
              deliverOnce(.failure(EngineError.remoteCommandFailed(message)))
            },
            onExitStatus: { _ in
              deliverOnce(.success(String(data: collected.withLockedValue { $0 }, encoding: .utf8) ?? ""))
            }
          )
          try childChannel.pipeline.syncOperations.addHandler(handler)
          let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: 80,
            terminalRowHeight: 24,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
          )
          childChannel.triggerUserOutboundEvent(pty, promise: nil)
          childChannel.triggerUserOutboundEvent(
            SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true),
            promise: nil
          )
        }
      }
      promise.futureResult.whenFailure { error in
        deliverOnce(.failure(error))
      }
    }
  }

  // MARK: Channel setup
  
  /// Opens the session's single channel: PTY + shell for normal sessions,
  /// PTY + exec for action sessions (execCommand non-nil). The pty is
  /// requested in BOTH cases so remote output renders like a terminal
  /// and Ctrl+C (ISIG) works over the wire.
  private func openChannel(on channel: Channel, execCommand: String?) {
    let size = sizeBox.withLockedValue { $0 }
    let isExec = execCommand != nil
    channel.eventLoop.execute {
      guard let sshHandler = try? channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self) else {
        DispatchQueue.main.async { [weak self] in
          self?.fail("SSH handler not found.")
        }
        return
      }
      
      let promise = channel.eventLoop.makePromise(of: Channel.self)
      sshHandler.createChannel(promise, channelType: .session) { childChannel, _ in
        childChannel.eventLoop.makeCompletedFuture { [weak self] in
          let handler = ShellDataHandler(
            onData: { [weak self] data in
              DispatchQueue.main.async {
                self?.onOutput?(data)
              }
            },
            onClose: { [weak self] in
              DispatchQueue.main.async {
                guard let self else { return }
                // Exec channels close right after reporting their exit
                // status — that close is expected and must NOT blank the
                // terminal (remoteTerminated replaces the snapshot). A
                // close without a prior exit status is a real error.
                if isExec, self.execExitSeen.withLockedValue({ $0 }) { return }
                self.terminate("Connection closed.")
              }
            },
            onError: { [weak self] message in
              DispatchQueue.main.async {
                self?.fail(message)
              }
            },
            onExitStatus: isExec ? { [weak self] status in
              self?.execExitSeen.withLockedValue { $0 = true }
              DispatchQueue.main.async {
                self?.onExit?(status)
              }
            } : nil
          )
          try childChannel.pipeline.syncOperations.addHandler(handler)
          self?.childChannelBox.withLockedValue { $0 = childChannel }
          
          // Request a PTY, then either a shell or the action's exec.
          let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: size.columns,
            terminalRowHeight: size.rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
          )
          childChannel.triggerUserOutboundEvent(pty, promise: nil)
          if let execCommand {
            childChannel.triggerUserOutboundEvent(
              SSHChannelRequestEvent.ExecRequest(command: execCommand, wantReply: true),
              promise: nil
            )
          } else {
            childChannel.triggerUserOutboundEvent(
              SSHChannelRequestEvent.ShellRequest(wantReply: true),
              promise: nil
            )
          }
          DispatchQueue.main.async { [weak self] in
            self?.onConnected?()
          }
        }
      }
      promise.futureResult.whenFailure { error in
        DispatchQueue.main.async { [weak self] in
          self?.fail(error.localizedDescription)
        }
      }
    }
  }
  
  private func terminate(_ message: String) {
    onTerminated?(message)
  }
  
  private func fail(_ message: String) {
    onTerminated?(message)
  }
}

// MARK: - Host key validation

private final class ServerAuthDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
  private let host: String
  private let port: Int
  private let knownHosts: KnownHostsStore
  private let onChallenge: @Sendable (SSHConnectionEngine.HostKeyChallenge) -> Void
  
  init(
    host: String,
    port: Int,
    knownHosts: KnownHostsStore,
    onChallenge: @escaping @Sendable (SSHConnectionEngine.HostKeyChallenge) -> Void
  ) {
    self.host = host
    self.port = port
    self.knownHosts = knownHosts
    self.onChallenge = onChallenge
  }
  
  nonisolated func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
    let fingerprint = SSHKeychain.fingerprint(of: hostKey)
    
    if knownHosts.fingerprint(for: host, port: port) == fingerprint {
      validationCompletePromise.succeed()
      return
    }
    
    let respond: @Sendable (Bool) -> Void = { [knownHosts, host, port] accept in
      if accept {
        knownHosts.save(fingerprint: fingerprint, host: host, port: port)
        validationCompletePromise.succeed()
      } else {
        validationCompletePromise.fail(SSHConnectionEngine.EngineError.hostKeyRejected)
      }
    }
    DispatchQueue.main.async { [onChallenge] in
      onChallenge(.init(hostKey: hostKey, fingerprint: fingerprint, respond: respond))
    }
  }
}

// MARK: - User authentication

private final class UserAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
  private let username: String
  private let privateKey: SecureEnclave.P256.Signing.PrivateKey?
  private let preferKey: Bool
  private let savedPassword: String?
  private let onPasswordChallenge: @Sendable (SSHConnectionEngine.PasswordChallenge) -> Void
  private let attemptCount = NIOLockedValueBox(0)
  
  init(
    username: String,
    privateKey: SecureEnclave.P256.Signing.PrivateKey?,
    preferKey: Bool,
    savedPassword: String?,
    onPasswordChallenge: @escaping @Sendable (SSHConnectionEngine.PasswordChallenge) -> Void
  ) {
    self.username = username
    self.privateKey = privateKey
    self.preferKey = preferKey
    self.savedPassword = savedPassword
    self.onPasswordChallenge = onPasswordChallenge
  }
  
  nonisolated func nextAuthenticationType(
    availableMethods: NIOSSHAvailableUserAuthenticationMethods,
    nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
  ) {
    let username = self.username
    let attempt = attemptCount.withLockedValue { count in
      count += 1
      return count
    }
    
    // Attempt 1: the app's Secure Enclave key.
    if attempt == 1, preferKey, availableMethods.contains(.publicKey), let privateKey {
      let offer = NIOSSHUserAuthenticationOffer(
        username: username,
        serviceName: "",
        offer: .privateKey(.init(privateKey: NIOSSHPrivateKey(secureEnclaveP256Key: privateKey)))
      )
      nextChallengePromise.succeed(offer)
      return
    }
    
    // Subsequent attempts: password (saved one first, then prompt).
    if availableMethods.contains(.password) {
      if attempt == 2, let savedPassword {
        let offer = NIOSSHUserAuthenticationOffer(
          username: username,
          serviceName: "",
          offer: .password(.init(password: savedPassword))
        )
        nextChallengePromise.succeed(offer)
        return
      }
      
      let respond: @Sendable (String?) -> Void = { password in
        if let password {
          let offer = NIOSSHUserAuthenticationOffer(
            username: username,
            serviceName: "",
            offer: .password(.init(password: password))
          )
          nextChallengePromise.succeed(offer)
        } else {
          nextChallengePromise.fail(SSHConnectionEngine.EngineError.authenticationCancelled)
        }
      }
      DispatchQueue.main.async { [onPasswordChallenge, username] in
        onPasswordChallenge(.init(username: username, respond: respond))
      }
      return
    }
    
    nextChallengePromise.fail(SSHConnectionEngine.EngineError.noAvailableAuthenticationMethods)
  }
}

// MARK: - Channel handlers

/// Converts between ByteBuffers (from the terminal) and SSHChannelData, and
/// forwards remote output back to the engine. For exec channels it also
/// captures the remote command's exit status (SSHChannelRequestEvent.
/// ExitStatusRequest arrives as an inbound channel event).
private final class ShellDataHandler: ChannelDuplexHandler {
  typealias InboundIn = SSHChannelData
  typealias InboundOut = ByteBuffer
  typealias OutboundIn = ByteBuffer
  typealias OutboundOut = SSHChannelData
  
  private let onData: @Sendable (Data) -> Void
  private let onClose: @Sendable () -> Void
  private let onError: @Sendable (String) -> Void
  private let onExitStatus: (@Sendable (Int32) -> Void)?
  
  init(
    onData: @escaping @Sendable (Data) -> Void,
    onClose: @escaping @Sendable () -> Void,
    onError: @escaping @Sendable (String) -> Void,
    onExitStatus: (@Sendable (Int32) -> Void)? = nil
  ) {
    self.onData = onData
    self.onClose = onClose
    self.onError = onError
    self.onExitStatus = onExitStatus
  }
  
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let channelData = unwrapInboundIn(data)
    guard channelData.type == .channel, case .byteBuffer(let buffer) = channelData.data else {
      context.fireChannelRead(data)
      return
    }
    let bytes = Data(buffer.readableBytesView)
    if !bytes.isEmpty {
      onData(bytes)
    }
  }
  
  func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
    let buffer = unwrapOutboundIn(data)
    let wrapped = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
    context.write(wrapOutboundOut(wrapped), promise: promise)
  }
  
  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    if let exit = event as? SSHChannelRequestEvent.ExitStatus {
      onExitStatus?(Int32(exit.exitStatus))
    }
    context.fireUserInboundEventTriggered(event)
  }
  
  func channelInactive(context: ChannelHandlerContext) {
    onClose()
    context.fireChannelInactive()
  }
  
  func errorCaught(context: ChannelHandlerContext, error: Error) {
    onError(error.localizedDescription)
    context.fireErrorCaught(error)
  }
}

/// Catches errors on the parent (TCP/SSH) channel, e.g. authentication failures.
/// For port-forward-only sessions it also reports a CLEAN close (channel
/// inactive) — such a session has no session channel to report closure, so the
/// parent close is the only teardown signal.
private final class ParentErrorHandler: ChannelInboundHandler {
  typealias InboundIn = Any
  
  private let onError: @Sendable (String) -> Void
  private let onInactive: (@Sendable () -> Void)?
  
  init(onError: @escaping @Sendable (String) -> Void, onInactive: (@Sendable () -> Void)? = nil) {
    self.onError = onError
    self.onInactive = onInactive
  }
  
  func errorCaught(context: ChannelHandlerContext, error: Error) {
    onError(error.localizedDescription)
    context.fireErrorCaught(error)
  }
  
  func channelInactive(context: ChannelHandlerContext) {
    onInactive?()
    context.fireChannelInactive()
  }
}

/// Signals when a port-forward-only connection finishes SSH authentication.
/// The engine opens no session channel for such a connection, so there is no
/// `openChannel -> onConnected` path; this handler watches for the
/// `UserAuthSuccessEvent` (fired by NIOSSH once the server accepts auth) and
/// reports readiness — the point at which `direct-tcpip` channels can be
/// multiplexed.
private final class ForwardingReadyHandler: ChannelInboundHandler {
  typealias InboundIn = Any
  
  private let onReady: @Sendable () -> Void
  
  init(onReady: @escaping @Sendable () -> Void) {
    self.onReady = onReady
  }
  
  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    if event is UserAuthSuccessEvent {
      onReady()
    }
    context.fireUserInboundEventTriggered(event)
  }
}
