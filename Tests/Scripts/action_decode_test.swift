// Standalone regression test for Action's persisted scope/default contract.
// Run: swift Tests/Scripts/action_decode_test.swift

import Foundation

struct Action: Decodable, Hashable {
  var id: UUID
  var name: String
  var category: String?
  var appliesToLocal: Bool
  var sshConnectionIDs: [UUID]
  var appliesToFutureSSHConnections: Bool
  var excludedSSHConnectionIDs: [UUID]
  var commands: String
  var focusWindow: Bool
  var keepAfterCompletion: Bool
  var lastUsed: Date?

  init(
    id: UUID = UUID(), name: String = "", category: String? = nil,
    appliesToLocal: Bool = true, sshConnectionIDs: [UUID] = [],
    appliesToFutureSSHConnections: Bool = false,
    excludedSSHConnectionIDs: [UUID] = [], commands: String = "",
    focusWindow: Bool = false, keepAfterCompletion: Bool = false,
    lastUsed: Date? = nil
  ) {
    self.id = id; self.name = name; self.category = category
    self.appliesToLocal = appliesToLocal; self.sshConnectionIDs = sshConnectionIDs
    self.appliesToFutureSSHConnections = appliesToFutureSSHConnections
    self.excludedSSHConnectionIDs = excludedSSHConnectionIDs
    self.commands = commands; self.focusWindow = focusWindow
    self.keepAfterCompletion = keepAfterCompletion; self.lastUsed = lastUsed
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, category, appliesToLocal, sshConnectionIDs, commands
    case appliesToFutureSSHConnections, excludedSSHConnectionIDs
    case focusWindow, keepAfterCompletion, lastUsed, appliesToAll
  }

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

  func applies(to kind: Kind) -> Bool {
    switch kind {
    case .local: return appliesToLocal
    case .ssh(let id):
      return sshConnectionIDs.contains(id)
        || (appliesToFutureSSHConnections && !excludedSSHConnectionIDs.contains(id))
    }
  }
}

enum Kind { case local, ssh(UUID) }

var failures = 0
func check(_ condition: Bool, _ label: String) {
  print("\(condition ? "PASS" : "FAIL"): \(label)")
  if !condition { failures += 1 }
}

let current = UUID(), future = UUID()
do {
  let legacy = """
  {"id":"\(UUID().uuidString)","name":"legacy","commands":"echo hi","appliesToAll":true,"appliesToLocal":false}
  """
  let action = try JSONDecoder().decode(Action.self, from: Data(legacy.utf8))
  check(action.applies(to: .local), "legacy global includes local")
  check(action.applies(to: .ssh(current)), "legacy global includes current SSH")
  check(action.appliesToFutureSSHConnections, "legacy global includes future SSH")
  check(!action.focusWindow, "missing focus defaults off")
  check(!action.keepAfterCompletion, "missing keep defaults off")
} catch {
  check(false, "legacy action decodes: \(error)")
}

let scoped = Action(
  appliesToLocal: false,
  appliesToFutureSSHConnections: true,
  excludedSSHConnectionIDs: [current],
  commands: "uptime"
)
check(!scoped.applies(to: .ssh(current)), "current unchecked SSH remains excluded")
check(scoped.applies(to: .ssh(future)), "new SSH connection applies")
check(!scoped.applies(to: .local), "local remains independent")

if failures == 0 { print("ALL PASS") } else { exit(1) }
