import CoreData
import Foundation
import SwiftData

/// The two SwiftData stores behind the notes list:
/// - `local` — plain on-disk store (`cloudKitDatabase: .none`). Explicitly
///   opting out is REQUIRED: automatic discovery would sync EVERY store,
///   since the app's entitlements declare an iCloud container.
/// - `cloud` — the CloudKit-synced store (private database of
///   `iCloud.dev.v57.sh`), nil when iCloud is unavailable.
///
/// A note lives in exactly one store (`NoteRecord` moved by
/// `NotesStore.setICloudStorage`); `keyId` says which key decrypts it.
struct NoteStores {
  let local: ModelContainer
  let cloud: ModelContainer?

  /// Production containers. The cloud store is only created when the
  /// iCloud account is available (same probe the old file store used).
  static func make() throws -> NoteStores {
    let localConfig = ModelConfiguration(
      "LocalNotes",
      cloudKitDatabase: .none
    )
    let local = try ModelContainer(
      for: NoteRecord.self,
      configurations: localConfig
    )

    let cloud: ModelContainer?
    if NotesStore.iCloudContainerURL() != nil {
      let cloudConfig = ModelConfiguration(
        "CloudNotes",
        cloudKitDatabase: .private("iCloud.dev.v57.sh")
      )
      cloud = try ModelContainer(
        for: NoteRecord.self,
        configurations: cloudConfig
      )
    } else {
      cloud = nil
    }
    return NoteStores(local: local, cloud: cloud)
  }

  /// Hermetic containers for tests: both stores on disk in a temp
  /// directory, no CloudKit anywhere (`cloudKitDatabase: .none` keeps the
  /// store a plain SQLite file; in-memory stores crash hosted test hosts).
  static func makeTest(in directory: URL) throws -> (NoteStores, cleanup: () -> Void) {
    let local = try ModelContainer(
      for: NoteRecord.self,
      configurations: ModelConfiguration(
        "LocalNotes",
        url: directory.appendingPathComponent("local.store"),
        cloudKitDatabase: .none
      )
    )
    let cloud = try ModelContainer(
      for: NoteRecord.self,
      configurations: ModelConfiguration(
        "CloudNotes",
        url: directory.appendingPathComponent("cloud.store"),
        cloudKitDatabase: .none
      )
    )
    return (NoteStores(local: local, cloud: cloud), { try? FileManager.default.removeItem(at: directory) })
  }

  // MARK: - CloudKit schema initialization (DEBUG only)

  /// Initializes the CloudKit schema for the private database during
  /// development. CloudKit schemas are additive-only after production
  /// promotion, so this runs only in DEBUG builds. Apple's recipe: load
  /// the store through NSPersistentCloudKitContainer, initialize the
  /// schema, then drop that container so SwiftData owns the store.
  static func initializeCloudKitSchemaForDevelopment() {
    #if DEBUG
    // Requires a signed-in iCloud account; skip silently otherwise.
    guard NotesStore.iCloudContainerURL() != nil else { return }
    let config = ModelConfiguration("CloudNotes", cloudKitDatabase: .private("iCloud.dev.v57.sh"))
    do {
      try autoreleasepool {
        let description = NSPersistentStoreDescription(url: config.url)
        description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
          containerIdentifier: "iCloud.dev.v57.sh"
        )
        description.shouldAddStoreAsynchronously = false
        guard let model = NSManagedObjectModel.makeManagedObjectModel(for: [NoteRecord.self, SSHConfigRecord.self, DeviceKeyRecord.self]) else { return }
        let container = NSPersistentCloudKitContainer(name: "CloudNotes", managedObjectModel: model)
        container.persistentStoreDescriptions = [description]
        container.loadPersistentStores { _, error in
          if let error { NSLog("NoteStores: CloudKit schema init store load failed: \(error)") }
        }
        try container.initializeCloudKitSchema()
        if let store = container.persistentStoreCoordinator.persistentStores.first {
          try container.persistentStoreCoordinator.remove(store)
        }
      }
    } catch {
      NSLog("NoteStores: CloudKit schema initialization failed: \(error)")
    }
    #endif
  }
}
