import Foundation

/// A saved web session: a named URL the app opens in an in-app SwiftUI
/// WebView (the system SwiftUI Web API, NOT a hand-rolled WKWebView).
///
/// `sshConfigID` is optional. When nil, the WebView loads `url` directly.
/// When set, the URL should be reached through the SSH host's localhost —
/// the dedicated port-forward utility (a sibling task) tunnels the host's
/// `localhost:<port>` to an in-app `127.0.0.1:<localPort>` and hands the
/// resulting URL to the WebView. This model only stores the raw config;
/// it does not perform any connection work itself.
struct WebSession: Identifiable, Codable, Hashable {
  var id: UUID
  var name: String
  /// The web page to load, e.g. `http://localhost:8080` or
  /// `https://example.com`. For an ssh-owned session this is the *host's*
  /// URL; the tunnel rewrites it to a reachable local URL.
  var url: String
  /// Optional SSH config id the session is bound to (nil = plain web page).
  var sshConfigID: UUID?

  init(
    id: UUID = UUID(),
    name: String = "",
    url: String = "",
    sshConfigID: UUID? = nil
  ) {
    self.id = id
    self.name = name
    self.url = url
    self.sshConfigID = sshConfigID
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, url, sshConfigID
  }

  /// Backward-compatible decode: every field decodeIfPresent with a default,
  /// so data saved before a field existed still decodes (the synthesized
  /// decoder throws keyNotFound in that case — same pattern as Action).
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
    url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
    sshConfigID = try c.decodeIfPresent(UUID.self, forKey: .sshConfigID)
  }
}
