import Foundation

/// Detects a Maven (JVM) project (`pom.xml`) and exposes build / test / run
/// smart actions. Active only when `mvn` is installed.
///
/// Thin: the marker/relevance and scan plumbing are delegated to the reusable
/// `ToolIntegrationBase` (this file supplies only the identity, the pom
/// reader, and the command builder), per the framework's per-language REUSE
/// RULE. Run (`mvn exec:java`) is emitted only when `exec-maven-plugin` is
/// configured in the pom. The pom reader is injectable so tests don't need a
/// real project on disk (mirrors `CargoIntegration`'s injectable manifest
/// reader).
public final class MavenIntegration: TerminalIntegration {
  /// Reads the `pom.xml` text for a directory; nil when unreadable.
  public typealias PomReader = (URL) -> String?

  private let base: ToolIntegrationBase

  public var id: String { base.id }
  public var displayName: String { base.displayName }
  public var requiredTool: String? { base.requiredTool }
  /// Starts false; the coordinator overwrites from `EnvironmentProbe` at launch.
  public var isAvailable: Bool {
    get { base.isAvailable }
    set { base.isAvailable = newValue }
  }

  /// - Parameters:
  ///   - isAvailable: Initial availability (overwritten by the coordinator).
  ///   - readPom: Reads `pom.xml`; injectable for headless tests.
  public init(
    isAvailable: Bool = false,
    readPom: @escaping PomReader = MavenIntegration.liveReadPom
  ) {
    self.base = ToolIntegrationBase(
      id: "maven",
      displayName: "Maven",
      requiredTool: "mvn",
      markerNames: ["pom.xml"],
      isDirectory: false,
      isAvailable: isAvailable
    ) { directory, _ in
      MavenIntegration.buildActions(directory: directory, readPom: readPom)
    }
  }

  public func relevance(files: [DirectoryEntry]) -> Bool {
    base.relevance(files: files)
  }

  public func scan(directory: URL, files: [DirectoryEntry]) -> [IntegrationAction] {
    base.scan(directory: directory, files: files)
  }

  /// Reads the `pom.xml` from disk. The live default for tests to override.
  public static func liveReadPom(_ url: URL) -> String? {
    try? String(contentsOf: url, encoding: .utf8)
  }

  /// Builds the smart actions for a Maven directory:
  /// build (`mvn compile`), test (`mvn test`), and — when `exec-maven-plugin`
  /// is configured — run (`mvn exec:java`). The run action is the only
  /// conditional one, gated on the exec plugin presence.
  static func buildActions(directory: URL, readPom: PomReader) -> [IntegrationAction] {
    let pomURL = directory.appendingPathComponent("pom.xml")
    guard let source = readPom(pomURL) else { return [] }
    let parsed = parsePom(source)

    var actions: [IntegrationAction] = []
    actions.append(IntegrationAction(kind: .build, title: "Build", target: nil, command: "mvn compile"))
    actions.append(IntegrationAction(kind: .test, title: "Test", target: nil, command: "mvn test"))
    if parsed.hasExecPlugin {
      actions.append(IntegrationAction(
        kind: .run,
        title: "Run",
        target: parsed.projectName,
        command: "mvn exec:java"
      ))
    }
    return actions
  }

  /// Extracts the project's own `artifactId` (the project name, a direct child
  /// of `<project>`) and whether `exec-maven-plugin` is *configured* (its
  /// `artifactId` is a direct child of a `<plugin>` element, whether that
  /// plugin is declared under `<build>` or `<pluginManagement>`). Only
  /// `artifactId` text is inspected, so a dependency or property that merely
  /// mentions the plugin name elsewhere does not turn on the Run action.
  /// `projectName` is nil when no direct `<project>` child artifactId is found
  /// (the run action then carries no target).
  static func parsePom(_ source: String) -> (projectName: String?, hasExecPlugin: Bool) {
    let chars = Array(source) // poms are small; array indexing avoids String.Index arithmetic
    let n = chars.count
    var projectName: String?
    var hasExecPlugin = false
    var stack: [String] = [] // open elements → the parent element of a tag
    var capturing = false // between <artifactId> and </artifactId>
    var artifactIdParent = ""
    var textBuffer = ""

    var i = 0
    while i < n {
      if chars[i] == "<" {
        // Close out any pending artifactId value now that the text is ending.
        if capturing, !textBuffer.isEmpty {
          let value = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
          if !value.isEmpty {
            // Only a direct child of <plugin> counts as "configured" — a
            // dependency or property of the same name is not a build plugin.
            if value == "exec-maven-plugin", artifactIdParent == "plugin" { hasExecPlugin = true }
            if artifactIdParent == "project", projectName == nil { projectName = value }
          }
        }
        textBuffer = ""
        capturing = false

        // Closing tag: `</name>`.
        if i + 1 < n, chars[i + 1] == "/" {
          var j = i + 2
          var name = ""
          while j < n, chars[j] != ">" { name.append(chars[j]); j += 1 }
          let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
          if stack.last == trimmed { _ = stack.popLast() }
          i = j + 1
          continue
        }
        // Comments / CDATA / doctype: `<!-- -->`, `<![CDATA[...]]>`, `<!DOCTYPE ...>`.
        if i + 1 < n, chars[i + 1] == "!" {
          var j = i + 1
          if i + 2 < n, chars[i + 1] == "!", chars[i + 2] == "[" { // CDATA
            while j < n {
              if chars[j] == "]", j + 2 < n, chars[j + 1] == "]", chars[j + 2] == ">" {
                j += 3
                break
              }
              j += 1
            }
            i = j
          } else {
            while j < n, chars[j] != ">" { j += 1 }
            i = j + 1
          }
          continue
        }
        // Processing instruction: `<? ... ?>`.
        if i + 1 < n, chars[i + 1] == "?" {
          var j = i + 1
          while j < n, chars[j] != ">" { j += 1 }
          i = j + 1
          continue
        }
        // Opening element including attributes and self-closing `/>`.
        var j = i + 1
        var name = ""
        var selfClosing = false
        while j < n {
          let c = chars[j]
          if c == ">" {
            j += 1
            break
          }
          if c == "/", j + 1 < n, chars[j + 1] == ">" {
            selfClosing = true
            j += 2
            break
          }
          if c == " " || c == "\t" || c == "\n" || c == "\r" {
            // Skip attribute text up to `>`, honoring a trailing `/>`.
            while j < n, chars[j] != ">" {
              if chars[j] == "/", j + 1 < n, chars[j + 1] == ">" { selfClosing = true }
              j += 1
            }
            if j < n, chars[j] == ">" { j += 1 }
            break
          }
          name.append(c)
          j += 1
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "artifactId" {
          capturing = true
          artifactIdParent = stack.last ?? ""
        } else if !selfClosing, !trimmed.isEmpty {
          stack.append(trimmed)
        }
        i = j
      } else {
        if capturing { textBuffer.append(chars[i]) }
        i += 1
      }
    }
    return (projectName, hasExecPlugin)
  }
}
