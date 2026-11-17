import Foundation

/// What tells whether a file on a host changed since it was read: its size and modification time (whole seconds, as
/// SFTP gives them).
nonisolated public struct RemoteFileStamp: Sendable, Equatable {
  public var size: UInt64
  public var modified: Date?

  public init(size: UInt64, modified: Date?) {
    self.size = size
    self.modified = modified
  }

  init(_ item: FolderSyncRemoteItem) {
    self.init(size: item.size, modified: item.modified)
  }
}

/// The start of a file on a host, read for an editor (`SSHSession.readFileForEditing`).
nonisolated public struct RemoteFileContents: Sendable {
  /// The file's path with links resolved: the file a save replaces.
  public var path: String
  /// At most the `maxBytes` asked for.
  public var data: Data
  /// The file is longer than `data`.
  public var isTruncated: Bool
  public var stamp: RemoteFileStamp

  public init(path: String, data: Data, isTruncated: Bool, stamp: RemoteFileStamp) {
    self.path = path
    self.data = data
    self.isTruncated = isTruncated
    self.stamp = stamp
  }
}

nonisolated public enum RemoteFileError: LocalizedError, Equatable {
  /// The path is a folder or something else that isn't a file.
  case notAFile(String)
  /// The file's size or modification time differs from when it was read.
  case changedOnHost(String)
  /// The file is gone from the host.
  case removedFromHost(String)
  /// The session isn't connected (any more): nothing was sent.
  case notConnected

  public var errorDescription: String? {
    switch self {
    case .notAFile(let path): "“\(path)” isn’t a file."
    case .changedOnHost(let path): "“\(path)” changed on the host since it was opened."
    case .removedFromHost(let path): "“\(path)” was removed from the host since it was opened."
    case .notConnected: "The SSH connection is closed."
    }
  }
}

extension Libssh2SFTP {
  /// Reads the first `maxBytes` of the file at `path` and its stamp. A file that changes while it is read is read
  /// again (up to three times), so the stamp matches the bytes.
  func readForEditing(_ path: String, maxBytes: Int) throws -> RemoteFileContents {
    let real = try realPath(path)
    var attempt = 0
    while true {
      attempt += 1
      guard let before = try info(real) else { throw RemoteFileError.removedFromHost(path) }
      guard before.kind == .file else { throw RemoteFileError.notAFile(path) }
      let data = try read(real, maxBytes: maxBytes + 1)
      guard let after = try info(real) else { throw RemoteFileError.removedFromHost(path) }
      if RemoteFileStamp(after) == RemoteFileStamp(before) || attempt == 3 {
        return RemoteFileContents(
          path: real, data: data.prefix(maxBytes), isTruncated: data.count > maxBytes,
          stamp: RemoteFileStamp(after))
      }
    }
  }

  /// Replaces the file at `path` with `data`: written to a hidden file beside it with the file's permissions, then
  /// renamed over it, so the file is never seen half written. Throws `RemoteFileError.changedOnHost` (and writes
  /// nothing) when the file's stamp isn't `expected`; a nil `expected` replaces whatever is there. In a folder that
  /// can't take a new file, the file itself is written over. Returns the new stamp.
  func saveEdited(_ data: Data, to path: String, expecting expected: RemoteFileStamp?) throws -> RemoteFileStamp {
    let current = try info(path)
    if let current, current.kind != .file { throw RemoteFileError.notAFile(path) }
    if let expected {
      guard let current else { throw RemoteFileError.removedFromHost(path) }
      guard RemoteFileStamp(current) == expected else { throw RemoteFileError.changedOnHost(path) }
    }
    let permissions = current?.permissions ?? 0o644
    let parent = FolderSyncPath.parent(path)
    let folder = parent.isEmpty && path.hasPrefix("/") ? "/" : parent
    let name = FolderSyncPath.name(path)
    let random = String(UInt32.random(in: 0...UInt32.max), radix: 16)
    let temporary = FolderSyncPath.join(folder, ".\(name).shell-save-\(random)")
    do {
      try write(data, to: temporary, permissions: permissions)
    } catch Failure.permissionDenied {
      try? removeFile(temporary)
      try write(data, to: path, permissions: permissions)
      return try stamp(of: path)
    } catch {
      try? removeFile(temporary)
      throw error
    }
    do {
      try? setPermissions(temporary, to: permissions)
      try rename(temporary, to: path)
    } catch {
      try? removeFile(temporary)
      throw error
    }
    return try stamp(of: path)
  }

  private func stamp(of path: String) throws -> RemoteFileStamp {
    guard let item = try info(path) else { throw RemoteFileError.removedFromHost(path) }
    return RemoteFileStamp(item)
  }
}
