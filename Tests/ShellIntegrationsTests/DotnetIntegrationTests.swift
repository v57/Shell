import Foundation
import Testing
@testable import ShellIntegrations

struct DotnetIntegrationTests {
  @Test func relevanceRequiresDotnetMarker() {
    let dotnet = DotnetIntegration(isAvailable: true)
    // Any of the three suffixes counts as a marker.
    #expect(dotnet.relevance(files: [DirectoryEntry(name: "Demo.csproj", isDirectory: false)]))
    #expect(dotnet.relevance(files: [DirectoryEntry(name: "Demo.sln", isDirectory: false)]))
    #expect(dotnet.relevance(files: [DirectoryEntry(name: "Demo.slnx", isDirectory: false)]))
    // A non-marker file is not relevant; neither is a *directory* named like
    // a marker (e.g. a folder named "Demo.csproj").
    #expect(!dotnet.relevance(files: [DirectoryEntry(name: "main.swift", isDirectory: false)]))
    #expect(!dotnet.relevance(files: [DirectoryEntry(name: "Demo.csproj", isDirectory: true)]))
  }

  @Test func scanProducesBuildTestRunForSolution() {
    let actions = DotnetIntegration(isAvailable: true).scan(
      directory: URL(fileURLWithPath: "/tmp/demo"),
      files: [DirectoryEntry(name: "Demo.sln", isDirectory: false)]
    )

    #expect(actions.contains { $0.kind == .build && $0.title == "Build" && $0.command == "dotnet build" })
    #expect(actions.contains { $0.kind == .test && $0.title == "Test" && $0.command == "dotnet test" })
    #expect(actions.contains { $0.kind == .run && $0.title == "Run" && $0.command == "dotnet run" })
    // Every action is grouped under the picked solution name.
    #expect(actions.allSatisfy { $0.target == "Demo" })
  }

  @Test func scanCarriesSingleCsprojAsTarget() {
    let actions = DotnetIntegration(isAvailable: true).scan(
      directory: URL(fileURLWithPath: "/tmp/demo"),
      files: [DirectoryEntry(name: "WebApp.csproj", isDirectory: false)]
    )
    #expect(actions.count == 3)
    #expect(actions.allSatisfy { $0.target == "WebApp" })
  }

  @Test func scanIgnoresDirectoryWithoutMarker() {
    let dotnet = DotnetIntegration(isAvailable: true)
    #expect(dotnet.scan(directory: URL(fileURLWithPath: "/tmp/demo"), files: []).isEmpty)
    #expect(dotnet.scan(
      directory: URL(fileURLWithPath: "/tmp/demo"),
      files: [DirectoryEntry(name: "README.md", isDirectory: false)]
    ).isEmpty)
  }

  @Test func projectNamePrefersSolutionThenSingleCsproj() {
    // A solution outranks any project file.
    #expect(DotnetIntegration.projectName(from: [
      DirectoryEntry(name: "Sol.sln", isDirectory: false),
      DirectoryEntry(name: "App.csproj", isDirectory: false),
    ]) == "Sol")
    // .slnx solution is also picked.
    #expect(DotnetIntegration.projectName(from: [
      DirectoryEntry(name: "Sol.slnx", isDirectory: false),
    ]) == "Sol")
    // A lone .csproj is picked.
    #expect(DotnetIntegration.projectName(from: [
      DirectoryEntry(name: "App.csproj", isDirectory: false),
    ]) == "App")
    // Multiple projects with no solution is ambiguous → nil.
    #expect(DotnetIntegration.projectName(from: [
      DirectoryEntry(name: "A.csproj", isDirectory: false),
      DirectoryEntry(name: "B.csproj", isDirectory: false),
    ]) == nil)
  }

  @Test func requiredToolSurfacesAsDotnet() {
    // Default isAvailable is false; the coordinator overwrites it from the probe.
    let dotnet = DotnetIntegration()
    #expect(dotnet.id == "dotnet")
    #expect(dotnet.displayName == ".NET")
    #expect(dotnet.requiredTool == "dotnet")
    #expect(!dotnet.isAvailable)
  }
}
