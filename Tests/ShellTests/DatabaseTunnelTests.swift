import Foundation
import Testing
@testable import Shell

/// Hermetic tests for the SSH tunnel routing decision of a database
/// connection — pure value logic, no live SSH server or driver required (an
/// end-to-end tunnel needs a real sshd/DB, which the headless runner cannot
/// provide; these cover the routing rules the tunnel layer is built on).
@Suite
struct DatabaseTunnelTests {
  private let sshID = UUID()

  @Test func remoteServerConnectionsRouteThroughTunnel() {
    for engine in [DatabaseEngine.mongodb, .postgresql, .redis] {
      let connection = DatabaseConnection(
        engine: engine, name: "remote", host: "db.internal", port: 5432, sshConfigID: sshID)
      #expect(connection.requiresTunnel)
    }
  }

  @Test func localConnectionsDoNotTunnel() {
    // No sshConfigID → connect directly to host:port as before.
    let local = DatabaseConnection(engine: .postgresql, name: "local", host: "127.0.0.1", port: 5432)
    #expect(!local.requiresTunnel)
    #expect(local.tunnelTarget == nil)
  }

  @Test func sqliteIsNeverTunneledEvenWithSSHID() {
    // SQLite is file-based; a tunneled file path is meaningless.
    let sqlite = DatabaseConnection(engine: .sqlite, name: "local-file", host: "/tmp/x.db", sshConfigID: sshID)
    #expect(!sqlite.requiresTunnel)
    #expect(sqlite.tunnelTarget == nil)
  }

  @Test func tunnelTargetBridgesToRemoteLocalhostPort() {
    let connection = DatabaseConnection(
      engine: .mongodb, name: "m", host: "db.internal", port: 27017, sshConfigID: sshID)
    #expect(connection.tunnelTarget?.host == "127.0.0.1")
    #expect(connection.tunnelTarget?.port == 27017)
  }

  @Test func tunnelTargetUsesTheSavedPort() {
    let connection = DatabaseConnection(
      engine: .redis, name: "r", host: "db.internal", port: 6380, database: "5", sshConfigID: sshID)
    #expect(connection.requiresTunnel)
    #expect(connection.tunnelTarget?.host == "127.0.0.1")
    #expect(connection.tunnelTarget?.port == 6380)
  }
}
