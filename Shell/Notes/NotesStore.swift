import Crypto
import Foundation
import Observation
import SwiftData

/// Backs the sidebar's Notes list. Each note is a `NoteRecord` living in
/// exactly one of two SwiftData stores:
/// - **Local** (`cloudKitDatabase: .none`): stays on this device, encrypted
///   with the Secure-Enclave-derived key (`NoteKeyID.device`).
/// - **iCloud** (CloudKit-synced store, `iCloud.dev.v57.sh`): syncs across
///   devices, encrypted with the iCloud Keychain key (`NoteKeyID.icloud`).
///
/// ALL note content — title, subtitle, and text — is stored as separate
/// AES-GCM ciphertexts, so CloudKit never sees plaintext note data (only
/// `lastUpdate` and the key id, which are needed for sorting/fetching).
///
/// **Lazy decryption**: the store exposes `NoteSummary` rows (no plaintext);
/// views call `decryptedNote(id:)`, which decrypts on demand and caches.
/// The sidebar's lazy List only materializes visible rows, so only visible
/// cells decrypt; the editor decrypts content when opened. Nothing is
/// decrypted eagerly at load.
@MainActor
@Observable
final class NotesStore {
  /// A sidebar row: identifiers + the sort key, no plaintext.
  struct NoteSummary: Identifiable, Equatable {
    let id: UUID
    var lastUpdate: Date
    var storedInICloud: Bool
  }

  /// Decrypted note contents, produced lazily by `decryptedNote(id:)`.
  struct DecryptedContents: Equatable {
    var title: String
    var subtitle: String?
    var text: String
  }

  /// All notes (local + iCloud), sorted by last usage: most recently
  /// updated first. Equal timestamps tie-break by id so the order is
  /// deterministic across reloads (Dictionary iteration is not stable).
  private(set) var notes: [NoteSummary] = []

  /// The most recent encryption or persistence failure. Plaintext is never
  /// used as a fallback.
  var storageError: String?

  /// Whether any note currently lives in iCloud.
  var hasICloudNotes: Bool { notes.contains { $0.storedInICloud } }

  private let localContext: ModelContext
  private let cloudContext: ModelContext?

  // MARK: Test seam — hermetic keys. Production defaults resolve the real
  // keychain keys; tests inject generated keys so the store logic runs on
  // any machine (the real keychain needs an unlocked screen / iCloud
  // session).
  var deviceKeyProvider: () throws -> SymmetricKey = {
    try SecureFileStore.symmetricKey(for: .notes)
  }
  var iCloudKeyProvider: () throws -> SymmetricKey = {
    try ICloudNotesKey.loadOrCreate()
  }

  private var saveTasks: [UUID: Task<Void, Never>] = [:]
  private var pendingText: [UUID: String] = [:]
  private var decryptionCache: [UUID: DecryptedContents] = [:]

  /// - Parameter stores: the pre-built containers. Production callers get
  ///   them from `NoteStores.make()`; tests from `NoteStores.makeTest()`.
  ///   Containers MUST be created outside this init — a container created
  ///   inside an @Observable init traps (SIGTRAP, `brk #0x1` ×2) on its
  ///   first insert, so the old `NotesStore()` nil-branch is gone.
  init(stores: NoteStores) {
    localContext = stores.local.mainContext
    cloudContext = stores.cloud?.mainContext
    reload()
  }

  // MARK: - Reading

  /// The title for a note: physical line one, else "Untitled". Derived at
  /// save time and stored encrypted; decrypted on demand (cached).
  func title(for id: UUID) -> String {
    decryptedNote(id: id)?.title ?? "Untitled"
  }

  /// Optional sidebar subtitle: physical line two only.
  func subtitle(for id: UUID) -> String? {
    decryptedNote(id: id)?.subtitle
  }

  /// Lazy decryption — the only place ciphertext becomes plaintext. The
  /// sidebar's List renders visible rows only, so this runs for visible
  /// cells; results are cached per note until the note changes.
  func decryptedNote(id: UUID) -> DecryptedContents? {
    if let cached = decryptionCache[id] { return cached }
    guard let summary = notes.first(where: { $0.id == id }) else { return nil }
    let context = summary.storedInICloud ? cloudContext : localContext
    guard let context, let record = fetchRecord(id, in: context) else { return nil }
    do {
      let key = try (summary.storedInICloud ? iCloudKeyProvider() : deviceKeyProvider())
      let contents: DecryptedContents
      if let plaintext = try NoteCrypto.decrypt(record: record, using: key) {
        contents = DecryptedContents(
          title: plaintext.title,
          subtitle: plaintext.subtitle,
          text: plaintext.text
        )
      } else {
        // Empty note (no content ciphertext yet).
        contents = DecryptedContents(title: "Untitled", subtitle: nil, text: "")
      }
      decryptionCache[id] = contents
      return contents
    } catch {
      storageError = error.localizedDescription
      return nil
    }
  }

  // MARK: - Editing

  /// Creates a new empty note in the LOCAL store (device-bound key, always
  /// available) and returns its summary. The caller selects it.
  @discardableResult
  func addNote() -> NoteSummary {
    let record = NoteRecord(lastUpdate: Date(), keyId: NoteKeyID.device)
    localContext.insert(record)
    try? localContext.save()
    reload()
    return notes.first { $0.id == record.id } ?? NoteSummary(
      id: record.id,
      lastUpdate: record.lastUpdate,
      storedInICloud: false
    )
  }

  /// Deletes a note (from whichever store it lives in), cancelling any
  /// pending autosave.
  func deleteNote(_ id: UUID) {
    saveTasks[id]?.cancel()
    saveTasks[id] = nil
    pendingText[id] = nil
    decryptionCache.removeValue(forKey: id)
    if let record = fetchRecord(id, in: localContext) {
      localContext.delete(record)
      try? localContext.save()
    } else if let cloudContext, let record = fetchRecord(id, in: cloudContext) {
      cloudContext.delete(record)
      try? cloudContext.save()
    }
    reload()
  }

  /// Replaces a note's text. The plaintext is cached immediately (so the
  /// sidebar title follows typing) and persisted 5s after the last edit.
  func updateText(_ text: String, for id: UUID) {
    guard notes.contains(where: { $0.id == id }) else { return }
    decryptionCache[id] = DecryptedContents(
      title: Self.title(for: text),
      subtitle: Self.subtitle(for: text),
      text: text
    )
    pendingText[id] = text
    // Bump the sort key immediately so the sidebar reorders while typing
    // (the persisted date catches up when the autosave lands).
    if let index = notes.firstIndex(where: { $0.id == id }) {
      notes[index].lastUpdate = Date()
      resortNotes()
    }
    scheduleSave(id, text: text)
  }

  // MARK: - Per-note storage location

  /// Moves one note between the local and iCloud stores: decrypt with the
  /// source key, re-encrypt with the destination key, insert into the
  /// target store, delete from the source. Failures leave the note in
  /// place and surface in `storageError`.
  func setICloudStorage(_ inICloud: Bool, for id: UUID) {
    guard let summary = notes.first(where: { $0.id == id }),
          summary.storedInICloud != inICloud else { return }
    do {
      let sourceContext = summary.storedInICloud ? cloudContext : localContext
      guard let sourceContext, let record = fetchRecord(id, in: sourceContext) else {
        throw NotesSyncError.noteNotFound
      }
      guard let targetContext = inICloud ? cloudContext : localContext else {
        storageError = "iCloud is unavailable. Sign in with your Apple Account, then try again."
        return
      }
      let sourceKey = try (summary.storedInICloud ? iCloudKeyProvider() : deviceKeyProvider())
      let targetKey = try (inICloud ? iCloudKeyProvider() : deviceKeyProvider())
      let plaintext = try NoteCrypto.decrypt(record: record, using: sourceKey)

      let targetRecord = NoteRecord(
        id: record.id,
        lastUpdate: Date(),
        keyId: inICloud ? NoteKeyID.icloud : NoteKeyID.device
      )
      if let text = plaintext?.text {
        let ciphers = try NoteCrypto.encrypt(text: text, using: targetKey)
        targetRecord.titleCipher = ciphers.titleCipher
        targetRecord.subtitleCipher = ciphers.subtitleCipher
        targetRecord.contentCipher = ciphers.contentCipher
      }
      targetContext.insert(targetRecord)
      try targetContext.save()
      sourceContext.delete(record)
      try sourceContext.save()
      decryptionCache.removeValue(forKey: id)
      storageError = nil
      reload()
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
      if let text = pendingText[id] {
        save(id: id, text: text)
      }
    }
    saveTasks.removeAll()
  }

  /// Re-fetches both stores — the no-push sync trigger. Called when the
  /// scene becomes active so notes changed on another device (synced by
  /// the CloudKit store while the app runs) appear promptly.
  func refreshOnActivation() {
    reload()
  }

  private func scheduleSave(_ id: UUID, text: String) {
    saveTasks[id]?.cancel()
    saveTasks[id] = Task { [weak self] in
      try? await Task.sleep(for: .seconds(5))
      guard !Task.isCancelled else { return }
      self?.save(id: id, text: text)
    }
  }

  private func save(id: UUID, text: String) {
    guard let summary = notes.first(where: { $0.id == id }) else { return }
    do {
      let context = summary.storedInICloud ? cloudContext : localContext
      guard let context, let record = fetchRecord(id, in: context) else {
        throw NotesSyncError.noteNotFound
      }
      let key = try (summary.storedInICloud ? iCloudKeyProvider() : deviceKeyProvider())
      let ciphers = try NoteCrypto.encrypt(text: text, using: key)
      record.titleCipher = ciphers.titleCipher
      record.subtitleCipher = ciphers.subtitleCipher
      record.contentCipher = ciphers.contentCipher
      record.lastUpdate = Date()
      try context.save()
      pendingText[id] = nil
      if let index = notes.firstIndex(where: { $0.id == id }) {
        notes[index].lastUpdate = record.lastUpdate
        resortNotes()
      }
      storageError = nil
    } catch {
      storageError = error.localizedDescription
      NSLog("NotesStore: could not save note: \(error)")
    }
  }

  private func fetchRecord(_ id: UUID, in context: ModelContext) -> NoteRecord? {
    var descriptor = FetchDescriptor<NoteRecord>(predicate: #Predicate { $0.id == id })
    descriptor.fetchLimit = 1
    return try? context.fetch(descriptor).first
  }

  /// Re-reads both stores, merging by id (same-id conflict: newer wins).
  private func reload() {
    var byID: [UUID: NoteSummary] = [:]
    let localRecords = (try? localContext.fetch(FetchDescriptor<NoteRecord>())) ?? []
    for record in localRecords {
      byID[record.id] = NoteSummary(id: record.id, lastUpdate: record.lastUpdate, storedInICloud: false)
    }
    if let cloudContext {
      let cloudRecords = (try? cloudContext.fetch(FetchDescriptor<NoteRecord>())) ?? []
      for record in cloudRecords {
        let summary = NoteSummary(id: record.id, lastUpdate: record.lastUpdate, storedInICloud: true)
        if let existing = byID[record.id] {
          if summary.lastUpdate > existing.lastUpdate { byID[record.id] = summary }
        } else {
          byID[record.id] = summary
        }
      }
    }
    notes = Array(byID.values)
    resortNotes()
  }

  /// Sorts `notes` by last usage: most recently updated first, equal
  /// timestamps tie-broken by id (stable, deterministic — Dictionary
  /// iteration order is not).
  private func resortNotes() {
    notes.sort { a, b in
      if a.lastUpdate == b.lastUpdate { return a.id.uuidString < b.id.uuidString }
      return a.lastUpdate > b.lastUpdate
    }
  }

  // MARK: - Title/subtitle derivation (also used at save time by NoteCrypto)

  static func title(for text: String) -> String {
    let firstLine = physicalLines(in: text).first ?? ""
    let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? "Untitled" : String(trimmed.prefix(60))
  }

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

  // MARK: - Locations

  /// The app's iCloud container URL, or nil when iCloud is unavailable
  /// (no Apple Account / iCloud Drive disabled). Used only as a fast probe
  /// to skip DEBUG CloudKit schema initialization when there is no iCloud
  /// session — the CloudKit-synced stores themselves are created
  /// unconditionally (CloudKit database sync works without iCloud Drive).
  static func iCloudContainerURL() -> URL? {
    FileManager.default.url(forUbiquityContainerIdentifier: nil)
  }
}

enum NotesSyncError: LocalizedError {
  case iCloudUnavailable
  case noteNotFound

  var errorDescription: String? {
    switch self {
    case .iCloudUnavailable:
      return "iCloud is unavailable. Sign in with your Apple Account, then try again."
    case .noteNotFound:
      return "The note no longer exists."
    }
  }
}
