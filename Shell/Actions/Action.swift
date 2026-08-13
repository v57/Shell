import Foundation
import Terminal

/// A user-defined action: a named multi-line script. Running it opens a
/// separate terminal session in the current environment.
struct Action: Identifiable, Codable, Hashable {
  var id: UUID
  var name: String
  var category: String?          // nil/empty -> "General" section
  var appliesToLocal: Bool       // local + persistent (.screen) terminals
  var sshConnectionIDs: [UUID]   // saved SSH connections by config id
  /// Apply to SSH connections saved after this scope was last edited.
  var appliesToFutureSSHConnections: Bool
  /// Connections that existed, were visible in the form, and were left off
  /// while future targeting was enabled. Newly created ids are absent.
  var excludedSSHConnectionIDs: [UUID]
  var commands: String           // multi-line shell script
  /// Bring the new action session to focus when run (else run in
  /// background; the run still shows in the sidebar's Running section).
  var focusWindow: Bool
  /// Preserve a successful run in the Running section after completion.
  var keepAfterCompletion: Bool
  /// When this action last ran (nil = never). Drives MRU ordering in the
  /// actions overlay; stamped by ActionsStore.touch on every run.
  var lastUsed: Date?

  init(
    id: UUID = UUID(),
    name: String = "",
    category: String? = nil,
    appliesToLocal: Bool = true,
    sshConnectionIDs: [UUID] = [],
    appliesToFutureSSHConnections: Bool = false,
    excludedSSHConnectionIDs: [UUID] = [],
    commands: String = "",
    focusWindow: Bool = false,
    keepAfterCompletion: Bool = false,
    lastUsed: Date? = nil
  ) {
    self.id = id
    self.name = name
    self.category = category
    self.appliesToLocal = appliesToLocal
    self.sshConnectionIDs = sshConnectionIDs
    self.appliesToFutureSSHConnections = appliesToFutureSSHConnections
    self.excludedSSHConnectionIDs = excludedSSHConnectionIDs
    self.commands = commands
    self.focusWindow = focusWindow
    self.keepAfterCompletion = keepAfterCompletion
    self.lastUsed = lastUsed
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, category, appliesToLocal, sshConnectionIDs, commands
    case appliesToFutureSSHConnections, excludedSSHConnectionIDs
    case focusWindow, keepAfterCompletion, lastUsed
    case appliesToAll // legacy global scope
  }

  /// Backward-compatible decode: every field decodeIfPresent ?? default
  /// (the synthesized decoder throws keyNotFound on data saved before a
  /// field existed — pitfall 20).
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    name = try c.decode(String.self, forKey: .name)
    category = try c.decodeIfPresent(String.self, forKey: .category)
    let legacyGlobal = try c.decodeIfPresent(Bool.self, forKey: .appliesToAll) ?? false
    let decodedLocal = try c.decodeIfPresent(Bool.self, forKey: .appliesToLocal) ?? true
    appliesToLocal = legacyGlobal || decodedLocal
    sshConnectionIDs = try c.decodeIfPresent([UUID].self, forKey: .sshConnectionIDs) ?? []
    appliesToFutureSSHConnections = try c.decodeIfPresent(
      Bool.self, forKey: .appliesToFutureSSHConnections
    ) ?? legacyGlobal
    excludedSSHConnectionIDs = try c.decodeIfPresent(
      [UUID].self, forKey: .excludedSSHConnectionIDs
    ) ?? []
    commands = try c.decodeIfPresent(String.self, forKey: .commands) ?? ""
    focusWindow = try c.decodeIfPresent(Bool.self, forKey: .focusWindow) ?? false
    keepAfterCompletion = try c.decodeIfPresent(Bool.self, forKey: .keepAfterCompletion) ?? false
    lastUsed = try c.decodeIfPresent(Date.self, forKey: .lastUsed)
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(name, forKey: .name)
    try c.encodeIfPresent(category, forKey: .category)
    try c.encode(appliesToLocal, forKey: .appliesToLocal)
    try c.encode(sshConnectionIDs, forKey: .sshConnectionIDs)
    try c.encode(appliesToFutureSSHConnections, forKey: .appliesToFutureSSHConnections)
    try c.encode(excludedSSHConnectionIDs, forKey: .excludedSSHConnectionIDs)
    try c.encode(commands, forKey: .commands)
    try c.encode(focusWindow, forKey: .focusWindow)
    try c.encode(keepAfterCompletion, forKey: .keepAfterCompletion)
    try c.encodeIfPresent(lastUsed, forKey: .lastUsed)
  }

  /// Whether this action is offered in the given environment.
  /// (The `.action` case is added in the ConnectionKind extension when
  /// action sessions land; it routes through its spec's config.)
  func applies(to kind: ConnectionKind) -> Bool {
    switch kind {
    case .local, .screen:
      return appliesToLocal
    case .ssh(let config):
      return applies(toSSHConnectionID: config.id)
    case .action(let spec):
      // Action sessions run in the environment of their target.
      if let config = spec.config {
        return applies(toSSHConnectionID: config.id)
      }
      return appliesToLocal
    }
  }

  private func applies(toSSHConnectionID id: UUID) -> Bool {
    sshConnectionIDs.contains(id)
      || (appliesToFutureSSHConnections && !excludedSSHConnectionIDs.contains(id))
  }
}

/// Persists actions in UserDefaults (same pattern as SSHConnectionStore).
/// @Observable so the actions overlay live-updates on add/edit/remove/run —
/// a store that re-reads UserDefaults on every access can't notify SwiftUI
/// when `remove` is called from a context menu, leaving the chip on screen.
@MainActor
@Observable
final class ActionsStore {
  private static let key = "actions"
  private let defaults: UserDefaults

  /// All actions in creation order. MRU ordering is a display concern in
  /// the overlay, not stored here.
  private(set) var all: [Action] = []

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    reload()
  }

  private func reload() {
    guard let data = defaults.data(forKey: Self.key) else { all = []; return }
    all = (try? JSONDecoder().decode([Action].self, from: data)) ?? []
  }

  func save(_ action: Action) {
    if let index = all.firstIndex(where: { $0.id == action.id }) {
      all[index] = action
    } else {
      all.append(action)
    }
    persist()
  }

  func remove(_ id: UUID) {
    all.removeAll { $0.id == id }
    persist()
  }

  /// Marks the action as used right now and persists it.
  func touch(_ id: UUID) {
    guard let index = all.firstIndex(where: { $0.id == id }) else { return }
    all[index].lastUsed = Date()
    persist()
  }

  private func persist() {
    if let data = try? JSONEncoder().encode(all) {
      defaults.set(data, forKey: Self.key)
    }
  }
}
