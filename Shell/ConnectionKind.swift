import Foundation
import Terminal


/// What an action session runs: the action plus the remote target config
/// (nil = local machine).
struct ActionSpec: Hashable {
  var action: Action
  var config: SSHConfig?
}

/// The kind of terminal a session runs.
enum ConnectionKind: Hashable {
  case local
  case screen(ScreenSessionInfo)
  case ssh(SSHConfig)
  /// A separate session running an Action's commands (local, or remote
  /// via the spec's config). Never grouped under the Remote section.
  case action(ActionSpec)

  /// The config id for `.ssh` connections, nil for local/screen/action
  /// sessions (action sessions have their own sidebar section).
  var sshConfigID: UUID? {
    switch self {
    case .local, .screen, .action:
      return nil
    case .ssh(let config):
      return config.id
    }
  }

  var displayName: String {
    switch self {
    case .local:
      return "Local"
    case .screen(let info):
      return info.name
    case .ssh(let config):
      return config.displayName
    case .action(let spec):
      return spec.action.name
    }
  }
}

