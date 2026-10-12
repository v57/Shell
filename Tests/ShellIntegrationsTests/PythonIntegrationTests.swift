import Foundation
import Testing
@testable import ShellIntegrations

private let pyproject = """
[project]
name = "demo-app"
version = "0.1.0"

[project.scripts]
serve = "demo_app.server:main"
demo = "demo_app.cli:main"

[dependencies]
requests = "*"
"""

private let pyprojectNoScripts = """
[project]
name = "demo-app"
version = "0.1.0"
"""

struct PythonIntegrationTests {
  private func makePython(
    driver: String? = "uv",
    manifest: String = pyproject
  ) -> PythonIntegration {
    PythonIntegration(
      resolveDriver: { driver },
      readManifest: { _ in manifest }
    )
  }

  @Test func relevanceRequiresMarkerFile() {
    let py = makePython()
    #expect(py.relevance(files: [DirectoryEntry(name: "pyproject.toml", isDirectory: false)]))
    #expect(py.relevance(files: [DirectoryEntry(name: "requirements.txt", isDirectory: false)]))
    // A directory literally named pyproject.toml / requirements.txt is NOT a marker.
    #expect(!py.relevance(files: [DirectoryEntry(name: "pyproject.toml", isDirectory: true)]))
    #expect(!py.relevance(files: [DirectoryEntry(name: "requirements.txt", isDirectory: true)]))
    // No marker file -> not relevant.
    #expect(!py.relevance(files: [DirectoryEntry(name: "main.py", isDirectory: false)]))
  }

  @Test func availabilityStartsFalse() {
    #expect(!makePython().isAvailable)
  }

  @Test func scanUvFirstEmitsUvCommands() {
    let actions = makePython(driver: "uv")
      .scan(directory: URL(fileURLWithPath: "/tmp/Demo"), files: [DirectoryEntry(name: "pyproject.toml", isDirectory: false)])

    #expect(actions.contains { $0.kind == .test && $0.title == "Test" && $0.command == "uv run pytest" })
    #expect(actions.contains { $0.kind == .lint && $0.title == "Lint" && $0.command == "uv run ruff check" })
    // Console scripts become per-script run targets.
    #expect(actions.contains { $0.kind == .run && $0.target == "serve" && $0.command == "uv run serve" })
    #expect(actions.contains { $0.kind == .run && $0.target == "demo" && $0.command == "uv run demo" })
    // Every command drives uv on the uv-first path.
    #expect(actions.allSatisfy { $0.command.contains("uv") })
  }

  @Test func scanFallsBackToPoetryWhenNoUv() {
    let actions = makePython(driver: "poetry")
      .scan(directory: URL(fileURLWithPath: "/tmp/Demo"), files: [DirectoryEntry(name: "pyproject.toml", isDirectory: false)])

    #expect(actions.contains { $0.kind == .test && $0.command == "poetry run pytest" })
    #expect(actions.contains { $0.kind == .run && $0.target == "serve" && $0.command == "poetry run serve" })
    // Lint is bare ruff on the non-uv path.
    #expect(actions.contains { $0.kind == .lint && $0.command == "ruff check" })
    #expect(actions.allSatisfy { !$0.command.contains("uv") })
    // Test + Run drive poetry; lint is bare ruff.
    #expect(actions.filter { $0.kind == .test || $0.kind == .run }.allSatisfy { $0.command.contains("poetry") })
  }

  @Test func scanPlainPip3Fallback() {
    let actions = makePython(driver: "pip3", manifest: pyprojectNoScripts)
      .scan(directory: URL(fileURLWithPath: "/tmp/Demo"), files: [DirectoryEntry(name: "requirements.txt", isDirectory: false)])

    #expect(actions.contains { $0.kind == .test && $0.command == "pytest" })
    #expect(actions.contains { $0.kind == .lint && $0.command == "ruff check" })
    // Project name becomes the single run target on the plain path.
    #expect(actions.contains { $0.kind == .run && $0.target == "demo-app" && $0.command == "python3 demo-app" })
    #expect(actions.allSatisfy { !$0.command.contains("uv") })
  }

  @Test func scanFallsBackToProjectNameWhenNoScripts() {
    let actions = makePython(manifest: pyprojectNoScripts)
      .scan(directory: URL(fileURLWithPath: "/tmp/Demo"), files: [DirectoryEntry(name: "pyproject.toml", isDirectory: false)])

    let runs = actions.filter { $0.kind == .run }
    #expect(runs.count == 1)
    #expect(runs.first?.target == "demo-app")
    #expect(runs.first?.title == "Run · demo-app")
    #expect(runs.first?.command == "uv run demo-app")
  }

  @Test func scanIgnoresDirectoryWithoutMarker() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let py = makePython()
    #expect(py.scan(directory: dir, files: []).isEmpty)
    #expect(py.scan(directory: dir, files: [DirectoryEntry(name: "README.md", isDirectory: false)]).isEmpty)
  }

  @Test func scanEmptyWhenNoDriverPresent() {
    let actions = makePython(driver: nil)
      .scan(directory: URL(fileURLWithPath: "/tmp/Demo"), files: [DirectoryEntry(name: "pyproject.toml", isDirectory: false)])
    #expect(actions.isEmpty)
  }

  @Test func requiredToolSurfacesAsPython3() {
    // Default isAvailable is false; the coordinator overwrites it from the probe.
    let py = PythonIntegration()
    #expect(py.id == "python")
    #expect(py.displayName == "Python")
    #expect(py.requiredTool == "python3")
    #expect(!py.isAvailable)
  }

  @Test func parseManifestCollectsNameAndScripts() {
    let parsed = PythonIntegration.parseManifest(pyproject)
    #expect(parsed.projectName == "demo-app")
    #expect(parsed.scriptNames == ["serve", "demo"])
  }

  @Test func parseManifestReadsPoetrySections() {
    let poetryToml = """
    [tool.poetry]
    name = "poetry-pkg"

    [tool.poetry.scripts]
    cli = "poetry_pkg.cli:main"
    """
    let parsed = PythonIntegration.parseManifest(poetryToml)
    #expect(parsed.projectName == "poetry-pkg")
    #expect(parsed.scriptNames == ["cli"])
  }

  @Test func parseManifestIgnoresDependencies() {
    let parsed = PythonIntegration.parseManifest(pyproject)
    // `[dependencies]` keys never become run targets.
    #expect(!parsed.scriptNames.contains("requests"))
  }
}
