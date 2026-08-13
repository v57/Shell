import Crypto
import Foundation
import Testing
@testable import Shell

struct NoteCryptoTests {
  @Test func encryptDecryptRoundTripDerivesTitleAndSubtitle() throws {
    let key = SymmetricKey(size: .bits256)
    let text = "Shopping list\nGroceries\nMilk, eggs, bread"
    let (titleCipher, subtitleCipher, contentCipher) = try NoteCrypto.encrypt(text: text, using: key)

    let record = NoteRecord(
      keyId: NoteKeyID.device,
      titleCipher: titleCipher,
      subtitleCipher: subtitleCipher,
      contentCipher: contentCipher
    )
    let plaintext = try NoteCrypto.decrypt(record: record, using: key)
    #expect(plaintext?.title == "Shopping list")
    #expect(plaintext?.subtitle == "Groceries")
    #expect(plaintext?.text == text)

    // No plaintext leaks into any ciphertext field.
    for blob in [titleCipher, contentCipher] {
      #expect(!blob.contains(Data("Shopping".utf8)))
      #expect(!blob.contains(Data("list".utf8)))
    }
    #expect(!(subtitleCipher ?? Data()).contains(Data("Groceries".utf8)))
  }

  @Test func singleLineNoteHasNoSubtitleBlob() throws {
    let key = SymmetricKey(size: .bits256)
    let (titleCipher, subtitleCipher, contentCipher) = try NoteCrypto.encrypt(text: "Only line", using: key)
    #expect(subtitleCipher == nil)

    let record = NoteRecord(
      keyId: NoteKeyID.device,
      titleCipher: titleCipher,
      subtitleCipher: subtitleCipher,
      contentCipher: contentCipher
    )
    let plaintext = try NoteCrypto.decrypt(record: record, using: key)
    #expect(plaintext?.title == "Only line")
    #expect(plaintext?.subtitle == nil)
  }

  @Test func wrongKeyFailsToDecrypt() throws {
    let key = SymmetricKey(size: .bits256)
    let other = SymmetricKey(size: .bits256)
    let (titleCipher, subtitleCipher, contentCipher) = try NoteCrypto.encrypt(text: "secret", using: key)
    let record = NoteRecord(
      keyId: NoteKeyID.device,
      titleCipher: titleCipher,
      subtitleCipher: subtitleCipher,
      contentCipher: contentCipher
    )
    #expect(throws: (any Error).self) {
      _ = try NoteCrypto.decrypt(record: record, using: other)
    }
  }

  @Test func missingContentIsNotANote() throws {
    let key = SymmetricKey(size: .bits256)
    let record = NoteRecord(keyId: NoteKeyID.device)
    #expect(try NoteCrypto.decrypt(record: record, using: key) == nil)
  }

  /// Hosted test (real keychain): both key ids resolve to working keys and
  /// an unknown id is rejected. Skips when the device keychain is
  /// inaccessible — Secure Enclave items are `WhenUnlocked`-protected, so a
  /// locked screen makes every read fail with errSecInteractionNotAllowed.
  @Test @MainActor func keyMappingResolvesBothKeyIDs() throws {
    guard SecureFileStore.isAvailable else { return }
    let deviceKey = try NoteKeyID.key(for: NoteKeyID.device)
    let iCloudKey = try NoteKeyID.key(for: NoteKeyID.icloud)
    for key in [deviceKey, iCloudKey] {
      let cipher = try SecureFileStore.seal(Data("roundtrip".utf8), using: key)
      #expect(try SecureFileStore.open(cipher, using: key) == Data("roundtrip".utf8))
    }
    #expect(throws: NoteCryptoError.self) {
      _ = try NoteKeyID.key(for: "unknown-key")
    }
  }
}
