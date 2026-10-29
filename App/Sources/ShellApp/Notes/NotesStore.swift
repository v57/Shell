import Foundation
import Observation
import VaultKit

/// Backs the sidebar's Notes list: the notes the v57 apps share through the vault (`../Vault`).
///
/// Each note is a `VaultNote`: it syncs through iCloud (encrypted, titles included) and is the same note the
/// Markdown app shows, which keeps it as a file in its notes folder (`NotesMirror`). Shell reads and edits the
/// records directly, so it works without Markdown and on iOS. `isEncrypted` decides the file Markdown writes:
/// `.mdenc` (only the v57 apps read it) or a plain `.md`. New notes are encrypted.
///
/// Edits show at once and are saved 2 seconds after the last keystroke. A note still named "Untitled" takes its
/// title as its name when saved. Changes from Markdown, other devices or other windows arrive live.
@MainActor
@Observable
final class NotesStore {
  /// A sidebar row.
  struct NoteSummary: Identifiable, Equatable {
    let id: UUID
    var lastUpdate: Date
    var isEncrypted: Bool
  }

  /// A note's text and the title and subtitle derived from it.
  struct DecryptedContents: Equatable {
    var title: String
    var subtitle: String?
    var text: String
  }

  /// All notes, most recently changed first.
  private(set) var notes: [NoteSummary] = []

  /// The most recent read or write failure.
  var storageError: String?

  /// Whether new notes are encrypted on disk (on unless turned off).
  static let encryptsNewNotesKey = "encryptsNewNotes"
  var encryptsNewNotes: Bool {
    get { UserDefaults.standard.object(forKey: Self.encryptsNewNotesKey) as? Bool ?? true }
    set { UserDefaults.standard.set(newValue, forKey: Self.encryptsNewNotesKey) }
  }

  @ObservationIgnored private let vault: Vault
  @ObservationIgnored private var records: [UUID: VaultNote] = [:]
  @ObservationIgnored private var saveTasks: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored private var pendingText: [UUID: String] = [:]
  @ObservationIgnored private var observer: VaultChangeObserver?
  @ObservationIgnored var saveDelay: Duration = .seconds(2)

  init(vault: Vault = .shared) {
    self.vault = vault
    reload()
    observer = VaultChangeObserver { [weak self] in
      Task { @MainActor in self?.refreshOnActivation() }
    }
  }

  // MARK: - Reading

  func title(for id: UUID) -> String {
    decryptedNote(id: id)?.title ?? "Untitled"
  }

  func subtitle(for id: UUID) -> String? {
    decryptedNote(id: id)?.subtitle
  }

  func decryptedNote(id: UUID) -> DecryptedContents? {
    if let pending = pendingText[id] { return Self.contents(of: pending) }
    return records[id].map { Self.contents(of: $0.text) }
  }

  /// Whether a note has no text yet (a new note closed without typing is deleted).
  func isEmptyNote(_ id: UUID) -> Bool {
    guard let contents = decryptedNote(id: id) else { return true }
    return contents.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  // MARK: - Editing

  /// Creates an empty note and returns it.
  @discardableResult
  func addNote() -> NoteSummary {
    let names = Set(records.values.filter { $0.folder.isEmpty }.map { $0.name.lowercased() })
    var name = "Untitled"
    var number = 2
    while names.contains(name.lowercased()) {
      name = "Untitled \(number)"
      number += 1
    }
    let note = VaultNote(name: name, encrypted: encryptsNewNotes)
    vault.save(note)
    storageError = vault.error
    reload()
    let id = Self.uuid(note.id)
    return notes.first { $0.id == id } ?? NoteSummary(id: id, lastUpdate: .now, isEncrypted: note.encrypted)
  }

  /// Creates a note holding `text` (a file dropped on Notes), named `name` or the next free "name 2".
  @discardableResult
  func addNote(named name: String, text: String, encrypted: Bool) -> NoteSummary {
    let note = VaultNote(name: availableName(Self.fileName(for: name), in: "", excluding: ""), encrypted: encrypted, text: text)
    vault.save(note)
    storageError = vault.error
    reload()
    let id = Self.uuid(note.id)
    return notes.first { $0.id == id } ?? NoteSummary(id: id, lastUpdate: .now, isEncrypted: note.encrypted)
  }

  func deleteNote(_ id: UUID) {
    saveTasks[id]?.cancel()
    saveTasks[id] = nil
    pendingText[id] = nil
    guard let note = records[id] else { return }
    vault.delete(note)
    reload()
  }

  /// Replaces a note's text: shown at once, saved shortly after the last edit. Unchanged text is a no-op (the
  /// editor repopulates its content when a note opens).
  func updateText(_ text: String, for id: UUID) {
    guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
    if let current = decryptedNote(id: id), current.text == text { return }
    pendingText[id] = text
    notes[index].lastUpdate = .now
    resort()
    saveTasks[id]?.cancel()
    saveTasks[id] = Task { [weak self, saveDelay] in
      try? await Task.sleep(for: saveDelay)
      guard !Task.isCancelled else { return }
      self?.save(id)
    }
  }

  /// Encrypts the note's file (`.mdenc`) or makes it a plain `.md` one. In iCloud it's encrypted either way.
  func setEncrypted(_ encrypted: Bool, for id: UUID) {
    save(id)
    guard var note = records[id], note.encrypted != encrypted else { return }
    note.encrypted = encrypted
    vault.save(note)
    reload()
  }

  // MARK: - Persistence

  /// Saves every pending edit now (scene change, quit).
  func flush() {
    for id in Array(pendingText.keys) { save(id) }
  }

  /// Re-reads the notes (another app or device changed them).
  func refreshOnActivation() {
    vault.reload()
    reload()
  }

  private func save(_ id: UUID) {
    saveTasks[id]?.cancel()
    saveTasks[id] = nil
    guard let text = pendingText.removeValue(forKey: id), var note = records[id] else { return }
    note.text = text
    // A note still named "Untitled" takes its title as its name, as Markdown shows names.
    let title = Self.title(for: text)
    if note.name.hasPrefix("Untitled"), title != "Untitled" {
      note.name = availableName(Self.fileName(for: title), in: note.folder, excluding: note.id)
    }
    vault.save(note)
    storageError = vault.error
    reload()
  }

  /// `name`, or the next free "name 2" among the notes in `folder`.
  private func availableName(_ name: String, in folder: String, excluding id: String) -> String {
    let taken = Set(records.values.filter { $0.folder == folder && $0.id != id }.map { $0.name.lowercased() })
    var candidate = name
    var number = 2
    while taken.contains(candidate.lowercased()) {
      candidate = "\(name) \(number)"
      number += 1
    }
    return candidate
  }

  private func reload() {
    guard let store = vault.store, let items = try? store.items(kind: VaultNote.kind) else { return }
    var byID: [UUID: VaultNote] = [:]
    var summaries: [NoteSummary] = []
    for item in items {
      let note = VaultNote(id: item.id, values: item.values)
      let id = Self.uuid(item.id)
      byID[id] = note
      let lastUpdate = pendingText[id] != nil ? (notes.first { $0.id == id }?.lastUpdate ?? item.modified) : item.modified
      summaries.append(NoteSummary(id: id, lastUpdate: lastUpdate, isEncrypted: note.encrypted))
    }
    records = byID
    notes = summaries
    resort()
  }

  private func resort() {
    notes.sort { a, b in
      if a.lastUpdate == b.lastUpdate { return a.id.uuidString < b.id.uuidString }
      return a.lastUpdate > b.lastUpdate
    }
  }

  static func uuid(_ id: String) -> UUID { UUID(uuidString: id) ?? stableUUID(id) }

  /// A file name for a title: no slashes or colons, at most 60 characters.
  static func fileName(for title: String) -> String {
    let cleaned = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
      .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
    return cleaned.isEmpty ? "Untitled" : String(cleaned.prefix(60))
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
