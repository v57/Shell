import Crypto
import Foundation

/// Identifies which key decrypts a note. Stored on every `NoteRecord`
/// (`keyId`) so the same schema supports both storage homes:
/// - `.device` — the Secure-Enclave ECDH-derived key (`SecureFileStore`),
///   bound to this device only.
/// - `.icloud` — the iCloud Keychain item (`ICloudNotesKey`), available on
///   every device signed into the same Apple Account.
enum NoteKeyID {
  static let device = "device"
  static let icloud = "icloud"

  static func key(for keyId: String?) throws -> SymmetricKey {
    switch keyId {
    case device:
      return try SecureFileStore.symmetricKey(for: .notes)
    case icloud:
      return try ICloudNotesKey.loadOrCreate()
    default:
      throw NoteCryptoError.unknownKeyID(keyId)
    }
  }
}

enum NoteCryptoError: LocalizedError {
  case unknownKeyID(String?)
  case invalidCiphertext

  var errorDescription: String? {
    switch self {
    case .unknownKeyID(let keyId):
      return "The note's key identifier is unknown (\(keyId ?? "nil"))."
    case .invalidCiphertext:
      return "The note is damaged or was created with another key."
    }
  }
}

/// App-level encryption for note records: title, subtitle, and content are
/// three separate AES-GCM ciphertexts (combined format, random nonce each),
/// so the sidebar can decrypt just the small title blob per visible row and
/// the editor decrypts content only when opened. CloudKit never sees
/// plaintext note data.
enum NoteCrypto {
  /// The decrypted contents of a note.
  struct Plaintext: Equatable {
    var title: String
    var subtitle: String?
    var text: String
  }

  /// Encrypts a note's text into the three record fields. Title/subtitle
  /// are derived from the text (first/second non-empty physical line) at
  /// save time, exactly like the old file store rendered them.
  static func encrypt(
    text: String,
    using key: SymmetricKey
  ) throws -> (titleCipher: Data, subtitleCipher: Data?, contentCipher: Data) {
    let title = NotesStore.title(for: text)
    let subtitle = NotesStore.subtitle(for: text)
    let contentCipher = try SecureFileStore.seal(Data(text.utf8), using: key)
    let titleCipher = try SecureFileStore.seal(Data(title.utf8), using: key)
    let subtitleCipher = try subtitle.map {
      try SecureFileStore.seal(Data($0.utf8), using: key)
    }
    return (titleCipher, subtitleCipher, contentCipher)
  }

  /// Decrypts a record. Falls back to deriving title/subtitle from the
  /// content when their blobs are missing or unreadable (older records).
  static func decrypt(record: NoteRecord, using key: SymmetricKey) throws -> Plaintext? {
    guard let contentCipher = record.contentCipher else { return nil }
    guard let text = String(data: try SecureFileStore.open(contentCipher, using: key), encoding: .utf8) else {
      throw NoteCryptoError.invalidCiphertext
    }
    let title: String
    if let titleCipher = record.titleCipher,
       let t = try? String(data: SecureFileStore.open(titleCipher, using: key), encoding: .utf8),
       !t.isEmpty {
      title = t
    } else {
      title = NotesStore.title(for: text)
    }
    let subtitle: String?
    if let subtitleCipher = record.subtitleCipher,
       let s = try? String(data: SecureFileStore.open(subtitleCipher, using: key), encoding: .utf8),
       !s.isEmpty {
      subtitle = s
    } else {
      subtitle = NotesStore.subtitle(for: text)
    }
    return Plaintext(title: title, subtitle: subtitle, text: text)
  }
}
