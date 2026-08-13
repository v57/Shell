# Shell
Modern terminal for your needs. Pure SwiftUI, no electron-type bullshit

- View status in the sidebar
- Persistent sessions using `screen` or `tmux`
- Built in SSH, keys stored in secure enclave
- Device-bound encrypted quick notes (per-note iCloud option: a note can
  live in iCloud Drive, encrypted with a key stored in iCloud Keychain)
- Encrypted local session history with replay
- Quick actions `cmd + r`

## Platforms
One SwiftUI app target builds for both macOS and iOS (iOS 18+):

- **macOS** — everything: local zsh terminals, persistent `screen`/`tmux`
  sessions, SSH, notes, actions, history.
- **iOS** — SSH and notes only. There is no local terminal (forkpty is
  macOS-only), so the Local and Persistent sidebar sections are hidden and
  local-only actions are filtered out.

The `Terminal` library is cross-platform; the local-pty pieces
(`LocalPTYTransport` + its `.zsh`/`.tmux`/`.screen` presets) are compiled
only on macOS.

## Notes storage
Each note is stored in one of two encrypted homes, chosen per note with the
cloud button in the note editor's toolbar (iCloud notes show a cloud badge
in the sidebar):

- **Local** (default): `~/Library/Application Support/<bundle id>/Notes/`,
  encrypted with the device-bound Secure Enclave key.
- **iCloud**: the app's iCloud Drive container (`ShellNotes/` subfolder),
  encrypted with a 256-bit key stored in **iCloud Keychain** — every device
  signed into the same Apple Account can open the same notes. Requires the
  iCloud Documents capability (enabled in `Shell.entitlements`).

## Use as library
**Local terminal (forkpty, macOS only):** use the `LocalPTYTransport`
presets — `.zsh` for an interactive login shell, `.screen(name)` /
`.tmux(name)` to attach to a persistent multiplexer session:
```swift
import Terminal

// Interactive zsh login shell — the default local terminal.
let session = TerminalSession(session: .zsh)

// Attach to a named GNU screen session (screen ships with macOS).
let screenSession = TerminalSession(session: .screen("work"))

// Attach to a named tmux session. tmux has no fixed macOS location, so
// the preset resolves the binary (Homebrew paths, then PATH) and is nil
// when tmux isn't installed — fall back to screen:
let transport = LocalPTYTransport.tmux("work") ?? .screen("work")
let tmuxSession = TerminalSession(session: transport)

// The presets are plain LocalPTYTransports — build your own for anything
// else (e.g. running a command: zsh -lc):
let execSession = TerminalSession(transport: LocalPTYTransport(
  executable: "/bin/zsh", argv: ["zsh", "-lc", "make && make test"]
))
```

**SSH terminal:**
```swift
let config = SSHConfig(host: "example.com", user: "me", authMethod: .keychainKey)
let session = TerminalSession(
  transport: SSHSession(config: config),
  startupMessage: "Connecting to example.com…"
)
```

**Render it in SwiftUI:**
```swift
TerminalView(session: session)
```

**Parse raw terminal output without a session** (device-query answers come back through `sendResponse`):
```swift
let parser = TerminalOutputParser { response in
  // e.g. "\u{1b}[?1;2c" (DA1), cursor position reports (CPR)
  print(response)
}
parser.consume(Data("ls\r\n\u{1b}[1;32mfile.txt\u{1b}[0m".utf8))
let snapshot = parser.snapshot()
print(snapshot.plainText)        // "ls" / "file.txt"
print(snapshot.fullPlainText)    // scrollback + current rendered screen
print(snapshot.cell(atRow: 1, column: 0).foreground)  // .ansi(2)
```

**Custom transport** — implement `TerminalTransport` to back a session with anything byte-oriented:
```swift
final class SerialTransport: TerminalTransport {
  var onOutput: ((Data) -> Void)?
  var onConnected: (() -> Void)?
  var onTerminated: ((String) -> Void)?
  var onExit: ((Int32) -> Void)?

  func start() { /* open device; call onConnected() when ready */ }
  func write(_ data: Data) { /* send bytes */ }
  func resize(columns: Int, rows: Int) { /* update device size */ }
  func close() { /* release */ }
}
```

## Keyboard shortcuts

| Keys | Action |
| --- | --- |
| ⌘N | New terminal in the current section (new note when a note is focused) |
| ⌘⇧N | New SSH connection… |
| ⌘W | Close the selected terminal (quits persistent sessions) |
| ⌘R | Actions overlay |
| ⌘⇧R | Create an action from the current session's submitted commands |
| ⌘⇧C | Copy SSH public key |
| ⌘C / ⌘V | Copy selection (or visible buffer) / paste |

## Notes
- The terminal's child environment always gets `TERM=xterm-256color` (inherited terminfo variables are stripped) so curses apps like vim/nano behave.
- SSH identity keys are Secure Enclave P-256 keys: device-bound, no export, no backup — install their public keys (`⌘⇧C`) on the servers you connect to.
- Notes and local history use domain-separated AES-256-GCM keys derived through a device-bound Secure Enclave P-256 agreement key. They are available only while the device is unlocked.
- Run a normally code-signed build: the data-protection Keychain requires Shell's Keychain Sharing entitlement, so an app built with `CODE_SIGNING_ALLOWED=NO` cannot save encrypted notes or history.
- Touch ID per-sign gating is intentionally not used (the Secure Enclave ACL can't be satisfied by swift-nio-ssh's signing path on this OS); the "sensitive" tier is a second, separate key instead.
