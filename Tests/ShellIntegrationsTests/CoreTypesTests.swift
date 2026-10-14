import Foundation
import Testing
@testable import ShellIntegrations

struct CoreTypesTests {
  @Test func directoryEntryHashableAndEqual() {
    let a = DirectoryEntry(name: "Package.swift", isDirectory: false)
    let b = DirectoryEntry(name: "Package.swift", isDirectory: false)
    #expect(a == b)
    #expect(Set([a, b]).count == 1)
  }
}
