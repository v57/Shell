import Foundation
import Testing
import ShellKit

/// Keychain-backed tests. These run in the app-hosted test bundle
/// (TEST_HOST = Shell.app), so they execute inside the app's signed
/// process and have the same Secure Enclave / Keychain access as the app —
/// a bare `swift test` binary would be treated as an unknown CLI and
/// prompt (or be denied) instead.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["RUN_SECURE_ENCLAVE_TESTS"] == "1"))
struct SSHKeychainTests {
  @Test func defaultKeyLoadsAndProducesOpenSSHLine() throws {
    let key = try SSHKeychain.loadOrCreateDefaultKey()
    let line = SSHKeychain.publicKeyOpenSSHLine(for: key, comment: "test")
    let parts = line.split(separator: " ")
    #expect(parts.count == 3)
    #expect(parts[0] == "ecdsa-sha2-nistp256")
    // The key blob must be valid base64 (the raw point 0x04||X||Y).
    #expect(Data(base64Encoded: String(parts[1])) != nil)
    #expect(String(parts[2]) == "test")
  }

  @Test func defaultKeyFingerprintIsOpenSSHFormat() throws {
    let key = try SSHKeychain.loadOrCreateDefaultKey()
    let fingerprint = SSHKeychain.publicKeyFingerprint(for: key)
    #expect(fingerprint.hasPrefix("SHA256:"))
    let encoded = String(fingerprint.dropFirst("SHA256:".count))
    // Base64 without padding, like ssh-keygen.
    #expect(Data(base64Encoded: encoded + "=") != nil)
  }
}
