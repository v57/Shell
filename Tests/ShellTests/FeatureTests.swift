import CryptoKit
import Foundation
import SwiftData
import Testing
import ShellKit
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

  /// ⌘E insert: "Send as separate commands" (default) translates newlines to
  /// carriage returns so each line runs as its own Enter; when disabled, the
  /// newlines pass through verbatim.
  @Test @MainActor func insertCommandTextTranslatesNewlinesPerToggle() {
    let transport = CommandInsertProbeTransport()
    let session = TerminalSession(transport: transport)
    let model = AppModel.shared

    // Default (separate commands): each line becomes an Enter.
    model.insertCommandText("echo one\necho two", into: session)
    #expect(transport.writes.last == Data("echo one\recho two".utf8))

    // Disabled: newlines stay literal.
    model.insertCommandText("echo one\necho two", into: session, sendAsSeparateCommands: false)
    #expect(transport.writes.last == Data("echo one\necho two".utf8))
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

  /// The registry must cover every toggleable feature, including the reserved
  /// `web` and `database` lanes, and never silently drop one.
  @Test func featureIDRegistryCoversEveryToggleableFeature() {
    #expect(FeatureID.allCases.map(\.rawValue) == [
      "animations", "sessions", "screen", "ssh", "notes", "history", "actions",
      "smartActions", "monitoring", "files", "authorizedKeys",
      "web", "database"
    ])
    #expect(FeatureID.allCases.count == 13)
    // Reserved lanes exist and round-trip through their rawValue.
    #expect(FeatureID.web.rawValue == "web")
    #expect(FeatureID.database.rawValue == "database")
    #expect(FeatureID.allCases.map(\.id) == FeatureID.allCases.map(\.rawValue))
  }

  /// Defaults are ON; disabling writes only a flag; a reload of the same
  /// defaults preserves the opt-out; re-enabling restores the prior state
  /// without any feature data being touched.
  @Test @MainActor func featureFlagsDefaultOnAndOptOutsPersist() throws {
    let suite = "ShellFeatureFlagsTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let store = FeatureFlagsStore(defaults: defaults)

    // Everything starts enabled.
    for feature in FeatureID.allCases {
      #expect(store.isEnabled(feature))
    }

    // Disabling flips only that flag; siblings stay on.
    store.setEnabled(false, for: .notes)
    #expect(!store.isEnabled(.notes))
    #expect(store.isEnabled(.sessions))
    #expect(store.isEnabled(.web))

    // A fresh store over the same defaults sees the persisted opt-out.
    let reloaded = FeatureFlagsStore(defaults: defaults)
    #expect(!reloaded.isEnabled(.notes))
    #expect(reloaded.isEnabled(.sessions))

    // Re-enabling restores the exact prior state (data was never deleted).
    store.setEnabled(true, for: .notes)
    #expect(store.isEnabled(.notes))
    let reloadedAgain = FeatureFlagsStore(defaults: defaults)
    #expect(reloadedAgain.isEnabled(.notes))
  }

  /// First-launch detection is driven purely by whether the disabled-set key
  /// has ever been written: absent = welcome due; present = configured. A
  /// first toggle commits it, and an explicit `markConfigured()` (welcome
  /// dismissed without changing anything) commits it too — and neither touches
  /// any feature's own persisted data.
  @Test @MainActor func featureFlagsFirstLaunchDetection() throws {
    // Fresh install: key absent -> the welcome sheet is due.
    let suite = "ShellFeatureFlagsFirstLaunch-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = FeatureFlagsStore(defaults: defaults)
    #expect(store.needsFirstLaunchSelection)
    #expect(store.disabledRaw.isEmpty)

    // Every toggleable feature has a label and a description for its row.
    for feature in FeatureID.allCases {
      #expect(!feature.label.isEmpty, "label for \(feature.rawValue)")
      #expect(!feature.description.isEmpty, "description for \(feature.rawValue)")
    }

    // A first toggle commits the disabled-set key -> the welcome is no longer due.
    store.setEnabled(false, for: .sessions)
    #expect(!store.needsFirstLaunchSelection)
    #expect(!store.isEnabled(.sessions))

    // markConfigured() on a separate suite writes the key even when the
    // selection is left empty (welcome dismissed unchanged) — no data touched.
    let suite2 = "ShellFeatureFlagsWelcomeDismiss-\(UUID().uuidString)"
    let defaults2 = try #require(UserDefaults(suiteName: suite2))
    defer { defaults2.removePersistentDomain(forName: suite2) }
    let fresh = FeatureFlagsStore(defaults: defaults2)
    #expect(fresh.needsFirstLaunchSelection)
    fresh.markConfigured()
    #expect(!fresh.needsFirstLaunchSelection)
    #expect(fresh.disabledRaw.isEmpty)   // no feature data touched
    #expect(fresh.isEnabled(.web))       // all features still default on
  }

  /// The Screen feature's background refresh is gated: with the 5s auto-poll
  /// removed (2026-09-10) `start()` performs a one-shot refresh only — there
  /// is no poller to arm — and a disabled feature starts nothing, so its
  /// published state stays empty. Uses an injected hermetic store so the
  /// shared `AppModel`/store are untouched.
  @Test @MainActor func screenMonitorRefreshGatedByFeatureFlag() throws {
    let suite = "ShellScreenGateTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let features = FeatureFlagsStore(defaults: defaults)

    // Feature ON: start() runs the one-shot refresh; stop() clears state.
    features.setEnabled(true, for: .screen)
    let monitor = ScreenSessionsMonitor(features: features)
    monitor.start()
    monitor.stop()

    // Feature OFF: start() is a no-op — no refresh, empty published state.
    features.setEnabled(false, for: .screen)
    let off = ScreenSessionsMonitor(features: features)
    off.start()
    #expect(off.sessions.isEmpty)
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

/// Minimal transport stub: captures what the session writes to the child so
/// tests can assert on the exact bytes `insertCommandText` produces.
@MainActor
private final class CommandInsertProbeTransport: TerminalTransport {
  var onOutput: ((Data) -> Void)?
  var onConnected: (() -> Void)?
  var onTerminated: ((String) -> Void)?
  var onExit: ((Int32) -> Void)?
  var writes: [Data] = []
  func start() { onConnected?() }
  func write(_ data: Data) { writes.append(data) }
  func resize(columns: Int, rows: Int) {}
  func close() {}
}
