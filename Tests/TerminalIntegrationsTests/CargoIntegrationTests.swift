import Foundation
import Testing
@testable import TerminalIntegrations

struct CargoIntegrationTests {
  private func makeCargo(_ manifest: String) -> CargoIntegration {
    CargoIntegration(isAvailable: true) { _ in manifest }
  }

  @Test func relevanceRequiresCargoToml() {
    let cargo = CargoIntegration(isAvailable: true) { _ in "" }
    #expect(cargo.relevance(files: [DirectoryEntry(name: "Cargo.toml", isDirectory: false)]))
    // Cargo.lock is not a marker; a directory named Cargo.toml isn't either.
    #expect(!cargo.relevance(files: [DirectoryEntry(name: "Cargo.lock", isDirectory: false)]))
    #expect(!cargo.relevance(files: [DirectoryEntry(name: "Cargo.toml", isDirectory: true)]))
    #expect(!cargo.relevance(files: [DirectoryEntry(name: "main.rs", isDirectory: false)]))
  }

  @Test func scanProducesBuildTestLintAndPerBinRun() {
    let cargoToml = """
    [package]
    name = "demo-app"
    version = "0.1.0"

    [[bin]]
    name = "server"
    path = "src/main.rs"

    [[bin]]
    name = "worker"
    path = "src/bin/worker.rs"

    [[example]]
    name = "sample"

    [[test]]
    name = "integration"

    [dependencies]
    serde = "1"
    """
    let actions = makeCargo(cargoToml).scan(
      directory: URL(fileURLWithPath: "/tmp/demo"),
      files: [DirectoryEntry(name: "Cargo.toml", isDirectory: false)]
    )

    #expect(actions.contains { $0.kind == .build && $0.title == "Build" && $0.command == "cargo build" })
    #expect(actions.contains { $0.kind == .test && $0.title == "Test" && $0.command == "cargo test" })
    #expect(actions.contains { $0.kind == .lint && $0.title == "Lint" && $0.command == "cargo clippy" })
    #expect(actions.contains { $0.kind == .run && $0.target == "server" && $0.command == "cargo run --bin server" })
    #expect(actions.contains { $0.kind == .run && $0.target == "worker" && $0.command == "cargo run --bin worker" })
    // [[example]] / [[test]] names are NOT run targets.
    #expect(!actions.contains { $0.kind == .run && $0.target == "sample" })
    #expect(!actions.contains { $0.kind == .run && $0.target == "integration" })
  }

  @Test func scanFallsBackToCargoRunWhenNoBins() {
    let cargoToml = """
    [package]
    name = "demo-app"
    version = "0.1.0"
    """
    let actions = makeCargo(cargoToml).scan(
      directory: URL(fileURLWithPath: "/tmp/demo"),
      files: [DirectoryEntry(name: "Cargo.toml", isDirectory: false)]
    )

    let runs = actions.filter { $0.kind == .run }
    #expect(runs.count == 1)
    #expect(runs.first?.command == "cargo run")
    #expect(runs.first?.target == "demo-app")
  }

  @Test func scanIgnoresDirectoryWithoutCargoToml() {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let cargo = CargoIntegration(isAvailable: true) { _ in "[package]\nname = \"should-not-run\"" }
    #expect(cargo.scan(directory: dir, files: []).isEmpty)
  }

  @Test func scanEmptyWhenManifestUnreadable() {
    let cargo = CargoIntegration(isAvailable: true) { _ in nil }
    let files = [DirectoryEntry(name: "Cargo.toml", isDirectory: false)]
    #expect(cargo.scan(directory: URL(fileURLWithPath: "/tmp/demo"), files: files).isEmpty)
  }

  @Test func parseManifestCollectsBinsAndPackageName() {
    let parsed = CargoIntegration.parseManifest("""
    [package]
    name = "demo-app"
    version = "0.1.0"

    [[bin]]
    name = "server"

    [[bin]]
    name = "server"
    """)
    #expect(parsed.packageName == "demo-app")
    #expect(parsed.binNames == ["server"])  // duplicates collapsed
  }

  @Test func requiredToolSurfacesAsCargo() {
    // Default isAvailable is false; the coordinator overwrites it from the probe.
    let cargo = CargoIntegration { _ in "" }
    #expect(cargo.id == "cargo")
    #expect(cargo.displayName == "Rust")
    #expect(cargo.requiredTool == "cargo")
    #expect(!cargo.isAvailable)  // starts false until the probe overrides it
  }
}
