import ComponentKit
import ShellIntegrations

extension ActionKind {
  /// Whether Shell offers this kind on this system: an Export notarizes, which needs Apple's notarytool, so Linux
  /// leaves it (and the Notarization sheet) out.
  var isOfferedHere: Bool {
    #if os(Linux)
    !needsNotarization
    #else
    true
    #endif
  }
}

#if os(macOS) || os(Windows) || os(Linux)
import CodeActionsUI
import Foundation
import SwiftUI

/// What opened the Notarization sheet: a scheme's Export waiting to run, or
/// the Distribute menu's settings item (no scheme).
struct NotarizationSetupRequest: Identifiable {
  let id = UUID()
  let scheme: ActionScheme?
  let directory: URL?

  init(scheme: ActionScheme? = nil, directory: URL? = nil) {
    self.scheme = scheme
    self.directory = directory
  }
}

/// Code's Notarization sheet (CodeActionsUI) on Shell's model: it saves the
/// checked profile and runs the Export that waited for it.
struct NotarizationSheet: View {
  let request: NotarizationSetupRequest
  @Environment(AppModel.self) private var model

  var body: some View {
    NotarizationSetupView(profile: model.notaryProfile, exportsWhenDone: request.scheme != nil) { profile in
      model.notaryProfile = profile
      if let scheme = request.scheme, let directory = request.directory {
        model.runSmartAction(.export, scheme: scheme, in: directory)
      }
    }
  }
}
#endif
