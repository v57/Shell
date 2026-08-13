import Foundation
import SwiftData

/// One device's public key, synced through iCloud so every device can see
/// (and grant access to) every other device's key.
///
/// PUBLIC KEYS ARE PUBLIC: the record is deliberately PLAINTEXT — the whole
/// point is that other devices read these lines to add them to a server's
/// `~/.ssh/authorized_keys`. No encryption, no keyId.
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
