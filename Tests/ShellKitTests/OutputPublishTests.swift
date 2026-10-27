import Foundation
import Testing
@testable import ShellKit

/// The coalescing timer must not lose output that was still on the parse
/// queue when it fired: a prompt arriving right after a burst of output
/// shows without another keystroke.
@MainActor
struct OutputPublishTests {
  @Test func lastChunkIsPublishedAfterABurst() {
    let transport = OutputStubTransport()
    let session = TerminalSession(transport: transport)
    defer { session.close() }

    for round in 0..<5 {
      // Long enough to still be parsing when the first tick fires.
      let burst = (0..<20_000).map { "line \(round)-\($0) " + String(repeating: "x", count: 50) }.joined(separator: "\r\n")
      transport.onOutput?(Data((burst + "\r\n").utf8))
      let prompt = "prompt-\(round) % "
      transport.onOutput?(Data(prompt.utf8))

      let deadline = Date(timeIntervalSinceNow: 5)
      var shown = false
      while !shown, Date() < deadline {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        shown = session.snapshot.plainText.contains("prompt-\(round) %")
      }
      #expect(shown, "round \(round)")
    }
  }
}

@MainActor
private final class OutputStubTransport: TerminalTransport {
  var onOutput: ((Data) -> Void)?
  var onConnected: (() -> Void)?
  var onTerminated: ((String) -> Void)?
  var onExit: ((Int32) -> Void)?

  func start() { onConnected?() }
  func write(_ data: Data) {}
  func resize(columns: Int, rows: Int) {}
  func close() {}
}
