import CLibssh2
import Foundation

/// SFTP calls on a `Libssh2Connection`'s session, for the folder sync: list, stat, create folders, upload, rename,
/// remove, set times. Lives on the connection's owner thread only (`Libssh2Connection.sftp`), where the session is
/// non-blocking: every call repeats while libssh2 would block, waiting on the socket in between, and gives up after
/// `timeout` seconds without an answer.
nonisolated final class Libssh2SFTP: @unchecked Sendable {
  enum Failure: LocalizedError, Equatable {
    case noSuchFile(String)
    case permissionDenied(String)
    case alreadyExists(String)
    case directoryNotEmpty(String)
    case unsupported(String)
    case failed(path: String, status: UInt, message: String)
    case connectionLost(String)

    var errorDescription: String? {
      switch self {
      case .noSuchFile(let path): "“\(path)” doesn’t exist on the host."
      case .permissionDenied(let path): "The host doesn’t allow access to “\(path)”."
      case .alreadyExists(let path): "“\(path)” already exists on the host."
      case .directoryNotEmpty(let path): "The folder “\(path)” on the host isn’t empty."
      case .unsupported(let what): "The host’s SFTP server doesn’t support \(what)."
      case .failed(let path, let status, let message):
        "The host refused “\(path)” (SFTP status \(status)\(message.isEmpty ? "" : ": \(message)"))."
      case .connectionLost(let detail): "The SSH connection broke: \(detail)"
      }
    }
  }

  private static let eagain = Int32(LIBSSH2_ERROR_EAGAIN)
  private static let chunk = 64 * 1024

  let session: OpaquePointer
  let sftp: OpaquePointer
  /// Waits for the socket in the direction libssh2 is blocked on (a short poll).
  private let waitSocket: () -> Void
  private let timeout: TimeInterval

  init(session: OpaquePointer, sftp: OpaquePointer, timeout: TimeInterval = 60, waitSocket: @escaping () -> Void) {
    self.session = session
    self.sftp = sftp
    self.timeout = timeout
    self.waitSocket = waitSocket
  }

  // MARK: Calls

  /// Repeats a call while libssh2 would block, until it returns ≥ 0 or fails.
  private func call(_ path: String, _ op: () -> Int) throws -> Int {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
      let rc = op()
      if rc >= 0 { return rc }
      guard rc == Int(Self.eagain) else { throw failure(Int32(rc), path: path) }
      guard Date() < deadline else { throw Failure.connectionLost("the host stopped answering") }
      waitSocket()
    }
  }

  /// Repeats a call that returns a handle while libssh2 would block.
  private func handle(_ path: String, _ op: () -> OpaquePointer?) throws -> OpaquePointer {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
      if let handle = op() { return handle }
      let rc = libssh2_session_last_errno(session)
      guard rc == Self.eagain else { throw failure(rc, path: path) }
      guard Date() < deadline else { throw Failure.connectionLost("the host stopped answering") }
      waitSocket()
    }
  }

  private func failure(_ rc: Int32, path: String) -> Failure {
    if rc == LIBSSH2_ERROR_SFTP_PROTOCOL {
      let status = libssh2_sftp_last_error(sftp)
      switch status {
      case UInt(LIBSSH2_FX_NO_SUCH_FILE), UInt(LIBSSH2_FX_NO_SUCH_PATH): return .noSuchFile(path)
      case UInt(LIBSSH2_FX_PERMISSION_DENIED), UInt(LIBSSH2_FX_WRITE_PROTECT): return .permissionDenied(path)
      case UInt(LIBSSH2_FX_FILE_ALREADY_EXISTS): return .alreadyExists(path)
      case UInt(LIBSSH2_FX_DIR_NOT_EMPTY): return .directoryNotEmpty(path)
      case UInt(LIBSSH2_FX_OP_UNSUPPORTED): return .unsupported("this operation")
      default: return .failed(path: path, status: UInt(status), message: lastError())
      }
    }
    return .connectionLost(lastError())
  }

  private func lastError() -> String {
    var message: UnsafeMutablePointer<CChar>?
    var length: Int32 = 0
    _ = libssh2_session_last_error(session, &message, &length, 0)
    return message.map { String(cString: $0) } ?? ""
  }

  private func close(_ handle: OpaquePointer, path: String) throws {
    _ = try call(path) { Int(libssh2_sftp_close_handle(handle)) }
  }

  // MARK: Operations

  func realPath(_ path: String) throws -> String {
    var buffer = [CChar](repeating: 0, count: 4096)
    let length = try call(path) {
      Int(libssh2_sftp_symlink_ex(sftp, path, UInt32(path.utf8.count), &buffer, UInt32(buffer.count), LIBSSH2_SFTP_REALPATH))
    }
    return String(decoding: buffer[0..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }

  /// The entry at `path` without following a link; nil when nothing is there.
  func info(_ path: String) throws -> FolderSyncRemoteItem? {
    var attributes = LIBSSH2_SFTP_ATTRIBUTES()
    do {
      _ = try call(path) {
        Int(libssh2_sftp_stat_ex(sftp, path, UInt32(path.utf8.count), LIBSSH2_SFTP_LSTAT, &attributes))
      }
    } catch Failure.noSuchFile {
      return nil
    }
    return Self.item(name: FolderSyncPath.name(path), attributes)
  }

  func list(_ path: String) throws -> [FolderSyncRemoteItem] {
    let directory = try handle(path) {
      libssh2_sftp_open_ex(sftp, path, UInt32(path.utf8.count), 0, 0, LIBSSH2_SFTP_OPENDIR)
    }
    var items: [FolderSyncRemoteItem] = []
    var name = [CChar](repeating: 0, count: 4096)
    do {
      while true {
        var attributes = LIBSSH2_SFTP_ATTRIBUTES()
        let length = try call(path) { Int(libssh2_sftp_readdir_ex(directory, &name, name.count, nil, 0, &attributes)) }
        if length == 0 { break }
        let entry = String(decoding: name[0..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        if entry == "." || entry == ".." { continue }
        items.append(Self.item(name: entry, attributes))
      }
    } catch {
      try? close(directory, path: path)
      throw error
    }
    try close(directory, path: path)
    return items
  }

  func makeDirectory(_ path: String, permissions: UInt32) throws {
    do {
      _ = try call(path) { Int(libssh2_sftp_mkdir_ex(sftp, path, UInt32(path.utf8.count), CLong(permissions))) }
    } catch let error as Failure {
      // OpenSSH answers only "failure" when something is already there.
      if case .failed = error, try info(path) != nil { throw Failure.alreadyExists(path) }
      throw error
    }
  }

  /// Streams the local file to `path` (created with `permissions`, or truncated) and closes it, which reports a
  /// failed flush (a full disk).
  func upload(_ local: URL, to path: String, permissions: UInt32) throws {
    let input = try FileHandle(forReadingFrom: local)
    defer { try? input.close() }
    let file = try openForWriting(path, permissions: permissions)
    do {
      while let data = try input.read(upToCount: Self.chunk), !data.isEmpty {
        try send(data, to: file, path: path)
      }
    } catch {
      try? close(file, path: path)
      throw error
    }
    try close(file, path: path)
  }

  /// Writes `data` to `path` (created with `permissions`, or truncated) and closes it.
  func write(_ data: Data, to path: String, permissions: UInt32) throws {
    let file = try openForWriting(path, permissions: permissions)
    do {
      try send(data, to: file, path: path)
    } catch {
      try? close(file, path: path)
      throw error
    }
    try close(file, path: path)
  }

  private func openForWriting(_ path: String, permissions: UInt32) throws -> OpaquePointer {
    let flags = CUnsignedLong(LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC)
    return try handle(path) {
      libssh2_sftp_open_ex(sftp, path, UInt32(path.utf8.count), flags, CLong(permissions), LIBSSH2_SFTP_OPENFILE)
    }
  }

  private func send(_ data: Data, to file: OpaquePointer, path: String) throws {
    try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
      var offset = 0
      while offset < bytes.count {
        let pointer = bytes.baseAddress!.advanced(by: offset).assumingMemoryBound(to: CChar.self)
        let count = min(bytes.count - offset, Self.chunk)
        offset += try call(path) { libssh2_sftp_write(file, pointer, count) }
      }
    }
  }

  /// The first `maxBytes` of the file at `path` (all of a shorter one).
  func read(_ path: String, maxBytes: Int) throws -> Data {
    let file = try handle(path) {
      libssh2_sftp_open_ex(sftp, path, UInt32(path.utf8.count), CUnsignedLong(LIBSSH2_FXF_READ), 0, LIBSSH2_SFTP_OPENFILE)
    }
    var data = Data()
    var buffer = [CChar](repeating: 0, count: Self.chunk)
    do {
      while data.count < maxBytes {
        let wanted = min(buffer.count, maxBytes - data.count)
        let count = try call(path) {
          buffer.withUnsafeMutableBufferPointer { libssh2_sftp_read(file, $0.baseAddress, wanted) }
        }
        if count == 0 { break }
        buffer.withUnsafeBytes { data.append(contentsOf: $0.prefix(count)) }
      }
    } catch {
      try? close(file, path: path)
      throw error
    }
    try close(file, path: path)
    return data
  }

  /// Sets the permission bits of `path` (the server's umask applied to the ones a new file was opened with).
  func setPermissions(_ path: String, to permissions: UInt32) throws {
    var attributes = LIBSSH2_SFTP_ATTRIBUTES()
    attributes.flags = CUnsignedLong(LIBSSH2_SFTP_ATTR_PERMISSIONS)
    attributes.permissions = CUnsignedLong(permissions)
    _ = try call(path) {
      Int(libssh2_sftp_stat_ex(sftp, path, UInt32(path.utf8.count), LIBSSH2_SFTP_SETSTAT, &attributes))
    }
  }

  /// Renames over whatever is at `destination` (a file or link) in one step with OpenSSH's `posix-rename`; without
  /// it, the destination is removed first and the plain rename follows.
  func rename(_ source: String, to destination: String) throws {
    do {
      _ = try call(source) {
        Int(libssh2_sftp_posix_rename_ex(sftp, source, source.utf8.count, destination, destination.utf8.count))
      }
      return
    } catch Failure.unsupported {
    } catch let Failure.failed(_, status, _) where status == UInt(LIBSSH2_FX_OP_UNSUPPORTED) {
    }
    let flags = CLong(LIBSSH2_SFTP_RENAME_OVERWRITE | LIBSSH2_SFTP_RENAME_ATOMIC | LIBSSH2_SFTP_RENAME_NATIVE)
    func plain() throws {
      _ = try call(source) {
        Int(libssh2_sftp_rename_ex(
          sftp, source, UInt32(source.utf8.count), destination, UInt32(destination.utf8.count), flags))
      }
    }
    do {
      try plain()
    } catch let error as Failure {
      guard case .connectionLost = error else {
        guard let existing = try info(destination), existing.kind != .directory else { throw error }
        try removeFile(destination)
        try plain()
        return
      }
      throw error
    }
  }

  func removeFile(_ path: String) throws {
    _ = try call(path) { Int(libssh2_sftp_unlink_ex(sftp, path, UInt32(path.utf8.count))) }
  }

  func removeDirectory(_ path: String) throws {
    do {
      _ = try call(path) { Int(libssh2_sftp_rmdir_ex(sftp, path, UInt32(path.utf8.count))) }
    } catch let error as Failure {
      // OpenSSH says only "failure" for a folder that isn't empty.
      if case .failed = error, let items = try? list(path), !items.isEmpty { throw Failure.directoryNotEmpty(path) }
      throw error
    }
  }

  func setModified(_ path: String, to date: Date) throws {
    var attributes = LIBSSH2_SFTP_ATTRIBUTES()
    attributes.flags = CUnsignedLong(LIBSSH2_SFTP_ATTR_ACMODTIME)
    let seconds = CUnsignedLong(max(0, date.timeIntervalSince1970.rounded(.down)))
    attributes.atime = seconds
    attributes.mtime = seconds
    _ = try call(path) {
      Int(libssh2_sftp_stat_ex(sftp, path, UInt32(path.utf8.count), LIBSSH2_SFTP_SETSTAT, &attributes))
    }
  }

  // MARK: Helpers

  static func item(name: String, _ attributes: LIBSSH2_SFTP_ATTRIBUTES) -> FolderSyncRemoteItem {
    var kind = FolderSyncEntry.Kind.other
    var permissions: UInt32?
    if attributes.flags & CUnsignedLong(LIBSSH2_SFTP_ATTR_PERMISSIONS) != 0 {
      let mode = UInt32(truncatingIfNeeded: attributes.permissions)
      permissions = mode & 0o777
      switch mode & 0o170000 {
      case 0o040000: kind = .directory
      case 0o100000: kind = .file
      case 0o120000: kind = .symbolicLink
      default: kind = .other
      }
    }
    let size = attributes.flags & CUnsignedLong(LIBSSH2_SFTP_ATTR_SIZE) != 0 ? UInt64(attributes.filesize) : 0
    let modified =
      attributes.flags & CUnsignedLong(LIBSSH2_SFTP_ATTR_ACMODTIME) != 0
      ? Date(timeIntervalSince1970: TimeInterval(attributes.mtime)) : nil
    return FolderSyncRemoteItem(
      name: name, kind: kind, size: kind == .file ? size : 0, modified: modified, permissions: permissions)
  }
}
