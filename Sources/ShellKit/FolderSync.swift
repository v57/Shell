import Foundation

// Folder sync: a local folder made the same on a saved SSH host, like `rsync -a --delete` without handing the host's
// login to another process. This file is the pure part (the settings an action keeps, the exclude patterns and the
// planner that compares two file lists); `FolderSyncEngine` lists both sides and applies a plan, and
// `FolderSyncTransport` runs it as an action's run.

/// What an action syncs: a local folder to a folder on the host it runs on.
nonisolated public struct FolderSyncSettings: Codable, Hashable, Sendable {
  /// The local folder, absolute.
  public var localPath: String
  /// The folder on the host: absolute, or relative to the login folder (`~/site` too). Never empty or `/`.
  public var remotePath: String
  /// Delete files and folders on the host that the local folder doesn't have (`rsync --delete`). Excluded ones stay.
  public var deletesRemovedFiles: Bool
  /// Patterns of paths neither uploaded nor deleted (`.*`: dotfiles, the default). A pattern without `/` matches a
  /// file or folder name anywhere; with one it matches the path from the folder (`/build`, `docs/*.md`); a trailing
  /// `/` matches folders only. `*` and `?` stay within a name, `**` crosses folders, `[abc]` is a class.
  public var excludes: [String]

  public static let defaultExcludes = [".*"]

  public init(
    localPath: String = "", remotePath: String = "", deletesRemovedFiles: Bool = true,
    excludes: [String] = FolderSyncSettings.defaultExcludes
  ) {
    self.localPath = localPath
    self.remotePath = remotePath
    self.deletesRemovedFiles = deletesRemovedFiles
    self.excludes = excludes
  }

  private enum CodingKeys: String, CodingKey {
    case localPath, remotePath, deletesRemovedFiles, excludes
  }

  /// Every field is optional in saved data, so a later field never fails an older action.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    localPath = try c.decodeIfPresent(String.self, forKey: .localPath) ?? ""
    remotePath = try c.decodeIfPresent(String.self, forKey: .remotePath) ?? ""
    deletesRemovedFiles = try c.decodeIfPresent(Bool.self, forKey: .deletesRemovedFiles) ?? true
    excludes = try c.decodeIfPresent([String].self, forKey: .excludes) ?? Self.defaultExcludes
  }
}

/// A sync that can't start, or a step that failed.
nonisolated public enum FolderSyncError: LocalizedError, Equatable, Sendable {
  case emptyRemotePath
  /// The host's `/`, as written or once resolved: a sync there could delete the whole system.
  case remoteRootIsSystemRoot
  /// The login folder itself, with deleting on: everything in it but the excluded files would go.
  case remoteRootIsHome(String)
  case remotePathHasParentReference(String)
  case remoteRootNotAFolder(String)
  case localFolderMissing(String)
  case unsafePath(String)
  case hostHasNoSHA256
  /// The run has no host to sync to: no terminal on one of the action's hosts is selected, and it has several.
  case noHost

  public var errorDescription: String? {
    switch self {
    case .emptyRemotePath: "The folder on the host is empty. Name the folder to sync to."
    case .remoteRootIsSystemRoot: "Shell doesn’t sync to the host’s root folder (/)."
    case .remoteRootIsHome(let path):
      "“\(path)” is the login folder on the host. With Delete removed files on, everything in it but the excluded files would be deleted; pick a folder inside it."
    case .remotePathHasParentReference(let path): "“\(path)” goes up with “..”. Write the folder’s path without it."
    case .remoteRootNotAFolder(let path): "“\(path)” on the host isn’t a folder."
    case .localFolderMissing(let path): "The local folder “\(path)” doesn’t exist or isn’t a folder."
    case .unsafePath(let path): "“\(path)” isn’t a path inside the synced folder."
    case .hostHasNoSHA256: "The host has neither sha256sum nor shasum."
    case .noHost: "This action syncs to one of several hosts: select a terminal on the one to sync to, then run it again."
    }
  }
}

// MARK: - Paths

nonisolated public enum FolderSyncPath {
  /// A path relative to the synced folder that stays inside it: not empty, not absolute, no empty, `.` or `..`
  /// part, no NUL. Every remote path the engine touches is the folder joined with one of these.
  public static func isSafe(_ relative: String) -> Bool {
    guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\0") else { return false }
    return relative.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
      !$0.isEmpty && $0 != "." && $0 != ".."
    }
  }

  /// `folder/relative`, for a `relative` that `isSafe`.
  public static func join(_ folder: String, _ relative: String) -> String {
    if relative.isEmpty { return folder }
    if folder.isEmpty { return relative }
    return folder.hasSuffix("/") ? folder + relative : folder + "/" + relative
  }

  /// The folder holding a relative path ("" at the top).
  public static func parent(_ relative: String) -> String {
    guard let slash = relative.lastIndex(of: "/") else { return "" }
    return String(relative[..<slash])
  }

  public static func name(_ relative: String) -> String {
    guard let slash = relative.lastIndex(of: "/") else { return relative }
    return String(relative[relative.index(after: slash)...])
  }

  /// The folders above a relative path, outermost first ("a/b/c" → "a", "a/b").
  public static func ancestors(_ relative: String) -> [String] {
    var result: [String] = []
    var current = ""
    let parts = relative.split(separator: "/")
    for part in parts.dropLast() {
      current = current.isEmpty ? String(part) : current + "/" + part
      result.append(current)
    }
    return result
  }

  static func depth(_ relative: String) -> Int { relative.split(separator: "/").count }

  /// The remote folder as SFTP takes it: trimmed, trailing slashes dropped, `~/x` as `x` (SFTP paths are relative
  /// to the login folder and don't expand `~`). Refuses an empty path, `/`, `..` parts, and the login folder (`~`,
  /// `.`) itself when `deletes` is on.
  public static func checkedRemoteRoot(_ path: String, deletes: Bool) throws -> String {
    var root = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !root.isEmpty else { throw FolderSyncError.emptyRemotePath }
    guard !root.contains("\0") else { throw FolderSyncError.unsafePath(root) }
    while root.count > 1, root.hasSuffix("/") { root.removeLast() }
    if root.allSatisfy({ $0 == "/" }) { throw FolderSyncError.remoteRootIsSystemRoot }
    if root == "~" || root == "." {
      if deletes { throw FolderSyncError.remoteRootIsHome(root) }
      return "."
    }
    if root.hasPrefix("~/") { root = String(root.dropFirst(2)) }
    while root.hasPrefix("./") { root = String(root.dropFirst(2)) }
    let parts = root.split(separator: "/")
    if parts.contains("..") { throw FolderSyncError.remotePathHasParentReference(path) }
    // "/./" and "//" parts are harmless but make the comparisons below unreliable: normalize them away.
    let cleaned = parts.filter { $0 != "." }.joined(separator: "/")
    if cleaned.isEmpty {
      if root.hasPrefix("/") { throw FolderSyncError.remoteRootIsSystemRoot }
      if deletes { throw FolderSyncError.remoteRootIsHome(path) }
      return "."
    }
    return root.hasPrefix("/") ? "/" + cleaned : cleaned
  }

  /// Checks the folder the host resolved the remote path to (`realpath`): never `/`, and not the login folder when
  /// deleting.
  public static func checkResolvedRoot(_ resolved: String, home: String?, deletes: Bool) throws {
    var trimmed = resolved
    while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
    if trimmed.isEmpty || trimmed.allSatisfy({ $0 == "/" }) { throw FolderSyncError.remoteRootIsSystemRoot }
    if deletes, let home, !home.isEmpty {
      var homeTrimmed = home
      while homeTrimmed.count > 1, homeTrimmed.hasSuffix("/") { homeTrimmed.removeLast() }
      if trimmed == homeTrimmed { throw FolderSyncError.remoteRootIsHome(resolved) }
    }
  }
}

// MARK: - Excludes

/// The exclude patterns of a sync (see `FolderSyncSettings.excludes`). A path is excluded when it or a folder above
/// it matches, so an excluded folder's files are neither uploaded nor deleted.
nonisolated public struct FolderSyncExcludes: Sendable, Hashable {
  struct Rule: Sendable, Hashable {
    var pattern: [Character]
    /// Matched against the whole relative path rather than the name.
    var anchored: Bool
    var directoriesOnly: Bool
  }

  let rules: [Rule]

  public init(_ patterns: [String]) {
    rules = patterns.compactMap { raw in
      var pattern = raw.trimmingCharacters(in: .whitespaces)
      guard !pattern.isEmpty, !pattern.hasPrefix("#") else { return nil }
      var directoriesOnly = false
      while pattern.count > 1, pattern.hasSuffix("/") {
        pattern.removeLast()
        directoriesOnly = true
      }
      var anchored = pattern.contains("/")
      if pattern.hasPrefix("/") {
        pattern = String(pattern.drop(while: { $0 == "/" }))
        anchored = true
      }
      guard !pattern.isEmpty else { return nil }
      return Rule(pattern: Array(pattern), anchored: anchored, directoriesOnly: directoriesOnly)
    }
  }

  /// Whether `path` (relative to the folder) is excluded: it matches, or a folder above it does.
  public func excludes(_ path: String, isDirectory: Bool) -> Bool {
    if rules.isEmpty { return false }
    for ancestor in FolderSyncPath.ancestors(path) where matches(ancestor, isDirectory: true) { return true }
    return matches(path, isDirectory: isDirectory)
  }

  /// Whether `path` itself matches a pattern (its folders aside). The scanners use this as they walk down, since an
  /// excluded folder is never entered.
  public func matches(_ path: String, isDirectory: Bool) -> Bool {
    let name = Array(FolderSyncPath.name(path))
    var whole: [Character]?
    for rule in rules {
      if rule.directoriesOnly && !isDirectory { continue }
      let subject: [Character]
      if rule.anchored {
        if whole == nil { whole = Array(path) }
        subject = whole!
      } else {
        subject = name
      }
      if Self.glob(rule.pattern, subject) { return true }
    }
    return false
  }

  /// Shell-style matching: `*` (not across `/`), `**` (across), `?`, `[a-z]`/`[!a]`, `\` escapes. Memoized, so a
  /// pattern full of stars stays linear in the path's length per pattern position.
  static func glob(_ pattern: [Character], _ text: [Character]) -> Bool {
    let width = text.count + 1
    var memo = [Int8](repeating: -1, count: (pattern.count + 1) * width)

    func match(_ p: Int, _ t: Int) -> Bool {
      let key = p * width + t
      if memo[key] >= 0 { return memo[key] == 1 }
      let result = compute(p, t)
      memo[key] = result ? 1 : 0
      return result
    }

    func compute(_ p: Int, _ t: Int) -> Bool {
      if p == pattern.count { return t == text.count }
      let c = pattern[p]
      if c == "*" {
        let doubled = p + 1 < pattern.count && pattern[p + 1] == "*"
        let next = doubled ? p + 2 : p + 1
        // `**/` also matches no folder at all ("**/x" matches "x").
        if doubled, next < pattern.count, pattern[next] == "/", match(next + 1, t) { return true }
        var i = t
        while true {
          if match(next, i) { return true }
          if i == text.count { return false }
          if !doubled && text[i] == "/" { return false }
          i += 1
        }
      }
      guard t < text.count else { return false }
      switch c {
      case "?":
        return text[t] != "/" && match(p + 1, t + 1)
      case "[":
        if let (matched, end) = matchClass(p, text[t]) {
          return matched && text[t] != "/" && match(end, t + 1)
        }
        return text[t] == "[" && match(p + 1, t + 1)
      case "\\" where p + 1 < pattern.count:
        return text[t] == pattern[p + 1] && match(p + 2, t + 1)
      default:
        return text[t] == c && match(p + 1, t + 1)
      }
    }

    /// A `[...]` class at `p`: whether `ch` is in it, and where the pattern continues; nil when unterminated.
    func matchClass(_ p: Int, _ ch: Character) -> (Bool, Int)? {
      var i = p + 1
      var negated = false
      if i < pattern.count, pattern[i] == "!" || pattern[i] == "^" {
        negated = true
        i += 1
      }
      var matched = false
      var first = true
      while i < pattern.count {
        let c = pattern[i]
        if c == "]" && !first { return (matched != negated, i + 1) }
        first = false
        if i + 2 < pattern.count, pattern[i + 1] == "-", pattern[i + 2] != "]" {
          if c <= ch && ch <= pattern[i + 2] { matched = true }
          i += 3
        } else {
          if c == ch { matched = true }
          i += 1
        }
      }
      return nil
    }

    return match(0, 0)
  }
}

// MARK: - Entries and plan

/// A file or folder on one side, by its path relative to the synced folder.
nonisolated public struct FolderSyncEntry: Sendable, Hashable {
  public enum Kind: String, Sendable, Hashable {
    case file
    case directory
    case symbolicLink
    case other
  }

  public var path: String
  public var kind: Kind
  public var size: UInt64
  public var modified: Date?
  /// Permission bits (`0o777`), when known.
  public var permissions: UInt32?

  public init(path: String, kind: Kind, size: UInt64 = 0, modified: Date? = nil, permissions: UInt32? = nil) {
    self.path = path
    self.kind = kind
    self.size = size
    self.modified = modified
    self.permissions = permissions
  }
}

/// What a sync will do, worked out before anything changes on the host (the dry run).
nonisolated public struct FolderSyncPlan: Sendable, Hashable {
  public enum UploadReason: String, Sendable, Hashable {
    /// The host doesn't have it.
    case new
    /// The sizes differ.
    case size
    /// Same size, different SHA-256.
    case content
    /// Same size, no hash to compare, different modification time.
    case modified
    /// Something else is at its path on the host (a link, a folder, a special file).
    case replaces
  }

  public struct Upload: Sendable, Hashable {
    public var path: String
    public var size: UInt64
    public var reason: UploadReason
    public var permissions: UInt32
    public var modified: Date?
  }

  /// Something on the host to remove.
  public struct Removal: Sendable, Hashable {
    public var path: String
    public var kind: FolderSyncEntry.Kind
  }

  public struct Skip: Sendable, Hashable {
    public var path: String
    public var reason: String
  }

  public enum Comparison: String, Sendable, Hashable {
    /// Same-size files compared by SHA-256 (the host has sha256sum or shasum).
    case sha256
    /// Same-size files compared by modification time (no hashing tool on the host).
    case modificationTime
    /// Nothing needed comparing.
    case none
  }

  /// The folder on the host, as resolved.
  public var remoteRoot: String
  /// The folder doesn't exist on the host yet: it's created first.
  public var createsRoot = false
  /// Removed first, to make way for a file or folder of another kind at the same path (deepest first).
  public var replacements: [Removal] = []
  /// Folders to create, outermost first.
  public var directories: [String] = []
  public var uploads: [Upload] = []
  /// Files and folders the local folder doesn't have, deepest first (removed after the uploads).
  public var deletions: [Removal] = []
  /// Files already the same on both sides.
  public var unchanged = 0
  /// Folders on the host the local folder doesn't have but that hold excluded files, so they stay.
  public var kept: [String] = []
  public var skipped: [Skip] = []
  public var comparison: Comparison = .none

  public init(remoteRoot: String) {
    self.remoteRoot = remoteRoot
  }

  /// Nothing to change on the host.
  public var isEmpty: Bool {
    !createsRoot && replacements.isEmpty && directories.isEmpty && uploads.isEmpty && deletions.isEmpty
  }

  /// The steps `apply` takes (the root's creation counts as one).
  public var stepCount: Int {
    (createsRoot ? 1 : 0) + replacements.count + directories.count + uploads.count + deletions.count
  }

  public var uploadBytes: UInt64 { uploads.reduce(0) { $0 + $1.size } }
}

/// Compares the two sides' file lists. Pure: the engine gathers the lists and hashes, this decides.
nonisolated public enum FolderSyncPlanner {
  /// The files whose content decides whether they changed: regular files on both sides with the same size (a
  /// different size has changed anyway). The engine hashes these on both sides.
  public static func hashCandidates(local: [FolderSyncEntry], remote: [FolderSyncEntry]) -> [String] {
    let remoteFiles = Dictionary(remote.filter { $0.kind == .file }.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
    return local.compactMap { entry in
      guard entry.kind == .file, let other = remoteFiles[entry.path], other.size == entry.size else { return nil }
      return entry.path
    }.sorted()
  }

  /// The plan for making the host's folder the same as the local one.
  ///
  /// - `local`, `remote`: every entry on each side (excluded ones may be left out or included: they're dropped here).
  /// - `remoteFoldersWithExcluded`: host folders that directly hold an excluded entry (the remote scan's); they and
  ///   the folders above them are never deleted.
  /// - `localHashes`, `remoteHashes`: SHA-256 by path for the `hashCandidates`; `remoteHashes` nil when the host
  ///   can't hash, so same-size files are compared by modification time.
  public static func plan(
    remoteRoot: String, rootExists: Bool = true, local: [FolderSyncEntry], remote: [FolderSyncEntry],
    remoteFoldersWithExcluded: Set<String> = [], localHashes: [String: String] = [:],
    remoteHashes: [String: String]?, settings: FolderSyncSettings
  ) -> FolderSyncPlan {
    let excludes = FolderSyncExcludes(settings.excludes)
    let deletes = settings.deletesRemovedFiles
    var plan = FolderSyncPlan(remoteRoot: remoteRoot)
    plan.createsRoot = !rootExists

    func included(_ entry: FolderSyncEntry) -> Bool {
      FolderSyncPath.isSafe(entry.path) && !excludes.excludes(entry.path, isDirectory: entry.kind == .directory)
    }
    var localEntries: [FolderSyncEntry] = []
    for entry in local {
      if !FolderSyncPath.isSafe(entry.path) {
        plan.skipped.append(.init(path: entry.path, reason: "not a path inside the folder"))
      } else if included(entry) {
        localEntries.append(entry)
      }
    }
    localEntries.sort { $0.path < $1.path }
    let remoteEntries = remote.filter(included)
    let remoteByPath = Dictionary(remoteEntries.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
    let localByPath = Dictionary(localEntries.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })

    // Host folders holding excluded files, and every folder above them: never deleted.
    var holdsExcluded = Set<String>()
    for folder in remoteFoldersWithExcluded where !folder.isEmpty {
      holdsExcluded.insert(folder)
      holdsExcluded.formUnion(FolderSyncPath.ancestors(folder))
    }
    // A host folder with an excluded file deeper down, also when the scan didn't say so (the planner's caller gave
    // the excluded entries themselves).
    for entry in remote where FolderSyncPath.isSafe(entry.path) && !included(entry) {
      holdsExcluded.formUnion(FolderSyncPath.ancestors(entry.path))
    }

    // Remote paths taken care of (replaced, or kept as they are because the local side has the same).
    var handledRemote = Set<String>()
    // Local paths whose subtree can't be synced (something on the host is in the way).
    var blocked = Set<String>()
    var hashedAny = false
    var comparedByTime = false

    /// Children before their folders; by path within a depth.
    func deepestFirst(_ a: FolderSyncPlan.Removal, _ b: FolderSyncPlan.Removal) -> Bool {
      let (da, db) = (FolderSyncPath.depth(a.path), FolderSyncPath.depth(b.path))
      return da != db ? da > db : a.path < b.path
    }

    /// The host entries at and below `path`, deepest first, for a folder replaced by a file.
    func subtree(_ path: String) -> [FolderSyncPlan.Removal] {
      let prefix = path + "/"
      return remoteEntries.filter { $0.path == path || $0.path.hasPrefix(prefix) }
        .map { FolderSyncPlan.Removal(path: $0.path, kind: $0.kind) }
        .sorted(by: deepestFirst)
    }

    for entry in localEntries {
      if let inside = FolderSyncPath.ancestors(entry.path).first(where: { blocked.contains($0) }) {
        plan.skipped.append(.init(path: entry.path, reason: "inside \(inside), which was skipped"))
        blocked.insert(entry.path)
        continue
      }
      let other = remoteByPath[entry.path]
      switch entry.kind {
      case .directory:
        switch other?.kind {
        case nil:
          plan.directories.append(entry.path)
        case .directory:
          handledRemote.insert(entry.path)
        case .file, .symbolicLink, .other:
          if deletes {
            plan.replacements.append(.init(path: entry.path, kind: other!.kind))
            handledRemote.insert(entry.path)
            plan.directories.append(entry.path)
          } else {
            plan.skipped.append(.init(path: entry.path, reason: "a file or link on the host is in the way (Delete removed files is off)"))
            blocked.insert(entry.path)
          }
        }
      case .file:
        let size = entry.size
        let mode = (entry.permissions ?? 0o644) & 0o777
        func upload(_ reason: FolderSyncPlan.UploadReason) {
          plan.uploads.append(.init(path: entry.path, size: size, reason: reason, permissions: mode, modified: entry.modified))
        }
        switch other?.kind {
        case nil:
          upload(.new)
        case .file:
          handledRemote.insert(entry.path)
          let remoteFile = other!
          if remoteFile.size != size {
            upload(.size)
          } else if let remoteHash = remoteHashes?[entry.path], let localHash = localHashes[entry.path] {
            hashedAny = true
            if remoteHash.lowercased() == localHash.lowercased() { plan.unchanged += 1 } else { upload(.content) }
          } else {
            comparedByTime = true
            if let a = entry.modified, let b = remoteFile.modified,
              Int64(a.timeIntervalSince1970.rounded(.down)) == Int64(b.timeIntervalSince1970.rounded(.down))
            {
              plan.unchanged += 1
            } else {
              upload(.modified)
            }
          }
        case .symbolicLink:
          // The upload's rename replaces the link itself, never what it points to.
          handledRemote.insert(entry.path)
          upload(.replaces)
        case .directory, .other:
          let removals = other!.kind == .directory ? subtree(entry.path) : [.init(path: entry.path, kind: other!.kind)]
          if !deletes {
            plan.skipped.append(.init(path: entry.path, reason: "a folder or special file on the host is in the way (Delete removed files is off)"))
          } else if other!.kind == .directory && holdsExcluded.contains(entry.path) {
            plan.skipped.append(.init(path: entry.path, reason: "a folder on the host holding excluded files is in the way"))
            handledRemote.formUnion(removals.map(\.path))
          } else {
            plan.replacements.append(contentsOf: removals)
            handledRemote.formUnion(removals.map(\.path))
            upload(.replaces)
          }
        }
      case .symbolicLink, .other:
        // The local scan follows links to files and leaves the rest out; another caller's are skipped here.
        plan.skipped.append(.init(path: entry.path, reason: "not a regular file or folder"))
      }
    }

    // What the host has and the local folder doesn't.
    if deletes {
      for entry in remoteEntries where !handledRemote.contains(entry.path) && localByPath[entry.path] == nil {
        if entry.kind == .directory && holdsExcluded.contains(entry.path) {
          plan.kept.append(entry.path)
          continue
        }
        plan.deletions.append(.init(path: entry.path, kind: entry.kind))
      }
      plan.deletions.sort(by: deepestFirst)
      plan.kept.sort()
    } else {
      // A file the host has and the local folder doesn't, inside a folder the local side replaces, still goes; with
      // deleting off nothing is replaced, so nothing else is removed.
    }
    plan.replacements.sort(by: deepestFirst)
    plan.directories.sort { (FolderSyncPath.depth($0), $0) < (FolderSyncPath.depth($1), $1) }
    plan.comparison = hashedAny ? .sha256 : comparedByTime ? .modificationTime : .none
    return plan
  }
}
