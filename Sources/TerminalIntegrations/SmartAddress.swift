import Foundation

/// Resolves a user-typed web address into a loadable absolute URL.
///
/// The action form's "web" field lets a user type a short, scheme-less
/// address and have it normalized to a real URL when the action's web view
/// opens. This makes a bare port or short host name usable directly.
///
/// Rules (matching the "run a web server, open a web view" action shape):
///   * Already has `http://` or `https://`  -> unchanged
///   * Bare port, all digits (`1997`)        -> `http://localhost:1997`
///   * Local host (`localhost`, loopback IPs, `*.local`) -> `http://<host>`
///   * Anything else (`v57.dev`)             -> `https://<host>`
///
/// Host and optional port are parsed so `localhost:1997` -> `http://localhost:1997`.
/// A port is only split off when the final `:segment` is numeric, so IPv6
/// literals keep their colons and are not mistaken for a host:port separator.
public enum SmartAddress {
  public static func resolve(_ written: String) -> String {
    let input = written.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !input.isEmpty else { return "" }
    // An explicit scheme is authoritative — never rewrite it.
    if input.hasPrefix("http://") || input.hasPrefix("https://") { return input }
    // A bare port (all digits) is a server on this machine's localhost.
    if input.allSatisfy({ $0.isNumber }) {
      return "http://localhost:\(input)"
    }
    // Split host[:port]. Only treat the trailing numeric segment as a port so
    // IPv6 colons are preserved.
    var host = input
    var port: String?
    if let colon = input.lastIndex(of: ":") {
      let candidate = String(input[input.index(after: colon)...])
      if !candidate.isEmpty, candidate.allSatisfy({ $0.isNumber }) {
        host = String(input[..<colon])
        port = candidate
      }
    }
    if host.isEmpty { host = "localhost" }
    let scheme = isLocal(host) ? "http" : "https"
    var result = "\(scheme)://\(host)"
    if let port { result += ":\(port)" }
    return result
  }

  /// A host is "local" when it should be served over plain http: `localhost`,
  /// the loopback addresses, or any `*.local` (mDNS) name. Everything else
  /// defaults to https.
  private static func isLocal(_ host: String) -> Bool {
    let unbracketed = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    let lower = unbracketed.lowercased()
    return lower == "localhost"
      || lower == "127.0.0.1"
      || lower == "::1"
      || lower == "0.0.0.0"
      || lower.hasSuffix(".local")
  }
}
