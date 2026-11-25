import Foundation
import Testing
@testable import ShellKit

// MARK: - Paths and excludes

struct FolderSyncPathTests {
  @Test func refusesEmptyAndSystemRoot() {
    for path in ["", "   ", "\n"] {
      #expect(throws: FolderSyncError.emptyRemotePath) { try FolderSyncPath.checkedRemoteRoot(path, deletes: true) }
    }
    for path in ["/", "//", "///", " / ", "/./", "/."] {
      #expect(throws: FolderSyncError.remoteRootIsSystemRoot) { try FolderSyncPath.checkedRemoteRoot(path, deletes: false) }
    }
  }

  @Test func refusesTheLoginFolderWhenDeleting() throws {
    for path in ["~", ".", "~/", "./"] {
      #expect(throws: FolderSyncError.self) { try FolderSyncPath.checkedRemoteRoot(path, deletes: true) }
    }
    #expect(try FolderSyncPath.checkedRemoteRoot("~", deletes: false) == ".")
  }

  @Test func refusesParentReferences() {
    #expect(throws: FolderSyncError.remotePathHasParentReference("/var/www/../etc")) {
      try FolderSyncPath.checkedRemoteRoot("/var/www/../etc", deletes: true)
    }
    #expect(throws: FolderSyncError.self) { try FolderSyncPath.checkedRemoteRoot("..", deletes: false) }
  }

  @Test func normalizesPaths() throws {
    #expect(try FolderSyncPath.checkedRemoteRoot("/var/www/site/", deletes: true) == "/var/www/site")
    #expect(try FolderSyncPath.checkedRemoteRoot("~/site", deletes: true) == "site")
    #expect(try FolderSyncPath.checkedRemoteRoot("./www//site/", deletes: true) == "www/site")
    #expect(try FolderSyncPath.checkedRemoteRoot("/srv/./site", deletes: true) == "/srv/site")
  }

  @Test func checksTheResolvedFolder() throws {
    #expect(throws: FolderSyncError.remoteRootIsSystemRoot) {
      try FolderSyncPath.checkResolvedRoot("/", home: "/home/me", deletes: false)
    }
    #expect(throws: FolderSyncError.remoteRootIsHome("/home/me/")) {
      try FolderSyncPath.checkResolvedRoot("/home/me/", home: "/home/me", deletes: true)
    }
    try FolderSyncPath.checkResolvedRoot("/home/me", home: "/home/me", deletes: false)
    try FolderSyncPath.checkResolvedRoot("/home/me/site", home: "/home/me", deletes: true)
  }

  @Test func safeRelativePaths() {
    #expect(FolderSyncPath.isSafe("index.html"))
    #expect(FolderSyncPath.isSafe("a/b/c.txt"))
    #expect(FolderSyncPath.isSafe("..hidden"))
    for path in ["", "/etc/passwd", "..", "a/../../b", "a//b", "./a", "a/.", "a/", "a\0b"] {
      #expect(!FolderSyncPath.isSafe(path), "\(path)")
    }
  }

  @Test func excludePatterns() {
    let excludes = FolderSyncExcludes([".*", "*.log", "/build", "docs/*.md", "node_modules/", "**/cache", "[ab]c", "# comment", ""])
    #expect(excludes.excludes(".env", isDirectory: false))
    #expect(excludes.excludes("a/.git/config", isDirectory: false))
    #expect(excludes.excludes("logs/today.log", isDirectory: false))
    #expect(excludes.excludes("build", isDirectory: true))
    #expect(excludes.excludes("build/out.js", isDirectory: false))
    #expect(!excludes.excludes("src/build", isDirectory: true))
    #expect(excludes.excludes("docs/a.md", isDirectory: false))
    #expect(!excludes.excludes("docs/sub/a.md", isDirectory: false))
    #expect(excludes.excludes("node_modules", isDirectory: true))
    #expect(excludes.excludes("x/node_modules/y.js", isDirectory: false))
    #expect(!excludes.excludes("node_modules", isDirectory: false))
    #expect(excludes.excludes("cache", isDirectory: true))
    #expect(excludes.excludes("deep/er/cache/x", isDirectory: false))
    #expect(excludes.excludes("ac", isDirectory: false))
    #expect(!excludes.excludes("cc", isDirectory: false))
    #expect(!excludes.excludes("index.html", isDirectory: false))
    #expect(!excludes.excludes("# comment", isDirectory: false))
  }

  @Test func globEdgeCases() {
    func glob(_ p: String, _ t: String) -> Bool { FolderSyncExcludes.glob(Array(p), Array(t)) }
    #expect(glob("*", "abc"))
    #expect(!glob("*", "a/b"))
    #expect(glob("**", "a/b"))
    #expect(glob("a?c", "abc"))
    #expect(!glob("a?c", "a/c"))
    #expect(glob("[!x]y", "ay"))
    #expect(!glob("[!x]y", "xy"))
    #expect(glob("[a-c]", "b"))
    #expect(glob("\\*", "*"))
    #expect(!glob("\\*", "a"))
    // Many stars stay fast (memoized).
    #expect(!glob(String(repeating: "*a", count: 30) + "b", String(repeating: "a", count: 200)))
  }

  @Test func parsesSHA256Output() {
    let a = String(repeating: "a", count: 64)
    let b = String(repeating: "B", count: 64)
    let c = String(repeating: "c", count: 64)
    let output = "\(a)  /srv/site/index.html\n\(b) */srv/site/img/logo.png\n\\\(c)  /srv/site/odd\\nname\\\\x\nnot a hash line\n"
    let hashes = Libssh2FolderSyncRemote.parseHashes(output)
    #expect(hashes["/srv/site/index.html"] == a)
    #expect(hashes["/srv/site/img/logo.png"] == b.lowercased())
    #expect(hashes["/srv/site/odd\nname\\x"] == c)
    #expect(hashes.count == 3)
  }
}

// MARK: - Planner

struct FolderSyncPlannerTests {
  let date = Date(timeIntervalSince1970: 1_700_000_000)
  let settings = FolderSyncSettings(localPath: "/l", remotePath: "/r")

  func file(_ path: String, _ size: UInt64 = 10, modified: Date? = nil) -> FolderSyncEntry {
    FolderSyncEntry(path: path, kind: .file, size: size, modified: modified ?? date, permissions: 0o644)
  }
  func folder(_ path: String) -> FolderSyncEntry { FolderSyncEntry(path: path, kind: .directory) }

  @Test func comparesBySizeThenHash() {
    let local = [file("same"), file("edited"), file("grown", 20), file("new")]
    let remote = [file("same"), file("edited"), file("grown", 10)]
    #expect(FolderSyncPlanner.hashCandidates(local: local, remote: remote) == ["edited", "same"])
    let plan = FolderSyncPlanner.plan(
      remoteRoot: "/r", local: local, remote: remote,
      localHashes: ["same": "11", "edited": "22"], remoteHashes: ["same": "11", "edited": "33"], settings: settings)
    #expect(plan.unchanged == 1)
    #expect(Dictionary(uniqueKeysWithValues: plan.uploads.map { ($0.path, $0.reason) })
      == ["edited": .content, "grown": .size, "new": .new])
    #expect(plan.comparison == .sha256)
    #expect(plan.deletions.isEmpty)
  }

  @Test func fallsBackToModificationTimeWithoutHashes() {
    let local = [file("a"), file("b", modified: date.addingTimeInterval(60)), file("c", modified: date.addingTimeInterval(0.7))]
    let remote = [file("a"), file("b"), file("c")]
    let plan = FolderSyncPlanner.plan(remoteRoot: "/r", local: local, remote: remote, remoteHashes: nil, settings: settings)
    // SFTP times are whole seconds: a fraction doesn't count as a change.
    #expect(plan.uploads.map(\.path) == ["b"])
    #expect(plan.uploads.first?.reason == .modified)
    #expect(plan.unchanged == 2)
    #expect(plan.comparison == .modificationTime)
  }

  @Test func deletesWhatTheLocalFolderLacksDeepestFirst() {
    let local = [file("index.html")]
    let remote = [file("index.html"), folder("old"), folder("old/deep"), file("old/deep/a.html"), file("old/b.html"), file("gone.css")]
    let plan = FolderSyncPlanner.plan(
      remoteRoot: "/r", local: local, remote: remote, localHashes: ["index.html": "x"], remoteHashes: ["index.html": "x"],
      settings: settings)
    #expect(plan.uploads.isEmpty)
    #expect(plan.deletions.map(\.path) == ["old/deep/a.html", "old/b.html", "old/deep", "gone.css", "old"])
    let off = FolderSyncPlanner.plan(
      remoteRoot: "/r", local: local, remote: remote, remoteHashes: [:],
      settings: FolderSyncSettings(localPath: "/l", remotePath: "/r", deletesRemovedFiles: false))
    #expect(off.deletions.isEmpty)
  }

  @Test func excludedFilesAreNeitherUploadedNorDeleted() {
    let local = [file(".env"), folder(".git"), file(".git/HEAD"), file("index.html"), folder("logs"), file("logs/x.log")]
    let remote = [file(".htaccess"), folder("old"), file("old/.keep"), file("old/page.html"), folder("logs"), file("logs/server.log")]
    let plan = FolderSyncPlanner.plan(
      remoteRoot: "/r", local: local, remote: remote, remoteHashes: [:],
      settings: FolderSyncSettings(localPath: "/l", remotePath: "/r", excludes: [".*", "*.log"]))
    #expect(plan.uploads.map(\.path) == ["index.html"])
    // old/ holds an excluded file: its other files go, the folder stays.
    #expect(plan.deletions.map(\.path) == ["old/page.html"])
    #expect(plan.kept == ["old"])
  }

  @Test func scanReportedExcludedFoldersAreKept() {
    let plan = FolderSyncPlanner.plan(
      remoteRoot: "/r", local: [], remote: [folder("a"), folder("a/b")], remoteFoldersWithExcluded: ["a/b"],
      remoteHashes: [:], settings: settings)
    #expect(plan.deletions.isEmpty)
    #expect(plan.kept == ["a", "a/b"])
  }

  @Test func replacesAFolderWithAFileOnlyWhenDeleting() {
    let local = [file("page")]
    let remote = [folder("page"), file("page/a"), folder("page/b"), file("page/b/c")]
    let plan = FolderSyncPlanner.plan(remoteRoot: "/r", local: local, remote: remote, remoteHashes: [:], settings: settings)
    #expect(plan.replacements.map(\.path) == ["page/b/c", "page/a", "page/b", "page"])
    #expect(plan.uploads.map(\.reason) == [.replaces])
    #expect(plan.deletions.isEmpty)

    let off = FolderSyncPlanner.plan(
      remoteRoot: "/r", local: local, remote: remote, remoteHashes: [:],
      settings: FolderSyncSettings(localPath: "/l", remotePath: "/r", deletesRemovedFiles: false))
    #expect(off.replacements.isEmpty && off.uploads.isEmpty)
    #expect(off.skipped.map(\.path) == ["page"])
  }

  @Test func aFileOverALinkReplacesTheLinkAndALinkIsNeverEntered() {
    let local = [file("current"), folder("assets"), file("assets/app.js")]
    let remote = [
      FolderSyncEntry(path: "current", kind: .symbolicLink),
      FolderSyncEntry(path: "assets", kind: .symbolicLink),
      FolderSyncEntry(path: "shared", kind: .symbolicLink),
    ]
    let plan = FolderSyncPlanner.plan(remoteRoot: "/r", local: local, remote: remote, remoteHashes: [:], settings: settings)
    #expect(plan.uploads.map(\.path) == ["assets/app.js", "current"])
    #expect(plan.replacements == [.init(path: "assets", kind: .symbolicLink)])
    #expect(plan.directories == ["assets"])
    // A link is removed as a link (an unlink), never followed.
    #expect(plan.deletions == [.init(path: "shared", kind: .symbolicLink)])
  }

  @Test func skipsUnsafePathsAndCreatesFoldersOutermostFirst() {
    let local = [file("../escape"), folder("a"), folder("a/b"), file("a/b/c")]
    let remote = [FolderSyncEntry(path: "../../etc", kind: .directory)]
    let plan = FolderSyncPlanner.plan(remoteRoot: "/r", local: local, remote: remote, remoteHashes: [:], settings: settings)
    #expect(plan.skipped.map(\.path) == ["../escape"])
    #expect(plan.directories == ["a", "a/b"])
    #expect(plan.uploads.map(\.path) == ["a/b/c"])
    #expect(plan.deletions.isEmpty)
  }

  @Test func decodesOldAndPartialSettings() throws {
    let partial = try JSONDecoder().decode(FolderSyncSettings.self, from: Data(#"{"localPath":"/a","remotePath":"b"}"#.utf8))
    #expect(partial.deletesRemovedFiles)
    #expect(partial.excludes == [".*"])
    let empty = try JSONDecoder().decode(FolderSyncSettings.self, from: Data("{}".utf8))
    #expect(empty.localPath.isEmpty && empty.remotePath.isEmpty)
    let round = try JSONDecoder().decode(
      FolderSyncSettings.self,
      from: JSONEncoder().encode(FolderSyncSettings(localPath: "/x", remotePath: "/y", deletesRemovedFiles: false, excludes: [])))
    #expect(round == FolderSyncSettings(localPath: "/x", remotePath: "/y", deletesRemovedFiles: false, excludes: []))
  }
}

// MARK: - Engine against a fake host

/// An in-memory host: absolute paths, links that `realPath` follows and listings don't. Records every change.
final class FakeSyncHost: FolderSyncRemote, @unchecked Sendable {
  enum Node {
    case file(Data, Date, UInt32)
    case directory
    case link(String)
  }

  private let lock = NSLock()
  private var nodes: [String: Node] = ["/": .directory]
  private(set) var changes: [String] = []
  let home: String
  var hashes = true

  init(home: String = "/home/me") {
    self.home = home
    mkdirs(home)
  }

  private func locked<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }

  func mkdirs(_ path: String) {
    locked {
      var current = ""
      for part in path.split(separator: "/") {
        current += "/" + part
        if nodes[current] == nil { nodes[current] = .directory }
      }
    }
  }

  func put(_ path: String, _ text: String, modified: Date = Date(timeIntervalSince1970: 1_000)) {
    mkdirs((path as NSString).deletingLastPathComponent)
    locked { nodes[path] = .file(Data(text.utf8), modified, 0o644) }
  }

  func link(_ path: String, to target: String) {
    locked { nodes[path] = .link(target) }
  }

  func text(_ path: String) -> String? {
    locked { if case .file(let data, _, _) = nodes[path] { String(decoding: data, as: UTF8.self) } else { nil } }
  }

  func exists(_ path: String) -> Bool { locked { nodes[path] != nil } }

  var paths: [String] { locked { nodes.keys.sorted() } }

  private func absolute(_ path: String) -> String {
    let joined = path.hasPrefix("/") ? path : (path == "." ? home : home + "/" + path)
    return joined.count > 1 && joined.hasSuffix("/") ? String(joined.dropLast()) : joined
  }

  private func resolve(_ path: String) -> String {
    var resolved = ""
    for part in absolute(path).split(separator: "/") {
      resolved += "/" + part
      var hops = 0
      while case .link(let target) = nodes[resolved], hops < 20 {
        resolved = target.hasPrefix("/") ? target : (resolved as NSString).deletingLastPathComponent + "/" + target
        hops += 1
      }
    }
    return resolved.isEmpty ? "/" : resolved
  }

  private func item(_ name: String, _ node: Node) -> FolderSyncRemoteItem {
    switch node {
    case .file(let data, let date, let mode):
      FolderSyncRemoteItem(name: name, kind: .file, size: UInt64(data.count), modified: date, permissions: mode)
    case .directory: FolderSyncRemoteItem(name: name, kind: .directory, permissions: 0o755)
    case .link: FolderSyncRemoteItem(name: name, kind: .symbolicLink)
    }
  }

  func realPath(_ path: String) async throws -> String { locked { resolve(path) } }

  func info(_ path: String) async throws -> FolderSyncRemoteItem? {
    locked {
      let full = absolute(path)
      let parent = resolve((full as NSString).deletingLastPathComponent)
      let key = parent == "/" ? "/" + FolderSyncPath.name(full) : parent + "/" + FolderSyncPath.name(full)
      return nodes[full == "/" ? "/" : key].map { item(FolderSyncPath.name(full), $0) }
    }
  }

  func list(_ path: String) async throws -> [FolderSyncRemoteItem] {
    try locked {
      // Opening a folder follows a link to it, as SFTP's opendir does.
      let folder = resolve(path)
      guard case .directory = nodes[folder] else { throw Libssh2SFTP.Failure.noSuchFile(path) }
      let prefix = folder == "/" ? "/" : folder + "/"
      return nodes.compactMap { key, node in
        guard key.hasPrefix(prefix), key != folder, !key.dropFirst(prefix.count).contains("/") else { return nil }
        return item(String(key.dropFirst(prefix.count)), node)
      }
    }
  }

  func makeDirectory(_ path: String, permissions: UInt32) async throws {
    try locked {
      let full = absolute(path)
      guard nodes[full] == nil else { throw Libssh2SFTP.Failure.alreadyExists(path) }
      guard case .directory = nodes[(full as NSString).deletingLastPathComponent] else { throw Libssh2SFTP.Failure.noSuchFile(path) }
      nodes[full] = .directory
      changes.append("mkdir \(full)")
    }
  }

  func upload(_ local: URL, to path: String, permissions: UInt32) async throws {
    let data = try Data(contentsOf: local)
    try locked {
      let full = absolute(path)
      guard case .directory = nodes[(full as NSString).deletingLastPathComponent] else { throw Libssh2SFTP.Failure.noSuchFile(path) }
      nodes[full] = .file(data, Date(), permissions)
      changes.append("upload \(full)")
    }
  }

  func rename(_ source: String, to destination: String) async throws {
    try locked {
      let from = absolute(source), to = absolute(destination)
      guard let node = nodes[from] else { throw Libssh2SFTP.Failure.noSuchFile(source) }
      if case .directory = nodes[to] { throw Libssh2SFTP.Failure.failed(path: to, status: 4, message: "is a folder") }
      nodes[from] = nil
      nodes[to] = node
      changes.append("rename \(from) -> \(to)")
    }
  }

  func removeFile(_ path: String) async throws {
    try locked {
      let full = absolute(path)
      guard let node = nodes[full] else { throw Libssh2SFTP.Failure.noSuchFile(path) }
      if case .directory = node { throw Libssh2SFTP.Failure.failed(path: full, status: 4, message: "is a folder") }
      nodes[full] = nil
      changes.append("rm \(full)")
    }
  }

  func removeDirectory(_ path: String) async throws {
    try locked {
      let full = absolute(path)
      guard case .directory = nodes[full] else { throw Libssh2SFTP.Failure.noSuchFile(path) }
      guard !nodes.keys.contains(where: { $0.hasPrefix(full + "/") }) else { throw Libssh2SFTP.Failure.directoryNotEmpty(path) }
      nodes[full] = nil
      changes.append("rmdir \(full)")
    }
  }

  func setModified(_ path: String, to date: Date) async throws {
    locked {
      let full = absolute(path)
      if case .file(let data, _, let mode) = nodes[full] {
        nodes[full] = .file(data, Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)), mode)
      }
    }
  }

  func sha256(_ paths: [String]) async throws -> [String: String]? {
    guard hashes else { return nil }
    return locked {
      var result: [String: String] = [:]
      for path in paths {
        if case .file(let data, _, _) = nodes[absolute(path)] {
          let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
          try? data.write(to: url)
          result[path] = try? FolderSyncEngine.sha256(of: url)
          try? FileManager.default.removeItem(at: url)
        }
      }
      return result
    }
  }
}

struct FolderSyncEngineTests {
  /// A local folder with `files` (relative path → text).
  func localFolder(_ files: [String: String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("folder-sync-\(UUID().uuidString)")
    for (path, text) in files {
      let url = root.appendingPathComponent(path)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try text.write(to: url, atomically: true, encoding: .utf8)
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  @Test func syncsAndThenHasNothingLeft() async throws {
    let local = try localFolder(["index.html": "<h1>new</h1>", "css/site.css": "body{}", "same.txt": "same", ".env": "SECRET=1"])
    defer { try? FileManager.default.removeItem(at: local) }
    let host = FakeSyncHost()
    host.put("/srv/site/index.html", "<h1>old!</h1>")
    host.put("/srv/site/same.txt", "same")
    host.put("/srv/site/stale.html", "gone")
    host.put("/srv/site/.htaccess", "keep me")
    host.put("/srv/site/old/.keep", "")
    host.put("/srv/site/old/page.html", "gone")
    host.put("/etc/passwd", "root")
    // A link out of the folder: removed as a link, never entered.
    host.link("/srv/site/escape", to: "/etc")

    let engine = FolderSyncEngine(settings: FolderSyncSettings(localPath: local.path, remotePath: "/srv/site"), remote: host)
    let preparation = try await engine.prepare()
    let plan = preparation.plan
    #expect(plan.comparison == .sha256)
    #expect(Set(plan.uploads.map(\.path)) == ["index.html", "css/site.css"])
    #expect(plan.unchanged == 1)
    #expect(Set(plan.deletions.map(\.path)) == ["stale.html", "old/page.html", "escape"])
    #expect(plan.kept == ["old"])
    #expect(host.changes.isEmpty, "the dry run changes nothing")

    let result = await engine.apply(preparation)
    #expect(result.failures.isEmpty)
    #expect(result.uploaded == 2 && result.deleted == 3 && result.createdFolders == 1)
    #expect(host.text("/srv/site/index.html") == "<h1>new</h1>")
    #expect(host.text("/srv/site/css/site.css") == "body{}")
    #expect(host.text("/srv/site/.htaccess") == "keep me")
    #expect(host.text("/etc/passwd") == "root")
    #expect(host.exists("/etc"))
    #expect(!host.exists("/srv/site/escape") && !host.exists("/srv/site/stale.html"))
    #expect(host.exists("/srv/site/old/.keep"))
    // Every change stays inside the folder, and every upload lands under a temporary name first.
    for change in host.changes {
      #expect(change.split(separator: " ")[1].hasPrefix("/srv/site/"), "\(change)")
    }
    let uploads = host.changes.filter { $0.hasPrefix("upload ") }
    #expect(uploads.count == 2 && uploads.allSatisfy { $0.hasSuffix(".part") && $0.contains("/.") })
    #expect(!host.paths.contains { $0.hasSuffix(".part") })

    let again = try await engine.prepare()
    #expect(again.plan.isEmpty)
  }

  @Test func withoutHashesTimesAreMatchedSoTheNextRunIsEmpty() async throws {
    let local = try localFolder(["a.txt": "one", "b.txt": "two"])
    defer { try? FileManager.default.removeItem(at: local) }
    let host = FakeSyncHost()
    host.hashes = false
    host.put("/home/me/site/a.txt", "uno")  // same size, other time
    let engine = FolderSyncEngine(settings: FolderSyncSettings(localPath: local.path, remotePath: "~/site"), remote: host)
    let first = try await engine.prepare()
    #expect(first.plan.comparison == .modificationTime)
    #expect(first.plan.uploads.map(\.path).sorted() == ["a.txt", "b.txt"])
    #expect(first.plan.remoteRoot == "/home/me/site")
    _ = await engine.apply(first)
    #expect(host.text("/home/me/site/a.txt") == "one")
    let second = try await engine.prepare()
    #expect(second.plan.isEmpty)
  }

  @Test func createsAMissingFolder() async throws {
    let local = try localFolder(["x/y.txt": "y"])
    defer { try? FileManager.default.removeItem(at: local) }
    let host = FakeSyncHost()
    let engine = FolderSyncEngine(settings: FolderSyncSettings(localPath: local.path, remotePath: "/srv/new/site"), remote: host)
    let preparation = try await engine.prepare()
    #expect(preparation.plan.createsRoot)
    let result = await engine.apply(preparation)
    #expect(result.failures.isEmpty)
    #expect(host.text("/srv/new/site/x/y.txt") == "y")
  }

  @Test func refusesTheSystemRootAndTheHomeFolderBeforeTouchingTheHost() async throws {
    let local = try localFolder(["a": "a"])
    defer { try? FileManager.default.removeItem(at: local) }
    let host = FakeSyncHost()
    host.put("/bin/sh", "x")
    for path in ["/", "", "~"] {
      let engine = FolderSyncEngine(settings: FolderSyncSettings(localPath: local.path, remotePath: path), remote: host)
      await #expect(throws: FolderSyncError.self) { _ = try await engine.prepare() }
    }
    // A path that resolves to / (a link to it) or to the login folder is refused too.
    host.link("/srv", to: "/")
    host.link("/home/me/here", to: "/home/me")
    for path in ["/srv", "here", "/home/me"] {
      let engine = FolderSyncEngine(settings: FolderSyncSettings(localPath: local.path, remotePath: path), remote: host)
      await #expect(throws: FolderSyncError.self) { _ = try await engine.prepare() }
    }
    #expect(host.changes.isEmpty)
    #expect(host.text("/bin/sh") == "x")
  }

  @Test func refusesAFileAsTheFolder() async throws {
    let local = try localFolder(["a": "a"])
    defer { try? FileManager.default.removeItem(at: local) }
    let host = FakeSyncHost()
    host.put("/srv/site", "a file")
    let engine = FolderSyncEngine(settings: FolderSyncSettings(localPath: local.path, remotePath: "/srv/site"), remote: host)
    await #expect(throws: FolderSyncError.remoteRootNotAFolder("/srv/site")) { _ = try await engine.prepare() }
  }

  @Test func listsAFailedUploadAndGoesOn() async throws {
    let local = try localFolder(["a.txt": "a", "b.txt": "b"])
    defer { try? FileManager.default.removeItem(at: local) }
    let host = FakeSyncHost()
    host.mkdirs("/srv/site")
    let engine = FolderSyncEngine(settings: FolderSyncSettings(localPath: local.path, remotePath: "/srv/site"), remote: host)
    let preparation = try await engine.prepare()
    try FileManager.default.removeItem(at: local.appendingPathComponent("a.txt"))
    let result = await engine.apply(preparation)
    #expect(result.uploaded == 1)
    #expect(result.failures.map(\.path) == ["a.txt"])
    #expect(host.text("/srv/site/b.txt") == "b")
  }

  @Test func localScanFollowsFileLinksAndSkipsFolderLinks() throws {
    let local = try localFolder(["real.txt": "r", "dir/x": "x"])
    defer { try? FileManager.default.removeItem(at: local) }
    let fm = FileManager.default
    try fm.createSymbolicLink(atPath: local.appendingPathComponent("link.txt").path, withDestinationPath: "real.txt")
    try fm.createSymbolicLink(atPath: local.appendingPathComponent("loop").path, withDestinationPath: ".")
    try fm.createSymbolicLink(atPath: local.appendingPathComponent("broken").path, withDestinationPath: "nowhere")
    let scan = try FolderSyncEngine.scanLocal(root: local, excludes: FolderSyncExcludes([".*"]))
    #expect(Set(scan.entries.map(\.path)) == ["real.txt", "link.txt", "dir", "dir/x"])
    #expect(Set(scan.skipped.map(\.path)) == ["loop", "broken"])
  }
}

// MARK: - The run

@MainActor
struct FolderSyncTransportTests {
  @Test func waitsForApplyThenFinishes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("folder-sync-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "hi".write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    let host = FakeSyncHost()
    host.put("/srv/site/old.html", "x")
    var closed = 0
    let transport = FolderSyncTransport(
      destination: "test", settings: FolderSyncSettings(localPath: root.path, remotePath: "/srv/site"),
      connect: { _ in (host, { closed += 1 }) })
    var output = ""
    var exit: Int32?
    transport.onOutput = { output += String(decoding: $0, as: UTF8.self) }
    transport.onExit = { exit = $0 }
    transport.start()
    try await waitUntil { transport.phase == .awaitingConfirmation }
    #expect(host.changes.isEmpty)
    #expect(output.contains("upload   index.html (new"))
    #expect(output.contains("delete   old.html"))
    #expect(output.contains("Plan: 1 to upload"))
    transport.write(Data("y".utf8))
    try await waitUntil { exit != nil }
    #expect(exit == 0)
    #expect(transport.phase == .finished)
    #expect(transport.result?.uploaded == 1 && transport.result?.deleted == 1)
    #expect(host.text("/srv/site/index.html") == "hi")
    #expect(output.contains("Done: uploaded 1"))
    #expect(closed == 1)
  }

  @Test func withAskingOffTheSyncAppliesAtOnce() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("folder-sync-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "hi".write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    let host = FakeSyncHost()
    host.put("/srv/site/old.html", "x")
    let transport = FolderSyncTransport(
      destination: "test",
      settings: FolderSyncSettings(localPath: root.path, remotePath: "/srv/site", asksBeforeApplying: false),
      connect: { _ in (host, {}) })
    var output = ""
    var exit: Int32?
    transport.onOutput = { output += String(decoding: $0, as: UTF8.self) }
    transport.onExit = { exit = $0 }
    transport.start()
    try await waitUntil { exit != nil }
    #expect(exit == 0)
    #expect(transport.phase == .finished)
    #expect(host.text("/srv/site/index.html") == "hi")
    #expect(output.contains("Plan: 1 to upload"))
    #expect(!output.contains("Waiting for Apply"))
    #expect(output.contains("Done: uploaded 1"))
  }

  @Test func anActionSavedBeforeTheSwitchStillAsks() throws {
    let saved = Data(#"{"localPath":"/site","remotePath":"/srv/site","deletesRemovedFiles":true,"excludes":[".*"]}"#.utf8)
    #expect(try JSONDecoder().decode(FolderSyncSettings.self, from: saved).asksBeforeApplying)
    let off = FolderSyncSettings(localPath: "/site", remotePath: "/srv/site", asksBeforeApplying: false)
    #expect(try JSONDecoder().decode(FolderSyncSettings.self, from: JSONEncoder().encode(off)).asksBeforeApplying == false)
  }

  @Test func cancelLeavesTheHostAlone() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("folder-sync-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let host = FakeSyncHost()
    host.put("/srv/site/old.html", "x")
    let transport = FolderSyncTransport(
      destination: "test", settings: FolderSyncSettings(localPath: root.path, remotePath: "/srv/site"),
      connect: { _ in (host, {}) })
    var exit: Int32?
    transport.onExit = { exit = $0 }
    transport.start()
    try await waitUntil { transport.phase == .awaitingConfirmation }
    transport.write(Data([0x03]))
    #expect(exit == 130)
    #expect(transport.phase == .cancelled)
    #expect(host.changes.isEmpty)
  }

  @Test func aRefusedFolderFailsTheRun() async throws {
    let host = FakeSyncHost()
    let transport = FolderSyncTransport(
      destination: "test", settings: FolderSyncSettings(localPath: "/tmp", remotePath: "/"),
      connect: { _ in (host, {}) })
    var failure: String?
    transport.onTerminated = { failure = $0 }
    transport.start()
    try await waitUntil { failure != nil }
    #expect(failure == FolderSyncError.remoteRootIsSystemRoot.errorDescription)
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<500 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("timed out")
  }
}
