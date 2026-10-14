import CryptoKit
import Foundation
import Security
import VaultKit

/// Generates and stores the app's SSH identities in the Secure Enclave.
///
/// Private keys are P-256 ECDSA keys generated INSIDE the Secure Enclave
/// (kSecAttrTokenIDSecureEnclave); the private scalar never exists outside
/// the chip, not even in RAM. Only the opaque, device-bound
/// `dataRepresentation` blob touches the Keychain (as a generic password),
/// and only the public key can be exported.
///
/// Note on per-sign gating: Touch ID gating (userPresence ACL) is NOT
/// used. The libssh2 external signer path drives the Secure Enclave P-256
/// key (spike-verified end-to-end), so the app uses a single Secure Enclave
/// identity key without a per-sign UI prompt.
///
/// Marked `nonisolated`: all operations are stateless Security-framework
/// calls safe to run off the main actor (e.g. from SSH auth callbacks).
public nonisolated enum SSHKeychain {
  public static let service = "dev.v57.sh"
  /// The app's SSH identity (Secure Enclave P-256).
  public static let defaultKeyAccount = "ssh-sep-key"
  
  public enum KeychainError: LocalizedError {
    case keychainAddFailed(OSStatus)
    case keychainReadFailed(OSStatus)
    case invalidKeyData
    
    public var errorDescription: String? {
      switch self {
      case .keychainAddFailed(let status):
        return "Failed to save to Keychain (OSStatus \(status))."
      case .keychainReadFailed(let status):
        return "Failed to read from Keychain (OSStatus \(status))."
      case .invalidKeyData:
        return "The Keychain contains invalid key data."
      }
    }
  }
  
  // MARK: - Identity keys (Secure Enclave)
  
  /// Returns this device's Secure Enclave key, the one every v57 app shares (`VaultIdentity`): Database
  /// logs in with it too. A key Shell made before the vault is handed over to it, so servers
  /// that already trust it keep working.
  public static func loadOrCreateDefaultKey() throws -> SecureEnclave.P256.Signing.PrivateKey {
    if !VaultIdentity.exists, let legacy = try? load(account: defaultKeyAccount) {
      try? VaultIdentity.adopt(legacy)
    }
    return try VaultIdentity.key()
  }
  
  private static func loadOrCreateKey(
    account: String,
    label: String
  ) throws -> SecureEnclave.P256.Signing.PrivateKey {
    if let blob = try load(account: account) {
      guard let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob) else {
        throw KeychainError.invalidKeyData
      }
      return key
    }
    // Key material is generated inside the Secure Enclave; only the
    // opaque wrapped blob (useless on any other machine) is persisted.
    let key = try SecureEnclave.P256.Signing.PrivateKey()
    try save(key.dataRepresentation, account: account, label: label)
    return key
  }
  
  // MARK: - Public keys (ecdsa-sha2-nistp256)
  
  /// The OpenSSH authorized_keys line for a Secure Enclave key, e.g.
  /// "ecdsa-sha2-nistp256 AAAA… Shell (user@host)".
  public static func publicKeyOpenSSHLine(
    for key: SecureEnclave.P256.Signing.PrivateKey,
    comment: String
  ) -> String {
    let blob = ecdsaBlob(for: key)
    return "ecdsa-sha2-nistp256 \(blob.base64EncodedString()) \(comment)"
  }
  
  /// SHA256 fingerprint of a Secure Enclave key's public key (OpenSSH format).
  public static func publicKeyFingerprint(for key: SecureEnclave.P256.Signing.PrivateKey) -> String {
    fingerprint(blob: ecdsaBlob(for: key))
  }

  /// SHA256 fingerprint of any OpenSSH public key line ("type base64 [comment]"),
  /// nil when the second field is not base64.
  public static func publicKeyFingerprint(forKeyLine line: String) -> String? {
    let fields = line.split(whereSeparator: \.isWhitespace)
    guard fields.count >= 2, let blob = Data(base64Encoded: String(fields[1])), !blob.isEmpty else { return nil }
    return fingerprint(blob: blob)
  }

  // MARK: - Per-connection passwords

  // SSH hosts' and databases' passwords (`ssh-password-<id>`, `db-password-<id>`) live in the shared
  // keychain group, named after the shared record (`VaultSecrets`), so Database use them
  // and iCloud Keychain brings them to the user's other devices. Ones saved before move there when read.

  public static func savePassword(_ password: String, account: String) throws {
    if let id = sharedID(account) {
      try VaultSecrets.setPassword(password, for: id)
      delete(account: account)
      return
    }
    try save(Data(password.utf8), account: account, label: "Shell SSH password")
  }

  public static func loadPassword(account: String) throws -> String? {
    if let id = sharedID(account) {
      if let shared = VaultSecrets.password(for: id) { return shared }
      guard let data = try load(account: account), let legacy = String(data: data, encoding: .utf8) else {
        return nil
      }
      if (try? VaultSecrets.setPassword(legacy, for: id)) != nil { delete(account: account) }
      return legacy
    }
    guard let data = try load(account: account) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  public static func deletePassword(account: String) {
    if let id = sharedID(account) { try? VaultSecrets.setPassword(nil, for: id) }
    delete(account: account)
  }

  /// The shared record a password account belongs to.
  private static func sharedID(_ account: String) -> String? {
    for prefix in ["ssh-password-", "db-password-"] where account.hasPrefix(prefix) {
      return String(account.dropFirst(prefix.count))
    }
    return nil
  }
  
  // MARK: - Internals
  
  /// SSH wire blob for an ECDSA P-256 public key (RFC 5656):
  /// string("ecdsa-sha2-nistp256") + string("nistp256") + string(Q),
  /// where Q is the X9.63 uncompressed point (0x04 || X || Y).
  public static func publicKeyBlob(for key: SecureEnclave.P256.Signing.PrivateKey) -> Data {
    ecdsaBlob(for: key)
  }

  private static func ecdsaBlob(for key: SecureEnclave.P256.Signing.PrivateKey) -> Data {
    // CryptoKit's rawRepresentation is the raw X||Y (64 bytes); the SSH
    // wire format needs the X9.63 uncompressed point (65 bytes).
    let point = Data([0x04]) + key.publicKey.rawRepresentation
    var out = Data()
    out.append(sshString(Data("ecdsa-sha2-nistp256".utf8)))
    out.append(sshString(Data("nistp256".utf8)))
    out.append(sshString(point))
    return out
  }
  
  private static func fingerprint(blob: Data) -> String {
    let digest = SHA256.hash(data: blob)
    let encoded = Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
    return "SHA256:\(encoded)"
  }
  
  /// Encodes a length-prefixed SSH string: UInt32 big-endian length + bytes.
  private static func sshString(_ data: Data) -> Data {
    var out = Data()
    var length = UInt32(data.count).bigEndian
    out.append(Data(bytes: &length, count: 4))
    out.append(data)
    return out
  }
  
  /// Encodes an SSH wire blob: string(keyType) + string(keyData).
  public static func sshBlob(keyType: String, keyData: Data) -> Data {
    var out = Data()
    out.append(sshString(Data(keyType.utf8)))
    out.append(sshString(keyData))
    return out
  }
  
  private static func save(_ data: Data, account: String, label: String) throws {
    delete(account: account)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrLabel as String: label,
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw KeychainError.keychainAddFailed(status)
    }
  }
  
  private static func load(account: String) throws -> Data? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess else {
      throw KeychainError.keychainReadFailed(status)
    }
    return result as? Data
  }
  
  private static func delete(account: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(query as CFDictionary)
  }
}
