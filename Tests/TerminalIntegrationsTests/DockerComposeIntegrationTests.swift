import Foundation
import Testing
@testable import TerminalIntegrations

struct DockerComposeIntegrationTests {
  private let docker = DockerComposeIntegration(isAvailable: true)

  @Test func relevanceRequiresNonDirectoryComposeFile() {
    #expect(docker.relevance(files: [DirectoryEntry(name: "compose.yml", isDirectory: false)]))
    #expect(docker.relevance(files: [DirectoryEntry(name: "compose.yaml", isDirectory: false)]))
    #expect(docker.relevance(files: [DirectoryEntry(name: "docker-compose.yml", isDirectory: false)]))
    // A directory literally named compose.yml is NOT a Compose marker.
    #expect(!docker.relevance(files: [DirectoryEntry(name: "compose.yml", isDirectory: true)]))
    #expect(!docker.relevance(files: [DirectoryEntry(name: "docker-compose.yml", isDirectory: true)]))
    #expect(!docker.relevance(files: [DirectoryEntry(name: "main.go", isDirectory: false)]))
  }

  @Test func scanProducesBuildUpDownLogs() {
    let files = [DirectoryEntry(name: "compose.yaml", isDirectory: false)]
    let actions = docker.scan(directory: URL(fileURLWithPath: "/tmp/ComposeDemo"), files: files)

    #expect(actions.contains { $0.kind == .build && $0.title == "Build" && $0.command == "docker compose build" })
    #expect(actions.contains { $0.kind == .run && $0.title == "Up" && $0.command == "docker compose up -d" })
    #expect(actions.contains { $0.kind == .run && $0.title == "Down" && $0.command == "docker compose down" })
    #expect(actions.contains { $0.kind == .run && $0.title == "Logs" && $0.command == "docker compose logs -f" })

    // Every command keys off `docker`; no parsed compose service target.
    #expect(actions.allSatisfy { $0.command.contains("docker") })
    #expect(actions.allSatisfy { $0.target == nil })
  }

  @Test func scanIgnoresDirectoryWithoutComposeMarker() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let actions = docker.scan(directory: dir, files: [])
    #expect(actions.isEmpty)
  }

  @Test func requiredToolSurfacesAsDocker() {
    // Default isAvailable is false; the coordinator overwrites it from the probe.
    let docker = DockerComposeIntegration()
    #expect(docker.id == "docker")
    #expect(docker.displayName == "Docker Compose")
    #expect(docker.requiredTool == "docker")
    #expect(!docker.isAvailable)  // starts false until the probe overrides it
  }
}
