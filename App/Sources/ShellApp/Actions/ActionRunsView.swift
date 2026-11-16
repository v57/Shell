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
              ActionRunBlock(run: run)
            }
          }
          .padding(KitMetrics.gutter)
        }
        // A folder sync logs in while its output shows: an unknown host key or a password is asked here too.
        .terminalPrompts(session)
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
}

/// One run's block. A view of its own that reads its run's output: read in `ActionRunsView`'s body, a line of output
/// from any run built every block again, each with its last 200 lines.
private struct ActionRunBlock: View {
  @Environment(AppModel.self) private var model
  let run: TerminalSession

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      RunBlock(
        model.actionSpec(for: run).map { "\($0.action.name)" } ?? "Action", command: command(of: run),
        id: run.id.uuidString, systemImage: run.folderSync == nil ? "play.fill" : "arrow.triangle.2.circlepath",
        status: run.actionRunStatus, progress: syncProgress, output: output(of: run),
        stop: canStop ? { [run] in run.send(Data([0x03])) } : nil
      )
      if let sync = run.folderSync, sync.phase == .awaitingConfirmation, let plan = sync.plan {
        FolderSyncConfirmation(sync: sync, plan: plan)
      }
    }
    .kitContextMenu {
      Button("Close", role: .destructive) { model.removeSession(run.id) }
    }
  }

  /// Stop while it runs; a folder sync waiting for Apply has its own Cancel.
  private var canStop: Bool {
    run.isActionRunning && run.folderSync?.phase != .awaitingConfirmation
  }

  /// A folder sync's "12 of 40" while it applies.
  private var syncProgress: String? {
    guard let sync = run.folderSync, sync.phase == .applying, let progress = sync.progress else { return nil }
    return String(localized: "\(progress.completed) of \(progress.total)")
  }

  /// The command the run executes, without the `cd` into the project and the
  /// exports a smart action prefixes it with.
  private func command(of run: TerminalSession) -> String {
    if let sync = run.folderSync {
      return "\(sync.settings.localPath) → \(sync.destination):\(sync.settings.remotePath)"
    }
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

/// Under a folder sync's dry run: what it will change, and Apply or Cancel. Typing Return or `y` into the run's
/// terminal applies too, `n` or Ctrl+C cancels.
private struct FolderSyncConfirmation: View {
  let sync: FolderSyncTransport
  let plan: FolderSyncPlan

  var body: some View {
    HStack(spacing: 8) {
      MetaLine(meta)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button("Cancel") { sync.cancel() }
        .buttonStyle(.kit)
        .controlSize(.small)
        .kitHelp("Leave the host as it is")
      Button("Apply") { sync.apply() }
        .buttonStyle(.kitPrimary)
        .controlSize(.small)
        .kitHelp("Upload and delete as listed")
    }
    .padding(EdgeInsets(top: 0, leading: 34, bottom: 8, trailing: 6))
  }

  private var meta: [String] {
    var parts = [
      String(localized: "\(plan.uploads.count) to upload"), FolderSyncTransport.bytes(plan.uploadBytes),
      String(localized: "\(plan.deletions.count) to delete"),
    ]
    if !plan.directories.isEmpty { parts.append(String(localized: "\(plan.directories.count) new folders")) }
    if !plan.skipped.isEmpty { parts.append(String(localized: "\(plan.skipped.count) skipped")) }
    return parts
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
    .kitHelp(showsTerminal ? "Show the run's output" : "Show the run's terminal, to type into it")
  }
}
