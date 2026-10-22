import ComponentKit
import SwiftUI
import ShellKit

/// The detail pane of an action run (the Actions palette's runs and the smart
/// actions): ComponentKit's run blocks, since nobody types into these. Each run
/// is a block headed by its live icon, the action and its command, its exit as
/// a chip and Stop while it runs; a failed run keeps its output open, and the
/// selected one rises as the raised card. The main window shows every run of
/// the Running section, a detached window just its own.
///
/// A run that does ask for input (a `sudo` password) still has its terminal:
/// the toolbar's Terminal button (`ActionTerminalToggle`) flips the pane to it.
struct ActionRunsView: View {
  @Environment(AppModel.self) private var model
  /// The selected run.
  let session: TerminalSession
  /// Every run of the Running section, or only `session`.
  var showsAll = true
  /// Whether the pane shows the run's terminal instead of its output (the
  /// toolbar's `ActionTerminalToggle`).
  @Binding var showsTerminal: Bool

  var body: some View {
    Group {
      if showsTerminal {
        TerminalView(session: session)
          .terminalPrompts(session)
          .transition(.opacity)
      } else {
        ScrollView {
          RunBlocks(selection: selection) {
            ForEach(showsAll ? model.actionSessions : [session]) { run in
              RunBlock(
                model.actionSpec(for: run)?.action.name ?? "Action", command: command(of: run),
                id: run.id.uuidString, systemImage: "play.fill", status: run.actionRunStatus,
                output: output(of: run),
                stop: run.isActionRunning ? { run.send(Data([0x03])) } : nil
              )
              .kitContextMenu {
                Button("Close", role: .destructive) { model.removeSession(run.id) }
              }
            }
          }
          .padding(KitMetrics.gutter)
        }
        .transition(.opacity)
      }
    }
    .animation(.kit, value: showsTerminal)
  }

  /// The selection of the track is the window's: picking a block selects its run.
  private var selection: Binding<String?> {
    Binding(
      get: { session.id.uuidString },
      set: { id in
        if let id, let uuid = UUID(uuidString: id), showsAll { model.selection = .session(uuid) }
      })
  }

  /// The command the run executes, without the `cd` into the project and the
  /// exports a smart action prefixes it with.
  private func command(of run: TerminalSession) -> String {
    var command = model.actionSpec(for: run)?.action.commands
      .split(separator: "\n").first.map(String.init) ?? ""
    while command.hasPrefix("cd ") || command.hasPrefix("export "), let and = command.range(of: " && ") {
      command = String(command[and.upperBound...])
    }
    return command
  }

  /// The run's latest output: its last 200 lines.
  private func output(of run: TerminalSession) -> String {
    let snapshot = run.snapshot
    return snapshot.plainText(fromLine: max(0, snapshot.totalLines - 200))
  }
}

/// The toolbar's switch between an action run's output and its terminal.
struct ActionTerminalToggle: View {
  @Binding var showsTerminal: Bool

  var body: some View {
    Button(
      showsTerminal ? "Run Output" : "Terminal",
      systemImage: showsTerminal ? "list.bullet.rectangle" : "terminal"
    ) {
      showsTerminal.toggle()
    }
    .help(showsTerminal ? "Show the run's output" : "Show the run's terminal, to type into it")
  }
}
