import CodeHighlighting
import Foundation
import Observation
import ShellKit

/// A file from the Files panel open in the iPhone and iPad's editor (`RemoteFileEditor`): there's no desktop on the
/// host to `open` it on, so it is read and saved over SFTP on an SSH login of the session's host, which stays open
/// while the editor is.
///
/// The first `maxBytes` are read. A text file that fits is editable; a longer one, one whose bytes aren't UTF-8 (so
/// they wouldn't come back the same) or one that isn't text is shown read-only with a note. A save writes a hidden
/// file beside the original and renames it into place, after checking the file's size and modification time are
/// still the ones it was read with (`SaveProblem.changedOnHost` otherwise).
@MainActor @Observable final class RemoteFileDocument: Identifiable {
  /// How much of a file is read; a longer one opens read-only.
  static let maxBytes = 512 * 1024
  static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn"]

  enum SaveProblem: Equatable {
    /// The host changed the file since it was read: Save Anyway replaces it.
    case changedOnHost
    /// The file is gone from the host: Save Anyway writes it again.
    case removedFromHost
    case failed(String)
  }

  let id = UUID()
  let name: String
  /// The file on the host, links resolved: what a save replaces.
  let path: String
  /// The language the colors come from (`Language.detect`), nil for plain text.
  let language: LanguageSpec?
  let isMarkdown: Bool
  /// False for a file that isn't text: nothing is shown.
  let isText: Bool
  /// Why the file is read-only, nil when it can be edited and saved.
  let notice: String?
  /// The text as it was read (Markdown's editor takes it once, when it is made).
  let loadedText: String
  /// The text being edited.
  private(set) var text: String
  /// The text was edited since it was read or saved.
  private(set) var isEdited = false
  private(set) var isSaving = false
  var saveProblem: SaveProblem?

  var isEditable: Bool { notice == nil }

  @ObservationIgnored private var stamp: RemoteFileStamp
  @ObservationIgnored private let config: SSHConfig
  @ObservationIgnored private var session: SSHSession?

  /// Logs in to `config`'s host and reads the file at `path`.
  static func open(path: String, name: String, config: SSHConfig) async throws -> RemoteFileDocument {
    let session = try await connect(config)
    do {
      let contents = try await session.readFileForEditing(remotePath: path, maxBytes: maxBytes)
      return RemoteFileDocument(name: name, contents: contents, config: config, session: session)
    } catch {
      session.close()
      throw error
    }
  }

  init(name: String, contents: RemoteFileContents, config: SSHConfig, session: SSHSession?) {
    self.name = name
    path = contents.path
    stamp = contents.stamp
    self.config = config
    self.session = session
    isMarkdown = Self.markdownExtensions.contains((contents.path as NSString).pathExtension.lowercased())
    let decoded = Self.decode(contents.data, isTruncated: contents.isTruncated)
    isText = decoded.isText
    text = decoded.text
    loadedText = decoded.text
    if !decoded.isText {
      notice = String(localized: "This file isn’t text, so it can’t be shown here.")
    } else if contents.isTruncated {
      notice = String(localized: "Showing the first \(Self.maxBytes / 1024) KB: a longer file opens read-only.")
    } else if !decoded.isExact {
      notice = String(localized: "This file isn’t UTF-8 text, so it opens read-only.")
    } else {
      notice = nil
    }
    let firstLine = String(decoded.text.prefix(while: { $0 != "\n" && $0 != "\r\n" }))
    language = isMarkdown ? nil : Language.detect(url: URL(fileURLWithPath: contents.path), firstLine: firstLine)
  }

  /// The bytes as text. `isExact` when they are UTF-8 that comes back byte for byte (a byte-order mark and CRLF line
  /// ends included), the condition for saving; a file cut at `maxBytes` drops the character cut in two.
  static func decode(_ data: Data, isTruncated: Bool) -> (text: String, isText: Bool, isExact: Bool) {
    if data.contains(0) { return ("", false, false) }
    var bytes = data
    if isTruncated {
      // The last character may be cut: drop up to three bytes of an incomplete UTF-8 sequence.
      for cut in 0...3 where cut < data.count {
        let candidate = data.dropLast(cut)
        if Data(String(decoding: candidate, as: UTF8.self).utf8) == candidate {
          bytes = Data(candidate)
          break
        }
      }
    }
    let text = String(decoding: bytes, as: UTF8.self)
    return (text, true, Data(text.utf8) == bytes)
  }

  /// An edit in the editor.
  func edit(_ newText: String) {
    text = newText
    isEdited = true
  }

  /// Saves the text over the host's file; `overwriting` skips the check that the host didn't change it. Returns
  /// whether it was saved; a problem is in `saveProblem`.
  @discardableResult
  func save(overwriting: Bool = false) async -> Bool {
    guard isEditable, !isSaving else { return false }
    isSaving = true
    defer { isSaving = false }
    let saved = text
    let data = Data(saved.utf8)
    let expected = overwriting ? nil : stamp
    do {
      stamp = try await withSession { session in
        try await session.saveEditedFile(data, to: self.path, expecting: expected)
      }
      if text == saved { isEdited = false }
      saveProblem = nil
      return true
    } catch RemoteFileError.changedOnHost {
      saveProblem = .changedOnHost
    } catch RemoteFileError.removedFromHost {
      saveProblem = .removedFromHost
    } catch {
      saveProblem = .failed(error.localizedDescription)
    }
    return false
  }

  /// Runs `body` on the editor's login, logging in again when it closed (the phone slept, the network changed):
  /// only a login that sent nothing is retried.
  private func withSession<T>(_ body: (SSHSession) async throws -> T) async throws -> T {
    if let session {
      do {
        return try await body(session)
      } catch RemoteFileError.notConnected {
        session.close()
        self.session = nil
      }
    }
    let fresh = try await Self.connect(config)
    session = fresh
    return try await body(fresh)
  }

  /// A login for SFTP alone, answered as the Files panel's commands are (`SSHCommandRunner`): a saved password
  /// silently, and a host key Shell doesn't know yet is refused, as the terminal asks about it.
  private static func connect(_ config: SSHConfig) async throws -> SSHSession {
    let session = SSHSession(config: config, forwardingOnly: true)
    session.onHostKeyPrompt = { $0.respond(false) }
    session.onPasswordPrompt = { prompt in
      prompt.respond((try? SSHKeychain.loadPassword(account: config.passwordAccount)) ?? nil, false)
    }
    do {
      try await session.connectAndWait()
    } catch {
      session.close()
      throw error
    }
    return session
  }

  /// Closes the editor's login.
  func close() {
    session?.close()
    session = nil
  }
}
