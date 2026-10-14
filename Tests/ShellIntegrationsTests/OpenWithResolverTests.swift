import Foundation
import Testing
@testable import ShellIntegrations

struct OpenWithResolverTests {
  @Test func xcodeProjectOffersXcodeFirst() {
    let files = [
      DirectoryEntry(name: "MyApp.xcodeproj", isDirectory: true),
      DirectoryEntry(name: "Sources", isDirectory: true),
    ]
    #expect(OpenWithResolver.kinds(for: files) == [.xcode, .code, .zed, .vscode, .dev, .finder])
  }

  @Test func workspaceOffersXcodeFirst() {
    let files = [DirectoryEntry(name: "MyWorkspace.xcworkspace", isDirectory: true)]
    #expect(OpenWithResolver.kinds(for: files).first == .xcode)
  }

  @Test func swiftPackageWithoutXcodeOffersXcode() {
    let files = [
      DirectoryEntry(name: "Package.swift", isDirectory: false),
      DirectoryEntry(name: "Sources", isDirectory: true),
    ]
    #expect(OpenWithResolver.kinds(for: files) == [.xcode, .code, .zed, .vscode, .dev, .finder])
  }

  @Test func plainDirectoryOffersOnlyGenericApps() {
    let files = [DirectoryEntry(name: "notes.txt", isDirectory: false)]
    #expect(OpenWithResolver.kinds(for: files) == [.code, .zed, .vscode, .finder])
  }

  @Test func emptyDirectoryOffersOnlyGenericApps() {
    #expect(OpenWithResolver.kinds(for: []) == [.code, .zed, .vscode, .finder])
  }

  @Test func packageWithXcodeProjectOffersXcodeOnce() {
    let files = [
      DirectoryEntry(name: "Package.swift", isDirectory: false),
      DirectoryEntry(name: "App.xcodeproj", isDirectory: true),
    ]
    #expect(OpenWithResolver.kinds(for: files) == [.xcode, .code, .zed, .vscode, .dev, .finder])
  }

  @Test func markdownFilesOfferMarkdown() {
    let files = [DirectoryEntry(name: "README.md", isDirectory: false)]
    #expect(OpenWithResolver.kinds(for: files) == [.code, .zed, .vscode, .markdown, .finder])
  }

  @Test func repositoryOffersGit() {
    let files = [
      DirectoryEntry(name: "Package.swift", isDirectory: false),
      DirectoryEntry(name: "README.md", isDirectory: false),
    ]
    #expect(
      OpenWithResolver.kinds(for: files, isRepository: true)
        == [.xcode, .code, .zed, .vscode, .markdown, .git, .dev, .finder])
  }
}
