import Foundation
import Testing
@testable import TerminalIntegrations

struct MavenIntegrationTests {
  private func makeMaven(_ pom: String?) -> MavenIntegration {
    MavenIntegration(isAvailable: true) { _ in pom }
  }

  @Test func relevanceRequiresNonDirectoryPomXml() {
    let maven = MavenIntegration(isAvailable: true) { _ in "" }
    #expect(maven.relevance(files: [DirectoryEntry(name: "pom.xml", isDirectory: false)]))
    // A directory literally named `pom.xml` is NOT a Maven project marker.
    #expect(!maven.relevance(files: [DirectoryEntry(name: "pom.xml", isDirectory: true)]))
    // Other build manifests are not ours.
    #expect(!maven.relevance(files: [DirectoryEntry(name: "build.gradle", isDirectory: false)]))
    #expect(!maven.relevance(files: [DirectoryEntry(name: "Main.java", isDirectory: false)]))
  }

  @Test func scanProducesBuildAndTestWithoutExecPlugin() {
    let pom = """
    <project>
      <modelVersion>4.0.0</modelVersion>
      <groupId>com.example</groupId>
      <artifactId>demo-app</artifactId>
      <version>1.0.0</version>
    </project>
    """
    let actions = makeMaven(pom).scan(
      directory: URL(fileURLWithPath: "/tmp/demo"),
      files: [DirectoryEntry(name: "pom.xml", isDirectory: false)]
    )

    #expect(actions.contains { $0.kind == .build && $0.title == "Build" && $0.command == "mvn compile" })
    #expect(actions.contains { $0.kind == .test && $0.title == "Test" && $0.command == "mvn test" })
    // No exec-maven-plugin configured -> no run action.
    #expect(!actions.contains { $0.kind == .run })
    // Every emitted command keys off `mvn`.
    #expect(actions.allSatisfy { $0.command.contains("mvn") })
  }

  @Test func scanAddsRunWhenExecPluginConfigured() {
    let pom = """
    <project>
      <modelVersion>4.0.0</modelVersion>
      <groupId>com.example</groupId>
      <artifactId>demo-app</artifactId>
      <version>1.0.0</version>
      <build>
        <plugins>
          <plugin>
            <groupId>org.codehaus.mojo</groupId>
            <artifactId>exec-maven-plugin</artifactId>
            <version>3.1.0</version>
            <configuration>
              <mainClass>com.example.Main</mainClass>
            </configuration>
          </plugin>
        </plugins>
      </build>
    </project>
    """
    let actions = makeMaven(pom).scan(
      directory: URL(fileURLWithPath: "/tmp/demo"),
      files: [DirectoryEntry(name: "pom.xml", isDirectory: false)]
    )

    let run = actions.first { $0.kind == .run }
    #expect(run != nil)
    #expect(run?.command == "mvn exec:java")
    #expect(run?.target == "demo-app")
    #expect(run?.title == "Run")
    // Build and test still present alongside the run action.
    #expect(actions.contains { $0.kind == .build && $0.command == "mvn compile" })
    #expect(actions.contains { $0.kind == .test && $0.command == "mvn test" })
  }

  @Test func scanIgnoresDirectoryWithoutPomXml() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let actions = makeMaven("<project></project>").scan(directory: dir, files: [])
    #expect(actions.isEmpty)
  }

  @Test func scanEmptyWhenPomUnreadable() {
    let maven = MavenIntegration(isAvailable: true) { _ in nil }
    let files = [DirectoryEntry(name: "pom.xml", isDirectory: false)]
    #expect(maven.scan(directory: URL(fileURLWithPath: "/tmp/demo"), files: files).isEmpty)
  }

  @Test func parsePomExtractsProjectNameAndExecPlugin() {
    let parsed = MavenIntegration.parsePom("""
    <project>
      <modelVersion>4.0.0</modelVersion>
      <artifactId>demo-app</artifactId>
      <parent>
        <artifactId>parent-override</artifactId>
      </parent>
      <build>
        <pluginManagement>
          <plugins>
            <plugin>
              <artifactId>exec-maven-plugin</artifactId>
            </plugin>
          </plugins>
        </pluginManagement>
      </build>
    </project>
    """)
    // The project's own artifactId is captured, not the parent's.
    #expect(parsed.projectName == "demo-app")
    // exec-maven-plugin inside pluginManagement still counts as configured.
    #expect(parsed.hasExecPlugin == true)
  }

  @Test func projectsWithoutExecPluginAreNotRun() {
    let parsed = MavenIntegration.parsePom("""
    <project>
      <artifactId>only-build</artifactId>
      <dependencies>
        <dependency>
          <groupId>com.example</groupId>
          <artifactId>exec-maven-plugin</artifactId>
          <version>3.1.0</version>
        </dependency>
      </dependencies>
    </project>
    """)
    // A *dependency* artifactId of the same name is NOT a configured build plugin.
    #expect(parsed.hasExecPlugin == false)
  }

  @Test func requiredToolSurfacesAsMaven() {
    // Default isAvailable is false; the coordinator overwrites it from the probe.
    let maven = MavenIntegration { _ in "" }
    #expect(maven.id == "maven")
    #expect(maven.displayName == "Maven")
    #expect(maven.requiredTool == "mvn")
    #expect(!maven.isAvailable) // starts false until the probe overrides it
  }
}
