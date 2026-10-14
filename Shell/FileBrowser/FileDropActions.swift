#if os(macOS)
import Foundation
import ShellKit

/// Where files were dropped.
enum FileDropTarget: Equatable {
  /// A session: its sidebar row, or its terminal.
  case session(UUID)
  /// A saved SSH host's row (no session, so no folder to follow: uploads land in the home folder).
  case host(SSHConfig)
  /// The Notes section.
  case notes
}

/// What the drop dialog offers for files dropped on a target.
enum FileDropAction: Hashable {
  /// Copies the files into a local session's folder.
  case copy
  /// Uploads the files to an SSH session's folder (a host row: its home folder).
  case upload
  /// Types the files' paths into the terminal, as Terminal does for a Finder drop.
  case insertPath
  /// `cd`s the terminal into the folder (a file: the folder it is in).
  case goToFolder
  /// Copies text files into new encrypted notes (the vault's encrypted storage).
  case copyToNote
  /// Opens text files in the Text Files section, editing the originals.
  case linkFile
}

/// A drop waiting for the user to pick a `FileDropAction` (ContentView's drop dialog).
struct FileDropRequest: Identifiable {
  let id = UUID()
  let files: [ShellFile]
  let target: FileDropTarget
}

/// Files dropped on Shell's targets: the dialog's choices and what each one does.
///
/// The PATH actions (`insertPath`, `goToFolder`) are offered only when the session can reach the files where they
/// are: local files in a local session, a host's files in a session on that same host. Copying always works: a remote
/// file is downloaded first, a local one uploaded.
extension AppModel {
  /// Asks what to do with `files` dropped on `target`, when there is anything to do.
  func requestFileDrop(_ files: [ShellFile], on target: FileDropTarget) {
    let request = FileDropRequest(files: files, target: target)
    guard !files.isEmpty, !fileDropActions(for: request).isEmpty else { return }
    fileDropRequest = request
  }

  func fileDropActions(for request: FileDropRequest) -> [FileDropAction] {
    switch request.target {
    case .session(let id):
      guard let session = session(id) else { return [] }
      var actions: [FileDropAction] = []
      switch kind(of: session) {
      case .local: actions.append(.copy)
      case .ssh: actions.append(.upload)
      default: break
      }
      if canReach(request.files, from: session) {
        actions.append(.insertPath)
        if request.files.count == 1 { actions.append(.goToFolder) }
      }
      return actions
    case .host:
      return [.upload]
    case .notes:
      let files = request.files.filter { !$0.isDirectory }
      guard !files.isEmpty else { return [] }
      return files.allSatisfy { $0.remote == nil } ? [.copyToNote, .linkFile] : [.copyToNote]
    }
  }

  /// The dialog's title: what was dropped where.
  func fileDropTitle(for request: FileDropRequest) -> String {
    let what = request.files.count == 1 ? "“\(request.files[0].name)”" : "\(request.files.count) items"
    switch request.target {
    case .session(let id):
      guard let session = session(id) else { return what }
      return "\(what) on \(displayName(for: session))"
    case .host(let config):
      return "\(what) on \(config.displayName)"
    case .notes:
      return "\(what) on Notes"
    }
  }

  func fileDropTitle(of action: FileDropAction, for request: FileDropRequest) -> String {
    let plural = request.files.count > 1
    switch action {
    case .copy, .upload:
      let verb = action == .copy ? "Copy" : "Upload"
      if case .host = request.target { return "\(verb) to Home Folder" }
      guard case .session(let id) = request.target, let folder = sessionFolder(id) else { return "\(verb) Here" }
      return "\(verb) to “\((folder as NSString).lastPathComponent)”"
    case .insertPath:
      return plural ? "Insert Paths" : "Insert Path"
    case .goToFolder:
      return request.files.first?.isDirectory == true ? "Go to Folder" : "Go to Enclosing Folder"
    case .copyToNote:
      return plural ? "Copy to Encrypted Notes" : "Copy to Encrypted Note"
    case .linkFile:
      return plural ? "Link Files" : "Link File"
    }
  }

  /// A line under the title saying what the choices mean, where they need it.
  func fileDropMessage(for request: FileDropRequest) -> String? {
    guard case .notes = request.target else { return nil }
    let skipped = request.files.filter(\.isDirectory).count
    var lines: [String] = []
    if fileDropActions(for: request).contains(.linkFile) {
      lines.append("A copy is a new note, encrypted and synced. A link edits the original file.")
    } else {
      lines.append("Remote files can only be copied into notes.")
    }
    if skipped > 0 { lines.append("Folders are skipped.") }
    return lines.joined(separator: " ")
  }

  func performFileDrop(_ action: FileDropAction, for request: FileDropRequest) {
    fileDropRequest = nil
    let files = request.files
    switch (action, request.target) {
    case (.copy, .session(let id)), (.upload, .session(let id)):
      guard let session = session(id) else { return }
      dropFiles(files, on: session)
    case (.upload, .host(let config)):
      uploadToRemote(files, config: config, remoteDirectory: nil)
    case (.insertPath, .session(let id)):
      guard let session = session(id) else { return }
      // A trailing space, so the next path or argument can follow straight away (Terminal does the same).
      session.paste(files.map { Self.shellQuoted($0.url.path) }.joined(separator: " ") + " ")
      selection = .session(id)
    case (.goToFolder, .session(let id)):
      guard let session = session(id), let file = files.first else { return }
      let folder = file.isDirectory ? file.url.path : file.url.deletingLastPathComponent().path
      session.send("cd " + Self.shellQuoted(folder) + "\r")
      selection = .session(id)
    case (.copyToNote, .notes):
      copyToNotes(files.filter { !$0.isDirectory })
    case (.linkFile, .notes):
      for file in files where !file.isDirectory && file.remote == nil { linkFile(file.url) }
    default:
      return
    }
  }

  // MARK: - Files panel

  /// Copies files dropped on the Files panel into the folder it shows. Files already on that machine are copied
  /// there by the panel's own `rsync`; the rest are downloaded or uploaded first.
  func dropFiles(_ files: [ShellFile], into browser: DirectoryBrowserModel) {
    guard let context = browser.context, !files.isEmpty else { return }
    let folder = browser.path
    let refresh = { Task { await browser.refresh() } }
    if context.isLocal {
      browser.copyIn(urls: files.filter { $0.remote == nil }.map(\.url))
      let remote = files.filter { $0.remote != nil }
      if !remote.isEmpty { copyLocally(remote, into: folder, then: { _ in _ = refresh() }) }
    } else if let config = context.kind.sshConfig {
      browser.copyIn(urls: files.filter { $0.remote?.id == config.id }.map(\.url))
      let others = files.filter { $0.remote?.id != config.id }
      if !others.isEmpty { uploadToRemote(others, config: config, remoteDirectory: folder, then: { _ in _ = refresh() }) }
    }
  }

  // MARK: - Sessions

  /// Copies files dropped onto a session into its current directory: a local session's with `FileManager`, an SSH
  /// session's over SFTP. Remote files are downloaded first.
  func dropFiles(_ files: [ShellFile], on session: TerminalSession) {
    guard !files.isEmpty else { return }
    switch kind(of: session) {
    case .local:
      copyLocally(files, into: session.currentDirectory?.path ?? NSHomeDirectory())
    case .ssh(let config):
      uploadToRemote(files, config: config, remoteDirectory: session.remoteCurrentDirectory?.path)
    default:
      return
    }
  }

  /// Whether `session` sees `files` at their paths: local files from a local shell, a host's files from a shell on
  /// that host.
  private func canReach(_ files: [ShellFile], from session: TerminalSession) -> Bool {
    switch kind(of: session) {
    case .local, .screen:
      return files.allSatisfy { $0.remote == nil }
    case .action(let spec):
      return files.allSatisfy { $0.remote?.id == spec.config?.id }
    case .ssh(let config):
      return files.allSatisfy { $0.remote?.id == config.id }
    case .web, .database:
      return false
    }
  }

  /// The folder a copy into the session lands in, when the session knows it.
  private func sessionFolder(_ id: UUID) -> String? {
    guard let session = session(id) else { return nil }
    switch kind(of: session) {
    case .local: return session.currentDirectory?.path ?? NSHomeDirectory()
    case .ssh: return session.remoteCurrentDirectory?.path
    default: return nil
    }
  }

  /// `path` as one shell word: as-is when it has nothing the shell would read, else in single quotes.
  static func shellQuoted(_ path: String) -> String {
    let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+,:@%")
    if !path.isEmpty, path.unicodeScalars.allSatisfy(plain.contains) { return path }
    return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  // MARK: - Copying

  private func copyLocally(_ files: [ShellFile], into directory: String, then done: @escaping @MainActor (Bool) -> Void = { _ in }) {
    Task {
      for file in files {
        let local: URL
        do {
          local = try await file.download()
        } catch {
          fileDropError = "Could not copy \(file.name): \(error.localizedDescription)"
          return done(false)
        }
        let message = await Task.detached(priority: .userInitiated) { () -> String? in
          let fm = FileManager.default
          do {
            try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let src = local.standardizedFileURL.path
            let dest = URL(fileURLWithPath: directory)
              .appendingPathComponent(file.name)
              .standardizedFileURL.path
            // Dropping a file onto the directory it already lives in is a no-op.
            guard src != dest else { return nil }
            if fm.fileExists(atPath: dest) { try fm.removeItem(atPath: dest) }
            try fm.copyItem(atPath: src, toPath: dest)
            return nil
          } catch {
            return "Could not copy \(file.name): \(error.localizedDescription)"
          }
        }.value
        if let message {
          fileDropError = message
          return done(false)
        }
      }
      done(true)
    }
  }

  private func uploadToRemote(
    _ files: [ShellFile], config: SSHConfig, remoteDirectory: String?,
    then done: @escaping @MainActor (Bool) -> Void = { _ in }
  ) {
    Task {
      do {
        // Dial ONE auth-only connection for the whole drop (Secure Enclave auth
        // is expensive, so never re-auth per file), resolve the remote cwd — or
        // the login dir when dropping on a saved connection with no running
        // session — then push each file over the SFTP subsystem.
        let session = try await SSHSession.connect(config: config)
        defer { session.close() }
        let dir: String
        if let remoteDirectory, !remoteDirectory.isEmpty {
          dir = remoteDirectory
        } else {
          dir = try await session.remoteHomeDirectory()
        }
        for file in files {
          if file.isDirectory {
            fileDropError = "Uploading the folder \(file.name) over SSH isn't supported yet."
            continue
          }
          do {
            let local = try await file.download()
            // A file from another app may arrive as a security-scoped URL whose access
            // must be held across the SFTP read (which runs on a background
            // queue, past the drop closure). No-op for ordinary local/temp URLs.
            let scoped = local.startAccessingSecurityScopedResource()
            defer { if scoped { local.stopAccessingSecurityScopedResource() } }
            let remotePath = (dir as NSString).appendingPathComponent(file.name)
            try await session.uploadFile(localURL: local, remotePath: remotePath)
          } catch {
            fileDropError = "Could not upload \(file.name): \(error.localizedDescription)"
            return done(false)
          }
        }
        done(true)
      } catch {
        fileDropError = "Could not upload to \(config.displayName): \(error.localizedDescription)"
        done(false)
      }
    }
  }

  // MARK: - Notes

  /// The largest file copied into a note (the Text Files editor's limit too).
  private static let maxNoteFileBytes = 2 * 1024 * 1024

  /// Copies text files into new encrypted notes, named after the files, and shows the last one.
  private func copyToNotes(_ files: [ShellFile]) {
    let limit = Self.maxNoteFileBytes
    Task {
      var last: NotesStore.NoteSummary?
      for file in files {
        do {
          let local = try await file.download()
          let text = try await Task.detached(priority: .userInitiated) { () throws -> String? in
            let data = try Data(contentsOf: local)
            guard data.count <= limit, !data.contains(0) else { return nil }
            return String(data: data, encoding: .utf8)
          }.value
          guard let text else {
            fileDropError = "\(file.name) isn't a text file (or is over 2 MB), so it wasn't copied into Notes."
            continue
          }
          last = notes.addNote(named: file.url.deletingPathExtension().lastPathComponent, text: text, encrypted: true)
        } catch {
          fileDropError = "Could not copy \(file.name) into Notes: \(error.localizedDescription)"
        }
      }
      if let last { selection = .note(last.id) }
    }
  }

  // MARK: - Linked files

  private static let linkedFilesKey = "linkedTextFiles"

  private var linkedFilePaths: [String] {
    get { UserDefaults.standard.stringArray(forKey: Self.linkedFilesKey) ?? [] }
    set { UserDefaults.standard.set(newValue, forKey: Self.linkedFilesKey) }
  }

  /// Opens a local text file in the Text Files section, where edits go to the file itself, and keeps it there
  /// across launches until it is closed.
  func linkFile(_ url: URL) {
    let path = url.standardizedFileURL.path
    if !linkedFilePaths.contains(path) { linkedFilePaths.append(path) }
    openFile(URL(fileURLWithPath: path))
  }

  /// Forgets a linked file (it was closed).
  func unlinkFile(_ url: URL) {
    linkedFilePaths.removeAll { $0 == url.standardizedFileURL.path }
  }

  /// Reopens the linked files that still exist, without selecting them (launch).
  func reopenLinkedFiles() {
    for path in linkedFilePaths where FileManager.default.fileExists(atPath: path) {
      openFile(URL(fileURLWithPath: path), select: false)
    }
  }
}
#endif
