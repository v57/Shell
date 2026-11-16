# ShellKit

ShellKit is Shell's terminal as a library: an xterm-compatible output parser, a terminal session that owns the
screen state, a SwiftUI view that draws it and takes input, and two transports: a local pseudo-terminal and SSH on
libssh2. Any byte-oriented transport can back a session through the `TerminalTransport` protocol.

## Purpose

ShellKit is the terminal in Shell, and in any app that wants one. It is not a full terminal app: tabs, the sidebar,
saved hosts, actions, history and settings live in Shell's app (`App/Sources/ShellApp`). The host-key and password
questions an SSH session raises are yours to present.

It also holds the folder sync behind Shell's sync actions: a dry run, then uploads and deletions over SFTP on Shell's
own SSH login.

## Platforms

<!-- platforms: macos ios=partial linux windows=partial -->

- **macOS:** everything. Local terminals use `forkpty` and run zsh; the SSH key is the device's Secure Enclave key.
- **iOS, iPadOS:** SSH only. There is no local pseudo-terminal, so `LocalPTYTransport` and `TerminalSession(session:)`
  aren't available.
- **Linux:** local terminals use `forkpty` and run the user's login shell (`$SHELL`, else bash); SSH works.
- **Windows:** local terminals run PowerShell 7 (else Windows PowerShell) in a pseudo console (ConPTY), and
  `command(_:in:)` runs through cmd. `LocalPTYTransport`'s initializer has no `startSize` there. SSH uses libssh2 on
  WinCNG. A local terminal's current directory isn't read yet, and screen, tmux and `session` don't exist there
  (`.tmux(_:)` and `.session(_:in:startSize:)` return nil).
- **Android:** not yet.

libssh2 comes from Database's `Libssh2` product, which re-exports the [SSH](https://github.com/v57/SSH) repository's
(see SSH's [Libssh2 page](https://github.com/v57/SSH/blob/main/docs/Libssh2.md)), so an app has one copy. On Linux and
Windows, CryptoKit and SwiftUI come from v57/SwiftUI's stand-ins.

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

A local shell in a SwiftUI view (macOS, Linux, Windows; `.zsh` is the platform's default shell):

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
  `close()`, `clearStdout()`. `currentDirectory` (local) and `remoteCurrentDirectory` (SSH, refreshed with
  `refreshRemoteDirectory(command:)`: with no command, `remoteDirectoryScript` finds the terminal's shell on the host
  and reads its folder, so it follows `cd`). `reconnectNow()` and `canReconnect`; `sshTransport` and `folderSync` give the
  session's transport when it is one of those.
- Handlers: `exitHandler`, `commandSubmittedHandler`, `snapshotUpdateHandler`, `actionCompletionHandler`.
- `TerminalView(session:)`: the screen, with selection, scrolling and keyboard input. Its drawing is
  `TerminalScreenView`, which has no public initializer; it exposes `defaultFontSize` (14) and `metrics(ofSize:)`.
- Environment values: `terminalFontSize`, `terminalBackgroundsDisabled` (no character backgrounds, low-contrast text
  in the default colour) and `terminalAnimationsEnabled` (typed-out output and a gliding cursor; off by default).
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
  (the local shell as a login shell), `.zsh(in:startSize:)`, `.command(_:in:)`, `.screen(_:)`, `.tmux(_:)` (nil when
  tmux isn't installed) and `.session(_:in:startSize:)` (v57's `session` tool; nil when it isn't installed). The child
  always gets `TERM=xterm-256color`.
- `SSHSession(config:execCommand:forwardingOnly:unattended:)`: SSH on libssh2. Once connected:
  `runCommand(_:completion:)` (a `RemoteCommandResult`), `downloadFile(remotePath:)`,
  `uploadFile(localURL:remotePath:)`, `remoteHomeDirectory()`,
  `startLocalPortForward(bindHost:bindPort:targetHost:targetPort:completion:)` and `stopLocalPortForward()`, and
  `dialer`: a WireKit `WireDialer` whose connections are SSH channels of this login, with no local port. Shell runs
  Database's engines over it. `SSHSession.connect(config:)` opens a login without a shell, for a batch of file
  transfers.
- `SSHConfig(id:name:host:fallbacks:automaticFallbacks:user:port:authMethod:savePassword:recordID:)`: `host`,
  `fallbacks` (other addresses tried in order), `automaticFallbacks` (the vault's other ways to one of your own devices,
  such as its Hub Network address; never saved), `user` (your user name by default), `port` (22), `authMethod`
  (`.keychainKey` or `.password`), `savePassword`, and `recordID` (the shared record's id when another app made the host).
- `SSHKeychain`: this device's SSH key (`loadOrCreateDefaultKey()`, shared with the other v57 apps through
  VaultKit's `VaultIdentity`), its `authorized_keys` line (`publicKeyOpenSSHLine(for:comment:)`) and fingerprint,
  and saved passwords (`savePassword(_:account:)`, `loadPassword(account:)`, `deletePassword(account:)`).

### Folder sync

- `FolderSyncSettings(localPath:remotePath:deletesRemovedFiles:excludes:)`, with `defaultExcludes` (`[".*"]`).
- `FolderSyncTransport(config:settings:script:)`: a `TerminalTransport` that runs one sync as a session. It lists both
  folders, shows the plan and waits (`phase`: `connecting`, `preparing`, `awaitingConfirmation`, `applying`,
  `runningScript`, `finished`, `failed`, `cancelled`); `apply()` makes the changes and `cancel()` stops. Return or `y`
  typed into the session applies, `n`, Escape or Ctrl+C cancels. `plan`, `progress` and `result` follow along, and
  `script` runs on the host after a clean sync. For tests, `init(destination:settings:script:connect:makeScriptTransport:)`
  takes your own `FolderSyncRemote`.
- `FolderSyncEngine(settings:remote:)`: `prepare(status:)` (a `FolderSyncPreparation` with the `FolderSyncPlan`) and
  `apply(…)`. `FolderSyncPlanner`, `FolderSyncExcludes` and `FolderSyncPath` (`checkedRemoteRoot(_:deletes:)` refuses
  `/`, an empty path, `..` and, while deleting, the login folder) are the pure parts.
- `FolderSyncRemote`: the host side (listing, hashing with `sha256sum` or `shasum`, uploads, renames, deletions).
  A connected `SSHSession`'s `folderSyncRemote` is one, on SFTP.

### Host keys

Accepted host keys are kept in the shared vault, so a server trusted in Shell is trusted in Database too. A changed
host key is reported with the old fingerprint (`previousFingerprint`), never accepted silently.

## Testing

```bash
swift test --filter ShellKitTests
```

Most tests are pure (the parser, screen switches, prompt markers, reconnect timing with fake transports). Three
integration suites need a real server and are skipped without one:

- `SSHChannelStreamIntegrationTests` (a client over an SSH channel): an sshd that reaches Redis on its own
  `127.0.0.1:6379`, named by `SHELL_SSH_CHANNEL_TEST_PORT`, `SHELL_SSH_CHANNEL_TEST_KEYS` (an authorized-keys file the
  test may write) and optionally `SHELL_SSH_CHANNEL_TEST_USER`. It needs a Secure Enclave.
- `FolderSyncIntegrationTests` (a sync over Shell's own SSH login): a user-level sshd on this machine, named by
  `SHELL_SSH_SYNC_TEST_PORT`, `SHELL_SSH_SYNC_TEST_KEYS`, `SHELL_SSH_SYNC_TEST_DIR` (a scratch folder it may delete
  in) and optionally `SHELL_SSH_SYNC_TEST_USER`. It needs a Secure Enclave. Never point it at a real server.
- `SSHReconnectIntegrationTests` (reboots the host from inside a session): a disposable host with password login and
  passwordless sudo, such as a colima VM, named by `SHELL_SSH_TEST_PORT`, `SHELL_SSH_TEST_USER`,
  `SHELL_SSH_TEST_PASSWORD` and optionally `SHELL_SSH_TEST_HOST`. See the header of
  `Tests/ShellKitTests/SSHReconnectIntegrationTests.swift`.

For tests of your own, a session takes any `TerminalTransport`, so a small fake that records `write(_:)` and calls
`onOutput` drives a `TerminalSession` without a process or network.

## Related

- [ShellIntegrations](ShellIntegrations.md): file commands, persistent sessions and smart actions on top of a
  session.
- [ShellMonitoring](ShellMonitoring.md): the CPU, GPU and power numbers in Shell's sidebar.
- SSH's [SSHKit](https://github.com/v57/SSH/blob/main/docs/SSHKit.md) and Database's
  [SSHTunnel](https://github.com/v57/Database/blob/main/docs/SSHTunnel.md): the SSH layers ShellKit sits on.
- [Vault](https://github.com/v57/Vault/blob/main/docs/README.md): the device key, saved passwords and known hosts.
- Shell's guide: [Terminal](Terminal.md) and [SSH Connections](SSH-Connections.md).
