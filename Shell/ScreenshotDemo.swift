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
///   --run-action <name>       runs that demo action and shows its run
///
/// A capture takes every scene in one launch: the next scene's arguments arrive through `Screenshots` and `open`
/// shows them in place, after undoing what the scene before left open.
enum ScreenshotDemo {
  static let isOn: Bool = {
    #if DEBUG
      CommandLine.arguments.contains("--screenshot-demo")
    #else
      false
    #endif
  }()

  static func value(_ option: String, in arguments: [String] = CommandLine.arguments) -> String? {
    guard let index = arguments.firstIndex(of: option), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
  }

  static func flag(_ option: String, in arguments: [String] = CommandLine.arguments) -> Bool {
    isOn && arguments.contains(option)
  }

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

  /// The demo's notes by name, for `--note`.
  @MainActor private static var noteIDs: [String: UUID] = [:]
  /// The arguments of the scene on screen, and whether it typed a command into the terminal.
  @MainActor private static var shown: [String]?
  @MainActor private static var ranCommand = false

  /// The demo's records (the scene itself is `open`'s).
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

    for (name, text) in [("Deploy checklist", deployChecklist), ("Release 2.0", releaseNotes)] {
      noteIDs[name] = model.notes.addNote(named: name, text: text, encrypted: false).id
    }
  }

  /// A scene, from its arguments: the first one's at launch, the later ones' in place. Closes what the scene before
  /// opened and clears the command it typed, then selects the terminal, types `--run`'s command, shows `--note`'s note
  /// and opens `--actions`, `--settings` or `--new-database`.
  @MainActor static func open(_ arguments: [String], in model: AppModel) async {
    // The same scene again (its other appearance) is already on screen.
    guard arguments != shown else { return }
    shown = arguments

    model.showingActions = false
    model.showingNewAction = false
    model.editingAction = nil
    model.showingSettings = false
    model.showingThemes = false
    model.showingCommandInsert = false
    model.showingNewConnection = false
    model.showingNewDatabaseConnection = false
    model.editingDatabaseConnection = nil
    let terminal = model.sessions.first
    if ranCommand, let terminal {
      terminal.clearStdout()
      ranCommand = false
    }
    model.selection = terminal.map { .session($0.id) }
    // The shell's first prompt at launch, or the prompt it redrew after the clear.
    if let terminal { await settle(terminal) }

    if let command = value("--run", in: arguments), let terminal {
      model.insertCommandText(command + "\n", into: terminal)
      ranCommand = true
      // The command's output, down to the next prompt.
      await settle(terminal) { $0.components(separatedBy: "\n").count > 1 }
    }
    if let name = value("--note", in: arguments), let id = noteIDs[name] ?? noteIDs.values.first {
      model.selection = .note(id)
    }
    if flag("--actions", in: arguments) { model.showingActions = true }
    if flag("--settings", in: arguments) { model.showingSettings = true }
    if flag("--new-database", in: arguments) { model.showingNewDatabaseConnection = true }
    if let name = value("--run-action", in: arguments), let action = model.actions.all.first(where: { $0.name == name }) {
      model.runAction(action)
      // The run's session, once it has started and printed something.
      try? await Task.sleep(for: .seconds(3))
      if let run = model.actionSessions.last { model.selection = .session(run.id) }
    }
  }

  /// Until the terminal shows a prompt on its last line (and `condition` holds for its text), with no new output for
  /// a moment; at most 10 seconds.
  @MainActor private static func settle(
    _ terminal: TerminalSession, until condition: (String) -> Bool = { _ in true }
  ) async {
    let start = Date.now
    var generation = terminal.snapshotGeneration
    var quietSince = Date.now
    while Date.now.timeIntervalSince(start) < 10 {
      try? await Task.sleep(for: .milliseconds(100))
      if terminal.snapshotGeneration != generation {
        generation = terminal.snapshotGeneration
        quietSince = .now
        continue
      }
      let text = terminal.snapshot.fullPlainText
      let last = text.components(separatedBy: "\n").last?.trimmingCharacters(in: .whitespaces) ?? ""
      let prompt = ["%", "$", "#"].contains { last.hasSuffix($0) }
      if prompt, condition(text), Date.now.timeIntervalSince(quietSince) >= 0.4 { return }
    }
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
