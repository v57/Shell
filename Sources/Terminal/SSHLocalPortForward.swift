import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSH

/// A reusable SSH local port-forward ("direct-tcpip") that bridges an
/// in-app `127.0.0.1` listener to a remote `host:port` over an
/// **already-authenticated** SSH connection.
///
/// The parent SSH `Channel` is supplied by the caller (e.g. a live
/// `SSHConnectionEngine`). This utility NEVER dials a new connection or
/// re-authenticates — it multiplexes fresh `direct-tcpip` channels over the
/// shared inbound SSH transport, exactly like an `ssh -L` forward. Each
/// accepted local connection is glued to its own SSH channel; the
/// bidirectional byte-bridge lives entirely inside this class, so the same
/// helper can be reused verbatim by the web-kind session and later by the
/// remote Database tunnel card.
nonisolated public final class SSHLocalPortForward: @unchecked Sendable {
  /// The tunnel's bind + remote target.
  public struct Config: Sendable {
    public var bindHost: String
    /// 0 = let the OS pick an ephemeral free port.
    public var bindPort: Int
    public var targetHost: String
    public var targetPort: Int

    public init(
      bindHost: String = "127.0.0.1",
      bindPort: Int = 0,
      targetHost: String,
      targetPort: Int
    ) {
      self.bindHost = bindHost
      self.bindPort = bindPort
      self.targetHost = targetHost
      self.targetPort = targetPort
    }
  }

  public enum ForwardError: LocalizedError {
    case notConnected
    case handlerNotFound
    case invalidChannelType
    case bindFailed(String)

    public var errorDescription: String? {
      switch self {
      case .notConnected:
        return "The SSH connection is not open."
      case .handlerNotFound:
        return "The SSH handler was not found on the connection."
      case .invalidChannelType:
        return "The SSH channel was not a direct-tcpip channel."
      case .bindFailed(let message):
        return "Could not bind the local port: \(message)"
      }
    }
  }

  private let parentChannel: Channel
  /// A dedicated event-loop group for the local listener + accepted
  /// connections, isolated from the SSH connection's event loop so a busy
  /// tunnel never stalls SSH I/O.
  private let group: EventLoopGroup
  private let serverBox = NIOLockedValueBox<Channel?>(nil)
  private let tunnelBox = NIOLockedValueBox<[Channel]>([])
  private let onError: @Sendable (String) -> Void

  /// - Parameters:
  ///   - parentChannel: the live, authenticated SSH parent channel
  ///     (multiplexed over by every `direct-tcpip` channel).
  ///   - onError: invoked (on the main thread) when the tunnel cannot be
  ///     established or drops — used to surface a user-facing error.
  public init(
    parentChannel: Channel,
    onError: @escaping @Sendable (String) -> Void
  ) {
    self.parentChannel = parentChannel
    self.onError = onError
    self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  }

  /// Binds the local listener and resolves to the bound local port once the
  /// server is accepting connections. On failure the error is delivered via
  /// the returned future AND `onError` (so the caller can surface it even if
  /// it does not hold onto the returned future).
  public func start(config: Config) -> EventLoopFuture<Int> {
    let promise = group.next().makePromise(of: Int.self)
    ServerBootstrap(group: group)
      .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
      .childChannelInitializer { [weak self] inbound in
        guard let self else {
          return inbound.eventLoop.makeFailedFuture(ForwardError.notConnected)
        }
        return self.forward(inbound, config: config)
      }
      .bind(host: config.bindHost, port: config.bindPort)
      .whenComplete { result in
        switch result {
        case .success(let server):
          self.serverBox.withLockedValue { $0 = server }
          guard let port = server.localAddress?.port, port > 0 else {
            self.onError(ForwardError.bindFailed("no local address").localizedDescription)
            promise.fail(ForwardError.bindFailed("no local address"))
            return
          }
          promise.succeed(port)
        case .failure(let error):
          self.onError("Could not open SSH port-forward: \(error.localizedDescription)")
          promise.fail(error)
        }
      }
    return promise.futureResult
  }

  /// Closes the local listener and every open tunnel channel, then shuts down
  /// this instance's event-loop group. Best-effort (fires each close without
  /// waiting) so it can be called from a synchronous teardown path.
  public func close() {
    let server = serverBox.withLockedValue { channel -> Channel? in
      let value = channel
      channel = nil
      return value
    }
    let tunnels = tunnelBox.withLockedValue { channels -> [Channel] in
      let value = channels
      channels = []
      return value
    }
    server?.close(promise: nil)
    for tunnel in tunnels {
      tunnel.close(promise: nil)
    }
    group.shutdownGracefully { _ in }
  }

  // MARK: - Connection bridging

  /// Bridges one accepted local connection to a fresh SSH `direct-tcpip`
  /// channel. Runs the SSH side on the parent channel's event loop (NIO
  /// requires SSH channel creation there) and the local side on its own
  /// loop, gluing the two with a byte-bridge. The returned future completes
  /// only once BOTH sides are wired, gating the accepted channel's reads
  /// until then.
  private func forward(_ inbound: Channel, config: Config) -> EventLoopFuture<Void> {
    let direct = SSHChannelType.DirectTCPIP(
      targetHost: config.targetHost,
      targetPort: config.targetPort,
      originatorAddress: Self.originatorAddress(for: inbound)
    )

    let wired = inbound.eventLoop.makePromise(of: Void.self)
    let sshChannelPromise = inbound.eventLoop.makePromise(of: Channel.self)

    // Once the SSH channel exists, track it for clean teardown.
    sshChannelPromise.futureResult.whenSuccess { [weak self] child in
      self?.tunnelBox.withLockedValue { $0.append(child) }
    }
    // A failure here means the remote could not be reached (or auth/close
    // raced us) — surface it so the WebView area can show an error instead
    // of a dead page.
    sshChannelPromise.futureResult.whenFailure { [weak self] error in
      self?.onError(
        "SSH tunnel to \(config.targetHost):\(config.targetPort) failed: \(error.localizedDescription)")
      wired.fail(error)
    }

    // All SSH channel creation MUST happen on the parent channel's loop.
    parentChannel.eventLoop.execute { [weak self] in
      guard let self else {
        sshChannelPromise.fail(ForwardError.notConnected)
        return
      }
      guard let sshHandler = try? self.parentChannel.pipeline.syncOperations.handler(type: NIOSSHHandler.self) else {
        sshChannelPromise.fail(ForwardError.handlerNotFound)
        return
      }
      sshHandler.createChannel(sshChannelPromise, channelType: .directTCPIP(direct)) { child, channelType in
        guard case .directTCPIP = channelType else {
          return child.eventLoop.makeFailedFuture(ForwardError.invalidChannelType)
        }
        // One shared gate that resolves only once BOTH sides are glued. The
        // createChannel initializer runs on the child (SSH) channel's loop, so
        // the SSH-side handlers are added synchronously here; the local side
        // must be wired on its own loop.
        let bothWired = child.eventLoop.makePromise(of: Void.self)
        let (ours, theirs) = GlueHandler.matchedPair()
        do {
          try child.pipeline.syncOperations.addHandler(SSHDataWrapper())
          try child.pipeline.syncOperations.addHandler(ours)
        } catch {
          bothWired.fail(error)
          return child.eventLoop.makeFailedFuture(error)
        }
        inbound.eventLoop.execute {
          do {
            try inbound.pipeline.syncOperations.addHandler(theirs)
            bothWired.succeed(())
          } catch {
            child.close(promise: nil)
            bothWired.fail(error)
          }
        }
        // Reflect the shared gate onto the local accepted channel's read gate.
        bothWired.futureResult.whenComplete { result in
          switch result {
          case .success: wired.succeed(())
          case .failure(let error): wired.fail(error)
          }
        }
        // Returning this future keeps the SSH child channel from activating
        // (and thus from streaming remote data) until the bridge is fully
        // installed on BOTH sides.
        return bothWired.futureResult
      }
    }
    return wired.futureResult
  }

  private static func originatorAddress(for channel: Channel) -> SocketAddress {
    if let remote = channel.remoteAddress { return remote }
    if let local = channel.localAddress { return local }
    // Last resort: a valid loopback v4 originator. An accepted TCP connection
    // always has a remote address, so this arm is effectively dead; `try!` is
    // safe because the literal loopback address is always encodable.
    return try! SocketAddress(ipAddress: "127.0.0.1", port: 0)
  }
}

/// Converts between `SSHChannelData` (on the wire) and raw `ByteBuffer`
/// (what the local side and the glue handler speak). Mirrors the Shell app's
/// `ShellDataHandler` but for tunnel channels (no PTY/exit-status handling).
private final class SSHDataWrapper: ChannelDuplexHandler {
  typealias InboundIn = SSHChannelData
  typealias InboundOut = ByteBuffer
  typealias OutboundIn = ByteBuffer
  typealias OutboundOut = SSHChannelData

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let channelData = unwrapInboundIn(data)
    guard channelData.type == .channel, case .byteBuffer(let buffer) = channelData.data else {
      context.fireErrorCaught(SSHDataWrapperError.invalidData)
      return
    }
    context.fireChannelRead(wrapInboundOut(buffer))
  }

  func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
    let buffer = unwrapOutboundIn(data)
    context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: promise)
  }
}

private enum SSHDataWrapperError: Error {
  case invalidData
}

/// Bidirectional byte-bridge that pipes each side's reads to the other side's
/// writes, propagating close/EOF/error in both directions. Copied from the
/// swift-nio-ssh example server (the library publishes it only in its example
/// executable target, not the `NIOSSH` product, so it must live here).
private final class GlueHandler {
  private var partner: GlueHandler?
  private var context: ChannelHandlerContext?
  private var pendingRead = false

  private init() {}

  static func matchedPair() -> (GlueHandler, GlueHandler) {
    let first = GlueHandler()
    let second = GlueHandler()
    first.partner = second
    second.partner = first
    return (first, second)
  }
}

extension GlueHandler {
  private func partnerWrite(_ data: NIOAny) {
    context?.write(data, promise: nil)
  }

  private func partnerFlush() {
    context?.flush()
  }

  private func partnerWriteEOF() {
    context?.close(mode: .output, promise: nil)
  }

  private func partnerCloseFull() {
    context?.close(promise: nil)
  }

  private func partnerBecameWritable() {
    if pendingRead {
      pendingRead = false
      context?.read()
    }
  }

  private var partnerWritable: Bool {
    context?.channel.isWritable ?? false
  }
}

extension GlueHandler: ChannelDuplexHandler {
  typealias InboundIn = NIOAny
  typealias OutboundIn = NIOAny
  typealias OutboundOut = NIOAny

  func handlerAdded(context: ChannelHandlerContext) {
    self.context = context
    if context.channel.isWritable {
      partner?.partnerBecameWritable()
    }
  }

  func handlerRemoved(context: ChannelHandlerContext) {
    self.context = nil
    partner = nil
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    partner?.partnerWrite(data)
  }

  func channelReadComplete(context: ChannelHandlerContext) {
    partner?.partnerFlush()
  }

  func channelInactive(context: ChannelHandlerContext) {
    partner?.partnerCloseFull()
  }

  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    if let event = event as? ChannelEvent, case .inputClosed = event {
      partner?.partnerWriteEOF()
    }
  }

  func errorCaught(context: ChannelHandlerContext, error: Error) {
    partner?.partnerCloseFull()
  }

  func channelWritabilityChanged(context: ChannelHandlerContext) {
    if context.channel.isWritable {
      partner?.partnerBecameWritable()
    }
  }

  func read(context: ChannelHandlerContext) {
    if let partner, partner.partnerWritable {
      context.read()
    } else {
      pendingRead = true
    }
  }
}
