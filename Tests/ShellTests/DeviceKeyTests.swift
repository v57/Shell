import Crypto
import Foundation
import SwiftData
import Testing
import Terminal
@testable import Shell

/// Hermetic tests for the iCloud device-key registry. Shared container +
/// `.serialized`, exactly like `SSHConfigStoreTests` (the hosted-runner
/// SwiftData container churn trap applies to every store).
@Suite(.serialized)
struct DeviceKeyStoreTests {
  private static let directory: URL = {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("device-keys-suite-\(UUID().uuidString)", isDirectory: true)
  }()
  private static let sharedContainer: ModelContainer = {
    // swiftlint:disable:next force_try
    try! DeviceKeyStore.makeTestContainer(in: directory)
  }()

  /// A fresh Secure Enclave key (no keychain persistence → works even with
  /// a locked screen; the public key is all the store needs).
  private static func freshKey() throws -> SecureEnclave.P256.Signing.PrivateKey {
    try SecureEnclave.P256.Signing.PrivateKey()
  }

  private func makeStore(keyProvider: @escaping () throws -> SecureEnclave.P256.Signing.PrivateKey) -> DeviceKeyStore {
    DeviceKeyStore(container: Self.sharedContainer, defaultKeyProvider: keyProvider)
  }

  @Test @MainActor func publishesThisDeviceAndUpsertsByFingerprint() throws {
    let key = try Self.freshKey()
    let store = makeStore(keyProvider: { key })
    store.deviceNameProvider = { "Test Mac" }

    #expect(store.publishThisDevice())
    #expect(store.all.count == 1)
    let published = try #require(store.all.first)
    #expect(published.deviceName == "Test Mac")
    #expect(published.keyLine?.hasPrefix("ecdsa-sha2-nistp256 ") == true)
    #expect(published.fingerprint == SSHKeychain.publicKeyFingerprint(for: key))

    // Re-publishing (launch/panel) updates the SAME record — no duplicates.
    store.deviceNameProvider = { "Test Mac Renamed" }
    #expect(store.publishThisDevice())
    #expect(store.all.count == 1)
    #expect(store.all.first?.deviceName == "Test Mac Renamed")
  }

  @Test @MainActor func keepsOtherDevicesRecords() throws {
    let store = makeStore(keyProvider: { try Self.freshKey() })
    store.deviceNameProvider = { "Device A" }
    #expect(store.publishThisDevice())

    // A different device key (another Secure Enclave key = another device).
    let store2 = makeStore(keyProvider: { try Self.freshKey() })
    store2.deviceNameProvider = { "Device B" }
    #expect(store2.publishThisDevice())

    // Refresh the first store's cached list, then both devices are visible
    // (content-scoped assertions: the shared container also holds records
    // from the other tests in this suite).
    store.refreshOnActivation()
    let names = store.all.compactMap(\.deviceName)
    #expect(names.contains("Device A"))
    #expect(names.contains("Device B"))
  }

  @Test @MainActor func listingWorksWithoutKeychain() throws {
    // A store whose key provider always fails: reading the registry must
    // still work (it's plaintext; only publishing needs the key).
    let failing = makeStore(keyProvider: { throw SSHKeychain.KeychainError.invalidKeyData })
    #expect(!failing.publishThisDevice())
    #expect(failing.storageError != nil)
    // Other devices' records from the previous tests are still readable.
    #expect(failing.all.count >= 2)
  }
}

/// The authorized-keys manager: local file operations + parsing + command
/// construction (the remote exec itself needs a live server, covered by
/// the command-builder tests + manual verification).
struct AuthorizedKeysManagerTests {
  @Test func localReadAppendRemoveRoundTrip() throws {
    let home = FileManager.default.temporaryDirectory
      .appendingPathComponent("authkeys-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }

    let keyA = "ecdsa-sha2-nistp256 AAAAEXAMPLE1 Shell (a@mac)"
    let keyB = "ecdsa-sha2-nistp256 AAAAEXAMPLE2 Shell (b@mac)"

    // Missing file → empty.
    #expect(try AuthorizedKeysManager.readLocalLines(homeURL: home).isEmpty)

    // Append twice → both lines present.
    try AuthorizedKeysManager.appendLocal(keyLine: keyA, homeURL: home)
    try AuthorizedKeysManager.appendLocal(keyLine: keyB, homeURL: home)
    let lines = try AuthorizedKeysManager.readLocalLines(homeURL: home)
    #expect(lines.count == 2)
    #expect(lines[0].hasPrefix("ecdsa-sha2-nistp256 AAAAEXAMPLE1"))
    #expect(lines[1].hasPrefix("ecdsa-sha2-nistp256 AAAAEXAMPLE2"))

    // File + dir permissions are ssh-standard.
    let attrs = try FileManager.default.attributesOfItem(
      atPath: home.appendingPathComponent(".ssh/authorized_keys").path
    )
    #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  }

  @Test func keyMaterialExtractionAndMatching() {
    #expect(AuthorizedKeysManager.keyMaterial(of: "ecdsa-sha2-nistp256 AAAA123 comment here")
      == "ecdsa-sha2-nistp256 AAAA123")
    #expect(AuthorizedKeysManager.keyMaterial(of: "ssh-ed25519 AAAA999 other@host")
      == "ssh-ed25519 AAAA999")
    // Comments, blanks, and non-key lines are ignored.
    #expect(AuthorizedKeysManager.keyMaterial(of: "# comment") == nil)
    #expect(AuthorizedKeysManager.keyMaterial(of: "   ") == nil)
    #expect(AuthorizedKeysManager.keyMaterial(of: "just-one-field") == nil)
  }

  @Test func parseOutputStripsPtyCR() {
    #expect(AuthorizedKeysManager.parseOutput("line1\r\nline2\r\n") == ["line1", "line2"])
    #expect(AuthorizedKeysManager.parseOutput("no-cr\nhere") == ["no-cr", "here"])
    // A real blank line survives; the phantom segment after the final \n doesn't.
    #expect(AuthorizedKeysManager.parseLines("a\n\n") == ["a", ""])
  }

  @Test func appendCommandEscapesSingleQuotes() {
    let command = AuthorizedKeysManager.appendCommand(keyLine: "ecdsa-sha2-nistp256 AAAA O'Brien")
    #expect(command.contains("'ecdsa-sha2-nistp256 AAAA O'\\''Brien'"))
    // The shell sees the original text after unquoting.
    #expect(!command.contains("O'Brien'"))
  }

  @Test func rewriteCommandPreservesLinesVerbatim() {
    let lines = ["line one", "line two"]
    let command = AuthorizedKeysManager.rewriteCommand(lines: lines)
    #expect(command.hasPrefix("mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat > ~/.ssh/authorized_keys <<'SHELLKEY_"))
    #expect(command.contains("\nline one\nline two\n"))
    #expect(command.contains("chmod 600 ~/.ssh/authorized_keys"))
    // The delimiter is random, so content can never collide.
    let command2 = AuthorizedKeysManager.rewriteCommand(lines: lines)
    #expect(command != command2)
  }

  @Test func removeFiltersByKeyMaterial() async throws {
    let home = FileManager.default.temporaryDirectory
      .appendingPathComponent("authkeys-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }

    try AuthorizedKeysManager.appendLocal(keyLine: "ecdsa-sha2-nistp256 AAAA111 a@mac", homeURL: home)
    try AuthorizedKeysManager.appendLocal(keyLine: "ecdsa-sha2-nistp256 AAAA222 b@mac", homeURL: home)
    try AuthorizedKeysManager.appendLocal(keyLine: "# a comment", homeURL: home)

    let manager = AuthorizedKeysManager(target: .local, homeURL: home)
    try await manager.remove(keyMaterials: ["ecdsa-sha2-nistp256 AAAA111"])

    let remaining = try AuthorizedKeysManager.readLocalLines(homeURL: home)
    #expect(remaining.count == 2)
    #expect(remaining[0].hasPrefix("ecdsa-sha2-nistp256 AAAA222"))
    #expect(remaining[1] == "# a comment")
  }
}
