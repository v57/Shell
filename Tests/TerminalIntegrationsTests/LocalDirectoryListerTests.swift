import Foundation
import Testing

@testable import TerminalIntegrations

/// Exercises the local `FileManager` fast path against a real temporary
/// directory. `LocalDirectoryLister` reads the actual local filesystem (no fake
/// executor), so these tests create a fixture directory, and clean it up after.
struct LocalDirectoryListerTests {
  /// Creates a fresh temp directory with a known layout, returning its URL.
  private func makeFixture() throws -> (URL, URL) {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("LocalLister-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // A regular file.
    try "hello".write(to: dir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
    // A nested directory.
    try FileManager.default.createDirectory(
      at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
    // A symlink to a sibling (relative target), mirroring `ls -la` output.
    try FileManager.default.createSymbolicLink(
      at: dir.appendingPathComponent("a-link"), withDestinationURL: dir.appendingPathComponent("sub"))
    return (dir, dir.appendingPathComponent("b.txt"))
  }

  private func removeFixture(_ dir: URL) {
    try? FileManager.default.removeItem(at: dir)
  }

  @Test func listsEntriesSortedByNameIncludingDotfiles() throws {
    let (dir, _) = try makeFixture()
    defer { removeFixture(dir) }
    // A hidden file, so we can prove the fast path includes dotfiles like `ls -la`.
    try ".hidden".write(to: dir.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)

    let rows = try LocalDirectoryLister.list(directory: dir.path)

    #expect(rows.map(\.name) == [".hidden", "a-link", "b.txt", "sub"])
  }

  @Test func parsesSizeAndModifiedForRegularFile() throws {
    let (dir, bFilePath) = try makeFixture()
    defer { removeFixture(dir) }
    // Write in a way that lets us assert the size exactly.
    try "hello".write(to: bFilePath, atomically: true, encoding: .utf8)

    let rows = try LocalDirectoryLister.list(directory: dir.path)
    let b = try #require(rows.first(where: { $0.name == "b.txt" }))

    #expect(!b.isDirectory)
    #expect(b.size == 5)
    #expect(b.modified != nil)
    #expect(b.symlinkTarget == nil)
  }

  @Test func directoryRowHasNoSizeButIsDirectory() throws {
    let (dir, _) = try makeFixture()
    defer { removeFixture(dir) }

    let rows = try LocalDirectoryLister.list(directory: dir.path)
    let sub = try #require(rows.first(where: { $0.name == "sub" }))

    #expect(sub.isDirectory)
    #expect(sub.size == nil)
    #expect(sub.symlinkTarget == nil)
  }

  @Test func symlinkIsNotFollowedAndCarriesTarget() throws {
    let (dir, _) = try makeFixture()
    defer { removeFixture(dir) }

    let rows = try LocalDirectoryLister.list(directory: dir.path)
    let link = try #require(rows.first(where: { $0.name == "a-link" }))

    // `ls -la` renders a symlink as type `l`, not the target's type — so the
    // fast path must NOT report it as a directory even though its target is one.
    #expect(!link.isDirectory)
    #expect(link.symlinkTarget != nil)
    #expect(link.symlinkTarget?.hasSuffix("sub") == true)
  }

  @Test func missingDirectoryThrows() throws {
    let bogus = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("LocalLister-DoesNotExist-\(UUID().uuidString)")
    #expect(throws: (any Error).self) {
      try LocalDirectoryLister.list(directory: bogus.path)
    }
  }
}
