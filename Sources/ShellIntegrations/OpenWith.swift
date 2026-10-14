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
  /// The v57 apps: Code (an editor), Markdown (notes and docs), Git, Dev (localization, icons, releases).
  case code
  case zed
  case vscode
  case markdown
  case git
  case dev
  case finder
}

/// Resolves which "Open With" apps apply to a directory, using the same
/// shared top-level `[DirectoryEntry]` enumeration the smart-action
/// integrations receive (see `SmartActionsCoordinator`). Pure logic — no
/// filesystem or AppKit access here.
///
/// Project classification (matches the smart-action Xcode/SwiftIntegration
/// gates):
/// - Xcode project (`.xcodeproj` / `.xcworkspace`) or SwiftPM package
///   (`Package.swift`) → Xcode, and Dev (localization, icons, releases)
/// - Markdown files at the top → Markdown
/// - A git repository (`.git`) → Git
/// - Every directory → the editors (Code, Zed, VS Code) and Finder
public enum OpenWithResolver {
  /// The editors offered for every directory.
  public static let editorKinds: [OpenWithKind] = [.code, .zed, .vscode]
  /// The generic apps offered for every directory.
  public static let genericKinds: [OpenWithKind] = editorKinds + [.finder]

  /// - Parameter isRepository: whether the directory holds `.git` (the listing skips dotfiles).
  public static func kinds(for files: [DirectoryEntry], isRepository: Bool = false) -> [OpenWithKind] {
    // `isAvailable` is irrelevant here (we're classifying a directory, not
    // checking the toolchain); `relevance` only inspects the file names.
    let hasXcodeProject = XcodeIntegration(isAvailable: true).relevance(files: files)
    let hasPackage = SwiftIntegration(isAvailable: true).relevance(files: files)
    let isApple = hasXcodeProject || hasPackage
    let hasMarkdown = files.contains { !$0.isDirectory && ["md", "markdown"].contains(($0.name as NSString).pathExtension.lowercased()) }
    var result: [OpenWithKind] = []
    if isApple { result.append(.xcode) }
    result.append(contentsOf: editorKinds)
    if hasMarkdown { result.append(.markdown) }
    if isRepository { result.append(.git) }
    if isApple { result.append(.dev) }
    result.append(.finder)
    return result
  }
}
