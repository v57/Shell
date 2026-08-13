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
  private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  private let knownHosts = KnownHostsStore()
  
  private let channelBox = NIOLockedValueBox<Channel?>(nil)
  private let childChannelBox = NIOLockedValueBox<Channel?>(nil)
  private let sizeBox = NIOLockedValueBox<(columns: Int, rows: Int)>((columns: 80, rows: 24))
  /// Set once an exec channel reports its exit status; the channel then
  /// closes on its own, and that close must NOT surface as an error.
  private let execExitSeen = NIOLockedValueBox(false)
  
  init(config: SSHConfig, privateKey: SecureEnclave.P256.Signing.PrivateKey?, execCommand: String? = nil) {
    self.config = config
    self.privateKey = privateKey
    self.execCommand = execCommand
  }
  
  deinit {
    // Best-effort cleanup if close() was never called.
    let group = self.group
    group.shutdownGracefully { _ in }
  }
  
  // MARK: Public API (main thread)
  
  func start() {
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
          try channel.pipeline.syncOperations.addHandler(ParentErrorHandler(onError: { [weak self] message in
            DispatchQueue.main.async {
              self?.fail(message)
            }
          }))
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
private final class ParentErrorHandler: ChannelInboundHandler {
  typealias InboundIn = Any
  
  private let onError: @Sendable (String) -> Void
  
  init(onError: @escaping @Sendable (String) -> Void) {
    self.onError = onError
  }
  
  func errorCaught(context: ChannelHandlerContext, error: Error) {
    onError(error.localizedDescription)
    context.fireErrorCaught(error)
  }
}
