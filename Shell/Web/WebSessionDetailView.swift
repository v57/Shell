import ComponentKit
import SwiftUI
#if canImport(WebKit)
import WebKit
import _WebKit_SwiftUI
#endif

/// The detail pane for an opened `.web` session: renders the session's URL in
/// the system SwiftUI `WebView`.
///
/// For a plain web session (`tunnel == nil`) it loads the stored URL directly.
/// For an ssh-owned session the AppModel supplies a `WebSessionRuntime` whose
/// observable state drives the pane: a connecting live icon until the SSH local
/// port-forward is healthy, then the reachable `http://127.0.0.1:<localPort>/`
/// URL, or a clear error in place of the blank WebView if the tunnel cannot be
/// established or drops.
///
/// The system SwiftUI Web API (`WebKit.WebPage` + `WebView`, available macOS /
/// iOS 26+) is used whenever it is available — which is always on this app's
/// 27.0 deployment target. Owning the `WebPage` (instead of the `WebView(url:)`
/// convenience) is what gives the app a handle on the loaded page's HTML
/// `<title>`, which names the session (`AppModel.autoNameWebSession`). A thin
/// representable fallback exists ONLY for a hypothetical pre-26 build (it is
/// dead code here) so the platform contract holds on any target that might ever
/// lower its deployment; that fallback cannot report a title.
struct WebSessionDetailView: View {
  @Environment(AppModel.self) private var model
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
          EmptyState(systemImage: "globe", title: "Couldn't Connect", message: error, status: .failed(error))
        } else if let tunneled = tunnel.tunnelURL {
          webView(for: tunneled)
        } else {
          EmptyState(
            systemImage: "globe", title: "Connecting", message: "Opening the tunnel to \(displayName)…", status: .working)
        }
      } else if let url {
        webView(for: url)
      } else {
        // A page with no URL yet: opened straight from a host's "Web Session"
        // item, so point the user at the toolbar's URL field (the address bar
        // is the toolbar search field — there is no in-content bar).
        EmptyState(
          systemImage: "globe", title: "Web Session",
          message: web.url.isEmpty ? "Type the page's address into the URL field, then press Return." : web.url)
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
    #if !canImport(WebKit)
    // No web view where WebKit is missing (Windows): the page opens in the browser.
    BrowserPageView(url: url)
    #else
    if #available(macOS 26.0, iOS 26.0, *) {
      SystemWebView(web: web, url: url)
    } else {
      // Dead code on the 27.0 deployment target — present only to satisfy the
      // "thin representable fallback where the system API is unavailable"
      // contract. Not a hand-rolled browser: a 1:1 WKWebView wrapper.
      WebViewRepresentableFallback(url: url)
    }
    #endif
  }
}

#if !canImport(WebKit)
/// The page's address and a button that opens it in the system browser.
private struct BrowserPageView: View {
  let url: URL
  @Environment(\.openURL) private var openURL

  var body: some View {
    EmptyState(systemImage: "globe", title: url.host() ?? "Web Session", message: url.absoluteString) {
      Button("Open in Browser", systemImage: "safari") { openURL(url) }
        .buttonStyle(.kit)
    }
  }
}
#else


/// The system SwiftUI web view, plus the page-title observer that names the
/// session. Owns the `WebPage` so the loaded document's `<title>` is readable
/// (`WebPage` is `Observable`, so reading `page.title` in `body` re-runs it and
/// fires `.onChange` when the loaded page's title arrives or changes).
@available(macOS 26.0, iOS 26.0, *)
private struct SystemWebView: View {
  @Environment(AppModel.self) private var model
  let web: WebSession
  let url: URL
  @State private var page = WebPage()

  var body: some View {
    _WebKit_SwiftUI.WebView(page)
      .onAppear { loadIfNeeded() }
      .onChange(of: url) { _, _ in loadIfNeeded() }
      .onChange(of: page.title) { _, title in
        // The page names the session: only a page with no name yet is renamed,
        // so a user-given name survives.
        model.autoNameWebSession(web, pageTitle: title)
      }
  }

  /// Loads the current URL unless the page is already showing it — the tunnel
  /// coming up re-supplies the same address on a re-render.
  private func loadIfNeeded() {
    guard page.url != url else { return }
    _ = page.load(url)
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
#endif
