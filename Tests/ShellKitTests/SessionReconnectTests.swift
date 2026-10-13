import Foundation
import Testing
@testable import ShellKit

/// A session created with a `reconnect` factory survives a dropped link:
/// it dials again (backing off), keeps its scrollback, and resumes on the
/// new transport. A final failure (bad auth) and a shell the user ended
/// are not retried on their own; `reconnectNow()` retries them.
@MainActor
struct SessionReconnectTests {
  /// A transport that only reports what the test tells it to.
  private final class ScriptedTransport: TerminalTransport {
    var onOutput: ((Data) -> Void)?
    var onConnected: (() -> Void)?
    var onTerminated: ((String) -> Void)?
    var onConnectionLost: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?
    var started = 0
    var closed = 0
    var resizes: [(columns: Int, rows: Int)] = []
    func start() { started += 1 }
    func write(_ data: Data) {}
    func resize(columns: Int, rows: Int) { resizes.append((columns, rows)) }
    func close() { closed += 1 }
  }

  private func settle(_ seconds: TimeInterval = 0.05) async {
    try? await Task.sleep(for: .seconds(seconds))
  }

  @Test func droppedLinkDialsAgainOnAFreshTransport() async {
    let first = ScriptedTransport()
    var made: [ScriptedTransport] = []
    let session = TerminalSession(transport: first, startupMessage: "Connecting to host…", reconnect: {
      let transport = ScriptedTransport()
      made.append(transport)
      return transport
    })
    defer { session.close() }
    session.reconnectDelay = { _ in 0.01 }

    first.onConnected?()
    #expect(session.connectionState == .connected)
    first.onOutput?(Data("old output\r\n".utf8))
    session.flushPendingOutput()
    session.resize(columns: 132, rows: 40)

    first.onConnectionLost?("The host stopped responding.")
    #expect(session.connectionState == .reconnecting(attempt: 1))
    #expect(session.snapshot.message?.contains("The host stopped responding.") == true)
    #expect(session.snapshot.message?.contains("Connecting to host… (attempt 1)") == true)

    await settle()
    #expect(made.count == 1)
    #expect(first.closed == 1)
    let second = made[0]
    #expect(second.started == 1)

    // The dead transport's late events are ignored.
    first.onOutput?(Data("ghost".utf8))
    first.onConnectionLost?("again")
    #expect(session.connectionState == .reconnecting(attempt: 1))

    // The second dial fails too: attempt 2, with the first delay's successor.
    second.onConnectionLost?("Connection refused")
    #expect(session.connectionState == .reconnecting(attempt: 2))
    await settle()
    #expect(made.count == 2)
    let third = made[1]

    third.onConnected?()
    #expect(session.connectionState == .connected)
    // The fresh pty is brought to the grid's size, and the old output
    // stays above a "reconnected" seam.
    #expect(third.resizes.last.map { $0.columns == 132 && $0.rows == 40 } == true)
    third.onOutput?(Data("new prompt $ ".utf8))
    session.flushPendingOutput()
    let text = session.snapshot.fullPlainText
    #expect(text.contains("old output"))
    #expect(text.contains("reconnected"))
    #expect(text.contains("new prompt $"))
    #expect(!text.contains("ghost"))
  }

  @Test func withoutAFactoryADroppedLinkIsAFailure() {
    let transport = ScriptedTransport()
    let session = TerminalSession(transport: transport)
    defer { session.close() }
    transport.onConnected?()
    transport.onConnectionLost?("Connection reset by peer")
    #expect(session.connectionState == .failed("Connection reset by peer"))
    #expect(!session.canReconnect)
  }

  @Test func finalFailureAndUserExitAreNotRetriedUntilAsked() async {
    let first = ScriptedTransport()
    var made: [ScriptedTransport] = []
    let session = TerminalSession(transport: first, reconnect: {
      let transport = ScriptedTransport()
      made.append(transport)
      return transport
    })
    defer { session.close() }
    session.reconnectDelay = { _ in 0.01 }

    first.onTerminated?("Host key was rejected.")
    #expect(session.connectionState == .failed("Host key was rejected."))
    await settle()
    #expect(made.isEmpty)

    session.reconnectNow()
    #expect(session.connectionState == .reconnecting(attempt: 1))
    #expect(made.count == 1)
    made[0].onConnected?()
    #expect(session.connectionState == .connected)

    made[0].onExit?(0)
    #expect(session.connectionState == .closed)
    await settle()
    #expect(made.count == 1)

    session.reconnectNow()
    #expect(made.count == 2)
    #expect(session.connectionState == .reconnecting(attempt: 1))
  }

  @Test func closingTheSessionStopsAScheduledDial() async {
    let first = ScriptedTransport()
    var made = 0
    let session = TerminalSession(transport: first, reconnect: { made += 1; return ScriptedTransport() })
    session.reconnectDelay = { _ in 0.01 }
    first.onConnected?()
    first.onConnectionLost?("gone")
    session.close()
    await settle()
    #expect(made == 0)
    #expect(session.connectionState == .reconnecting(attempt: 1))
  }

  @Test func defaultDelayBacksOffToFiveSeconds() {
    #expect(TerminalSession.defaultReconnectDelay(attempt: 1) == 1)
    #expect(TerminalSession.defaultReconnectDelay(attempt: 3) == 3)
    #expect(TerminalSession.defaultReconnectDelay(attempt: 4) == 5)
    #expect(TerminalSession.defaultReconnectDelay(attempt: 100) == 5)
  }
}
