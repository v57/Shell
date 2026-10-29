import Foundation
import Observation
import SwiftUI

/// Persists saved web sessions in UserDefaults (same pattern as
/// ActionsStore — web sessions carry no secrets, so plain JSON is fine).
/// @Observable so the sidebar live-updates on add/edit/remove — a store that
/// re-reads UserDefaults on every access can't notify SwiftUI when `remove`
/// is called from a context menu.
@MainActor
@Observable
final class WebSessionStore {
  private static let key = "webSessions"
  private let defaults: UserDefaults

  /// All saved web sessions in creation order.
  private(set) var all: [WebSession] = []

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    reload()
  }

  private func reload() {
    guard let data = defaults.data(forKey: Self.key) else { all = []; return }
    all = (try? JSONDecoder().decode([WebSession].self, from: data)) ?? []
  }

  /// Inserts or replaces the session with the same id (sidebar save keeps
  /// the row's identity), then persists.
  func save(_ web: WebSession) {
    if let index = all.firstIndex(where: { $0.id == web.id }) {
      all[index] = web
    } else {
      all.append(web)
    }
    persist()
  }

  func remove(_ id: UUID) {
    all.removeAll { $0.id == id }
    persist()
  }

  /// Reorders the whole saved list to `list` (drag-to-reorder) and persists.
  func reorder(_ list: [WebSession]) {
    all = list
    persist()
  }

  private func persist() {
    if let data = try? JSONEncoder().encode(all) {
      defaults.set(data, forKey: Self.key)
    }
  }
}
