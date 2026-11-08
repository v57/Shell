# ShellKit

ShellKit is Shell's terminal as a library: an xterm-compatible output parser, a terminal session that owns the
screen state, a SwiftUI view that draws it and takes input, and two transports: a local pseudo-terminal and SSH on
libssh2. Any byte-oriented transport can back a session through the `TerminalTransport` protocol.

It is not a full terminal app. Tabs, the sidebar, saved hosts, actions, history and settings live in Shell's app
(`App/Sources/ShellApp`). The host-key and password questions an SSH session raises are yours to present.

## Getting started

```swift
// Package.swift
dependencies: [
  .package(url: "https://github.com/v57/Shell.git", branch: "main"),
],
targets: [
  .target(name: "MyApp", dependencies: [.product(name: "ShellKit", package: "Shell")]),
]
```

In the v57 checkout, `Shell-Local.xcworkspace` builds against the sibling repositories instead of GitHub's, and
SwiftPM does the same with `V57_LOCAL=1`.

A local shell in a SwiftUI view (macOS, Linux, Windows):

```swift
import ShellKit
import SwiftUI

struct TerminalWindow: View {
  @State private var session = TerminalSession(session: .zsh)

  var body: some View {
    TerminalView(session: session)
      .onDisappear { session.close() }
  }
}
```

An SSH terminal, with the host-key question answered by your interface:

```swift
let config = SSHConfig(host: "example.com", user: "user", authMethod: .keychainKey)
let session = TerminalSession(
  transport: SSHSession(config: config), startupMessage: "Connecting to example.com…",
  reconnect: { SSHSession(config: config) })

// Later, when session.hostKeyPrompt is set:
if let prompt = session.hostKeyPrompt {
  // Show prompt.fingerprint (and prompt.previousFingerprint, if the key changed), then:
  session.acceptHostKey(prompt)  // or session.rejectHostKey(prompt)
}
```

The repository's [README](../README.md#use-as-library) has more examples: screen and tmux sessions, running a
command, parsing output without a session, and a custom transport.

## Main API

### Sessions and views

- `TerminalSession` (`@Observable`): starts its transport at once and keeps the parsed `snapshot`, `connectionState`
  (`starting`, `connecting`, `connected`, `reconnecting`, `failed`, `closed`), the selection and scrollback offset,
  and the prompts (`hostKeyPrompt`, `passwordPrompt`). `init(transport:startupMessage:reconnect:)`: with a
  `reconnect` factory, a dropped link doesn't end the session; it dials again, backing off to one try every five
  seconds, and keeps the scrollback. `init(session:startupMessage:)` is the short form for local terminals.
- Input and output: `send(_:)` (text or data), `paste(_:)`, `submitCommand(_:)`,
  `handleKey(characters:charactersIgnoringModifiers:keyCode:modifierFlags:)`, `resize(columns:rows:)`,
  `close()`. `currentDirectory` (local) and `remoteCurrentDirectory` (SSH, refreshed with
  `refreshRemoteDirectory(command:)`).
- Handlers: `exitHandler`, `commandSubmittedHandler`, `snapshotUpdateHandler`, `actionCompletionHandler`.
- `TerminalView(session:)` and `TerminalScreenView`: the screen, with selection, scrolling and keyboard input. Set
  the text size with the `terminalFontSize` environment value (`TerminalScreenView.defaultFontSize` is 14).
- `TerminalHostKeyPrompt` (`host`, `port`, `fingerprint`, `previousFingerprint`, `respond`) and
  `TerminalPasswordPrompt` (`host`, `username`, `respond(password, save)`).

### Parsing

- `TerminalOutputParser(sendResponse:)`: an xterm-style parser. `consume(_:)` feeds bytes; `snapshot()` returns a
  `TerminalSnapshot` (`rows`, `columns`, `cells`, `scrollback`, `plainText`, `fullPlainText`,
  `cell(atRow:column:)`). Answers to device queries (DA1, cursor position reports) come back through
  `sendResponse`.
- `TerminalCell`, `TerminalColor`, `TerminalCursor`, `TerminalGridSize`, `TerminalPalette`, `TerminalFont`,
  `TerminalModifierFlags`, `TerminalContrast` (keeps low-contrast colours readable on the current background).
- `TerminalHistoryCapture(seed:)`: the text a session printed, for history.

### Transports

- `TerminalTransport`: `onOutput`, `onConnected`, `onTerminated`, `onExit`, `start()`, `write(_:)`,
  `resize(columns:rows:)`, `close()`. Optional: `onConnectionLost` (the session may dial again),
  `onHostKeyPrompt`, `onPasswordPrompt`, `initialGridSize` (80×24 by default), `childProcessID`,
  `foregroundProcessID`, `echoesInput`.
- `LocalPTYTransport(executable:argv:workingDirectory:startSize:)`: a child in a pseudo-terminal. Presets: `.zsh`
  (the login shell), `.zsh(in:startSize:)`, `.command(_:in:)`, `.screen(_:)`, `.tmux(_:)` (nil when tmux isn't
  installed). The child always gets `TERM=xterm-256color`.
- `SSHSession(config:execCommand:forwardingOnly:unattended:)`: SSH on libssh2. Once connected:
  `runCommand(_:completion:)` (a `RemoteCommandResult`), `downloadFile(remotePath:)`,
  `uploadFile(localURL:remotePath:)`, `remoteHomeDirectory()`,
  `startLocalPortForward(bindHost:bindPort:targetHost:targetPort:completion:)` and `stopLocalPortForward()`, and
  `dialer`: a WireKit `WireDialer` whose connections are SSH channels of this login, with no local port. Shell runs
  Database's engines over it. `SSHSession.connect(config:)` opens a login without a shell, for a batch of file
  transfers.
- `SSHConfig`: `host`, `fallbacks` (other addresses tried in order), `user`, `port`, `authMethod` (`.keychainKey`
  or `.password`), `savePassword`.
- `SSHKeychain`: this device's SSH key (`loadOrCreateDefaultKey()`, shared with the other v57 apps through
  VaultKit's `VaultIdentity`), its `authorized_keys` line (`publicKeyOpenSSHLine(for:comment:)`) and fingerprint,
  and saved passwords (`savePassword(_:account:)`, `loadPassword(account:)`, `deletePassword(account:)`).

Accepted host keys are kept in the shared vault, so a server trusted in Shell is trusted in Database too. A changed
host key is reported with the old fingerprint (`previousFingerprint`), never accepted silently.

## Platform notes

- **macOS:** everything. Local terminals use `forkpty`; the SSH key is the device's Secure Enclave key.
- **iOS, iPadOS:** SSH only. There is no local pseudo-terminal, so `LocalPTYTransport` and `TerminalSession(session:)`
  aren't available.
- **Linux:** local terminals use `forkpty` and run the user's login shell (`$SHELL`, else bash); SSH works.
- **Windows:** local terminals run PowerShell in a pseudo console (ConPTY), and `command(_:in:)` runs through cmd.
  SSH uses libssh2 on WinCNG. A local terminal's current directory isn't read yet, and screen, tmux and `session`
  don't exist there.
- **Android:** not yet.

libssh2 comes from Database's `Libssh2` product (see Database's
[SSHTunnel and Libssh2 page](https://github.com/v57/Database/blob/main/docs/SSHTunnel.md)), so an app has one copy.

## Testing

```bash
swift test --filter ShellKitTests
```

Most tests are pure (the parser, screen switches, prompt markers, reconnect timing with fake transports). Two
integration suites need a real server and are skipped without one:

- `SSHChannelStreamIntegrationTests` (a client over an SSH channel): an sshd that reaches Redis on its own
  `127.0.0.1:6379`, named by `SHELL_SSH_CHANNEL_TEST_PORT`, `SHELL_SSH_CHANNEL_TEST_KEYS` (an authorized-keys file the
  test may write) and optionally `SHELL_SSH_CHANNEL_TEST_USER`. It needs a Secure Enclave.
- `SSHReconnectIntegrationTests` (reboots the host from inside a session): a disposable host with password login and
  passwordless sudo, such as a colima VM, named by `SHELL_SSH_TEST_PORT`, `SHELL_SSH_TEST_USER`,
  `SHELL_SSH_TEST_PASSWORD` and optionally `SHELL_SSH_TEST_HOST`. See the header of
  `Tests/ShellKitTests/SSHReconnectIntegrationTests.swift`.

For tests of your own, a session takes any `TerminalTransport`, so a small fake that records `write(_:)` and calls
`onOutput` drives a `TerminalSession` without a process or network.
