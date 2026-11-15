import Foundation
import Testing
@testable import ShellKit

/// A command that prints far more than the scrollback keeps (`seq 1 300000`)
/// must parse in time linear in its output: trimming the scrollback's head
/// one line at a time made every line past the limit shift 10,000 rows, and
/// the main thread waited on that parse backlog in `resize`.
struct TerminalScrollbackSpeedTests {
  private func output(lines: Int) -> Data {
    var text = ""
    text.reserveCapacity(lines * 8)
    for i in 1...lines { text += "\(i)\r\n" }
    return Data(text.utf8)
  }

  private func parseSeconds(lines: Int) -> Double {
    let parser = TerminalOutputParser(sendResponse: { _ in })
    parser.resize(columns: 80, rows: 24)
    let data = output(lines: lines)
    let start = Date()
    var offset = 0
    while offset < data.count { // in pipe-sized chunks, as the PTY delivers it
      let end = min(offset + 65_536, data.count)
      parser.consume(data[offset..<end])
      offset = end
    }
    return Date().timeIntervalSince(start)
  }

  @Test func parsingPastTheScrollbackLimitTakesLinearTime() {
    let limit = TerminalGrid.scrollbackLimit
    let small = parseSeconds(lines: limit + 20_000)
    let large = parseSeconds(lines: limit + 80_000)
    print("scrollback parse: \(limit + 20_000) lines \(small) s, \(limit + 80_000) lines \(large) s")
    #expect(large < small * 6)
  }

  @Test func scrollbackKeepsTheNewestLinesWithinTheLimit() {
    let parser = TerminalOutputParser(sendResponse: { _ in })
    parser.resize(columns: 80, rows: 24)
    let lines = TerminalGrid.scrollbackLimit * 2 + 1_234
    parser.consume(output(lines: lines))
    let s = parser.snapshot()
    #expect(s.scrollback.count >= TerminalGrid.scrollbackLimit)
    #expect(s.scrollback.count <= TerminalGrid.scrollbackLimit + TerminalGrid.scrollbackSlack)
    let last = String(s.scrollback.last!.map(\.character))
    #expect(last == "\(lines - 23)")
    #expect(s.scrolledLineCount == lines - 23)
  }
}
