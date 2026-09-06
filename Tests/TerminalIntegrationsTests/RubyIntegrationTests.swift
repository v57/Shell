import Foundation
import Testing
@testable import TerminalIntegrations

struct RubyIntegrationTests {
  private func makeRuby() -> RubyIntegration {
    RubyIntegration(isAvailable: true)
  }

  @Test func relevanceRequiresNonDirectoryGemfile() {
    let ruby = RubyIntegration(isAvailable: true)
    #expect(ruby.relevance(files: [DirectoryEntry(name: "Gemfile", isDirectory: false)]))
    // A directory literally named Gemfile is NOT a Bundler marker.
    #expect(!ruby.relevance(files: [DirectoryEntry(name: "Gemfile", isDirectory: true)]))
    #expect(!ruby.relevance(files: [DirectoryEntry(name: "gems.rb", isDirectory: false)]))
    #expect(!ruby.relevance(files: [DirectoryEntry(name: "package.json", isDirectory: false)]))
  }

  @Test func scanEmitsInstallTestLintAndRun() {
    let actions = makeRuby().scan(
      directory: URL(fileURLWithPath: "/tmp/ruby"),
      files: [
        DirectoryEntry(name: "Gemfile", isDirectory: false),
        DirectoryEntry(name: "main.rb", isDirectory: false),
      ]
    )

    #expect(actions.contains { $0.kind == .build && $0.title == "Install" && $0.command == "bundle install" })
    #expect(actions.contains { $0.kind == .test && $0.title == "Test" && $0.command == "bundle exec rspec" })
    #expect(actions.contains { $0.kind == .lint && $0.title == "Lint" && $0.command == "bundle exec rubocop" })
    #expect(actions.contains { $0.kind == .run && $0.title == "Run · main" && $0.target == "main" && $0.command == "bundle exec ruby main.rb" })

    // Every command keys off the Bundler toolchain.
    #expect(actions.allSatisfy { $0.command.contains("bundle") })
  }

  @Test func scanOmitsRunWhenNoMainFileResolves() {
    let actions = makeRuby().scan(
      directory: URL(fileURLWithPath: "/tmp/ruby"),
      files: [
        DirectoryEntry(name: "Gemfile", isDirectory: false),
        DirectoryEntry(name: "README.md", isDirectory: false),
      ]
    )
    #expect(actions.contains { $0.kind == .build })
    #expect(actions.contains { $0.kind == .test })
    #expect(actions.contains { $0.kind == .lint })
    #expect(!actions.contains { $0.kind == .run })
  }

  @Test func scanPrefersConventionalEntryNames() {
    let actions = makeRuby().scan(
      directory: URL(fileURLWithPath: "/tmp/ruby"),
      files: [
        DirectoryEntry(name: "Gemfile", isDirectory: false),
        DirectoryEntry(name: "app.rb", isDirectory: false),
        DirectoryEntry(name: "zzz.rb", isDirectory: false),
      ]
    )
    #expect(actions.contains { $0.kind == .run && $0.command == "bundle exec ruby app.rb" })
  }

  @Test func scanUsesMainBaseNameAsTarget() {
    let actions = makeRuby().scan(
      directory: URL(fileURLWithPath: "/tmp/ruby"),
      files: [
        DirectoryEntry(name: "Gemfile", isDirectory: false),
        DirectoryEntry(name: "server.rb", isDirectory: false),
      ]
    )
    #expect(actions.contains { $0.kind == .run && $0.target == "server" && $0.command == "bundle exec ruby server.rb" })
  }

  @Test func scanIgnoresDirectoryWithoutGemfile() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let actions = makeRuby().scan(directory: dir, files: [])
    #expect(actions.isEmpty)
  }

  @Test func requiredToolSurfacesAsBundler() {
    // Default isAvailable is false; the coordinator overwrites it from the probe.
    let ruby = RubyIntegration()
    #expect(ruby.id == "ruby")
    #expect(ruby.displayName == "Ruby")
    #expect(ruby.requiredTool == "bundle")
    #expect(!ruby.isAvailable)  // starts false until the probe overrides it
  }
}
