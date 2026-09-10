import Foundation
import Testing
import Terminal
@testable import Shell

/// Regression: the Remote section emits ONE terminal row per SSH shell session.
///
/// A host-bound web page (and a tunneled database connection) belongs to the
/// same host — `ConnectionKind.sshConfigID` answers for all three kinds — so
/// filtering the host's rows on `sshConfigID` rendered an open page twice: a
/// terminal row labelled with the page's name, plus the page's own globe row.
/// Only `.ssh` kinds are shell rows (`ConnectionKind.shellConfigID`).
@Suite(.serialized)
@MainActor
struct SidebarHostRowsTests {
  /// The kind table the rule rests on: everything bound to a host answers
  /// `sshConfigID` (section grouping), but only a shell session is a SHELL row.
  @Test func onlyShellSessionsAreShellRows() {
    let config = SSHConfig(name: "server", host: "example.com", user: "me", port: 22)
    let bound = WebSession(name: "Grafana", url: "http://localhost:3000", sshConfigID: config.id)

    #expect(ConnectionKind.ssh(config).sshConfigID == config.id)
    #expect(ConnectionKind.web(bound).sshConfigID == config.id)
    #expect(ConnectionKind.ssh(config).shellConfigID == config.id)
    #expect(ConnectionKind.web(bound).shellConfigID == nil)
    #expect(ConnectionKind.web(WebSession()).shellConfigID == nil)
    #expect(ConnectionKind.local.shellConfigID == nil)
  }

  /// End to end through the real open path: an opened host-bound page is in the
  /// host's section but produces NO shell row, so the Remote section renders it
  /// exactly once (its own globe row).
  @Test func openedHostBoundPageAddsNoShellRow() {
    let config = SSHConfig(name: "server", host: "example.com")
    let web = WebSession(url: "http://localhost:8080", sshConfigID: config.id)
    let model = AppModel.shared
    let page = model.openWebSession(web)   // no URL-less tunnel, no SSH dial
    defer { model.removeSession(page.id) }

    #expect(model.kind(of: page) == .web(web))
    #expect(model.liveWebSession(for: web)?.id == page.id)
    #expect(model.sessions(for: config).map(\.id) == [page.id])
    #expect(model.shellSessions(for: config).isEmpty)
  }
}
