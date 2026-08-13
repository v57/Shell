import Crypto
import Foundation
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

  @Test func noteMoveReencryptsAndMovesFile() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(
      "notes-move-\(UUID().uuidString)", isDirectory: true
    )
    let local = root.appendingPathComponent("local", isDirectory: true)
    let cloud = root.appendingPathComponent("cloud", isDirectory: true)
    defer { try? fm.removeItem(at: root) }
    try fm.createDirectory(at: local, withIntermediateDirectories: true)
    try fm.createDirectory(at: cloud, withIntermediateDirectories: true)

    // A note encrypted with the "local" key.
    let localKey = SymmetricKey(size: .bits256)
    let cloudKey = SymmetricKey(size: .bits256)
    let id = UUID()
    let localFile = local.appendingPathComponent("\(id.uuidString).note")
    let cloudFile = cloud.appendingPathComponent("\(id.uuidString).note")
    try SecureFileStore.seal(Data("migrating note".utf8), using: localKey)
      .write(to: localFile)

    try NotesStore.moveNote(
      id: id,
      from: localFile,
      decryptingWith: localKey,
      to: cloudFile,
      encryptingWith: cloudKey,
      write: { data, url in try data.write(to: url) }
    )

    // Source removed; destination opens with the NEW key only.
    #expect(!fm.fileExists(atPath: localFile.path))
    #expect(fm.fileExists(atPath: cloudFile.path))
    let plaintext = try SecureFileStore.open(Data(contentsOf: cloudFile), using: cloudKey)
    #expect(String(data: plaintext, encoding: .utf8) == "migrating note")
    #expect(throws: SecureFileStore.StoreError.self) {
      _ = try SecureFileStore.open(Data(contentsOf: cloudFile), using: localKey)
    }
  }

  /// Store-level move test. Gated on device-keychain availability: the
  /// file-based store hardwires the real keys, and Secure Enclave items are
  /// `WhenUnlocked`-protected (locked screen → errSecInteractionNotAllowed).
  /// The SwiftData store rewrite replaces this with injected hermetic keys.
  @Test @MainActor func storeMovesNoteBetweenLocalAndICloud() throws {
    guard SecureFileStore.isAvailable else { return }
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(
      "notes-store-\(UUID().uuidString)", isDirectory: true
    )
    defer { try? fm.removeItem(at: root) }
    let local = root.appendingPathComponent("local", isDirectory: true)
    let cloud = root.appendingPathComponent("cloud", isDirectory: true)
    let store = NotesStore(directoryURL: local, iCloudDirectoryURL: cloud)

    let note = store.addNote()
    store.updateText("to the cloud", for: note.id)
    store.flush()
    #expect(store.notes.first { $0.id == note.id }?.storedInICloud == false)

    store.setICloudStorage(true, for: note.id)
    #expect(store.notes.first { $0.id == note.id }?.storedInICloud == true)
    #expect(store.storageError == nil)
    #expect(fm.fileExists(atPath: cloud.appendingPathComponent("\(note.id.uuidString).note").path))
    #expect(!fm.fileExists(atPath: local.appendingPathComponent("\(note.id.uuidString).note").path))

    store.setICloudStorage(false, for: note.id)
    #expect(store.notes.first { $0.id == note.id }?.storedInICloud == false)
    #expect(store.storageError == nil)
    #expect(fm.fileExists(atPath: local.appendingPathComponent("\(note.id.uuidString).note").path))
    #expect(!fm.fileExists(atPath: cloud.appendingPathComponent("\(note.id.uuidString).note").path))
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
