import Foundation
import ShellKit

/// Debug builds: `--screenshot-demo` runs Shell on made-up hosts, databases and notes for the screenshots
/// (`.dev/screenshots.json`), never the user's. The vault opens a fresh store in a temporary folder and never syncs;
/// actions, web pages and history are the demo's own (debug builds share the installed app's defaults); the
/// screen/tmux monitor stays off, since it lists the Mac's real sessions. `.dev/screenshots.json` also gives the
/// launch a `ZDOTDIR` with a plain prompt.
///
///   --screenshot-demo         the demo
///   --run <command>           typed into the first terminal
///   --note <name>             shows a demo note
///   --actions / --settings    opens that overlay
///   --new-database            opens the New Database Connection sheet
enum ScreenshotDemo {
  static let isOn: Bool = {
    #if DEBUG
      CommandLine.arguments.contains("--screenshot-demo")
    #else
      false
    #endif
  }()

  static func value(_ option: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: option), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
  }

  static func flag(_ option: String) -> Bool { isOn && CommandLine.arguments.contains(option) }

  private static let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ShellScreenshotDemo")

  /// Actions and web pages of the demo, apart from the user's.
  static let defaults: UserDefaults = {
    let name = "dev.v57.sh.screenshot-demo"
    let defaults = UserDefaults(suiteName: name) ?? .standard
    defaults.removePersistentDomain(forName: name)
    return defaults
  }()

  static var historyFile: URL { folder.appendingPathComponent("history.shellhistory") }

  /// Before anything opens the vault: a fresh, empty store of the demo's own.
  static func prepare() {
    try? FileManager.default.removeItem(at: folder)
    let vault = folder.appendingPathComponent("Vault", isDirectory: true)
    try? FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
    setenv("VAULT_DIRECTORY", vault.path, 1)
  }

  /// The demo's records, then the scene's terminal command, note or panel.
  @MainActor static func apply(to model: AppModel) {
    let atlas = SSHConfig(name: "atlas-web-1", host: "web1.atlas.example.com", user: "deploy")
    let staging = SSHConfig(name: "staging", host: "staging.atlas.example.com", user: "maya")
    let pi = SSHConfig(name: "Raspberry Pi", host: "pi.local", user: "pi")
    for config in [atlas, staging, pi] { model.updateConnection(config) }

    model.saveDatabaseConnection(
      DatabaseConnection(
        engine: .postgres, name: "Atlas production", host: "db.atlas.example.com", port: 5432, database: "atlas",
        username: "readonly", sshConfigID: atlas.id))
    model.saveDatabaseConnection(
      DatabaseConnection(engine: .redis, name: "Sessions cache", host: "cache.atlas.example.com", port: 6379))
    model.saveDatabaseConnection(
      DatabaseConnection(engine: .mongodb, name: "Catalog", host: "localhost", port: 27017, database: "catalog"))

    for (name, category, commands) in [
      ("Build", "Atlas", "swift build"), ("Test", "Atlas", "swift test"), ("Deploy", "Atlas", "atlas deploy --tag v2.0"),
      ("Tail logs", "Servers", "journalctl -u atlas -f"), ("Restart", "Servers", "sudo systemctl restart atlas"),
      ("Disk usage", "Servers", "df -h"), ("Postgres", "Daemons", "postgres -D /usr/local/var/postgres"),
      ("Redis", "Daemons", "redis-server"),
    ] {
      model.actions.save(
        Action(name: name, category: category, appliesToFutureSSHConnections: category == "Servers", commands: commands))
    }

    model.notes.addNote(named: "Deploy checklist", text: deployChecklist, encrypted: false)
    let release = model.notes.addNote(named: "Release 2.0", text: releaseNotes, encrypted: false)

    if let command = value("--run"), let session = model.sessions.first {
      // The shell needs a moment to print its first prompt.
      Task {
        try? await Task.sleep(for: .seconds(1))
        model.insertCommandText(command + "\n", into: session)
      }
    }
    if value("--note") != nil { model.selection = .note(release.id) }
    if flag("--actions") { model.showingActions = true }
    if flag("--settings") { model.showingSettings = true }
    if flag("--new-database") { model.showingNewDatabaseConnection = true }
  }

  private static let deployChecklist = """
    # Deploy checklist

    - [x] Tag the release
    - [x] Run the migrations on staging
    - [ ] Warm the cache on atlas-web-1
    - [ ] Post in #releases
    """

  private static let releaseNotes = """
    # Release 2.0

    Trips start on the first screen, and sync is faster for large trips.

    ## Steps

    1. `ssh atlas-web-1`
    2. `sudo systemctl restart atlas`
    3. Check `journalctl -u atlas -f` for a minute

    > Roll back with `atlas deploy --previous`.
    """
}
