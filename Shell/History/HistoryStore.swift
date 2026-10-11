import Foundation
import Observation

struct SubmittedCommand: Identifiable, Codable, Hashable {
  let id: UUID
  let text: String
  let submittedAt: Date

  init(id: UUID = UUID(), text: String, submittedAt: Date = Date()) {
    self.id = id
    self.text = text
    self.submittedAt = submittedAt
  }
}

struct HistorySession: Identifiable, Codable, Hashable {
  let id: UUID
  let commands: [SubmittedCommand]
  let output: String
  let archivedAt: Date

  var title: String {
    guard let command = commands.last?.text else { return "Local Session" }
    let oneLine = command
      .replacingOccurrences(of: "\r\n", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
      .trimmingCharacters(in: .whitespaces)
    return oneLine.isEmpty ? "Local Session" : oneLine
  }

  var activityDate: Date { commands.last?.submittedAt ?? archivedAt }
}

@MainActor
@Observable
final class HistoryStore {
  private(set) var sessions: [HistorySession] = []
  var storageError: String?

  private let fileURL: URL
  /// The history file exists but couldn't be read (keychain locked, file
  /// damaged). Saving must not replace it with only this run's sessions.
  private var loadFailed = false

  init(fileURL: URL? = nil) {
    self.fileURL = fileURL ?? Self.defaultFileURL()
    load()
  }

  func archive(_ session: HistorySession) {
    guard !session.commands.isEmpty else { return }
    sessions.removeAll { $0.id == session.id }
    sessions.append(session)
    sessions.sort { $0.activityDate > $1.activityDate }
  }

  func remove(_ id: UUID) {
    sessions.removeAll { $0.id == id }
    persist()
  }

  func removeAll() {
    sessions.removeAll()
    loadFailed = false
    do {
      if FileManager.default.fileExists(atPath: fileURL.path) {
        try FileManager.default.removeItem(at: fileURL)
      }
      storageError = nil
    } catch {
      storageError = error.localizedDescription
      NSLog("HistoryStore: could not remove history: \(error)")
    }
  }

  func flush() {
    persist()
  }

  private func load() {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
    do {
      sessions = try readSessions().sorted { $0.activityDate > $1.activityDate }
      loadFailed = false
      storageError = nil
    } catch {
      loadFailed = true
      storageError = error.localizedDescription
      NSLog("HistoryStore: could not load history: \(error)")
    }
  }

  private func readSessions() throws -> [HistorySession] {
    let data = try SecureFileStore.read(from: fileURL, domain: .history)
    return try JSONDecoder().decode([HistorySession].self, from: data)
  }

  private func persist() {
    if loadFailed {
      // Merge in the history that failed to load, or leave the file alone
      // until it can be read.
      guard let earlier = try? readSessions() else { return }
      let ids = Set(sessions.map(\.id))
      sessions = (sessions + earlier.filter { !ids.contains($0.id) })
        .sorted { $0.activityDate > $1.activityDate }
      loadFailed = false
    }
    do {
      if sessions.isEmpty {
        if FileManager.default.fileExists(atPath: fileURL.path) {
          try FileManager.default.removeItem(at: fileURL)
        }
      } else {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try SecureFileStore.write(
          try encoder.encode(sessions),
          to: fileURL,
          domain: .history
        )
      }
      storageError = nil
    } catch {
      storageError = error.localizedDescription
      NSLog("HistoryStore: could not save history: \(error)")
    }
  }

  static func defaultFileURL() -> URL {
    let support = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first!
    let bundleID = Bundle.main.bundleIdentifier ?? "Shell"
    return support
      .appendingPathComponent(bundleID, isDirectory: true)
      .appendingPathComponent("History", isDirectory: true)
      .appendingPathComponent("history.shellhistory")
  }
}
