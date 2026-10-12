import Foundation
import Testing
@testable import ShellIntegrations

struct FileListerTests {
  private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  @Test func listerReturnsTopLevelEntries() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try "".write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("Sources"), withIntermediateDirectories: true)

    let entries = IntegrationFileLister.list(directory: dir)
    #expect(entries.contains { $0.name == "Package.swift" && !$0.isDirectory })
    #expect(entries.contains { $0.name == "Sources" && $0.isDirectory })
  }

  @Test func listerSkipsHiddenEntries() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try "".write(to: dir.appendingPathComponent("app.swift"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)

    let entries = IntegrationFileLister.list(directory: dir)
    #expect(entries.contains { $0.name == "app.swift" })
    #expect(!entries.contains { $0.name == ".git" })
    #expect(!entries.contains { $0.name == ".DS_Store" })
  }
}

struct FingerprintTests {
  @Test func fingerprintOrderIndependent() {
    let a = [DirectoryEntry(name: "z", isDirectory: true), DirectoryEntry(name: "a", isDirectory: false)]
    let b = [DirectoryEntry(name: "a", isDirectory: false), DirectoryEntry(name: "z", isDirectory: true)]
    #expect(IntegrationFingerprint.hash(entries: a) == IntegrationFingerprint.hash(entries: b))
  }

  @Test func fingerprintChangesWhenTypeChanges() {
    let a = [DirectoryEntry(name: "a", isDirectory: false)]
    let b = [DirectoryEntry(name: "a", isDirectory: true)]
    #expect(IntegrationFingerprint.hash(entries: a) != IntegrationFingerprint.hash(entries: b))
  }

  @Test func fingerprintChangesWhenEntryAdded() {
    let a = [DirectoryEntry(name: "a", isDirectory: false)]
    let b = [DirectoryEntry(name: "a", isDirectory: false), DirectoryEntry(name: "b", isDirectory: false)]
    #expect(IntegrationFingerprint.hash(entries: a) != IntegrationFingerprint.hash(entries: b))
  }
}
