import Foundation
import VaultKit

/// A build for recording the App Review video (`~/Developer/v57/Demo.md`): Shell starts empty, as on the reviewer's
/// device, and nothing of the user's shows up or leaves the device.
///
/// The other v57 apps on the device share one store, so a fresh install alone would still list the user's hosts, notes
/// and keys. This build keeps its vault and secrets in memory instead (`VaultSecrets.useInMemoryStore()`): it never
/// reads or writes the shared store or the keychain, never syncs, and starts empty again on every launch.
///
/// Only a build made with the `REVIEW_RECORDING` compilation condition has it:
///
///   xcodebuild … SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) REVIEW_RECORDING'
enum ReviewRecording {
  static let isOn: Bool = {
    #if REVIEW_RECORDING
      true
    #else
      false
    #endif
  }()

  /// Before anything opens the vault: secrets, the identity and the store in memory, iCloud off for this run only (the
  /// switch's file lives in the run's temporary store, so the other apps keep syncing).
  static func prepare() {
    VaultSecrets.useInMemoryStore()
    try? VaultICloud.setOff(true)
  }
}
