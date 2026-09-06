import Foundation
import Testing
@testable import TerminalIntegrations

struct ElixirIntegrationTests {
  private func makeMix() -> ElixirIntegration {
    ElixirIntegration(isAvailable: true)
  }

  @Test func relevanceRequiresNonDirectoryMixExs() {
    let elixir = makeMix()
    #expect(elixir.relevance(files: [DirectoryEntry(name: "mix.exs", isDirectory: false)]))
    // A directory literally named `mix.exs` is NOT an Elixir project marker.
    #expect(!elixir.relevance(files: [DirectoryEntry(name: "mix.exs", isDirectory: true)]))
    // Other manifest/source files are not ours.
    #expect(!elixir.relevance(files: [DirectoryEntry(name: "package.json", isDirectory: false)]))
    #expect(!elixir.relevance(files: [DirectoryEntry(name: "lib.ex", isDirectory: false)]))
  }

  @Test func scanProducesInstallTestAndRun() {
    let actions = makeMix().scan(
      directory: URL(fileURLWithPath: "/tmp/demo"),
      files: [DirectoryEntry(name: "mix.exs", isDirectory: false)]
    )

    #expect(actions.contains { $0.kind == .build && $0.title == "Install" && $0.command == "mix deps.get" })
    #expect(actions.contains { $0.kind == .test && $0.title == "Test" && $0.command == "mix test" })
    #expect(actions.contains { $0.kind == .run && $0.title == "Run" && $0.command == "mix run" })
    // Every emitted command keys off the Elixir build tool.
    #expect(actions.allSatisfy { $0.command.contains("mix") })
  }

  @Test func scanTargetsAreNilForEveryAction() {
    // `mix` reads mix.exs itself — there is no project/script/bin name to
    // resolve into a target, so all three run against the whole project.
    let actions = makeMix().scan(
      directory: URL(fileURLWithPath: "/tmp/demo"),
      files: [DirectoryEntry(name: "mix.exs", isDirectory: false)]
    )
    #expect(actions.allSatisfy { $0.target == nil })
  }

  @Test func scanReturnsEmptyWithoutMixExs() {
    let actions = makeMix().scan(directory: URL(fileURLWithPath: "/tmp/demo"), files: [])
    #expect(actions.isEmpty)
  }

  @Test func requiredToolSurfacesAsMix() {
    // Default isAvailable is false; the coordinator overwrites it from the probe.
    let elixir = ElixirIntegration()
    #expect(elixir.id == "elixir")
    #expect(elixir.displayName == "Elixir")
    #expect(elixir.requiredTool == "mix")
    #expect(!elixir.isAvailable) // starts false until the probe overrides it
  }
}
