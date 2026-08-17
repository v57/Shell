import Crypto
import Foundation
import SwiftData
import Testing
import Terminal
@testable import Shell

struct FeatureTests {
  @Test func noteTitleAndSubtitleUsePhysicalLines() {
    #expect(NotesStore.title(for: "Title\nSubtitle\nBody") == "Title")
    #expect(NotesStore.subtitle(for: "Title\nSubtitle\nBody") == "Subtitle")
    #expect(NotesStore.title(for: "\nLater title") == "Untitled")
    #expect(NotesStore.subtitle(for: "Title\n\nLater") == nil)
    #expect(NotesStore.subtitle(for: "Title") == nil)
  }

  @Test func legacyGlobalActionMapsToCurrentAndFutureScopes() throws {
    let json = """
    {
      "id":"6D28B4C5-2F7A-4E3B-9C1D-0A5B8E6F2C41",
      "name":"Legacy",
      "appliesToAll":true,
      "appliesToLocal":false,
      "commands":"echo legacy"
    }
    """
    let action = try JSONDecoder().decode(Action.self, from: Data(json.utf8))
    let config = SSHConfig(host: "example.com", user: "me")
    #expect(action.applies(to: .local))
    #expect(action.applies(to: .ssh(config)))
    #expect(action.appliesToFutureSSHConnections)
    #expect(!action.focusWindow)
    #expect(!action.keepAfterCompletion)
  }

  @Test func futureScopePreservesCurrentExclusions() {
    let selected = SSHConfig(host: "selected.example")
    let excluded = SSHConfig(host: "excluded.example")
    let future = SSHConfig(host: "future.example")
    let action = Action(
      appliesToLocal: false,
      sshConnectionIDs: [selected.id],
      appliesToFutureSSHConnections: true,
      excludedSSHConnectionIDs: [excluded.id],
      commands: "uptime"
    )
    #expect(action.applies(to: .ssh(selected)))
    #expect(!action.applies(to: .ssh(excluded)))
    #expect(action.applies(to: .ssh(future)))
    #expect(!action.applies(to: .local))
  }

  @Test func encryptedPayloadUsesNonceAndRejectsTampering() throws {
    let key = SymmetricKey(size: .bits256)
    let plaintext = Data("a private note".utf8)
    let first = try SecureFileStore.seal(plaintext, using: key)
    let second = try SecureFileStore.seal(plaintext, using: key)
    #expect(first != second)
    #expect(!first.contains(plaintext))
    #expect(try SecureFileStore.open(first, using: key) == plaintext)

    var damaged = first
    damaged[damaged.index(before: damaged.endIndex)] ^= 0x01
    #expect(throws: SecureFileStore.StoreError.self) {
      try SecureFileStore.open(damaged, using: key)
    }
  }

  @Test func encryptedStorageKeysAreDomainSeparated() throws {
    let first = P256.KeyAgreement.PrivateKey()
    let second = P256.KeyAgreement.PrivateKey()
    let secret = try first.sharedSecretFromKeyAgreement(with: second.publicKey)
    let notesKey = SecureFileStore.deriveSymmetricKey(from: secret, domain: .notes)
    let historyKey = SecureFileStore.deriveSymmetricKey(from: secret, domain: .history)
    let ciphertext = try SecureFileStore.seal(Data("domain secret".utf8), using: notesKey)

    #expect(throws: SecureFileStore.StoreError.self) {
      try SecureFileStore.open(ciphertext, using: historyKey)
    }
  }

  @Test func historyTitleUsesLastCommandAndNormalizesLines() {
    let record = HistorySession(
      id: UUID(),
      commands: [
        SubmittedCommand(text: "pwd"),
        SubmittedCommand(text: "printf one\nprintf two"),
      ],
      output: "one\ntwo",
      archivedAt: Date()
    )
    #expect(record.title == "printf one printf two")
  }

  @Test func tmuxEmptyAndMissingSessionMessagesAreExpected() {
    #expect(ScreenSessionsMonitor.isTmuxEmptyState(
      "no server running on /private/tmp/tmux-501/default"
    ))
    #expect(ScreenSessionsMonitor.isTmuxEmptyState("no sessions"))
    #expect(ScreenSessionsMonitor.isTmuxMissingTarget("can't find session: zsh"))
    #expect(!ScreenSessionsMonitor.isTmuxEmptyState("permission denied"))
    #expect(!ScreenSessionsMonitor.isTmuxMissingTarget("permission denied"))
  }

  /// Store-level move test, fully hermetic: temp SwiftData stores + injected
  /// generated keys (no real keychain needed — runs on any machine, even
  /// with a locked screen or no iCloud session).
  @Test @MainActor func storeMovesNoteBetweenLocalAndICloud() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("notes-store-\(UUID().uuidString)", isDirectory: true)
    let (stores, cleanup) = try NoteStores.makeTest(in: root)
    defer { cleanup() }
    let store = NotesStore(stores: stores)
    let localKey = SymmetricKey(size: .bits256)
    let cloudKey = SymmetricKey(size: .bits256)
    store.deviceKeyProvider = { localKey }
    store.iCloudKeyProvider = { cloudKey }

    let note = store.addNote()
    store.updateText("to the cloud\nSecond line", for: note.id)
    store.flush()
    #expect(store.notes.first { $0.id == note.id }?.storedInICloud == false)
    #expect(store.decryptedNote(id: note.id)?.text == "to the cloud\nSecond line")
    #expect(store.decryptedNote(id: note.id)?.title == "to the cloud")

    store.setICloudStorage(true, for: note.id)
    #expect(store.notes.first { $0.id == note.id }?.storedInICloud == true)
    #expect(store.storageError == nil)
    #expect(store.decryptedNote(id: note.id)?.text == "to the cloud\nSecond line")
    #expect(store.decryptedNote(id: note.id)?.subtitle == "Second line")

    store.setICloudStorage(false, for: note.id)
    #expect(store.notes.first { $0.id == note.id }?.storedInICloud == false)
    #expect(store.storageError == nil)
    #expect(store.decryptedNote(id: note.id)?.text == "to the cloud\nSecond line")
  }

  /// Lazy decryption: decrypting one note must not decrypt the others, and
  /// repeated reads hit the cache (key provider call count = decrypts).
  /// Uses a fresh store instance over the same files so the cache is cold
  /// (updateText pre-warms the cache for live sidebar updates, so notes
  /// edited this session never re-decrypt).
  @Test @MainActor func decryptionIsLazyAndCachedPerNote() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("notes-lazy-\(UUID().uuidString)", isDirectory: true)
    let (stores, cleanup) = try NoteStores.makeTest(in: root)
    defer { cleanup() }
    let key = SymmetricKey(size: .bits256)

    let writer = NotesStore(stores: stores)
    writer.deviceKeyProvider = { key }
    writer.iCloudKeyProvider = { key }
    let a = writer.addNote()
    let b = writer.addNote()
    writer.updateText("Note A", for: a.id)
    writer.updateText("Note B", for: b.id)
    writer.flush()

    // Cold cache: a fresh store over the same containers.
    let reader = NotesStore(stores: stores)
    var decryptCalls = 0
    reader.deviceKeyProvider = { decryptCalls += 1; return key }
    reader.iCloudKeyProvider = { decryptCalls += 1; return key }

    _ = reader.decryptedNote(id: a.id)
    #expect(decryptCalls == 1)          // only note A decrypted
    _ = reader.decryptedNote(id: a.id)
    #expect(decryptCalls == 1)          // cached — no second decrypt
    _ = reader.decryptedNote(id: b.id)
    #expect(decryptCalls == 2)          // note B decrypts on demand only
  }

  /// Notes are sorted by last usage: most recently updated first. Seeded
  /// with explicit timestamps so the order is fully deterministic.
  @Test @MainActor func notesSortMostRecentlyUpdatedFirst() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("notes-sort-\(UUID().uuidString)", isDirectory: true)
    let (stores, cleanup) = try NoteStores.makeTest(in: root)
    defer { cleanup() }
    let key = SymmetricKey(size: .bits256)
    let context = stores.local.mainContext
    let oldest = NoteRecord(id: UUID(), lastUpdate: Date(timeIntervalSince1970: 100), keyId: NoteKeyID.device)
    let middle = NoteRecord(id: UUID(), lastUpdate: Date(timeIntervalSince1970: 200), keyId: NoteKeyID.device)
    let newest = NoteRecord(id: UUID(), lastUpdate: Date(timeIntervalSince1970: 300), keyId: NoteKeyID.device)
    for record in [oldest, middle, newest] { context.insert(record) }
    try context.save()

    let store = NotesStore(stores: stores)
    store.deviceKeyProvider = { key }
    store.iCloudKeyProvider = { key }
    #expect(store.notes.map(\.id) == [newest.id, middle.id, oldest.id])
  }

  /// Editing a note moves it to the top immediately (the sort key bumps on
  /// keystroke, not only when the 5s autosave lands).
  @Test @MainActor func editingNoteMovesItToTopImmediately() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("notes-edit-sort-\(UUID().uuidString)", isDirectory: true)
    let (stores, cleanup) = try NoteStores.makeTest(in: root)
    defer { cleanup() }
    let key = SymmetricKey(size: .bits256)
    let context = stores.local.mainContext
    let older = NoteRecord(id: UUID(), lastUpdate: Date(timeIntervalSince1970: 100), keyId: NoteKeyID.device)
    let newer = NoteRecord(id: UUID(), lastUpdate: Date(timeIntervalSince1970: 200), keyId: NoteKeyID.device)
    for record in [older, newer] { context.insert(record) }
    try context.save()

    let store = NotesStore(stores: stores)
    store.deviceKeyProvider = { key }
    store.iCloudKeyProvider = { key }
    #expect(store.notes.first?.id == newer.id)

    store.updateText("edited", for: older.id)
    #expect(store.notes.first?.id == older.id)

    // The persisted date catches up at flush; order stays.
    store.flush()
    #expect(store.notes.first?.id == older.id)
  }

  /// A new note lands at the top (it is the most recently used) and the
  /// order stays deterministic across reloads — no random shuffling.
  @Test @MainActor func newNoteLandsAtTopAndOrderSurvivesReload() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("notes-new-sort-\(UUID().uuidString)", isDirectory: true)
    let (stores, cleanup) = try NoteStores.makeTest(in: root)
    defer { cleanup() }
    let key = SymmetricKey(size: .bits256)

    let store = NotesStore(stores: stores)
    store.deviceKeyProvider = { key }
    store.iCloudKeyProvider = { key }
    let first = store.addNote()
    let second = store.addNote()
    #expect(store.notes.first?.id == second.id)

    // Reload from disk (fresh store, cold cache) preserves the order.
    let reloaded = NotesStore(stores: stores)
    reloaded.deviceKeyProvider = { key }
    reloaded.iCloudKeyProvider = { key }
    #expect(reloaded.notes.map(\.id) == [second.id, first.id])
  }

  /// Equal timestamps (e.g. notes created in the same instant) tie-break
  /// by id, so the order never shuffles between reloads.
  @Test @MainActor func equalTimestampsTieBreakDeterministically() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("notes-tie-\(UUID().uuidString)", isDirectory: true)
    let (stores, cleanup) = try NoteStores.makeTest(in: root)
    defer { cleanup() }
    let context = stores.local.mainContext
    let a = NoteRecord(id: UUID(), lastUpdate: Date(timeIntervalSince1970: 500), keyId: NoteKeyID.device)
    let b = NoteRecord(id: UUID(), lastUpdate: Date(timeIntervalSince1970: 500), keyId: NoteKeyID.device)
    for record in [a, b] { context.insert(record) }
    try context.save()

    let expected = [a.id, b.id].sorted { $0.uuidString < $1.uuidString }
    let store = NotesStore(stores: stores)
    #expect(store.notes.map(\.id) == expected)
    let reloaded = NotesStore(stores: stores)
    #expect(reloaded.notes.map(\.id) == expected)
  }

  /// Archiving sessions keeps the history list sorted newest-first (the
  /// sort HistoryStore relies on when a session is captured at quit).
  @Test @MainActor func historyArchiveKeepsNewestFirst() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("history-\(UUID().uuidString).shellhistory")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = HistoryStore(fileURL: url)
    let older = HistorySession(
      id: UUID(),
      commands: [SubmittedCommand(text: "older", submittedAt: Date(timeIntervalSince1970: 100))],
      output: "",
      archivedAt: Date(timeIntervalSince1970: 100)
    )
    let newer = HistorySession(
      id: UUID(),
      commands: [SubmittedCommand(text: "newer", submittedAt: Date(timeIntervalSince1970: 200))],
      output: "",
      archivedAt: Date(timeIntervalSince1970: 200)
    )
    store.archive(older)
    store.archive(newer)
    #expect(store.sessions.map(\.id) == [newer.id, older.id])
  }
}

/// Opt-in because unsigned command-line test hosts cannot reliably access the
/// data-protection Keychain or Secure Enclave. The Xcode test target is app-hosted.
@Suite(.enabled(if:
  ProcessInfo.processInfo.environment["RUN_SECURE_ENCLAVE_TESTS"] == "1"
    && SecureEnclave.isAvailable
))
struct SecureEnclaveEncryptedFileSmokeTests {
  @Test func deviceBoundFileRoundTripContainsNoPlaintext() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("shell-secure-file-smoke-\(UUID().uuidString)", isDirectory: true)
    let file = directory.appendingPathComponent("smoke.note")
    let plaintext = Data("secure enclave smoke test".utf8)
    defer { try? FileManager.default.removeItem(at: directory) }

    try SecureFileStore.write(plaintext, to: file, domain: .notes)
    let persisted = try Data(contentsOf: file)
    #expect(!persisted.contains(plaintext))
    #expect(try SecureFileStore.read(from: file, domain: .notes) == plaintext)
    #expect(throws: SecureFileStore.StoreError.self) {
      try SecureFileStore.read(from: file, domain: .history)
    }
  }
}
