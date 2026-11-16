import CryptoKit
import Foundation

/// A file or folder in a listing of the host, as `lstat` sees it: a symbolic link is a link, never what it points to.
nonisolated public struct FolderSyncRemoteItem: Sendable, Hashable {
  public var name: String
  public var kind: FolderSyncEntry.Kind
  public var size: UInt64
  public var modified: Date?
  public var permissions: UInt32?

  public init(name: String, kind: FolderSyncEntry.Kind, size: UInt64 = 0, modified: Date? = nil, permissions: UInt32? = nil) {
    self.name = name
    self.kind = kind
    self.size = size
    self.modified = modified
    self.permissions = permissions
  }
}

/// The host side of a sync: the SFTP and command calls the engine needs. `Libssh2FolderSyncRemote` is Shell's own
/// SSH connection; tests use fakes. Paths are the host's (absolute, or relative to the login folder).
nonisolated public protocol FolderSyncRemote: Sendable {
  /// The path resolved by the host (`realpath`): absolute, links followed.
  func realPath(_ path: String) async throws -> String
  /// The entry at `path` without following a link, nil when nothing is there.
  func info(_ path: String) async throws -> FolderSyncRemoteItem?
  /// A folder's entries (not `.` and `..`), links not followed.
  func list(_ path: String) async throws -> [FolderSyncRemoteItem]
  func makeDirectory(_ path: String, permissions: UInt32) async throws
  /// Writes the local file to `path`, created with `permissions` (or truncated).
  func upload(_ local: URL, to path: String, permissions: UInt32) async throws
  /// Renames, replacing a file or link at `destination` in one step where the server can (`posix-rename`).
  func rename(_ source: String, to destination: String) async throws
  /// Removes a file or a link (never what it points to).
  func removeFile(_ path: String) async throws
  /// Removes an empty folder.
  func removeDirectory(_ path: String) async throws
  func setModified(_ path: String, to date: Date) async throws
  /// SHA-256 (lowercase hex) of each path that could be read, keyed by the path as given; nil when the host has no
  /// tool for it (then files are compared by size and modification time).
  func sha256(_ paths: [String]) async throws -> [String: String]?
}

/// One step of applying a plan, for progress.
nonisolated public struct FolderSyncStep: Sendable, Hashable {
  public enum Kind: String, Sendable, Hashable {
    case createRoot, replace, createFolder, upload, delete
  }

  public var kind: Kind
  public var path: String
}

nonisolated public struct FolderSyncProgress: Sendable, Hashable {
  public var completed: Int
  public var total: Int
  public var step: FolderSyncStep
  public var bytesUploaded: UInt64
}

/// What applying a plan did.
nonisolated public struct FolderSyncResult: Sendable, Hashable {
  public struct Failure: Sendable, Hashable {
    public var path: String
    public var message: String
  }

  public var uploaded = 0
  public var bytesUploaded: UInt64 = 0
  public var deleted = 0
  public var createdFolders = 0
  public var replaced = 0
  public var failures: [Failure] = []
  /// Stopped before the end (Stop, Ctrl+C).
  public var cancelled = false

  public init() {}
}

/// What the local scan found.
nonisolated public struct FolderSyncLocalScan: Sendable {
  public var entries: [FolderSyncEntry]
  public var skipped: [FolderSyncPlan.Skip]
}

/// What the host's scan found.
nonisolated public struct FolderSyncRemoteScan: Sendable {
  public var entries: [FolderSyncEntry]
  /// Folders (relative, "" for the top) that directly hold an excluded entry.
  public var foldersWithExcluded: Set<String>
}

/// A sync ready to apply: the plan and what it was made from.
nonisolated public struct FolderSyncPreparation: Sendable {
  public var plan: FolderSyncPlan
  public var localRoot: URL
  public var localSkipped: [FolderSyncPlan.Skip]
  public var localCount: Int
  public var remoteCount: Int
}

/// Lists both sides, compares them (`FolderSyncPlanner`) and applies the plan. Changes nothing on the host until
/// `apply`; deletes only what the host's own listing found under the resolved folder, never through a link.
nonisolated public struct FolderSyncEngine: Sendable {
  public let settings: FolderSyncSettings
  public let remote: any FolderSyncRemote
  /// The most entries either side may have: a guard against syncing the wrong folder (a whole disk).
  public var entryLimit = 500_000
  /// Paths per hashing command on the host.
  public var hashBatch = 500

  public init(settings: FolderSyncSettings, remote: any FolderSyncRemote) {
    self.settings = settings
    self.remote = remote
  }

  // MARK: Preparing (the dry run)

  /// Lists both sides, hashes same-size files and makes the plan. Nothing on the host changes.
  public func prepare(status: (@Sendable (String) -> Void)? = nil) async throws -> FolderSyncPreparation {
    let deletes = settings.deletesRemovedFiles
    let root = try FolderSyncPath.checkedRemoteRoot(settings.remotePath, deletes: deletes)
    let localRoot = URL(fileURLWithPath: (settings.localPath as NSString).expandingTildeInPath)
    let excludes = FolderSyncExcludes(settings.excludes)
    let limit = entryLimit

    status?("Reading \(localRoot.path)…")
    let local = try await Task.detached(priority: .userInitiated) {
      try Self.scanLocal(root: localRoot, excludes: excludes, limit: limit)
    }.value

    // The folder as the host resolves it: deletes happen only below this path.
    let resolved: String
    var rootExists = true
    if let item = try await remote.info(root) {
      let target = try await remote.realPath(root)
      if item.kind != .directory {
        // A link to a folder is followed once, here; anything else isn't a folder to sync into.
        guard item.kind == .symbolicLink, try await remote.info(target)?.kind == .directory else {
          throw FolderSyncError.remoteRootNotAFolder(root)
        }
      }
      resolved = target
    } else {
      rootExists = false
      resolved = try await Self.absolute(root, remote: remote)
    }
    let home = try? await remote.realPath(".")
    try FolderSyncPath.checkResolvedRoot(resolved, home: home, deletes: deletes)

    var remoteScan = FolderSyncRemoteScan(entries: [], foldersWithExcluded: [])
    if rootExists {
      status?("Listing \(resolved) on the host…")
      remoteScan = try await Self.scanRemote(root: resolved, remote: remote, excludes: excludes, limit: limit)
    }

    let candidates = FolderSyncPlanner.hashCandidates(local: local.entries, remote: remoteScan.entries)
    var remoteHashes: [String: String]?
    var localHashes: [String: String] = [:]
    if !candidates.isEmpty {
      status?("Comparing \(candidates.count) files of the same size by SHA-256…")
      remoteHashes = try await hashRemote(candidates, root: resolved)
      if remoteHashes != nil {
        localHashes = try await Task.detached(priority: .userInitiated) {
          var hashes: [String: String] = [:]
          for path in candidates {
            try Task.checkCancellation()
            hashes[path] = try? Self.sha256(of: localRoot.appendingPathComponent(path))
          }
          return hashes
        }.value
      }
    }

    var plan = FolderSyncPlanner.plan(
      remoteRoot: resolved, rootExists: rootExists, local: local.entries, remote: remoteScan.entries,
      remoteFoldersWithExcluded: remoteScan.foldersWithExcluded, localHashes: localHashes,
      remoteHashes: remoteHashes, settings: settings)
    plan.skipped.insert(contentsOf: local.skipped, at: 0)
    return FolderSyncPreparation(
      plan: plan, localRoot: localRoot, localSkipped: local.skipped, localCount: local.entries.count,
      remoteCount: remoteScan.entries.count)
  }

  /// A relative root made absolute against the login folder (for a folder that doesn't exist yet).
  static func absolute(_ root: String, remote: any FolderSyncRemote) async throws -> String {
    if root.hasPrefix("/") { return root }
    let home = try await remote.realPath(".")
    return root == "." ? home : FolderSyncPath.join(home, root)
  }

  /// The host's SHA-256 of `paths` (relative to `root`), in batches; nil when it can't hash.
  func hashRemote(_ paths: [String], root: String) async throws -> [String: String]? {
    var result: [String: String] = [:]
    var index = 0
    while index < paths.count {
      try Task.checkCancellation()
      let batch = Array(paths[index..<min(index + hashBatch, paths.count)])
      index += batch.count
      let absolute = batch.map { FolderSyncPath.join(root, $0) }
      guard let hashes = try await remote.sha256(absolute) else { return nil }
      for (relative, full) in zip(batch, absolute) {
        if let hash = hashes[full] { result[relative] = hash }
      }
    }
    return result
  }

  // MARK: Scanning

  /// Every file and folder under `root` that isn't excluded. A link to a file counts as that file (its content is
  /// uploaded); a link to a folder, a broken link and special files are skipped. Excluded folders aren't entered.
  public static func scanLocal(root: URL, excludes: FolderSyncExcludes, limit: Int = 500_000) throws -> FolderSyncLocalScan {
    let fm = FileManager.default
    var isFolder: ObjCBool = false
    guard fm.fileExists(atPath: root.path, isDirectory: &isFolder), isFolder.boolValue else {
      throw FolderSyncError.localFolderMissing(root.path)
    }
    var entries: [FolderSyncEntry] = []
    var skipped: [FolderSyncPlan.Skip] = []
    var pending = [""]
    while let folder = pending.popLast() {
      try Task.checkCancellation()
      let folderURL = folder.isEmpty ? root : root.appendingPathComponent(folder)
      let names: [String]
      do {
        names = try fm.contentsOfDirectory(atPath: folderURL.path).sorted()
      } catch {
        skipped.append(.init(path: folder.isEmpty ? "." : folder, reason: "couldn’t be read: \(error.localizedDescription)"))
        continue
      }
      for name in names {
        let relative = FolderSyncPath.join(folder, name)
        let url = folderURL.appendingPathComponent(name)
        guard let attributes = try? fm.attributesOfItem(atPath: url.path) else {
          skipped.append(.init(path: relative, reason: "couldn’t be read"))
          continue
        }
        var type = attributes[.type] as? FileAttributeType
        var info = attributes
        if type == .typeSymbolicLink {
          if excludes.matches(relative, isDirectory: false) { continue }
          guard let target = try? fm.attributesOfItem(atPath: url.resolvingSymlinksInPath().path) else {
            skipped.append(.init(path: relative, reason: "a broken symbolic link"))
            continue
          }
          if target[.type] as? FileAttributeType == .typeDirectory {
            skipped.append(.init(path: relative, reason: "a symbolic link to a folder"))
            continue
          }
          type = target[.type] as? FileAttributeType
          info = target
        }
        let isDirectory = type == .typeDirectory
        if excludes.matches(relative, isDirectory: isDirectory) { continue }
        let modified = info[.modificationDate] as? Date
        let permissions = (info[.posixPermissions] as? NSNumber).map { UInt32(truncating: $0) & 0o777 }
        if isDirectory {
          entries.append(FolderSyncEntry(path: relative, kind: .directory, modified: modified, permissions: permissions))
          pending.append(relative)
        } else if type == .typeRegular {
          let size = (info[.size] as? NSNumber)?.uint64Value ?? 0
          entries.append(FolderSyncEntry(path: relative, kind: .file, size: size, modified: modified, permissions: permissions))
        } else {
          skipped.append(.init(path: relative, reason: "not a regular file or folder"))
        }
        if entries.count > limit {
          throw FolderSyncError.unsafePath("\(root.path) has more than \(limit) files and folders")
        }
      }
    }
    return FolderSyncLocalScan(entries: entries, skipped: skipped)
  }

  /// Every file, folder and link under `root` on the host that isn't excluded, without following links. Excluded
  /// entries are left out, and the folders holding them noted, so they are never deleted.
  public static func scanRemote(
    root: String, remote: any FolderSyncRemote, excludes: FolderSyncExcludes, limit: Int = 500_000
  ) async throws -> FolderSyncRemoteScan {
    var scan = FolderSyncRemoteScan(entries: [], foldersWithExcluded: [])
    var pending = [""]
    while let folder = pending.popLast() {
      try Task.checkCancellation()
      let items = try await remote.list(FolderSyncPath.join(root, folder))
      for item in items where item.name != "." && item.name != ".." {
        // A name with a slash or NUL can't come from a real listing; never act on one.
        guard !item.name.isEmpty, !item.name.contains("/"), !item.name.contains("\0") else { continue }
        let relative = FolderSyncPath.join(folder, item.name)
        if excludes.matches(relative, isDirectory: item.kind == .directory) {
          scan.foldersWithExcluded.insert(folder)
          continue
        }
        scan.entries.append(
          FolderSyncEntry(
            path: relative, kind: item.kind, size: item.size, modified: item.modified, permissions: item.permissions))
        if item.kind == .directory { pending.append(relative) }
        if scan.entries.count > limit {
          throw FolderSyncError.unsafePath("\(root) has more than \(limit) files and folders")
        }
      }
    }
    return scan
  }

  /// SHA-256 of a local file as lowercase hex, read in 1 MB pieces.
  public static func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty {
      hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  // MARK: Applying

  /// Applies `preparation`'s plan: removals that make way, folders, uploads (each to a temporary name beside the
  /// file, then renamed over it, so a page is never half-written), then deletions. A failed step is listed and the
  /// rest go on; what depends on it is skipped. Stops between steps when the task is cancelled.
  public func apply(
    _ preparation: FolderSyncPreparation, progress: (@Sendable (FolderSyncProgress) -> Void)? = nil
  ) async -> FolderSyncResult {
    let plan = preparation.plan
    let root = plan.remoteRoot
    var result = FolderSyncResult()
    var completed = 0
    let total = plan.stepCount
    // Paths whose step failed: nothing inside them (or at them) is attempted.
    var failed = Set<String>()

    func report(_ kind: FolderSyncStep.Kind, _ path: String) {
      progress?(FolderSyncProgress(
        completed: completed, total: total, step: FolderSyncStep(kind: kind, path: path),
        bytesUploaded: result.bytesUploaded))
    }
    func fail(_ path: String, _ error: Error) {
      result.failures.append(.init(path: path, message: Self.describe(error)))
      failed.insert(path)
    }
    func blocked(_ path: String) -> String? {
      ([path] + FolderSyncPath.ancestors(path)).first { failed.contains($0) }
    }
    /// The host path of a relative path, which must stay inside the folder.
    func target(_ relative: String) -> String? {
      guard FolderSyncPath.isSafe(relative) else {
        result.failures.append(.init(path: relative, message: FolderSyncError.unsafePath(relative).localizedDescription))
        return nil
      }
      return FolderSyncPath.join(root, relative)
    }
    func cancelled() -> Bool {
      if Task.isCancelled { result.cancelled = true }
      return result.cancelled
    }

    if plan.createsRoot {
      report(.createRoot, root)
      do {
        try await makeDirectories(root)
      } catch {
        result.failures.append(.init(path: root, message: Self.describe(error)))
        return result
      }
      completed += 1
    }

    for removal in plan.replacements {
      if cancelled() { return result }
      guard let path = target(removal.path) else { continue }
      report(.replace, removal.path)
      do {
        if removal.kind == .directory {
          try await remote.removeDirectory(path)
        } else {
          try await remote.removeFile(path)
        }
        result.replaced += 1
      } catch {
        fail(removal.path, error)
      }
      completed += 1
    }

    for folder in plan.directories {
      if cancelled() { return result }
      guard let path = target(folder) else { continue }
      report(.createFolder, folder)
      if let cause = blocked(folder), cause != folder {
        result.failures.append(.init(path: folder, message: "skipped: \(cause) failed"))
        failed.insert(folder)
      } else if failed.contains(folder) {
        // Its replacement failed; already listed.
      } else {
        do {
          try await remote.makeDirectory(path, permissions: 0o755)
          result.createdFolders += 1
        } catch {
          fail(folder, error)
        }
      }
      completed += 1
    }

    for upload in plan.uploads {
      if cancelled() { return result }
      guard let path = target(upload.path) else { continue }
      report(.upload, upload.path)
      if let cause = blocked(upload.path) {
        if cause != upload.path {
          result.failures.append(.init(path: upload.path, message: "skipped: \(cause) failed"))
        }
      } else {
        let temporary = Self.temporaryPath(for: path)
        let local = preparation.localRoot.appendingPathComponent(upload.path)
        do {
          try await remote.upload(local, to: temporary, permissions: upload.permissions)
          if let modified = upload.modified {
            // Matching times let a host without a hashing tool tell the file is unchanged next time.
            try? await remote.setModified(temporary, to: modified)
          }
          try await remote.rename(temporary, to: path)
          result.uploaded += 1
          result.bytesUploaded += upload.size
        } catch {
          try? await remote.removeFile(temporary)
          fail(upload.path, error)
        }
      }
      completed += 1
    }

    for deletion in plan.deletions {
      if cancelled() { return result }
      guard let path = target(deletion.path) else { continue }
      report(.delete, deletion.path)
      do {
        if deletion.kind == .directory {
          try await remote.removeDirectory(path)
        } else {
          try await remote.removeFile(path)
        }
        result.deleted += 1
      } catch {
        fail(deletion.path, error)
      }
      completed += 1
    }
    progress?(FolderSyncProgress(
      completed: completed, total: total, step: FolderSyncStep(kind: .delete, path: ""),
      bytesUploaded: result.bytesUploaded))
    return result
  }

  /// Creates `path` and the folders above it that are missing.
  func makeDirectories(_ path: String) async throws {
    var current = path.hasPrefix("/") ? "/" : ""
    for part in path.split(separator: "/") where part != "." {
      current = current.isEmpty || current == "/" ? current + part : current + "/" + part
      if let item = try await remote.info(current) {
        if item.kind == .directory { continue }
        if item.kind == .symbolicLink, try await remote.info(try await remote.realPath(current))?.kind == .directory {
          continue
        }
        throw FolderSyncError.remoteRootNotAFolder(current)
      }
      try await remote.makeDirectory(current, permissions: 0o755)
    }
  }

  /// A hidden name beside `path` for the upload before its rename (excluded by the default `.*` pattern).
  static func temporaryPath(for path: String) -> String {
    let parent = path.lastIndex(of: "/").map { String(path[...$0]) } ?? ""
    let name = FolderSyncPath.name(path)
    let tag = UUID().uuidString.prefix(8).lowercased()
    return parent + ".\(name.prefix(200)).shell-sync-\(tag).part"
  }

  static func describe(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
  }
}
