import ComponentKit
import SwiftUI
#if canImport(PlatformWeb)
import PlatformWeb
#endif

/// The detail pane for an opened `.web` session: renders the session's URL in
/// Platform's `PlatformWebView` (WKWebView on Apple platforms, WebKitGTK on Linux).
///
/// For a plain web session (`tunnel == nil`) it loads the stored URL directly.
/// For an ssh-owned session the AppModel supplies a `WebSessionRuntime` whose
/// observable state drives the pane: a connecting live icon until the SSH local
/// port-forward is healthy, then the reachable `http://127.0.0.1:<localPort>/`
/// URL, or a clear error in place of the blank WebView if the tunnel cannot be
/// established or drops.
///
/// Owning the `PlatformWebPage` is what gives the app a handle on the loaded
/// page's HTML `<title>`, which names the session (`AppModel.autoNameWebSession`).
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
    #if canImport(PlatformWeb)
    SystemWebView(web: web, url: url)
    #else
    // No web view where Platform's web library isn't linked (Windows): the page opens in the browser.
    BrowserPageView(url: url)
    #endif
  }
}

#if !canImport(PlatformWeb)
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
/// The web view, plus the page-title observer that names the session. Owns the
/// `PlatformWebPage` so the loaded document's `<title>` is readable (the page is
/// `Observable`, so reading `page.title` in `body` re-runs it and fires
/// `.onChange` when the loaded page's title arrives or changes).
private struct SystemWebView: View {
  @Environment(AppModel.self) private var model
  let web: WebSession
  let url: URL
  @State private var page = PlatformWebPage()

  var body: some View {
    PlatformWebView(page)
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
    page.load(url)
  }
}
#endif
