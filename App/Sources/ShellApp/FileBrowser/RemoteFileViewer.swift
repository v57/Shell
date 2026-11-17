import CodeHighlighting
import ComponentKit
import SwiftUI

/// A file the Files panel read for the read-only viewer: its first `maxBytes` as text, with Code's syntax tokens.
struct ViewedFile: Identifiable {
  /// How much of a file the viewer reads; a longer one shows its start with a note.
  static let maxBytes = 512 * 1024

  /// A line of the file and its tokens, in UTF-16 offsets from the line's start.
  struct Line {
    let text: String
    let tokens: [CodeToken]
  }

  let id = UUID()
  let name: String
  let path: String
  /// The text's lines, or empty for a file that isn't text.
  let lines: [Line]
  /// The language the colors come from (`Language.detect`), nil for plain text.
  let language: String?
  /// Why the viewer shows less than the whole file, if it does.
  let notice: String?

  init(name: String, path: String, output: String) {
    self.name = name
    self.path = path
    if output.contains("\u{0}") || output.contains("\u{FFFD}") {
      lines = []
      language = nil
      notice = String(localized: "This file isn’t text, so it can’t be shown here.")
      return
    }
    var text = output
    let truncated = text.utf8.count > Self.maxBytes
    if truncated { text = String(decoding: text.utf8.prefix(Self.maxBytes), as: UTF8.self) }
    if text.hasSuffix("\n") { text.removeLast() }
    notice = truncated ? String(localized: "Showing the first \(Self.maxBytes / 1024) KB.") : nil
    let firstLine = text.prefix(while: { $0 != "\n" })
    let spec = Language.detect(url: URL(fileURLWithPath: path), firstLine: String(firstLine))
    language = spec?.name
    lines = text.isEmpty ? [] : Self.split(text, tokens: spec.map { spec in
      var scanner = CodeScanner(code: text, spec: spec)
      return scanner.scan()
    } ?? [])
  }

  /// Cuts the text into lines and each token into the lines it covers (a block comment spans several).
  private static func split(_ text: String, tokens: [CodeToken]) -> [Line] {
    let string = text as NSString
    var lines: [Line] = []
    var start = 0
    var next = 0
    let sorted = tokens.sorted { $0.range.location < $1.range.location }
    while start <= string.length {
      var end = 0
      var contentsEnd = 0
      string.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: start, length: 0))
      let lineRange = NSRange(location: start, length: contentsEnd - start)
      // Skip tokens that ended before this line; keep the scan index at the first one that might reach it.
      while next < sorted.count, NSMaxRange(sorted[next].range) <= start, sorted[next].range.length > 0 {
        next += 1
      }
      var lineTokens: [CodeToken] = []
      var index = next
      while index < sorted.count, sorted[index].range.location < NSMaxRange(lineRange) {
        let clipped = NSIntersectionRange(sorted[index].range, lineRange)
        if clipped.length > 0 {
          lineTokens.append(
            CodeToken(range: NSRange(location: clipped.location - start, length: clipped.length), kind: sorted[index].kind))
        }
        index += 1
      }
      lines.append(Line(text: string.substring(with: lineRange), tokens: lineTokens))
      if end >= string.length { break }
      start = end
    }
    return lines
  }
}

/// The iPhone and iPad's viewer for a file in the Files panel: the host has no screen to `open` it on, so its text is
/// shown here, read-only, in Code's syntax colors (`CodeHighlighting`, as in Markdown's code blocks).
struct RemoteFileViewer: View {
  let file: ViewedFile
  @Environment(\.kitDismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let scheme = CodeColorScheme.systemAware(isDark: colorScheme == .dark)
    KitSheet(
      title: file.name, meta: file.language.map { "\(file.path) · \($0)" } ?? file.path, systemImage: "doc.text",
      hue: .blue, width: nil
    ) {
      VStack(alignment: .leading, spacing: 8) {
        if let notice = file.notice {
          Text(notice).font(.footnote).foregroundStyle(.secondary)
        }
        if file.lines.isEmpty, file.notice == nil {
          Text("This file is empty.").font(.footnote).foregroundStyle(.secondary)
        }
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(file.lines.indices, id: \.self) { index in
            Text(Self.attributed(file.lines[index], scheme: scheme))
              .font(.system(.footnote, design: .monospaced))
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .textSelection(.enabled)
      }
    } footer: {
      Button("Done") { dismiss() }
        .buttonStyle(.kitPrimary)
        .keyboardShortcut(.defaultAction)
    }
  }

  private static func attributed(_ line: ViewedFile.Line, scheme: CodeColorScheme) -> AttributedString {
    var text = AttributedString(line.text.isEmpty ? " " : line.text)
    text.foregroundColor = color(scheme.plainText)
    guard !line.text.isEmpty else { return text }
    for token in line.tokens {
      guard let range = Range(token.range, in: text) else { continue }
      text[range].foregroundColor = color(scheme.color(for: token.kind))
    }
    return text
  }

  private static func color(_ rgb: UInt32) -> Color {
    Color(
      red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
  }
}
