import Foundation
import Testing
@testable import TerminalIntegrations

struct XcodeIntegrationTests {
  private let projectJSON = #"""
  {"project":{"name":"Demo","targets":["App","Core"]},"schemes":["Demo"]}
  """#

  private func makeXcode() -> XcodeIntegration {
    XcodeIntegration(isAvailable: true) { _ in projectJSON }
  }

  @Test func relevanceRequiresProjectBundle() {
    let files = [DirectoryEntry(name: "Demo.xcodeproj", isDirectory: true)]
    #expect(makeXcode().relevance(files: files))
    #expect(!makeXcode().relevance(files: [DirectoryEntry(name: "main.swift", isDirectory: false)]))
  }

  @Test func scanProducesBuildTestRunPerScheme() throws {
    let xcode = makeXcode()
    let files = [DirectoryEntry(name: "Demo.xcodeproj", isDirectory: true)]
    let actions = xcode.scan(
      directory: URL(fileURLWithPath: "/tmp/Demo"),
      files: files
    )

    #expect(actions.count == 5)
    #expect(actions.filter { $0.target == "Demo" }.count == 5)

    let build = actions.first { $0.kind == .build }
    #expect(build?.command.contains("-project") == true)
    #expect(build?.command.contains("-scheme 'Demo' build") == true)

    let test = actions.first { $0.kind == .test }
    #expect(test?.command.contains("test") == true)

    let run = actions.first { $0.kind == .run }
    #expect(run?.command.contains("-derivedDataPath") == true)
    #expect(run?.command.contains("open ") == true)
    #expect(run?.command.hasSuffix("Demo.app'") == true)

    let distribute = actions.filter { $0.kind == .distribute }
    #expect(distribute.count == 2)

    let install = distribute.first { $0.title == "Install · Demo" }
    #expect(install?.command.contains("rm -rf '/Applications/Demo.app'") == true)
    #expect(install?.command.contains("ditto 'build/Demo/Demo.xcarchive/Products/Applications/Demo.app' '/Applications/Demo.app'") == true)
    #expect(install?.command.contains("-archivePath 'build/Demo/Demo.xcarchive'") == true)

    let upload = distribute.first { $0.title == "Upload to App Store · Demo" }
    #expect(upload?.command.contains("-archivePath 'build/Demo/Demo.xcarchive' archive -allowProvisioningUpdates") == true)
    #expect(upload?.command.contains("exportOptions.plist") == true)
    #expect(upload?.command.contains("-allowProvisioningUpdates") == true)
    #expect(upload?.command.contains("app-store-connect") == true)
  }

  @Test func scanIgnoresDirectoryWithoutProject() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(makeXcode().scan(directory: dir, files: []).isEmpty)
  }

  @Test func scanEmptyWhenBuildListFails() throws {
    let xcode = XcodeIntegration(isAvailable: true) { _ in nil }
    let files = [DirectoryEntry(name: "Demo.xcodeproj", isDirectory: true)]
    #expect(xcode.scan(directory: URL(fileURLWithPath: "/tmp/Demo"), files: files).isEmpty)
  }

  @Test func parseSchemesPrefersTopLevelOverProjectTargets() {
    #expect(XcodeIntegration.parseSchemes(from: projectJSON) == ["Demo"])
  }

  @Test func parseSchemesFallsBackToWorkspace() {
    let json = #"{"workspace":{"name":"W","schemes":["A","B"]}}"#
    #expect(XcodeIntegration.parseSchemes(from: json) == ["A", "B"])
  }

  @Test func parseSchemesFallsBackToTargets() {
    let json = #"{"project":{"name":"P","targets":["T1","T2"]}}"#
    #expect(XcodeIntegration.parseSchemes(from: json) == ["T1", "T2"])
  }

  @Test func parseSchemesRejectsGarbage() {
    #expect(XcodeIntegration.parseSchemes(from: "not json") == nil)
  }
}
