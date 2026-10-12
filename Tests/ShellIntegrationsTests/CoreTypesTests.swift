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

  @Test func actionKindRoundTrips() {
    for kind in IntegrationActionKind.allCases {
      #expect(IntegrationActionKind(rawValue: kind.rawValue) == kind)
    }
  }

  @Test func actionCodableRoundTrip() throws {
    let action = IntegrationAction(kind: .build, title: "Build", target: nil, command: "swift build")
    let data = try JSONEncoder().encode(action)
    let decoded = try JSONDecoder().decode(IntegrationAction.self, from: data)
    #expect(decoded == action)
    #expect(decoded.id == action.id)
  }

  @Test func actionWithTargetPreservesTarget() {
    let action = IntegrationAction(kind: .run, title: "Run · server", target: "server", command: "swift run server")
    #expect(action.target == "server")
    #expect(action.kind == .run)
  }
}
