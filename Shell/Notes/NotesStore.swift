import Foundation
import Observation

/// Backs the sidebar's Notes list: one encrypted file per note under
/// ~/Library/Application Support/<bundle id>/Notes/<uuid>.note,
/// loaded at launch and autosaved 5 seconds after the last edit — every
/// keystroke restarts the timer. `flush()` writes immediately for scene
/// changes / termination.
@MainActor
@Observable
final class NotesStore {
  /// A single note. The title shown in the sidebar and window title is
  /// derived from the first non-empty line of `text` (Notes.app style),
  /// so renaming is just editing the first line.
  struct Note: Identifiable, Equatable {
    let id: UUID
    var text: String
  }

  /// All notes, in creation order (oldest first).
  private(set) var notes: [Note] = []

  /// The most recent encryption or persistence failure. Plaintext is never
  /// used as a fallback.
  var storageError: String?

  private var saveTasks: [UUID: Task<Void, Never>] = [:]
  private let directoryURL: URL

  init(directoryURL: URL? = nil) {
    let url = directoryURL ?? Self.defaultDirectoryURL()
    self.directoryURL = url
    load()
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

  /// Creates a new empty note (and its file) and returns it. The caller
  /// selects it in the sidebar.
  @discardableResult
  func addNote() -> Note {
    let note = Note(id: UUID(), text: "")
    notes.append(note)
    save(noteID: note.id)  // materialize the file now, not after 5s
    return note
  }

  /// Deletes a note and its file, cancelling any pending autosave.
  func deleteNote(_ id: UUID) {
    saveTasks[id]?.cancel()
    saveTasks[id] = nil
    notes.removeAll { $0.id == id }
    try? FileManager.default.removeItem(at: fileURL(for: id))
  }

  /// Replaces a note's text and restarts its 5s autosave timer.
  func updateText(_ text: String, for id: UUID) {
    guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
    notes[index].text = text
    scheduleSave(id)
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
      let fm = FileManager.default
      try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
      try SecureFileStore.write(Data(note.text.utf8), to: fileURL(for: id), domain: .notes)
      storageError = nil
    } catch {
      storageError = error.localizedDescription
      NSLog("NotesStore: could not save note: \(error)")
    }
  }

  private func fileURL(for id: UUID) -> URL {
    directoryURL.appendingPathComponent("\(id.uuidString).note")
  }

  private func load() {
    let fm = FileManager.default
    try? fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    let files = (try? fm.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey]
    )) ?? []
    let sorted = files
      .filter { $0.pathExtension == "note" }
      .sorted {
        let a = date(of: $0), b = date(of: $1)
        if a == b { return $0.lastPathComponent < $1.lastPathComponent }
        return a < b
      }
    for url in sorted {
      guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
      do {
        let data = try SecureFileStore.read(from: url, domain: .notes)
        guard let text = String(data: data, encoding: .utf8) else {
          throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        notes.append(Note(id: id, text: text))
      } catch {
        storageError = error.localizedDescription
        NSLog("NotesStore: could not load \(url.lastPathComponent): \(error)")
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

  static func defaultDirectoryURL() -> URL {
    let support = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first!
    let bundleID = Bundle.main.bundleIdentifier ?? "Shell"
    return support
      .appendingPathComponent(bundleID, isDirectory: true)
      .appendingPathComponent("Notes", isDirectory: true)
  }
}
