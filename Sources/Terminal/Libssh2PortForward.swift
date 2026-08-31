import CLibssh2
import Darwin
import Foundation

/// A reusable SSH local port-forward ("direct-tcpip") that bridges one or more
/// in-app `bindHost:bindPort` listeners to remote `targetHost:targetPort`
/// over an **already-authenticated** libssh2 connection.
///
/// This helper NEVER dials a new connection or re-authenticates — it
/// multiplexes fresh `direct-tcpip` channels over the shared inbound SSH
/// transport, exactly like an `ssh -L` forward. Each accepted local connection
/// is glued to its own SSH channel.
///
/// # Thread safety (libssh2 is NOT thread-safe per session)
/// libssh2 requires ONE OS thread to own a session. Every libssh2 channel call
/// (open / read / write / eof / send_eof / close / free) happens on the session's
/// owner thread. This helper splits the work accordingly:
///
/// - The **listener queue** binds the local socket and `accept()`s inbound local
///   connections. It never touches libssh2; accepted sockets are handed off by
///   queueing their FDs.
/// - The **owner thread** (the caller's session-owning loop) calls `pump(...)`
///   on every tick. `pump` drains the queued FDs, opens a `direct-tcpip` channel
///   for each, and bridges bytes both ways. All libssh2 calls happen only here.
nonisolated final class Libssh2PortForward: @unchecked Sendable {
  /// The tunnel's bind + remote target.
  struct Config: Sendable {
    var bindHost: String
    /// 0 = let the OS pick an ephemeral free port.
    var bindPort: Int
    var targetHost: String
    var targetPort: Int

    init(
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

  enum ForwardError: LocalizedError {
    case notConnected
    case bindFailed(String)
    case channelOpenFailed(String)
    case alreadyStarted

    var errorDescription: String? {
      switch self {
      case .notConnected:
        return "The SSH connection is not open."
      case .bindFailed(let message):
        return "Could not bind the local port: \(message)"
      case .channelOpenFailed(let message):
        return "Could not open the SSH channel: \(message)"
      case .alreadyStarted:
        return "The port-forward has already been started."
      }
    }
  }

  /// One live tunnel: a `direct-tcpip` channel glued to an accepted local
  /// socket. All fields are only accessed on the session's owner thread.
  private final class Tunnel {
    let channel: OpaquePointer
    var localFD: Int32
    /// Bytes read from the local socket waiting to be written to the channel.
    var pendingChannelWrite = Data()
    /// Bytes read from the channel waiting to be written to the local socket.
    var pendingLocalWrite = Data()
    var localEof = false
    var channelEof = false
    var closed = false

    init(channel: OpaquePointer, localFD: Int32) {
      self.channel = channel
      self.localFD = localFD
    }
  }

  private let config: Config
  private let onError: @Sendable (String) -> Void
  /// The queue that owns the local listener + accept loop. Separate from the
  /// session owner thread, so a busy tunnel never stalls SSH I/O on its own.
  private let listenerQueue = DispatchQueue(label: "Terminal.Libssh2PortForward.listener")

  /// Only touched on the owner thread.
  private var tunnels: [Tunnel] = []

  // ---- Cross-thread state (guarded by `stateLock`) ----
  private let stateLock = NSLock()
  private var listenerFD: Int32 = -1
  private var shouldStop = false
  /// Accepted local FDs handed off by the listener queue, drained by pump().
  private var pendingFDs: [Int32] = []
  private var started = false

  init(config: Config, onError: @escaping @Sendable (String) -> Void) {
    self.config = config
    self.onError = onError
  }

  // MARK: - Public API (callable from any thread)

  /// Binds the local listener. `bindPort == 0` selects an ephemeral port; the
  /// actually-bound port is delivered to `completion` on the main thread.
  func start(completion: @escaping @Sendable (Result<Int, Error>) -> Void) {
    stateLock.lock()
    guard !started else {
      stateLock.unlock()
      DispatchQueue.main.async { completion(.failure(ForwardError.alreadyStarted)) }
      return
    }
    started = true
    stateLock.unlock()

    listenerQueue.async { [self] in
      do {
        let (fd, boundPort) = try Self.openListener(host: config.bindHost, port: config.bindPort)
        stateLock.lock()
        listenerFD = fd
        stateLock.unlock()
        DispatchQueue.main.async { completion(.success(boundPort)) }
        runAcceptLoop(fd: fd)
      } catch {
        DispatchQueue.main.async { completion(.failure(error)) }
      }
    }
  }

  /// Stops accepting new connections and closes the listener. Existing tunnels
  /// are torn down by the owner thread's `pump` on its next iteration (the
  /// owner thread is the sole libssh2 owner and drives pump).
  func stop() {
    stateLock.lock()
    shouldStop = true
    let fd = listenerFD
    listenerFD = -1
    stateLock.unlock()
    if fd >= 0 { Darwin.close(fd) }
  }

  // MARK: - Owner-thread pump (call ONLY on the session owner thread)

  /// Drives all forwarding I/O on the session's owner thread: drains pending
  /// accepted connections (opening a `direct-tcpip` channel for each), and
  /// bridges bytes for every live tunnel in both directions, propagating
  /// close/EOF. Must be invoked from the loop that owns the libssh2 session.
  func pump(session: OpaquePointer, socketFD: Int32, eagain: Int32) {
    // 1. Open a channel for each newly accepted local connection.
    drainPendingConnections(session: session, socketFD: socketFD, eagain: eagain)

    // 2. Bridge every live tunnel in both directions.
    var remaining: [Tunnel] = []
    for tunnel in tunnels where !tunnel.closed {
      bridge(tunnel, session: session, eagain: eagain)
      if !tunnel.closed { remaining.append(tunnel) }
    }
    tunnels = remaining

    // 3. If stop() was requested, tear down listener + remaining tunnels.
    stateLock.lock()
    let stopping = shouldStop
    stateLock.unlock()
    if stopping {
      for tunnel in tunnels { closeTunnel(tunnel) }
      tunnels = []
    }
  }

  /// Whether any tunnel currently has bytes buffered toward the channel, i.e.
  /// the SSH socket should be polled for writability (POLLOUT) so the transport
  /// can flush this tick. Read by the owner loop to build its poll mask.
  var needsSocketOut: Bool {
    tunnels.contains { !$0.pendingChannelWrite.isEmpty }
  }

  // MARK: - Listener queue

  private func runAcceptLoop(fd: Int32) {
    while true {
      stateLock.lock()
      let stop = shouldStop
      stateLock.unlock()
      if stop { break }

      var addr = sockaddr_storage()
      var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
      let client = withUnsafeMutablePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
          accept(fd, sp, &len)
        }
      }
      if client < 0 {
        if errno == EINTR { continue }
        break // listener closed / fatal
      }

      // Make the accepted socket non-blocking so the owner thread never blocks.
      let fl = fcntl(client, F_GETFL, 0)
      if fl >= 0 { _ = fcntl(client, F_SETFL, fl | O_NONBLOCK) }
      // Disable Nagle on the tunnel socket too.
      var one: Int32 = 1
      setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))

      stateLock.lock()
      pendingFDs.append(client)
      stateLock.unlock()
    }
  }

  /// Opens a `direct-tcpip` channel for each pending accepted FD. Runs on the
  /// owner thread; all libssh2 calls here are safe.
  private func drainPendingConnections(session: OpaquePointer, socketFD: Int32, eagain: Int32) {
    stateLock.lock()
    let fds = pendingFDs
    pendingFDs.removeAll()
    stateLock.unlock()

    for fd in fds {
      let (originHost, originPort) = Self.originatorAddress(fd: fd)
      guard let channel = openDirectChannel(
        session: session, socketFD: socketFD, eagain: eagain,
        targetHost: config.targetHost, targetPort: config.targetPort,
        originHost: originHost, originPort: originPort
      ) else {
        onError("SSH tunnel to \(config.targetHost):\(config.targetPort) failed.")
        Darwin.close(fd)
        continue
      }
      tunnels.append(Tunnel(channel: channel, localFD: fd))
    }
  }

  /// Opens a `direct-tcpip` channel with the non-blocking EAGAIN retry loop.
  private func openDirectChannel(
    session: OpaquePointer, socketFD: Int32, eagain: Int32,
    targetHost: String, targetPort: Int, originHost: String, originPort: Int
  ) -> OpaquePointer? {
    var ch = targetHost.withCString { host in
      originHost.withCString { shost in
        libssh2_channel_direct_tcpip_ex(session, host, Int32(targetPort), shost, Int32(originPort))
      }
    }
    let deadline = DispatchTime.now() + .seconds(20)
    var attempts = 0
    while ch == nil && libssh2_session_last_errno(session) == eagain
      && attempts < 200 && DispatchTime.now() < deadline {
      let dirs = libssh2_session_block_directions(session)
      var pfd = pollfd(fd: socketFD, events: Self.polevents(dirs), revents: 0)
      _ = poll(&pfd, 1, 100)
      attempts += 1
      ch = targetHost.withCString { host in
        originHost.withCString { shost in
          libssh2_channel_direct_tcpip_ex(session, host, Int32(targetPort), shost, Int32(originPort))
        }
      }
    }
    return ch
  }

  // MARK: - Byte bridging (owner thread)

  private func bridge(_ tunnel: Tunnel, session: OpaquePointer, eagain: Int32) {
    // remote -> local
    drainChannelToLocal(tunnel)
    flushPendingLocalWrite(tunnel)

    // local -> remote
    drainLocalToChannel(tunnel)
    flushPendingChannelWrite(tunnel, eagain: eagain)

    // Close/EOF propagation. When BOTH sides have signaled EOF, tear down.
    if tunnel.localEof && tunnel.channelEof {
      closeTunnel(tunnel)
      return
    }
    // Remote sent EOF and we've flushed it to the local socket: shut down the
    // local write side so the local peer sees the remote closed.
    if tunnel.channelEof && tunnel.localFD >= 0 {
      _ = Darwin.shutdown(tunnel.localFD, SHUT_WR)
    }
  }

  /// Reads available bytes from the channel into `pendingLocalWrite` (and flushes
  /// them to the local socket). A clean read of 0 means the remote closed.
  private func drainChannelToLocal(_ tunnel: Tunnel) {
    guard !tunnel.closed, !tunnel.channelEof else { return }
    var buffer = [UInt8](repeating: 0, count: 32768)
    while true {
      let n = libssh2_channel_read_ex(tunnel.channel, 0, &buffer, buffer.count)
      if n > 0 {
        tunnel.pendingLocalWrite.append(Data(buffer.prefix(Int(n))))
        if tunnel.localFD >= 0 { flushPendingLocalWrite(tunnel) }
        continue
      }
      if n == 0 {
        tunnel.channelEof = true
      }
      break // n == EAGAIN or error: stop for this tick
    }
  }

  /// Reads bytes from the local socket (non-blocking) into `pendingChannelWrite`.
  /// A 0 read means the local peer closed its write side.
  private func drainLocalToChannel(_ tunnel: Tunnel) {
    guard !tunnel.closed, !tunnel.localEof else { return }
    var buffer = [UInt8](repeating: 0, count: 32768)
    let capacity = buffer.count
    while true {
      // Darwin.recv takes UnsafeMutableRawPointer: &buffer here would pass a
      // pointer to the Array STRUCT, not its elements (which silently corrupts
      // the bytes). Use withUnsafeMutableBytes to hand a real element pointer,
      // copying the result out so there is no exclusivity conflict with the
      // subsequent buffer.prefix read.
      let n = buffer.withUnsafeMutableBytes { raw in
        Darwin.recv(tunnel.localFD, raw.baseAddress, capacity, 0)
      }
      if n > 0 {
        tunnel.pendingChannelWrite.append(Data(buffer.prefix(Int(n))))
        break
      }
      if n == 0 {
        // Local peer closed its write side — propagate EOF to the remote.
        tunnel.localEof = true
        _ = libssh2_channel_send_eof(tunnel.channel)
        break
      }
      if errno == EAGAIN || errno == EWOULDBLOCK {
        break // no more data right now
      }
      // Real error reading the local socket.
      tunnel.localEof = true
      _ = libssh2_channel_send_eof(tunnel.channel)
      break
    }
  }

  private func flushPendingChannelWrite(_ tunnel: Tunnel, eagain: Int32) {
    guard !tunnel.closed else { return }
    let data = tunnel.pendingChannelWrite
    tunnel.pendingChannelWrite = Data()
    if data.isEmpty { return }

    var offset = 0
    while offset < data.count {
      let written = data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Int in
        guard let base = buf.baseAddress else { return 0 }
        let ptr = base.assumingMemoryBound(to: UInt8.self).advanced(by: offset)
        return Int(libssh2_channel_write_ex(tunnel.channel, 0, ptr, data.count - offset))
      }
      if written > 0 {
        offset += written
        continue
      }
      if written == Int(eagain) {
        // Put the unsent remainder back for the next tick.
        tunnel.pendingChannelWrite = data.subdata(in: offset..<data.count) + tunnel.pendingChannelWrite
        break
      }
      // Real write error: close the tunnel.
      closeTunnel(tunnel)
      break
    }
  }

  private func flushPendingLocalWrite(_ tunnel: Tunnel) {
    guard !tunnel.closed, tunnel.localFD >= 0 else { return }
    let data = tunnel.pendingLocalWrite
    tunnel.pendingLocalWrite = Data()
    if data.isEmpty { return }

    var offset = 0
    while offset < data.count {
      let written = data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Int in
        guard let base = buf.baseAddress else { return 0 }
        let ptr = base.assumingMemoryBound(to: UInt8.self).advanced(by: offset)
        return Darwin.write(tunnel.localFD, ptr, data.count - offset)
      }
      if written > 0 {
        offset += written
        continue
      }
      if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
        // Local receiver is slow — keep the remainder buffered for next tick.
        tunnel.pendingLocalWrite = data.subdata(in: offset..<data.count) + tunnel.pendingLocalWrite
        break
      }
      // EPIPE / other error writing to the local socket: close the tunnel.
      closeTunnel(tunnel)
      break
    }
  }

  // MARK: - Teardown (owner thread)

  /// Idempotent full teardown of one tunnel on the owner thread. Does not block
  /// on the remote (the session is non-blocking); a best-effort EOF is sent, the
  /// channel is closed and freed, and the local socket is closed.
  private func closeTunnel(_ tunnel: Tunnel) {
    guard !tunnel.closed else { return }
    tunnel.closed = true
    _ = libssh2_channel_send_eof(tunnel.channel)
    _ = libssh2_channel_close(tunnel.channel)
    _ = libssh2_channel_free(tunnel.channel)
    if tunnel.localFD >= 0 {
      Darwin.close(tunnel.localFD)
      tunnel.localFD = -1
    }
  }

  // MARK: - Helpers

  /// Binds a blocking TCP listener to `host:port` and returns the FD plus the
  /// actually-bound port (ephemeral when `port == 0`).
  private static func openListener(host: String, port: Int) throws -> (Int32, Int) {
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
      throw ForwardError.bindFailed("getaddrinfo failed: \(String(cString: gai_strerror(rc)))")
    }
    defer { freeaddrinfo(addrInfo) }

    var lastError: Error = ForwardError.bindFailed("no usable address")
    var current: UnsafeMutablePointer<addrinfo>? = addrInfo
    while let cand = current {
      let info = cand.pointee
      let s = socket(info.ai_family, info.ai_socktype, info.ai_protocol)
      if s >= 0 {
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

        let bindRc = info.ai_addr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
          Darwin.bind(s, sp, info.ai_addrlen)
        }
        if bindRc == 0, listen(s, 16) == 0 {
          // Read back the real bound port (ephemeral when requested 0).
          var bound = sockaddr_in()
          var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
          let gc = withUnsafeMutablePointer(to: &bound) { bp in
            bp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
              getsockname(s, sp, &boundLen)
            }
          }
          var boundPort: UInt16 = 0
          if gc == 0 {
            let p = withUnsafePointer(to: &bound) { $0.pointee.sin_port }
            boundPort = p.bigEndian
          }
          // Leave the listener socket blocking; accept() runs on its own queue.
          return (s, Int(boundPort))
        }
        lastError = ForwardError.bindFailed(String(cString: strerror(errno)))
        Darwin.close(s)
      }
      current = cand.pointee.ai_next
    }
    throw lastError
  }

  /// The originator address to report to the SSH server: the accepted peer's
  /// host/port, or a loopback fallback.
  private static func originatorAddress(fd: Int32) -> (String, Int) {
    var addr = sockaddr_storage()
    var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
    let rc = withUnsafeMutablePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
        getpeername(fd, sp, &len)
      }
    }
    if rc == 0 {
      let sa = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee } }
      let host = ipv4String(from: sa.sin_addr)
      return (host, Int(sa.sin_port.bigEndian))
    }
    return ("127.0.0.1", 0)
  }

  private static func ipv4String(from addr: in_addr) -> String {
    var a = addr
    let bytes = withUnsafeBytes(of: &a) { Array($0) }
    return "\(bytes[0]).\(bytes[1]).\(bytes[2]).\(bytes[3])"
  }

  /// Maps libssh2's block-directions bitmask to a poll() event mask.
  private static func polevents(_ blockDirs: Int32) -> Int16 {
    var events: Int16 = 0
    if blockDirs & LIBSSH2_SESSION_BLOCK_INBOUND != 0 { events |= Int16(POLLIN) }
    if blockDirs & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0 { events |= Int16(POLLOUT) }
    return events == 0 ? Int16(POLLIN) : events
  }
}
