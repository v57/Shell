import Foundation
import SwiftData

/// One device's public key, synced through iCloud so every device can see
/// (and grant access to) every other device's key.
///
/// PUBLIC KEYS ARE PUBLIC: the record is deliberately PLAINTEXT — the whole
/// point is that other devices read these lines to add them to a server's
/// `~/.ssh/authorized_keys`. No encryption, no keyId.
///
/// Keys added by hand in the authorized-keys panel ("custom keys") use the
/// same record: `deviceName` holds the name the user gave, and the line keeps
/// its own comment. Shell's device keys are told apart by their comment
/// (`isDeviceKey`), which avoids a schema change.
///
/// CloudKit compatibility (additive-only schema): no unique attributes,
/// every attribute optional or defaulted. "One record per device" is
/// enforced in code by fingerprint (the key material IS the device's
/// identity), not by a unique constraint.
@Model
final class DeviceKeyRecord {
  var id: UUID = UUID()
  /// SHA256 fingerprint of the key — the device identity / dedupe key.
  var fingerprint: String?
  /// The full OpenSSH authorized_keys line (type, base64, comment).
  var keyLine: String?
  /// The device's display name (Host name / UIDevice name).
  var deviceName: String?
  /// Last publish time (sort key).
  var updatedAt: Date = Date.distantPast

  /// Whether a device published this key (its comment is the
  /// "Shell (user@device)" that `DeviceKeyStore.publishThisDevice` writes),
  /// as opposed to a custom key added by hand.
  var isDeviceKey: Bool {
    guard let keyLine else { return false }
    let fields = keyLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
    return fields.count == 3 && fields[2].hasPrefix("Shell (")
  }

  init(
    id: UUID = UUID(),
    fingerprint: String? = nil,
    keyLine: String? = nil,
    deviceName: String? = nil,
    updatedAt: Date = Date.distantPast
  ) {
    self.id = id
    self.fingerprint = fingerprint
    self.keyLine = keyLine
    self.deviceName = deviceName
    self.updatedAt = updatedAt
  }
}
