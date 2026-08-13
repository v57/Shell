import Crypto
import Foundation
import Observation

/// Backs the sidebar's Notes list: one encrypted file per note, each note
/// stored in exactly one of two homes:
/// - **Local** (default): `~/Library/Application Support/<bundle id>/Notes/`,
///   encrypted with the device-bound Secure Enclave key (`SecureFileStore`).
/// - **iCloud** (per-note toggle): the app's iCloud Drive container
///   (`<container>/ShellNotes/`), encrypted with `ICloudNotesKey` — a key
///   stored in iCloud Keychain, so every device signed into the same Apple
///   Account can open the same notes. Files sync via iCloud Drive; changes
///   from other devices are picked up by a lightweight poll.
///
/// Moving a note (`setICloudStorage`) decrypts it with the source key,
/// re-encrypts with the destination key, writes the new file, and only
/// then deletes the source. Notes are loaded at launch and autosaved 5
/// seconds after the last edit — every keystroke restarts the timer.
/// `flush()` writes immediately for scene changes / termination.
@MainActor
@Observable
final class NotesStore {
  /// A single note. The title shown in the sidebar and window title is
  /// derived from the first non-empty line of `text` (Notes.app style),
  /// so renaming is just editing the first line. `storedInICloud` is the
  /// note's storage location (set via `setICloudStorage`).
  struct Note: Identifiable, Equatable {
    let id: UUID
    var text: String
    var storedInICloud: Bool
  }

  /// All notes (local + iCloud), in creation order (oldest first).
  private(set) var notes: [Note] = []

  /// The most recent encryption or persistence failure. Plaintext is never
  /// used as a fallback.
  var storageError: String?

  /// Whether any note currently lives in iCloud (drives the poll + a
  /// subtle cloud badge in the sidebar).
  var hasICloudNotes: Bool { notes.contains { $0.storedInICloud } }

  private var saveTasks: [UUID: Task<Void, Never>] = [:]
  private let localDirectoryURL: URL
  private let iCloudDirectoryURL: URL?

  private static let iCloudSubdirectory = "ShellNotes"
  /// Poll interval for iCloud changes arriving from other devices.
  private static let syncPollInterval: Duration = .seconds(2.5)

  private var syncPollTask: Task<Void, Never>?
  private var lastCloudSignature: [String: Date] = [:]

  init(directoryURL: URL? = nil, iCloudDirectoryURL: URL? = nil) {
    self.localDirectoryURL = directoryURL ?? Self.defaultDirectoryURL()
    self.iCloudDirectoryURL = iCloudDirectoryURL ?? Self.iCloudNotesDirectoryURL()
    load()
    if self.iCloudDirectoryURL != nil {
      startSyncPolling()
    }
  }

  // MARK: - Reading

  /// The title for a note: physical line one, else "Untitled".
  func title(for id: UUID) -> String {
    guard let note = notes.first(where: { $0.id == id }) else { return "Untitled" }
    return Self.title(for: note.text)
  }

  static func title(for text: String) -> String {
    let firstLine = physicalLines(in: text).first ?? ""
    let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? "Untitled" : String(trimmed.prefix(60))
  }

  /// Optional sidebar subtitle: physical line two only.
  static func subtitle(for text: String) -> String? {
    let lines = physicalLines(in: text)
    guard lines.count > 1 else { return nil }
    let subtitle = lines[1].trimmingCharacters(in: .whitespaces)
    return subtitle.isEmpty ? nil : subtitle
  }

  private static func physicalLines(in text: String) -> [String] {
    text
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
  }

  // MARK: - Editing

  /// Creates a new empty note (and its file) and returns it. New notes
  /// are stored locally by default (device-bound key, always available);
  /// move them to iCloud with `setICloudStorage`. The caller selects it
  /// in the sidebar.
  @discardableResult
  func addNote() -> Note {
    let note = Note(id: UUID(), text: "", storedInICloud: false)
    notes.append(note)
    save(noteID: note.id)  // materialize the file now, not after 5s
    return note
  }

  /// Deletes a note and its file (wherever it lives), cancelling any
  /// pending autosave.
  func deleteNote(_ id: UUID) {
    saveTasks[id]?.cancel()
    saveTasks[id] = nil
    guard let note = notes.first(where: { $0.id == id }) else { return }
    notes.removeAll { $0.id == id }
    let url = note.storedInICloud ? cloudFileURL(for: id) : localFileURL(for: id)
    if note.storedInICloud {
      try? Self.coordinateDelete(url)
      lastCloudSignature = cloudDirectorySignature()
    } else {
      try? FileManager.default.removeItem(at: url)
    }
  }

  /// Replaces a note's text and restarts its 5s autosave timer.
  func updateText(_ text: String, for id: UUID) {
    guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
    notes[index].text = text
    scheduleSave(id)
  }

  // MARK: - Per-note storage location

  /// Moves one note between local and iCloud storage. The note is
  /// decrypted with its current key and re-encrypted with the destination
  /// key; the destination file is written before the source is deleted, so
  /// a failure leaves the note untouched in place. Failures surface in
  /// `storageError`.
  func setICloudStorage(_ inICloud: Bool, for id: UUID) {
    guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
    guard notes[index].storedInICloud != inICloud else { return }
    let note = notes[index]
    do {
      if inICloud {
        guard let cloud = iCloudDirectoryURL else {
          storageError = "iCloud is unavailable. Sign in with your Apple Account and enable iCloud Drive, then try again."
          return
        }
        let plaintext = try readPlaintext(note)
        let ciphertext = try SecureFileStore.seal(plaintext, using: ICloudNotesKey.loadOrCreate())
        try Self.coordinateWrite(ciphertext, to: cloudFileURL(for: id))
        try? FileManager.default.removeItem(at: localFileURL(for: id))
      } else {
        let plaintext = try readPlaintext(note)
        let ciphertext = try SecureFileStore.seal(plaintext, using: SecureFileStore.symmetricKey(for: .notes))
        try ciphertext.write(to: localFileURL(for: id), options: .atomic)
        try? Self.coordinateDelete(cloudFileURL(for: id))
        lastCloudSignature = cloudDirectorySignature()
      }
      notes[index].storedInICloud = inICloud
      storageError = nil
    } catch {
      storageError = error.localizedDescription
      NSLog("NotesStore: could not move note to \(inICloud ? "iCloud" : "local") storage: \(error)")
    }
  }

  // MARK: - Persistence

  /// Writes every note with a pending edit immediately (scene change, quit).
  func flush() {
    for (id, task) in saveTasks {
      task.cancel()
      save(noteID: id)
    }
    saveTasks.removeAll()
  }

  private func scheduleSave(_ id: UUID) {
    saveTasks[id]?.cancel()
    saveTasks[id] = Task { [weak self] in
      try? await Task.sleep(for: .seconds(5))
      guard !Task.isCancelled else { return }
      self?.save(noteID: id)
    }
  }

  private func save(noteID id: UUID) {
    guard let note = notes.first(where: { $0.id == id }) else { return }
    do {
      let plaintext = Data(note.text.utf8)
      if note.storedInICloud {
        guard iCloudDirectoryURL != nil else {
          throw NotesSyncError.iCloudUnavailable
        }
        let key = try ICloudNotesKey.loadOrCreate()
        let ciphertext = try SecureFileStore.seal(plaintext, using: key)
        try Self.coordinateWrite(ciphertext, to: cloudFileURL(for: id))
        lastCloudSignature = cloudDirectorySignature()
      } else {
        try SecureFileStore.write(plaintext, to: localFileURL(for: id), domain: .notes)
      }
      storageError = nil
    } catch {
      storageError = error.localizedDescription
      NSLog("NotesStore: could not save note: \(error)")
    }
  }

  private func localFileURL(for id: UUID) -> URL {
    localDirectoryURL.appendingPathComponent("\(id.uuidString).note")
  }

  private func cloudFileURL(for id: UUID) -> URL {
    iCloudDirectoryURL!.appendingPathComponent("\(id.uuidString).note")
  }

  /// Reads and decrypts a note's current file with the key matching its
  /// storage location.
  private func readPlaintext(_ note: Note) throws -> Data {
    let url = note.storedInICloud ? cloudFileURL(for: note.id) : localFileURL(for: note.id)
    let key = note.storedInICloud
      ? (try ICloudNotesKey.loadOrCreate() as SymmetricKey)
      : (try SecureFileStore.symmetricKey(for: .notes) as SymmetricKey)
    return try SecureFileStore.open(Data(contentsOf: url), using: key)
  }

  /// Loads local + iCloud notes. The same UUID in both stores (a race
  /// between two devices) resolves to the newer file. iCloud notes are
  /// skipped entirely when the container is unavailable (signed out).
  private func load() {
    let fm = FileManager.default
    try? fm.createDirectory(at: localDirectoryURL, withIntermediateDirectories: true)

    // Local notes first (device-bound key).
    var byID: [UUID: (note: Note, date: Date)] = [:]
    let localFiles = (try? fm.contentsOfDirectory(
      at: localDirectoryURL,
      includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey]
    )) ?? []
    for url in localFiles where url.pathExtension == "note" {
      guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
      do {
        let data = try SecureFileStore.read(from: url, domain: .notes)
        guard let text = String(data: data, encoding: .utf8) else { continue }
        byID[id] = (Note(id: id, text: text, storedInICloud: false), date(of: url))
      } catch {
        storageError = error.localizedDescription
        NSLog("NotesStore: could not load \(url.lastPathComponent): \(error)")
      }
    }

    // iCloud notes (iCloud key). Conflicts with a local file of the same
    // id keep whichever file is newer.
    if let cloud = iCloudDirectoryURL {
      let cloudFiles = (try? fm.contentsOfDirectory(
        at: cloud,
        includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey]
      )) ?? []
      for url in cloudFiles where url.pathExtension == "note" {
        guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
        do {
          let key = try ICloudNotesKey.loadOrCreate()
          let data = try SecureFileStore.open(Self.coordinateRead(url), using: key)
          guard let text = String(data: data, encoding: .utf8) else { continue }
          let entry = (Note(id: id, text: text, storedInICloud: true), date(of: url))
          if let existing = byID[id] {
            if entry.1 > existing.1 { byID[id] = entry }
          } else {
            byID[id] = entry
          }
        } catch {
          storageError = error.localizedDescription
          NSLog("NotesStore: could not load \(url.lastPathComponent): \(error)")
        }
      }
    }

    notes = byID.values
      .sorted { a, b in
        if a.1 == b.1 { return a.0.id.uuidString < b.0.id.uuidString }
        return a.1 < b.1
      }
      .map(\.0)
    lastCloudSignature = cloudDirectorySignature()
  }

  /// Re-reads both stores. In-memory edits with a pending autosave are
  /// re-applied so a remote-triggered reload never reverts what the user
  /// is typing (the pending save writes it).
  private func reload() {
    let pending = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
    load()
    for (id, note) in pending {
      if let index = notes.firstIndex(where: { $0.id == id }) {
        if notes[index].text != note.text { notes[index].text = note.text }
      } else if saveTasks[id] != nil {
        // Deleted on another device but we still owe a save — local edit wins.
        notes.append(note)
      }
    }
  }

  /// Creation order for the list; falls back to the file's modification
  /// date when creationDate is unavailable.
  private func date(of url: URL) -> Date {
    if let values = try? url.resourceValues(forKeys: [.creationDateKey]),
       let created = values.creationDate {
      return created
    }
    return (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
      ?? .distantPast
  }

  // MARK: - Single-note move primitive (also used by tests)

  /// Re-encrypts one note file and writes it to the destination, removing
  /// the source only after the destination exists. Throws without touching
  /// the source when the destination write fails.
  static func moveNote(
    id: UUID,
    from sourceURL: URL,
    decryptingWith oldKey: SymmetricKey,
    to destinationURL: URL,
    encryptingWith newKey: SymmetricKey,
    write: (Data, URL) throws -> Void
  ) throws {
    let plaintext = try SecureFileStore.open(Data(contentsOf: sourceURL), using: oldKey)
    let reencrypted = try SecureFileStore.seal(plaintext, using: newKey)
    try write(reencrypted, destinationURL)
    try? FileManager.default.removeItem(at: sourceURL)
  }

  // MARK: - iCloud change polling

  private func startSyncPolling() {
    stopSyncPolling()
    lastCloudSignature = cloudDirectorySignature()
    syncPollTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: Self.syncPollInterval)
        guard !Task.isCancelled else { return }
        self?.pollForRemoteChanges()
      }
    }
  }

  private func stopSyncPolling() {
    syncPollTask?.cancel()
    syncPollTask = nil
  }

  /// Reloads when iCloud downloaded or removed files while the app runs.
  private func pollForRemoteChanges() {
    guard iCloudDirectoryURL != nil else { return }
    let signature = cloudDirectorySignature()
    guard signature != lastCloudSignature else { return }
    lastCloudSignature = signature
    reload()
  }

  private func cloudDirectorySignature() -> [String: Date] {
    guard let cloud = iCloudDirectoryURL else { return [:] }
    let fm = FileManager.default
    let files = (try? fm.contentsOfDirectory(
      at: cloud,
      includingPropertiesForKeys: [.contentModificationDateKey]
    )) ?? []
    var signature: [String: Date] = [:]
    for url in files where url.pathExtension == "note" {
      signature[url.lastPathComponent] = date(of: url)
    }
    return signature
  }

  // MARK: - Locations & coordinated IO

  /// The app's iCloud Drive container URL, or nil when iCloud is not
  /// available (no Apple Account / iCloud Drive disabled / entitlement
  /// missing).
  static func iCloudContainerURL() -> URL? {
    FileManager.default.url(forUbiquityContainerIdentifier: nil)
  }

  /// Where iCloud notes live: a private (non-Documents) folder so the
  /// encrypted blobs stay out of the Files app.
  static func iCloudNotesDirectoryURL() -> URL? {
    iCloudContainerURL()?.appendingPathComponent(iCloudSubdirectory, isDirectory: true)
  }

  static func defaultDirectoryURL() -> URL {
    let support = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first!
    let bundleID = Bundle.main.bundleIdentifier ?? "Shell"
    return support
      .appendingPathComponent(bundleID, isDirectory: true)
      .appendingPathComponent("Notes", isDirectory: true)
  }

  /// Coordinated write for iCloud Drive files (never atomic — atomic
  /// renames confuse the sync machinery).
  static func coordinateWrite(_ data: Data, to url: URL) throws {
    var coordinationError: NSError?
    var writeError: Error?
    NSFileCoordinator(filePresenter: nil).coordinate(
      writingItemAt: url, options: [], error: &coordinationError
    ) { coordinatedURL in
      do {
        try FileManager.default.createDirectory(
          at: coordinatedURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try data.write(to: coordinatedURL)
      } catch {
        writeError = error
      }
    }
    if let coordinationError { throw coordinationError }
    if let writeError { throw writeError }
  }

  /// Coordinated read for iCloud Drive files (materializes a
  /// not-yet-downloaded file before reading).
  static func coordinateRead(_ url: URL) throws -> Data {
    var coordinationError: NSError?
    var readError: Error?
    var result: Data?
    NSFileCoordinator(filePresenter: nil).coordinate(
      readingItemAt: url, options: [], error: &coordinationError
    ) { coordinatedURL in
      do {
        result = try Data(contentsOf: coordinatedURL)
      } catch {
        readError = error
      }
    }
    if let coordinationError { throw coordinationError }
    if let readError { throw readError }
    return result ?? Data()
  }

  static func coordinateDelete(_ url: URL) throws {
    var coordinationError: NSError?
    NSFileCoordinator(filePresenter: nil).coordinate(
      writingItemAt: url, options: .forDeleting, error: &coordinationError
    ) { coordinatedURL in
      try? FileManager.default.removeItem(at: coordinatedURL)
    }
    if let coordinationError { throw coordinationError }
  }
}

enum NotesSyncError: LocalizedError {
  case iCloudUnavailable

  var errorDescription: String? {
    switch self {
    case .iCloudUnavailable:
      return "iCloud is unavailable. Sign in with your Apple Account and enable iCloud Drive, then try again."
    }
  }
}
