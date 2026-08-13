import Foundation
import SwiftData

/// The CloudKit-synced note record. Everything about the note's text is
/// stored as separate AES-GCM ciphertexts — title, subtitle, and content —
/// so CloudKit only ever sees opaque blobs plus the sort key. Decryption
/// happens lazily in the views (sidebar rows decrypt title/subtitle when
/// they render; the editor decrypts content when opened), never eagerly at
/// load.
///
/// CloudKit compatibility rules (additive-only schema after production
/// promotion):
/// - NO `@Attribute(.unique)` on any property (banned with CloudKit).
/// - Every attribute must be optional or have a default value.
@Model
final class NoteRecord {
  var id: UUID = UUID()
  /// Plaintext sort key — the only timestamp metadata CloudKit sees.
  /// Renamed semantics: `contentModificationDate`-equivalent, bumped on
  /// every save.
  var lastUpdate: Date = Date.distantPast
  /// Which key decrypts this note: `NoteKeyID.device` (Secure Enclave,
  /// this device only) or `NoteKeyID.icloud` (iCloud Keychain item).
  var keyId: String?
  /// AES-GCM(first non-empty line), combined format (nonce included).
  var titleCipher: Data?
  /// AES-GCM(second non-empty line), nil when the note has one line.
  var subtitleCipher: Data?
  /// AES-GCM(full text).
  var contentCipher: Data?

  init(
    id: UUID = UUID(),
    lastUpdate: Date = .distantPast,
    keyId: String? = nil,
    titleCipher: Data? = nil,
    subtitleCipher: Data? = nil,
    contentCipher: Data? = nil
  ) {
    self.id = id
    self.lastUpdate = lastUpdate
    self.keyId = keyId
    self.titleCipher = titleCipher
    self.subtitleCipher = subtitleCipher
    self.contentCipher = contentCipher
  }
}
