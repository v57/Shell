import SwiftUI
import WebKit
import _WebKit_SwiftUI

/// The detail pane for an opened `.web` session: renders the session's URL in
/// the system SwiftUI `WebView`.
///
/// For a plain web session (`tunnel == nil`) it loads the stored URL directly.
/// For an ssh-owned session the AppModel supplies a `WebSessionRuntime` whose
/// observable state drives the pane: a connecting spinner until the SSH local
/// port-forward is healthy, then the reachable `http://127.0.0.1:<localPort>/`
/// URL, or a clear error in place of the blank WebView if the tunnel cannot be
/// established or drops.
///
/// The system SwiftUI Web API (`_WebKit_SwiftUI.WebView`, available macOS /
/// iOS 26+) is used whenever it is available — which is always on this app's
/// 27.0 deployment target. A thin representable fallback exists ONLY for a
/// hypothetical pre-26 build (it is dead code here) so the platform contract
/// holds on any target that might ever lower its deployment.
struct WebSessionDetailView: View {
  let web: WebSession
  /// Non-nil for an ssh-owned session; drives the tunneled URL / error state.
  var tunnel: WebSessionRuntime?

  /// The URL currently being loaded for a plain (non-ssh) session. For
  /// ssh-owned sessions the runtime's `tunnelURL` is authoritative instead.
  @State private var url: URL?

  var body: some View {
    Group {
      if let tunnel {
        if let error = tunnel.errorMessage {
          ContentUnavailableView(
            "Web Session",
            systemImage: "exclamationmark.octagon",
            description: Text(error)
          )
        } else if let tunneled = tunnel.tunnelURL {
          webView(for: tunneled)
        } else {
          ProgressView("Connecting to \(displayName)…")
        }
      } else if let url {
        webView(for: url)
      } else {
        ContentUnavailableView(
          "Web Session",
          systemImage: "globe",
          description: Text(web.url.isEmpty ? "This web session has no URL configured." : web.url)
        )
      }
    }
    .onAppear { resolveURL(from: web.url) }
    .onChange(of: web.url) { _, newValue in resolveURL(from: newValue) }
  }

  private var displayName: String {
    web.name.isEmpty ? (web.url.isEmpty ? "Web Session" : web.url) : web.name
  }

  /// Resolves the stored URL string into a `URL`. For an ssh-owned session the
  /// runtime's tunneled local URL is used instead, so this only seeds the raw
  /// (host-side) URL for plain sessions.
  private func resolveURL(from string: String) {
    guard tunnel == nil else { return }
    url = URL(string: string)
  }

  @ViewBuilder
  private func webView(for url: URL) -> some View {
    if #available(macOS 26.0, iOS 26.0, *) {
      _WebKit_SwiftUI.WebView(url: url)
    } else {
      // Dead code on the 27.0 deployment target — present only to satisfy the
      // "thin representable fallback where the system API is unavailable"
      // contract. Not a hand-rolled browser: a 1:1 WKWebView wrapper.
      WebViewRepresentableFallback(url: url)
    }
  }
}

#if os(macOS)
/// Thin representable used ONLY when the system SwiftUI WebView API is
/// unavailable (pre-macOS 26). Never reached on the 27.0 target.
private struct WebViewRepresentableFallback: NSViewRepresentable {
  let url: URL

  func makeNSView(context: Context) -> WKWebView {
    let view = WKWebView()
    view.load(URLRequest(url: url))
    return view
  }

  func updateNSView(_ nsView: WKWebView, context: Context) {
    if nsView.url != url {
      nsView.load(URLRequest(url: url))
    }
  }
}
#else
/// Thin representable used ONLY when the system SwiftUI WebView API is
/// unavailable (pre-iOS 26). Never reached on the 27.0 target.
private struct WebViewRepresentableFallback: UIViewRepresentable {
  let url: URL

  func makeUIView(context: Context) -> WKWebView {
    let view = WKWebView()
    view.load(URLRequest(url: url))
    return view
  }

  func updateUIView(_ uiView: WKWebView, context: Context) {
    if uiView.url != url {
      uiView.load(URLRequest(url: url))
    }
  }
}
#endif
