import SwiftUI
import UniformTypeIdentifiers

// TerminalView: the terminal screen. The host-key and password prompts it
// raises (`TerminalSession.hostKeyPrompt`, `.passwordPrompt`) are the app's to
// present (Shell's `terminalPrompts(_:)`, as kit overlays).

public struct TerminalView: View {
  @Bindable public var session: TerminalSession

  public init(session: TerminalSession) {
    self.session = session
  }
  
  public var body: some View {
    TerminalScreenView(session: session)
  }
}

