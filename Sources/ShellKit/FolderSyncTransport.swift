import Foundation
import Observation

/// An action's folder sync as the transport of its run (a `TerminalSession` in the Running section): it logs in to
/// the host with Shell's own SSH connection, lists both sides and prints the plan (the dry run), then waits. `apply()`
/// (the run's Apply button, or Return or `y` typed into its terminal) makes the changes, with a line per step and a
/// summary; `cancel()` (Cancel, `n`, Ctrl+C) leaves the host as it was. A script given with the sync runs on the
/// host after it, in the same run.
///
/// The host's login never leaves Shell: no `ssh`, `rsync` or `~/.ssh/config` is involved.
@Observable
public final class FolderSyncTransport: TerminalTransport {
  public enum Phase: Equatable, Sendable {
    case connecting
    case preparing
    /// The plan is printed; waiting for Apply or Cancel.
    case awaitingConfirmation
    case applying
    /// The action's commands run on the host after the sync.
    case runningScript
    case finished
    case failed(String)
    /// Cancelled before or while applying.
    case cancelled
  }

  public private(set) var phase: Phase = .connecting
  public private(set) var plan: FolderSyncPlan?
  public private(set) var progress: FolderSyncProgress?
  public private(set) var result: FolderSyncResult?

  @ObservationIgnored public var onOutput: ((Data) -> Void)?
  @ObservationIgnored public var onConnected: (() -> Void)?
  @ObservationIgnored public var onTerminated: ((String) -> Void)?
  @ObservationIgnored public var onConnectionLost: ((String) -> Void)?
  @ObservationIgnored public var onExit: ((Int32) -> Void)?
  @ObservationIgnored public var onHostKeyPrompt: ((TerminalHostKeyPrompt) -> Void)?
  @ObservationIgnored public var onPasswordPrompt: ((TerminalPasswordPrompt) -> Void)?

  public let settings: FolderSyncSettings
  /// The host's name in the log.
  public let destination: String
  @ObservationIgnored private let script: String?
  /// Logs in and hands back the host and how to close the login.
  @ObservationIgnored private let connect: (FolderSyncTransport) async throws -> (any FolderSyncRemote, () -> Void)
  /// Starts the script's run on the host (an exec session), nil without SSH (tests).
  @ObservationIgnored private let makeScriptTransport: ((String) -> any TerminalTransport)?

  @ObservationIgnored private var closeLogin: (() -> Void)?
  @ObservationIgnored private var scriptTransport: (any TerminalTransport)?
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var preparation: FolderSyncPreparation?
  @ObservationIgnored private var engine: FolderSyncEngine?
  @ObservationIgnored private var started = false
  @ObservationIgnored private var exited = false
  @ObservationIgnored private var applyStarted = Date()

  /// A sync to `config`'s host over Shell's SSH connection (Secure Enclave key or saved password, the known hosts),
  /// then `script` there when it isn't empty.
  public convenience init(config: SSHConfig, settings: FolderSyncSettings, script: String? = nil) {
    self.init(
      destination: config.displayName, settings: settings, script: script,
      connect: { transport in
        let session = SSHSession(config: config, forwardingOnly: true)
        // The login's questions (an unknown host key, a password) go to the run, which shows them.
        session.onHostKeyPrompt = { [weak transport] in transport?.onHostKeyPrompt?($0) }
        session.onPasswordPrompt = { [weak transport] in transport?.onPasswordPrompt?($0) }
        do {
          try await session.connectAndWait()
        } catch {
          session.close()
          throw error
        }
        guard let remote = session.folderSyncRemote else {
          session.close()
          throw Libssh2Connection.EngineError.notConnected
        }
        return (remote, { session.close() })
      },
      makeScriptTransport: { SSHSession(config: config, execCommand: $0) })
  }

  /// A sync through `connect` (tests pass a fake host).
  public init(
    destination: String, settings: FolderSyncSettings, script: String? = nil,
    connect: @escaping (FolderSyncTransport) async throws -> (any FolderSyncRemote, () -> Void),
    makeScriptTransport: ((String) -> any TerminalTransport)? = nil
  ) {
    self.destination = destination
    self.settings = settings
    let trimmed = script?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    self.script = trimmed.isEmpty ? nil : script
    self.connect = connect
    self.makeScriptTransport = makeScriptTransport
  }

  // MARK: TerminalTransport

  /// Wide enough for a path and its step on one line.
  public var initialGridSize: TerminalGridSize { TerminalGridSize(rows: 40, columns: 160) }
  public var childProcessID: pid_t? { nil }
  public var foregroundProcessID: pid_t? { nil }
  public var echoesInput: Bool { true }

  public func start() {
    guard !started else { return }
    started = true
    // The run shows its log from the start; the login's progress is in it.
    onConnected?()
    line("Sync \(settings.localPath) → \(destination):\(settings.remotePath)")
    line("Connecting to \(destination)…")
    task = Task { [weak self] in await self?.prepare() }
  }

  /// Keys typed into the run's terminal: Return or `y` applies a waiting plan, `n`, Escape or Ctrl+C cancels;
  /// Ctrl+C stops a sync under way. While the script runs, its terminal gets them.
  public func write(_ data: Data) {
    if phase == .runningScript {
      scriptTransport?.write(data)
      return
    }
    for byte in data {
      switch (phase, byte) {
      case (.awaitingConfirmation, UInt8(ascii: "y")), (.awaitingConfirmation, UInt8(ascii: "Y")),
        (.awaitingConfirmation, 0x0D), (.awaitingConfirmation, 0x0A):
        apply()
        return
      case (.awaitingConfirmation, UInt8(ascii: "n")), (.awaitingConfirmation, UInt8(ascii: "N")),
        (.awaitingConfirmation, 0x1B), (_, 0x03):
        cancel()
        return
      default:
        continue
      }
    }
  }

  public func resize(columns: Int, rows: Int) {
    scriptTransport?.resize(columns: columns, rows: rows)
  }

  public func close() {
    task?.cancel()
    task = nil
    closeLogin?()
    closeLogin = nil
    scriptTransport?.close()
    scriptTransport = nil
  }

  // MARK: Actions

  /// Applies the printed plan.
  public func apply() {
    guard phase == .awaitingConfirmation, let preparation, let engine else { return }
    phase = .applying
    applyStarted = Date()
    line("")
    line("Applying \(preparation.plan.stepCount) changes…")
    task = Task { [weak self] in
      guard let self else { return }
      let result = await engine.apply(preparation) { [self] progress in
        Self.onMain { self.stepped(progress) }
      }
      self.applied(result)
    }
  }

  /// Leaves the host as it is (before Apply), or stops between steps (while applying).
  public func cancel() {
    switch phase {
    case .awaitingConfirmation:
      phase = .cancelled
      line("")
      line("Cancelled: nothing changed on \(destination).")
      closeLogin?()
      closeLogin = nil
      end(130)
    case .connecting, .preparing:
      task?.cancel()
      phase = .cancelled
      line("Stopped before anything changed on \(destination).")
      close()
      end(130)
    case .applying:
      // The step under way finishes; `applied` reports what was done.
      task?.cancel()
    case .runningScript:
      scriptTransport?.write(Data([0x03]))
    case .finished, .failed, .cancelled:
      break
    }
  }

  // MARK: Running

  private func prepare() async {
    do {
      let (remote, close) = try await connect(self)
      if phase == .cancelled {
        close()
        return
      }
      closeLogin = close
      phase = .preparing
      let engine = FolderSyncEngine(settings: settings, remote: remote)
      self.engine = engine
      let preparation = try await engine.prepare { [self] status in Self.onMain { self.line(status) } }
      guard phase == .preparing else { return }
      self.preparation = preparation
      plan = preparation.plan
      printPlan(preparation)
      if preparation.plan.isEmpty {
        line("Already in sync: nothing to change on \(destination).")
        closeLogin?()
        closeLogin = nil
        finishSync()
      } else {
        phase = .awaitingConfirmation
        if settings.asksBeforeApplying {
          line("")
          line("Waiting for Apply: nothing has changed on \(destination) yet. Return or y makes these changes, n cancels.")
        } else {
          // The action's Ask before applying is off: the plan is in the log, and it goes ahead.
          apply()
        }
      }
    } catch {
      guard phase != .cancelled else { return }
      let message = FolderSyncEngine.describe(error)
      line("error: \(message)")
      fail(message)
    }
  }

  private func printPlan(_ preparation: FolderSyncPreparation) {
    let plan = preparation.plan
    line("Local: \(preparation.localCount) files and folders. \(destination): \(preparation.remoteCount) in \(plan.remoteRoot).")
    switch plan.comparison {
    case .sha256: line("Files of the same size compared by SHA-256.")
    case .modificationTime: line("The host has no sha256sum or shasum: files of the same size compared by modification time.")
    case .none: break
    }
    if plan.createsRoot { line("  create   \(plan.remoteRoot)/ (doesn’t exist yet)") }
    for removal in plan.replacements { line("  replace  \(removal.path)\(removal.kind == .directory ? "/" : "") (another kind of file is there)") }
    for folder in plan.directories { line("  mkdir    \(folder)/") }
    for upload in plan.uploads {
      line("  upload   \(upload.path) (\(Self.reasonText(upload.reason)), \(Self.bytes(upload.size)))")
    }
    for deletion in plan.deletions { line("  delete   \(deletion.path)\(deletion.kind == .directory ? "/" : "")") }
    for folder in plan.kept { line("  keep     \(folder)/ (holds excluded files)") }
    for skip in plan.skipped { line("  skip     \(skip.path): \(skip.reason)") }
    var parts = [
      "\(plan.uploads.count) to upload (\(Self.bytes(plan.uploadBytes)))",
      "\(plan.deletions.count) to delete",
    ]
    if !plan.directories.isEmpty { parts.append("\(plan.directories.count) folders to create") }
    if !plan.replacements.isEmpty { parts.append("\(plan.replacements.count) to replace") }
    parts.append("\(plan.unchanged) unchanged")
    if !settings.deletesRemovedFiles { parts.append("deleting off") }
    line("Plan: " + parts.joined(separator: ", ") + ".")
  }

  private func stepped(_ progress: FolderSyncProgress) {
    self.progress = progress
    guard !progress.step.path.isEmpty else { return }
    let verb: String
    switch progress.step.kind {
    case .createRoot: verb = "create "
    case .replace: verb = "replace"
    case .createFolder: verb = "mkdir  "
    case .upload: verb = "upload "
    case .delete: verb = "delete "
    }
    line("[\(progress.completed + 1)/\(progress.total)] \(verb)  \(progress.step.path)")
  }

  private func applied(_ result: FolderSyncResult) {
    self.result = result
    closeLogin?()
    closeLogin = nil
    for failure in result.failures { line("error: \(failure.path): \(failure.message)") }
    let seconds = Date().timeIntervalSince(applyStarted)
    var parts = ["uploaded \(result.uploaded) (\(Self.bytes(result.bytesUploaded)))", "deleted \(result.deleted)"]
    if result.createdFolders > 0 { parts.append("created \(result.createdFolders) folders") }
    if result.replaced > 0 { parts.append("replaced \(result.replaced)") }
    if !result.failures.isEmpty { parts.append("\(result.failures.count) failed") }
    let summary = parts.joined(separator: ", ") + String(format: " in %.1f s.", seconds)
    if result.cancelled {
      phase = .cancelled
      line("Stopped: " + summary)
      end(130)
    } else if !result.failures.isEmpty {
      line("Finished with errors: " + summary)
      phase = .failed("\(result.failures.count) failed")
      end(1)
    } else {
      line("Done: " + summary)
      finishSync()
    }
  }

  /// After a sync with nothing left to do: the script, or the end of the run.
  private func finishSync() {
    guard let script, let makeScriptTransport else {
      phase = .finished
      end(0)
      return
    }
    phase = .runningScript
    line("")
    line("Running the action’s commands on \(destination)…")
    let transport = makeScriptTransport(script)
    scriptTransport = transport
    transport.onOutput = { [weak self] in self?.onOutput?($0) }
    transport.onHostKeyPrompt = { [weak self] in self?.onHostKeyPrompt?($0) }
    transport.onPasswordPrompt = { [weak self] in self?.onPasswordPrompt?($0) }
    transport.onExit = { [weak self] code in
      guard let self else { return }
      self.phase = code == 0 ? .finished : .failed("exit \(code)")
      self.end(code)
    }
    let ended: (String) -> Void = { [weak self] message in
      guard let self else { return }
      self.line("error: \(message)")
      self.fail(message)
    }
    transport.onTerminated = ended
    transport.onConnectionLost = ended
    transport.start()
  }

  private func fail(_ message: String) {
    phase = .failed(message)
    closeLogin?()
    closeLogin = nil
    guard !exited else { return }
    exited = true
    onTerminated?(message)
  }

  private func end(_ code: Int32) {
    guard !exited else { return }
    exited = true
    onExit?(code)
  }

  private func line(_ text: String) {
    onOutput?(Data((text + "\r\n").utf8))
  }

  /// Runs `body` on the main actor: at once from the main thread (the engine reports from its caller's), else after.
  private nonisolated static func onMain(_ body: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
      MainActor.assumeIsolated { body() }
    } else {
      DispatchQueue.main.async { body() }
    }
  }

  static func reasonText(_ reason: FolderSyncPlan.UploadReason) -> String {
    switch reason {
    case .new: "new"
    case .size: "size changed"
    case .content: "content changed"
    case .modified: "modified"
    case .replaces: "replaces another kind"
    }
  }

  /// "512 B", "4.2 KB", "12.4 MB".
  public static func bytes(_ count: UInt64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var value = Double(count)
    var unit = 0
    while value >= 1000 && unit < units.count - 1 {
      value /= 1000
      unit += 1
    }
    return unit == 0 ? "\(count) B" : String(format: "%.1f", value) + " " + units[unit]
  }
}
