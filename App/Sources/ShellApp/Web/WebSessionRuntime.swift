import ComponentKit
import Foundation
import Observation
import ShellKit

/// The runtime backing an OPEN ssh-owned web session. AppModel creates one per
/// opened web page that has an `sshConfigID`, owns it for the session's
/// lifetime (started on connect, stopped on teardown), and exposes the
/// observable state the WebView reads:
///
///  - `tunnelURL`: the reachable `http://127.0.0.1:<localPort>/…` the WebView
///    should load, set once the SSH local port-forward is confirmed healthy.
///  - `errorMessage`: a user-facing error shown in place of the (blank)
///    WebView when the tunnel cannot be established or drops.
///  - `isConnecting`: true until SSH auth + the tunnel bind complete.
///
/// The SSH connection is established with the reusable `SSHSession` in
/// forwarding-only mode (no remote shell/exec channel); the tunnel runs on the
/// same authenticated connection — the reusable `SSHLocalPortForward` bridges
/// an in-app local port to the host's `localhost:<port>`, with NO re-dial and
/// NO re-authentication.
@MainActor
@Observable
final class WebSessionRuntime {
  let web: WebSession
  /// The resolved SSH config; nil when the bound config no longer exists.
  private let config: SSHConfig?

  private(set) var tunnelURL: URL?
  private(set) var errorMessage: String?
  private(set) var isConnecting = true

  /// The tunnel's state for the page's live icon (its row, the page title).
  var status: WorkStatus {
    if let errorMessage { return .failed(errorMessage) }
    return isConnecting ? .working : .idle
  }

  private var session: SSHSession?
  private var started = false

  init(web: WebSession, config: SSHConfig?) {
    self.web = web
    self.config = config
  }

  /// Establishes the SSH connection and, once authenticated, opens the local
  /// port-forward and records the reachable local URL. Safe to call once.
  func start() {
    guard !started else { return }
    started = true

    guard let config else {
      isConnecting = false
      errorMessage = "The SSH connection for this web session no longer exists. Add it in the SSH settings, then reopen the page."
      return
    }

    isConnecting = true
    let session = SSHSession(config: config, forwardingOnly: true)
    self.session = session

    // Trust on first use, never a changed key — opening a web page bound to a
    // host IS the intent to connect (same policy as the file browser /
    // authorized-keys panel).
    session.onHostKeyPrompt = { prompt in
      prompt.respondTrustingFirstUse()
    }
    session.onPasswordPrompt = { [config, weak self] prompt in
      let saved = (try? SSHKeychain.loadPassword(account: config.passwordAccount)) ?? nil
      if let saved {
        prompt.respond(saved, false)
      } else {
        // No saved password and key auth failed — surface a clear error rather
        // than leaving a blank page. The HeadlessSSHCommandRunner behaves the
        // same way for the authorized-keys panel.
        self?.isConnecting = false
        self?.errorMessage = "SSH authentication needs a password that is not saved. Add one in the connection settings, or use an SSH key, then reopen the page."
        prompt.respond(nil, false)
      }
    }
    session.onConnected = { [weak self] in
      guard let self else { return }
      self.isConnecting = false
      self.openTunnel()
    }
    session.onTerminated = { [weak self] message in
      guard let self else { return }
      self.isConnecting = false
      self.tunnelURL = nil
      self.errorMessage = message
      self.session?.stopLocalPortForward()
    }
    session.start()
  }

  /// Stops the SSH connection and closes the tunnel. Called when the web
  /// session is closed/removed, so the tunnel lifecycle is tied to the
  /// session's connect/disconnect behavior.
  func stop() {
    session?.stopLocalPortForward()
    session?.close()
    session = nil
  }

  // MARK: - Tunnel

  private func openTunnel() {
    let (targetHost, targetPort) = Self.target(from: web.url)
    session?.startLocalPortForward(
      bindHost: "127.0.0.1",
      bindPort: 0,
      targetHost: targetHost,
      targetPort: targetPort
    ) { [weak self] result in
      DispatchQueue.main.async {
        guard let self else { return }
        switch result {
        case .success(let boundPort):
          self.tunnelURL = Self.localURL(from: self.web.url, boundPort: boundPort)
        case .failure(let error):
          self.errorMessage = "Could not open the SSH port-forward: \(error.localizedDescription)"
        }
      }
    }
  }

  /// The remote host + port the tunnel targets: derived from the host's URL
  /// (the SSH host's own view of the service, e.g. `http://localhost:8080`).
  static func target(from urlString: String) -> (host: String, port: Int) {
    let url = URL(string: urlString)
    let scheme = url?.scheme?.lowercased() ?? ""
    let host = url?.host.flatMap { $0.isEmpty ? nil : $0 } ?? "localhost"
    let port = url?.port ?? (scheme == "https" ? 443 : 80)
    return (host, port)
  }

  /// Rewrites the host's URL into the reachable local URL the WebView loads:
  /// same scheme/path, but host `127.0.0.1` and the bound tunnel port.
  static func localURL(from urlString: String, boundPort: Int) -> URL? {
    guard var components = URLComponents(string: urlString) else {
      return URL(string: urlString)
    }
    components.host = "127.0.0.1"
    components.port = boundPort
    return components.url
  }
}
