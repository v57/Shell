import Foundation
import SwiftData
import Testing
@testable import Shell

struct NoteModelTests {
  /// Temp-file container: in-memory SwiftData stores crash the hosted test
  /// host with "No eligible connection available" (known SwiftData issue in
  /// test targets). On-disk temp stores behave.
  private static func makeTestContainer() throws -> (ModelContainer, URL) {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("notes-model-\(UUID().uuidString).store")
    let container = try ModelContainer(
      for: NoteRecord.self,
      configurations: ModelConfiguration(url: url, cloudKitDatabase: .none)
    )
    return (container, url)
  }

  @Test @MainActor func recordRoundTripsThroughContainer() throws {
    let (container, url) = try Self.makeTestContainer()
    defer { try? FileManager.default.removeItem(at: url) }
    let context = container.mainContext
    let record = NoteRecord(
      id: UUID(),
      lastUpdate: Date(timeIntervalSince1970: 1234),
      keyId: "icloud",
      titleCipher: Data([1, 2, 3]),
      subtitleCipher: Data([4, 5]),
      contentCipher: Data([6, 7, 8, 9])
    )
    context.insert(record)
    try context.save()

    let fetched = try context.fetch(FetchDescriptor<NoteRecord>())
    #expect(fetched.count == 1)
    #expect(fetched[0].id == record.id)
    #expect(fetched[0].lastUpdate == Date(timeIntervalSince1970: 1234))
    #expect(fetched[0].keyId == "icloud")
    #expect(fetched[0].titleCipher == Data([1, 2, 3]))
    #expect(fetched[0].subtitleCipher == Data([4, 5]))
    #expect(fetched[0].contentCipher == Data([6, 7, 8, 9]))
  }

  /// Guard against the additive-only CloudKit schema trap: after production
  /// promotion, model types and attributes can't be deleted or changed, and
  /// CloudKit bans unique constraints and non-optional attributes. This test
  /// fails the build if the schema drifts.
  @Test @MainActor func noteSchemaStaysCloudKitCompatible() throws {
    for model in [NoteRecord.self, SSHConfigRecord.self, DeviceKeyRecord.self] as [any PersistentModel.Type] {
      let schema = Schema(model)
      #expect(schema.entities.count == 1)
      let attributes = schema.entities[0].attributes
      // Every attribute is optional or defaulted, none unique.
      for attribute in attributes {
        let attributeName = attribute.name
        #expect(!attribute.options.contains(.unique), "\(attributeName) must not be unique (CloudKit bans it)")
        #expect(
          attribute.isOptional || attribute.defaultValue != nil,
          "\(attributeName) must be optional or have a default value (CloudKit rule)"
        )
      }
    }
    // The fields we rely on must exist (schema drift detection).
    let noteNames = Set(Schema(NoteRecord.self).entities[0].attributes.map { $0.name })
    #expect(noteNames == ["id", "lastUpdate", "keyId", "titleCipher", "subtitleCipher", "contentCipher"])
    let sshNames = Set(Schema(SSHConfigRecord.self).entities[0].attributes.map { $0.name })
    #expect(sshNames == ["id", "order", "keyId", "updatedAt", "payloadCipher"])
    let deviceKeyNames = Set(Schema(DeviceKeyRecord.self).entities[0].attributes.map { $0.name })
    #expect(deviceKeyNames == ["id", "fingerprint", "keyLine", "deviceName", "updatedAt"])
  }

  // MARK: - Title/subtitle derivation strips leading markdown prefixes

  /// Display-only derivation: a leading markdown prefix on the physical line
  /// is stripped for the sidebar label, but the underlying note text is never
  /// mutated. See NotesStore.stripMarkdownPrefix.
  @Test @MainActor func titleStripsLeadingMarkdownPrefixes() {
    #expect(NotesStore.title(for: "# Foo") == "Foo")
    #expect(NotesStore.title(for: "- Foo") == "Foo")
    #expect(NotesStore.title(for: "* Foo") == "Foo")
    #expect(NotesStore.title(for: "+ Foo") == "Foo")
    #expect(NotesStore.title(for: "> Foo") == "Foo")
  }

  @Test @MainActor func titleIsUntitledWhenEmptyAfterStripping() {
    #expect(NotesStore.title(for: "## ") == "Untitled")
    #expect(NotesStore.title(for: "# ") == "Untitled")
    // Whitespace-only bullet: the marker + single space are stripped, leaving
    // whitespace that trims to empty → "Untitled".
    #expect(NotesStore.title(for: "-   ") == "Untitled")
    #expect(NotesStore.title(for: "- ") == "Untitled")
  }

  @Test @MainActor func subtitleStripsLeadingMarkdownPrefixes() {
    #expect(NotesStore.subtitle(for: "# Title\n- Sub") == "Sub")
    #expect(NotesStore.subtitle(for: "# Title\n* Sub") == "Sub")
    #expect(NotesStore.subtitle(for: "# Title\n> Sub") == "Sub")
    #expect(NotesStore.subtitle(for: "# Title") == nil)
  }

  @Test @MainActor func subtitleIsNilWhenEmptyAfterStripping() {
    #expect(NotesStore.subtitle(for: "# Title\n## ") == nil)
    #expect(NotesStore.subtitle(for: "# Title\n- ") == nil)
  }

  @Test @MainActor func titlePreservesNotesWithoutMarkdownPrefix() {
    #expect(NotesStore.title(for: "Plain note") == "Plain note")
    // A bare '#' with no space is NOT an ATX heading, so it stays as-is.
    #expect(NotesStore.title(for: "#") == "#")
  }
}
