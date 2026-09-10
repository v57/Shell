import Foundation
import Terminal
import TerminalIntegrations


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
  /// An in-app web page rendered in a SwiftUI WebView. `sshConfigID` binds
  /// it to an SSH host whose localhost is tunnelled to the WebView (built by
  /// the dedicated port-forward utility); nil loads the URL directly.
  case web(WebSession)
  /// A saved database connection opened in the in-app browser panel. Its
  /// session is backed by an inert transport — the database content is the
  /// `DatabaseBrowserView`, not a terminal.
  case database(DatabaseConnection)

  /// The config id for `.ssh` and `.web(sshConfigID != nil)` connections,
  /// nil for local/screen/action/plain-web sessions.
  var sshConfigID: UUID? {
    switch self {
    case .local, .screen, .action:
      return nil
    case .ssh(let config):
      return config.id
    case .web(let web):
      return web.sshConfigID
    case .database(let connection):
      return connection.sshConfigID
    }
  }

  /// The config id when this kind is an SSH **shell** session — the only kind
  /// that gets a terminal row under its host in the Remote section.
  ///
  /// Deliberately narrower than `sshConfigID`: a host-bound web page and a
  /// tunneled database connection ALSO answer `sshConfigID` (they belong to the
  /// host's section and share its tunnel) but render their own row views.
  /// Filtering rows on `sshConfigID` therefore rendered an open page twice —
  /// once with a terminal icon, once with its globe row and the same name.
  var shellConfigID: UUID? {
    if case .ssh(let config) = self { return config.id }
    return nil
  }

  /// The SSH connection config behind a remote kind, nil for local runs. Used
  /// to thread the host into a drag payload so a remote file can be downloaded.
  var sshConfig: SSHConfig? {
    switch self {
    case .local, .screen, .web, .database:
      return nil
    case .ssh(let config):
      return config
    case .action(let spec):
      return spec.config
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
    case .web(let web):
      return web.name
    case .database(let connection):
      return connection.displayName
    }
  }
}

