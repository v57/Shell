import Foundation

/// An app the "Open With" control can launch a project/directory in.
///
/// Order matters: the first kind in a list is the primary (shown as the
/// toolbar control's label). The pure resolver only decides WHICH app kinds
/// apply for a directory — resolving the real app URL / bundle and launching
/// is done by the app (see the Shell target's `ProjectOpener`), keeping this
/// layer free of AppKit/NSWorkspace dependencies.
public enum OpenWithKind: String, CaseIterable, Hashable, Codable, Sendable {
  case xcode
  case zed
  case vscode
  case finder
}

/// Resolves which "Open With" apps apply to a directory, using the same
/// shared top-level `[DirectoryEntry]` enumeration the smart-action
/// integrations receive (see `SmartActionsCoordinator`). Pure logic — no
/// filesystem or AppKit access here.
///
/// Project classification (matches the smart-action Xcode/SwiftIntegration
/// gates):
/// - Xcode project (`.xcodeproj` / `.xcworkspace`) → Xcode + the generic apps
/// - SwiftPM package (`Package.swift`, no Xcode project) → Xcode + generic apps
/// - Anything else → just the generic editors + Finder
public enum OpenWithResolver {
  /// The generic apps offered for every directory.
  public static let genericKinds: [OpenWithKind] = [.zed, .vscode, .finder]

  public static func kinds(for files: [DirectoryEntry]) -> [OpenWithKind] {
    // `isAvailable` is irrelevant here (we're classifying a directory, not
    // checking the toolchain); `relevance` only inspects the file names.
    let hasXcodeProject = XcodeIntegration(isAvailable: true).relevance(files: files)
    let hasPackage = SwiftIntegration(isAvailable: true).relevance(files: files)
    var result: [OpenWithKind] = []
    if hasXcodeProject || hasPackage {
      result.append(.xcode)
    }
    result.append(contentsOf: genericKinds)
    return result
  }
}
