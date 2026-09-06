import Foundation
import Testing
@testable import TerminalIntegrations

private let composerWithScripts = #"""
{
    "name": "acme/app",
    "description": "A demo PHP application.",
    "scripts": {
        "test": "phpunit",
        "lint": "phpcs",
        "serve": "php -S localhost:8000",
        "migrate": ["php artisan migrate", "php artisan db:seed"]
    }
}
"""#

private let composerWithoutTest = #"""
{
    "name": "acme/app",
    "scripts": {
        "lint": "phpcs",
        "serve": "php -S localhost:8000"
    }
}
"""#

struct PHPIntegrationTests {
  private let marker = DirectoryEntry(name: "composer.json", isDirectory: false)

  private func makePHP(_ manifest: String?) -> PHPIntegration {
    PHPIntegration(isAvailable: true) { _ in manifest }
  }

  @Test func relevanceRequiresNonDirectoryComposerJson() {
    let php = PHPIntegration(isAvailable: true) { _ in "" }
    #expect(php.relevance(files: [marker]))
    // A directory literally named `composer.json` is NOT a PHP marker.
    #expect(!php.relevance(files: [DirectoryEntry(name: "composer.json", isDirectory: true)]))
    // Other files are not ours.
    #expect(!php.relevance(files: [DirectoryEntry(name: "package.json", isDirectory: false)]))
    #expect(!php.relevance(files: [DirectoryEntry(name: "index.php", isDirectory: false)]))
  }

  @Test func scanEmitsInstallTestAndRun() {
    let actions = makePHP(composerWithScripts).scan(
      directory: URL(fileURLWithPath: "/tmp/demo"),
      files: [marker]
    )

    #expect(actions.contains { $0.kind == .build && $0.title == "Install" && $0.command == "composer install" })
    #expect(actions.contains { $0.kind == .test && $0.title == "Test" && $0.command == "composer test" })
    #expect(actions.contains { $0.kind == .run && $0.target == "lint" && $0.command == "composer run-script lint" })
    #expect(actions.contains { $0.kind == .run && $0.target == "serve" && $0.command == "composer run-script serve" })
    // Every emitted command keys off the Composer toolchain.
    #expect(actions.allSatisfy { $0.command.contains("composer") })
  }

  @Test func scanRunTargetsEachScriptExcludingTest() {
    let actions = makePHP(composerWithScripts).scan(
      directory: URL(fileURLWithPath: "/tmp/demo"),
      files: [marker]
    )

    let runs = actions.filter { $0.kind == .run }
    #expect(runs.count == 3) // lint, serve, migrate — NOT test
    #expect(runs.allSatisfy { $0.target != "test" })
    #expect(runs.contains { $0.target == "migrate" && $0.command == "composer run-script migrate" })
    #expect(runs.allSatisfy { $0.command.hasPrefix("composer run-script ") })
  }

  @Test func scanOmitsTestWhenNoTestScript() {
    let actions = makePHP(composerWithoutTest).scan(
      directory: URL(fileURLWithPath: "/tmp/demo"),
      files: [marker]
    )

    #expect(!actions.contains { $0.kind == .test })
    #expect(actions.contains { $0.kind == .build && $0.command == "composer install" })
    #expect(actions.contains { $0.kind == .run && $0.target == "lint" && $0.command == "composer run-script lint" })
  }

  @Test func scanStillEmitsInstallWhenManifestUnreadable() {
    // A Composer project is relevant even without a parseable manifest — install
    // stays available; test/run (which need the scripts) simply drop out.
    let actions = makePHP(nil).scan(
      directory: URL(fileURLWithPath: "/tmp/demo"),
      files: [marker]
    )

    #expect(actions.contains { $0.kind == .build && $0.command == "composer install" })
    #expect(!actions.contains { $0.kind == .test })
    #expect(!actions.contains { $0.kind == .run })
  }

  @Test func scanIgnoresDirectoryWithoutComposerJson() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let actions = makePHP(composerWithScripts).scan(directory: dir, files: [])
    #expect(actions.isEmpty)
    #expect(makePHP(composerWithScripts).scan(
      directory: dir,
      files: [DirectoryEntry(name: "README.md", isDirectory: false)]
    ).isEmpty)
  }

  @Test func scriptNamesExtractsSortedKeys() {
    #expect(PHPIntegration.scriptNames(from: composerWithScripts) == ["lint", "migrate", "serve", "test"])
    #expect(PHPIntegration.scriptNames(from: composerWithoutTest) == ["lint", "serve"])
  }

  @Test func scriptNamesHandlesArrayAndStringValues() {
    // Both string- and array-valued scripts resolve; so do keys with no value.
    let source = #"{"scripts": {"t": "phpunit", "m": ["a", "b"], "e": null}}"#
    #expect(PHPIntegration.scriptNames(from: source) == ["e", "m", "t"])
  }

  @Test func scriptNamesRejectsGarbage() {
    #expect(PHPIntegration.scriptNames(from: "not json").isEmpty)
    #expect(PHPIntegration.scriptNames(from: #"{"name": "acme/app"}"#).isEmpty)
  }

  @Test func requiredToolSurfacesAsComposer() {
    // Default isAvailable is false; the coordinator overwrites it from the probe.
    let php = PHPIntegration { _ in "" }
    #expect(php.id == "php")
    #expect(php.displayName == "PHP")
    #expect(php.requiredTool == "composer")
    #expect(!php.isAvailable) // starts false until the probe overrides it
  }
}
