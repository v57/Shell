import Foundation
import Observation
import VaultKit

/// Backs the sidebar's Notes list: Markdown files Shell shares with the Markdown app.
///
/// - **iCloud** notes are the files in Markdown's iCloud Drive folder (`iCloud.dev.v57.md`): the notes the
///   Markdown app shows, synced by iCloud Drive to every device.
/// - **Local** notes are files in Shell's own folder, on this device only.
///
/// A note is a plain `.md` file or an encrypted `.mdenc` one (`EncryptedNote` in `../Vault`, sealed with the
/// key the v57 apps share through iCloud Keychain), so Markdown opens Shell's notes and the reverse. New notes
/// are encrypted. When two devices saved a note before seeing each other's version, iCloud Drive's copies are
/// merged line by line (`NoteConflicts`).
///
/// Notes are read lazily (visible rows and the open editor), cached until the file changes. Edits are written
/// 5 seconds after the last keystroke. A note whose file is still named "Untitled" takes its title as its
/// file name when saved.
@MainActor
@Observable
final class NotesStore {
  /// A sidebar row: an id (stable while the app runs), the sort key and where the note lives.
  struct NoteSummary: Identifiable, Equatable {
    let id: UUID
    var lastUpdate: Date
    var storedInICloud: Bool
    var isEncrypted: Bool = true
  }

  /// A note's text and the title and subtitle derived from it.
  struct DecryptedContents: Equatable {
    var title: String
    var subtitle: String?
    var text: String
  }

  /// All notes (local + iCloud), most recently changed first.
  private(set) var notes: [NoteSummary] = []

  /// The most recent read or write failure.
  var storageError: String?

  /// Whether any note lives in iCloud.
  var hasICloudNotes: Bool { notes.contains { $0.storedInICloud } }

  /// Whether new notes are encrypted (on unless turned off).
  static let encryptsNewNotesKey = "encryptsNewNotes"
  var encryptsNewNotes: Bool {
    get { UserDefaults.standard.object(forKey: Self.encryptsNewNotesKey) as? Bool ?? true }
    set { UserDefaults.standard.set(newValue, forKey: Self.encryptsNewNotesKey) }
  }

  @ObservationIgnored let localFolder: URL
  @ObservationIgnored private(set) var iCloudFolder: URL?
  @ObservationIgnored private let keys: VaultKeyProvider
  @ObservationIgnored private let bases: NoteBaseCache
  @ObservationIgnored private var urls: [UUID: URL] = [:]
  @ObservationIgnored private var cache: [UUID: (modified: Date, contents: DecryptedContents)] = [:]
  @ObservationIgnored private var saveTasks: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored private var pendingText: [UUID: String] = [:]
  @ObservationIgnored private var presenters: [FolderPresenter] = []

  /// - Parameters:
  ///   - localFolder: the folder of this device's notes.
  ///   - iCloudFolder: Markdown's iCloud Drive folder; nil looks it up (off the main thread), or without iCloud
  ///     leaves only local notes.
  init(
    localFolder: URL = NotesStore.defaultLocalFolder, iCloudFolder: URL? = nil, lookUpICloud: Bool = true,
    keys: VaultKeyProvider = KeychainKeyProvider()
  ) {
    self.localFolder = localFolder
    self.iCloudFolder = iCloudFolder
    self.keys = keys
    bases = NoteBaseCache(
      directory: URL.cachesDirectory.appendingPathComponent("NoteBases", isDirectory: true), keys: keys)
    try? FileManager.default.createDirectory(at: localFolder, withIntermediateDirectories: true)
    watch(localFolder)
    reload()
    if iCloudFolder == nil, lookUpICloud {
      Task {
        let folder = await Task.detached { Self.markdownICloudFolder() }.value
        guard let folder else { return }
        self.iCloudFolder = folder
        self.watch(folder)
        self.reload()
      }
    } else if let iCloudFolder {
      watch(iCloudFolder)
    }
  }

  nonisolated static var defaultLocalFolder: URL {
    URL.applicationSupportDirectory
      .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Shell", isDirectory: true)
      .appendingPathComponent("Notes", isDirectory: true)
  }

  /// Markdown's iCloud Drive notes folder, nil without iCloud Drive. Blocks on first use: call off the main
  /// thread.
  nonisolated static func markdownICloudFolder() -> URL? {
    guard let container = FileManager.default.url(forUbiquityContainerIdentifier: VaultConfiguration.notesContainer)
    else { return nil }
    let documents = container.appendingPathComponent("Documents", isDirectory: true)
    try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
    return documents
  }

  // MARK: - Reading

  func title(for id: UUID) -> String {
    decryptedNote(id: id)?.title ?? "Untitled"
  }

  func subtitle(for id: UUID) -> String? {
    decryptedNote(id: id)?.subtitle
  }

  /// The note's text, read (and decrypted) on demand and cached until the file changes.
  func decryptedNote(id: UUID) -> DecryptedContents? {
    if let pending = pendingText[id] { return Self.contents(of: pending) }
    guard let url = urls[id], let summary = notes.first(where: { $0.id == id }) else { return nil }
    if let cached = cache[id], cached.modified == summary.lastUpdate { return cached.contents }
    do {
      NoteConflicts.resolveQuietly(at: url, bases: bases, keys: keys)
      let text = try Self.read(url, keys: keys)
      bases.setBase(text, for: url)
      let contents = Self.contents(of: text)
      cache[id] = (summary.lastUpdate, contents)
      return contents
    } catch {
      storageError = error.localizedDescription
      return nil
    }
  }

  /// Whether a note has no text yet (a new note closed without typing is deleted).
  func isEmptyNote(_ id: UUID) -> Bool {
    guard let contents = decryptedNote(id: id) else { return true }
    return contents.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  // MARK: - Editing

  /// Creates an empty note (in iCloud when available, encrypted unless turned off) and returns it.
  @discardableResult
  func addNote() -> NoteSummary {
    let folder = iCloudFolder ?? localFolder
    let encrypted = encryptsNewNotes
    let url = Self.availableURL(named: "Untitled", encrypted: encrypted, in: folder)
    do {
      try Self.write("", to: url, keys: keys)
    } catch {
      storageError = error.localizedDescription
    }
    reload()
    let id = id(for: url)
    return notes.first { $0.id == id }
      ?? NoteSummary(id: id, lastUpdate: .now, storedInICloud: folder == iCloudFolder, isEncrypted: encrypted)
  }

  func deleteNote(_ id: UUID) {
    saveTasks[id]?.cancel()
    saveTasks[id] = nil
    pendingText[id] = nil
    cache[id] = nil
    guard let url = urls[id] else { return }
    var error: NSError?
    NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &error) { target in
      try? FileManager.default.removeItem(at: target)
    }
    if let error { storageError = error.localizedDescription }
    urls[id] = nil
    reload()
  }

  /// Replaces a note's text: shown at once, written 5 seconds after the last edit. Unchanged text is a no-op
  /// (the editor repopulates its content when a note opens).
  func updateText(_ text: String, for id: UUID) {
    guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
    if let current = decryptedNote(id: id), current.text == text { return }
    pendingText[id] = text
    notes[index].lastUpdate = .now
    resort()
    saveTasks[id]?.cancel()
    saveTasks[id] = Task { [weak self] in
      try? await Task.sleep(for: .seconds(5))
      guard !Task.isCancelled else { return }
      self?.save(id)
    }
  }

  // MARK: - Location and encryption

  /// Moves a note between iCloud (Markdown's folder) and this device.
  func setICloudStorage(_ inICloud: Bool, for id: UUID) {
    guard let url = urls[id], let summary = notes.first(where: { $0.id == id }), summary.storedInICloud != inICloud
    else { return }
    guard let folder = inICloud ? iCloudFolder : localFolder else {
      storageError = NotesSyncError.iCloudUnavailable.localizedDescription
      return
    }
    save(id)
    move(id, from: url, to: Self.availableURL(named: url.deletingPathExtension().lastPathComponent,
                                              encrypted: NoteFiles.isEncrypted(url), in: folder))
  }

  /// Encrypts a note (`.mdenc`) or decrypts it to a plain `.md` file.
  func setEncrypted(_ encrypted: Bool, for id: UUID) {
    guard let url = urls[id], NoteFiles.isEncrypted(url) != encrypted else { return }
    save(id)
    do {
      let text = try Self.read(url, keys: keys)
      let target = Self.availableURL(
        named: url.deletingPathExtension().lastPathComponent, encrypted: encrypted, in: url.deletingLastPathComponent())
      try Self.write(text, to: target, keys: keys)
      var error: NSError?
      NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &error) { old in
        try? FileManager.default.removeItem(at: old)
      }
      bases.moveBase(from: url, to: target)
      rebind(id, to: target)
    } catch {
      storageError = error.localizedDescription
    }
    reload()
  }

  // MARK: - Persistence

  /// Writes every pending edit now (scene change, quit).
  func flush() {
    for id in Array(pendingText.keys) { save(id) }
  }

  /// Re-reads the folders (iCloud Drive brought changes, another app wrote).
  func refreshOnActivation() {
    reload()
  }

  private func save(_ id: UUID) {
    saveTasks[id]?.cancel()
    saveTasks[id] = nil
    guard let text = pendingText.removeValue(forKey: id), var url = urls[id] else { return }
    do {
      try Self.write(text, to: url, keys: keys)
      bases.setBase(text, for: url)
      // A note still named "Untitled" takes its title as its name, as Markdown shows names.
      let title = Self.title(for: text)
      if url.deletingPathExtension().lastPathComponent.hasPrefix("Untitled"), title != "Untitled" {
        let target = Self.availableURL(
          named: Self.fileName(for: title), encrypted: NoteFiles.isEncrypted(url), in: url.deletingLastPathComponent())
        move(id, from: url, to: target)
        url = target
      }
      cache[id] = nil
      storageError = nil
    } catch {
      pendingText[id] = text
      storageError = error.localizedDescription
    }
    reload()
  }

  private func move(_ id: UUID, from url: URL, to target: URL) {
    var error: NSError?
    let coordinator = NSFileCoordinator()
    coordinator.coordinate(writingItemAt: url, options: .forMoving, writingItemAt: target, options: .forReplacing,
                           error: &error) { from, to in
      do {
        try FileManager.default.moveItem(at: from, to: to)
        coordinator.item(at: from, didMoveTo: to)
      } catch {
        self.storageError = error.localizedDescription
      }
    }
    if let error {
      storageError = error.localizedDescription
      return
    }
    bases.moveBase(from: url, to: target)
    rebind(id, to: target)
    reload()
  }

  // MARK: - Listing

  /// Re-lists both folders, keeping each file's id.
  private func reload() {
    var found: [NoteSummary] = []
    var seen: [UUID: URL] = [:]
    for (folder, inICloud) in [(localFolder, false)] + (iCloudFolder.map { [($0, true)] } ?? []) {
      for url in Self.noteFiles(in: folder) {
        let id = id(for: url)
        seen[id] = url
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        let lastUpdate = pendingText[id] != nil ? (notes.first { $0.id == id }?.lastUpdate ?? modified) : modified
        found.append(NoteSummary(id: id, lastUpdate: lastUpdate, storedInICloud: inICloud, isEncrypted: NoteFiles.isEncrypted(url)))
      }
    }
    urls = seen
    notes = found
    resort()
  }

  private func resort() {
    notes.sort { a, b in
      if a.lastUpdate == b.lastUpdate { return a.id.uuidString < b.id.uuidString }
      return a.lastUpdate > b.lastUpdate
    }
  }

  @ObservationIgnored private var idsByPath: [String: UUID] = [:]

  private func id(for url: URL) -> UUID {
    let path = url.standardizedFileURL.path
    if let id = idsByPath[path] { return id }
    let id = UUID()
    idsByPath[path] = id
    return id
  }

  private func rebind(_ id: UUID, to url: URL) {
    if let old = urls[id] { idsByPath[old.standardizedFileURL.path] = nil }
    idsByPath[url.standardizedFileURL.path] = id
    urls[id] = url
  }

  /// The note files under a folder (subfolders too), iCloud placeholders of notes not downloaded yet included
  /// (their download starts).
  nonisolated private static func noteFiles(in folder: URL) -> [URL] {
    let fileManager = FileManager.default
    guard let enumerator = fileManager.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey]) else {
      return []
    }
    var files: [URL] = []
    for case let url as URL in enumerator {
      var name = url.lastPathComponent
      var file = url
      if name.hasPrefix("."), name.hasSuffix(".icloud") {
        name = String(name.dropFirst().dropLast(".icloud".count))
        file = url.deletingLastPathComponent().appendingPathComponent(name)
        try? fileManager.startDownloadingUbiquitousItem(at: file)
      } else if name.hasPrefix(".") {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { enumerator.skipDescendants() }
        continue
      }
      let ext = (name as NSString).pathExtension.lowercased()
      if ext == "md" || ext == "markdown" || ext == EncryptedNote.fileExtension { files.append(file) }
    }
    return files
  }

  // MARK: - Files

  nonisolated private static func read(_ url: URL, keys: VaultKeyProvider) throws -> String {
    var result: Result<String, Error> = .failure(CocoaError(.fileReadUnknown))
    var error: NSError?
    NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { url in
      result = Result {
        let data = try Data(contentsOf: url)
        if NoteFiles.isEncrypted(url) { return data.isEmpty ? "" : try EncryptedNote.open(data, keys: keys) }
        return String(decoding: data, as: UTF8.self)
      }
    }
    if let error { throw error }
    return try result.get()
  }

  nonisolated private static func write(_ text: String, to url: URL, keys: VaultKeyProvider) throws {
    let data = NoteFiles.isEncrypted(url) ? try EncryptedNote.seal(text, keys: keys) : Data(text.utf8)
    var writeError: Error?
    var error: NSError?
    NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &error) { target in
      do { try data.write(to: target, options: .atomic) } catch { writeError = error }
    }
    if let failure = error ?? writeError { throw failure }
  }

  private static func availableURL(named base: String, encrypted: Bool, in folder: URL) -> URL {
    let ext = encrypted ? EncryptedNote.fileExtension : "md"
    var url = folder.appendingPathComponent(base).appendingPathExtension(ext)
    var number = 2
    while FileManager.default.fileExists(atPath: url.path) {
      url = folder.appendingPathComponent("\(base) \(number)").appendingPathExtension(ext)
      number += 1
    }
    return url
  }

  /// A file name for a title: no slashes or colons, at most 60 characters.
  static func fileName(for title: String) -> String {
    let cleaned = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
      .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
    return cleaned.isEmpty ? "Untitled" : String(cleaned.prefix(60))
  }

  private func watch(_ folder: URL) {
    let presenter = FolderPresenter(url: folder) { [weak self] in
      Task { @MainActor in self?.reload() }
    }
    NSFileCoordinator.addFilePresenter(presenter)
    presenters.append(presenter)
  }

  // MARK: - Title/subtitle derivation

  static func contents(of text: String) -> DecryptedContents {
    DecryptedContents(title: title(for: text), subtitle: subtitle(for: text), text: text)
  }

  // Display-only derivation: a leading markdown prefix on the physical line is stripped so sidebar labels read
  // cleanly, but the note text is never changed. Supported prefixes (each with the single following space):
  // ATX heading '#{1,6} ', list bullet '- ' / '* ' / '+ ', blockquote '> '.

  static func title(for text: String) -> String {
    let firstLine = physicalLines(in: text).first ?? ""
    let derived = stripMarkdownPrefix(firstLine).trimmingCharacters(in: .whitespaces)
    return derived.isEmpty ? "Untitled" : String(derived.prefix(60))
  }

  static func subtitle(for text: String) -> String? {
    let lines = physicalLines(in: text)
    guard lines.count > 1 else { return nil }
    let derived = stripMarkdownPrefix(lines[1]).trimmingCharacters(in: .whitespaces)
    return derived.isEmpty ? nil : derived
  }

  private static func stripMarkdownPrefix(_ line: String) -> String {
    guard !line.isEmpty else { return line }
    if line.first == "#" {
      var hashCount = 0
      for ch in line {
        guard ch == "#" else { break }
        hashCount += 1
      }
      let spaceIndex = line.index(line.startIndex, offsetBy: hashCount)
      if (1...6).contains(hashCount), spaceIndex < line.endIndex, line[spaceIndex] == " " {
        return String(line[line.index(after: spaceIndex)...])
      }
      return line
    }
    if line.count >= 2 {
      let marker = line[line.startIndex]
      let next = line[line.index(line.startIndex, offsetBy: 1)]
      if next == " ", "-*+>".contains(marker) {
        return String(line.dropFirst(2))
      }
    }
    return line
  }

  private static func physicalLines(in text: String) -> [String] {
    text
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
  }
}

/// Note file helpers shared with the Markdown app's conventions.
enum NoteFiles {
  nonisolated static func isEncrypted(_ url: URL) -> Bool { EncryptedNote.isEncrypted(url) }
}

extension NoteConflicts {
  /// Merges iCloud Drive's conflicting versions of a note, if any, against the last version this device saw.
  nonisolated static func resolveQuietly(at url: URL, bases: NoteBaseCache, keys: VaultKeyProvider) {
    guard (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true else { return }
    if let merged = try? resolve(at: url, base: bases.base(for: url), keys: keys) {
      bases.setBase(merged, for: url)
    }
  }
}

/// Reports changes in a folder (another app's write, iCloud Drive's sync).
final class FolderPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
  let presentedItemURL: URL?
  let presentedItemOperationQueue = OperationQueue()
  private let changed: @Sendable () -> Void

  init(url: URL, changed: @escaping @Sendable () -> Void) {
    presentedItemURL = url
    self.changed = changed
    presentedItemOperationQueue.maxConcurrentOperationCount = 1
  }

  func presentedSubitemDidChange(at url: URL) { changed() }
  func presentedItemDidChange() { changed() }
  func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { changed() }
  func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping (Error?) -> Void) {
    changed()
    completionHandler(nil)
  }
}

enum NotesSyncError: LocalizedError {
  case iCloudUnavailable
  case noteNotFound

  var errorDescription: String? {
    switch self {
    case .iCloudUnavailable:
      return "iCloud Drive is unavailable. Sign in with your Apple Account and turn on iCloud Drive, then try again."
    case .noteNotFound:
      return "The note no longer exists."
    }
  }
}
