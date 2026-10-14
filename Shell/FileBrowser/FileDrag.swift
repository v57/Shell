#if os(macOS)
import AppKit
import Foundation
import ShellKit
import SwiftUI
import UniformTypeIdentifiers

/// A file dragged out of the Files panel, and the files dropped onto Shell's own targets.
///
/// Dragging out is SwiftUI's `Transferable`, with the order and types chosen so every receiver gets what it needs:
///
///  - the FILE comes first (`FileRepresentation`, export only), so Finder, Mail or any other app receives the real
///    file: a local row's original, a remote row's SFTP download. SwiftUI asks for it only when the drop lands;
///  - Shell's own description (`CodableRepresentation` of `.shellFile`) comes second and is declared as a plain
///    `public.item` in Shell-Info.plist, never `public.data`: Finder takes the first data type it finds and saved
///    this JSON as a "Shell File" clipping instead of copying the file.
///
/// Dropping in is AppKit's drag pasteboard (`NSPasteboard(name: .drag)`, `FileDrop.read`), not `Transferable`
/// importing: an imported `FileRepresentation` is a temporary COPY of a Finder file (no original path to insert or
/// link), and SwiftUI hands an `onDrop` closure one opaque provider for a multi-file drag. The pasteboard has one
/// item per file, carrying `.shellFile` for Shell's own rows and `public.file-url` for everything else.
///
/// SwiftUI resolves every representation before it calls a drop target in this process, so a remote row dropped on
/// a sidebar session would be downloaded only to be ignored (the target reads `.shellFile` and decides itself).
/// `exportedFile()` therefore hands over an empty placeholder while the pointer is over one of Shell's windows.
struct ShellFile: Transferable, Codable, Hashable {
  let url: URL
  let isDirectory: Bool
  /// Non-nil for a REMOTE (SSH) row: the host to fetch the file from so it can
  /// be materialized (downloaded) before drag-out. Nil for local rows.
  var remote: SSHConfig?

  init(url: URL, isDirectory: Bool, remote: SSHConfig? = nil) {
    self.url = url
    self.isDirectory = isDirectory
    self.remote = remote
  }

  var name: String { url.lastPathComponent }

  /// Returns a REAL local file URL for the transfer: a local row's own `url`,
  /// or a freshly SFTP-downloaded temp copy of a remote row's file (so Finder /
  /// a session-cell drop get actual bytes, not a remote path that doesn't exist
  /// on this Mac).
  func download() async throws -> URL {
    guard remote != nil else { return url }
    return try await RemoteFileDownloads.shared.download(self)
  }

  /// The file handed to another app: the download, or a placeholder when the drop is Shell's own (see above).
  fileprivate func exportedFile() async throws -> URL {
    guard remote != nil else { return url }
    if FileDrop.pointerIsOverThisApp() { return try RemoteFileDownloads.placeholder(named: name) }
    return try await download()
  }

  nonisolated static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(exportedContentType: .data) { file in
      // allowAccessingOriginalFile:true gives the destination the ORIGINAL URL
      // instead of a sandbox-hidden temp copy. A staged copy (false) forces
      // SwiftUI to hand off a `public.file-url` sandbox extension on drop, which
      // fails with -20 ("does client lack read access") for an in-app file → the
      // drop silently does nothing. Local files are already readable by this
      // (non-sandboxed) process, so pass the original through.
      try await SentTransferredFile(file.exportedFile(), allowAccessingOriginalFile: true)
    }
    .suggestedFileName { $0.name }
    CodableRepresentation(contentType: .shellFile).visibility(.ownProcess)
  }
}

extension UTType {
  /// Shell's own description of a dragged file (`ShellFile`), declared in Shell-Info.plist as a `public.item`.
  nonisolated static var shellFile: UTType { UTType(exportedAs: "dev.v57.url") }
}

/// SFTP downloads of dragged remote files. A drop asks for the file more than once (Finder did twice), so one drag
/// downloads once: a request joins the download in flight, or reuses one finished in the last minute.
actor RemoteFileDownloads {
  static let shared = RemoteFileDownloads()

  private var downloads: [String: (task: Task<URL, Error>, started: Date)] = [:]

  func download(_ file: ShellFile) async throws -> URL {
    guard let config = file.remote else { return file.url }
    let key = config.id.uuidString + ":" + file.url.path
    downloads = downloads.filter { $0.value.started.timeIntervalSinceNow > -60 }
    if let existing = downloads[key] { return try await existing.task.value }
    let task = Task {
      let data = try await SSHSession.downloadFile(config: config, remotePath: file.url.path)
      // A folder per download, so two files with the same name never overwrite each other.
      let dir = Self.directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let dest = dir.appendingPathComponent(file.name)
      try data.write(to: dest)
      return dest
    }
    downloads[key] = (task, Date())
    do {
      return try await task.value
    } catch {
      downloads[key] = nil
      throw error
    }
  }

  /// An empty file standing in for a remote file dropped inside Shell (never read).
  nonisolated static func placeholder(named name: String) throws -> URL {
    let dir = directory.appendingPathComponent("placeholder", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url) }
    return url
  }

  private nonisolated static var directory: URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("shell-drag", isDirectory: true)
  }
}

/// Reading a drop on one of Shell's targets (a session, the terminal, the Files panel, Notes).
enum FileDrop {
  /// What a file drop target accepts: Shell's own rows and files from anywhere else.
  static let contentTypes: [UTType] = [.shellFile, .fileURL]

  /// The files of the drag being dropped, one per pasteboard item: Shell's own description of a Files-panel row
  /// (local or remote), or the ORIGINAL path of a file from Finder or another app.
  @MainActor
  static func read(from pasteboard: NSPasteboard = NSPasteboard(name: .drag)) -> [ShellFile] {
    let decoder = JSONDecoder()
    return (pasteboard.pasteboardItems ?? []).compactMap { item in
      if let data = item.data(forType: NSPasteboard.PasteboardType(UTType.shellFile.identifier)),
         let file = try? decoder.decode(ShellFile.self, from: data) {
        return file
      }
      guard let string = item.string(forType: .fileURL), let url = URL(string: string), url.isFileURL else {
        return nil
      }
      var isDirectory: ObjCBool = false
      FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
      return ShellFile(url: url.standardizedFileURL, isDirectory: isDirectory.boolValue)
    }
  }

  /// Whether the pointer is over one of Shell's windows: the topmost normal window under it belongs to this process.
  /// Safe off the main thread (SwiftUI asks for a dragged file there while the main thread waits for it).
  nonisolated static func pointerIsOverThisApp() -> Bool {
    let mouse = NSEvent.mouseLocation
    // Window bounds have a top-left origin on the main display; `mouseLocation` a bottom-left one.
    let point = CGPoint(x: mouse.x, y: CGDisplayBounds(CGMainDisplayID()).height - mouse.y)
    guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
      as? [[String: Any]]
    else { return false }
    for window in windows {
      // Layer 0 is the normal windows: the drag image and menus float above it.
      guard (window[kCGWindowLayer as String] as? Int) == 0,
            let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
            CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
              .contains(point)
      else { continue }
      return (window[kCGWindowOwnerPID as String] as? Int32) == getpid()
    }
    return false
  }
}

extension View {
  /// `fileDrop` for a sidebar row. A drag-reorderable row of the `LazyVStack` sidebar is already a drop target
  /// (its siblings), and SwiftUI gives a drop to the innermost target only, so the row's reorder target takes the
  /// files too (`SidebarRowDropHandler`); this one serves every other row.
  func sidebarFileDrop(perform: @escaping ([ShellFile]) -> Void) -> some View {
    let read: @MainActor () -> Bool = {
      let files = FileDrop.read()
      guard !files.isEmpty else { return false }
      perform(files)
      return true
    }
    return environment(\.sidebarRowDropHandler, SidebarRowDropHandler(contentTypes: FileDrop.contentTypes, perform: read))
      .fileDrop(perform: perform)
  }

  /// Accepts files dropped from the Files panel, Finder or another app (see `FileDrop`).
  func fileDrop(isTargeted: Binding<Bool>? = nil, perform: @escaping ([ShellFile]) -> Void) -> some View {
    onDrop(of: FileDrop.contentTypes, isTargeted: isTargeted) { _ in
      let files = FileDrop.read()
      guard !files.isEmpty else { return false }
      perform(files)
      return true
    }
  }
}
#endif
