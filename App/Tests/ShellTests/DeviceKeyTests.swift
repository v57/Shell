import CryptoKit
import Foundation
import Testing
import ShellKit
import VaultKit
@testable import ShellApp

/// The key registry, on a throwaway vault (publishing this device's key needs the Secure Enclave and the
/// shared keychain, so it's covered by running the app).
struct DeviceKeyStoreTests {
  /// A real `authorized_keys` line for a software P-256 key.
  private let keyLine: String = {
    let point = P256.Signing.PrivateKey().publicKey.x963Representation
    let blob = SSHWire.string("ecdsa-sha2-nistp256") + SSHWire.string("nistp256") + SSHWire.string(point)
    return "ecdsa-sha2-nistp256 \(blob.base64EncodedString()) YubiKey"
  }()

  @Test @MainActor func addsAndForgetsCustomKeys() throws {
    let store = DeviceKeyStore(vault: TestVault.make())
    let record = try store.addCustomKey(line: keyLine, name: "Hardware key")
    #expect(record.deviceName == "Hardware key")
    #expect(!record.isDeviceKey)
    #expect(store.all.map(\.fingerprint) == [record.fingerprint])
    // Adding it again updates the same entry.
    _ = try store.addCustomKey(line: keyLine, name: "Renamed")
    #expect(store.all.count == 1)
    #expect(store.all.first?.deviceName == "Renamed")
    try store.forget(fingerprint: try #require(record.fingerprint))
    #expect(store.all.isEmpty)
  }

  @Test @MainActor func rejectsNonKeyLines() {
    let store = DeviceKeyStore(vault: TestVault.make())
    #expect(throws: (any Error).self) { try store.addCustomKey(line: "not a key", name: nil) }
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

  @Test func onlyPlainKeyLinesAreAppended() {
    #expect(AuthorizedKeysManager.isPlainKeyLine("ecdsa-sha2-nistp256 AAAA123 Shell (v57@Mac)"))
    // A synced line must not smuggle in a second key or options.
    #expect(!AuthorizedKeysManager.isPlainKeyLine("ecdsa-sha2-nistp256 AAAA123 x\nssh-ed25519 AAAA999 y"))
    #expect(!AuthorizedKeysManager.isPlainKeyLine("command=\"sh\" ecdsa-sha2-nistp256 AAAA123"))
    #expect(!AuthorizedKeysManager.isPlainKeyLine("ecdsa-sha2-nistp256 AAAA123 x\r"))
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
