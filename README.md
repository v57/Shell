# Shell
Modern terminal for your needs. Pure SwiftUI, no electron-type bullshit

- View status in the sidebar
- Persistent sessions using `screen` or `tmux`
- Built in SSH, keys stored in secure enclave, saved connections synced
  through iCloud (encrypted) and shared with Database
- Database connections for PostgreSQL, MySQL, MariaDB, SQL Server, SQLite,
  MongoDB, Redis, Cassandra and ScyllaDB, attached to the SSH host they run on
- Authorized-keys manager: add or remove keys on any server's
  `~/.ssh/authorized_keys` (local or over SSH), with every device's public
  key published through iCloud
- Notes shared with the Markdown app, synced through iCloud, kept as files by
  Markdown (encrypted per note)
- Open the current folder in Code, Markdown, Git or Dev
- Encrypted local session history with replay
- Quick actions `cmd + r`

## Platforms
One SwiftUI app target builds for both macOS 14+ (Apple silicon) and iOS 17+:

- **macOS** — everything: local zsh terminals, persistent `screen`/`tmux`
  sessions, SSH, notes, actions, history.
- **iOS** — SSH and notes only. There is no local terminal (forkpty is
  macOS-only), so the Local and Persistent sidebar sections are hidden and
  local-only actions are filtered out.

The `ShellKit` library is cross-platform; the local-pty pieces
(`LocalPTYTransport` + its `.zsh`/`.tmux`/`.screen` presets) are compiled
only on macOS.

## Shared data (the vault)
SSH hosts, database connections, accepted host keys and every device's public
key are the records the v57 apps share through the vault (`../Vault`, see its
README): one encrypted store per device in the app group container, synced
through iCloud (`iCloud.dev.v57`). Database list the same
connections and tunnel through the same hosts; a change in any app shows in
the others at once. Passwords are iCloud Keychain items in the shared keychain
group. The SSH key is this device's Secure Enclave key, shared by the v57 apps
on it (`VaultIdentity`), so it goes into `authorized_keys` once per device.

A database connection without an SSH host of its own attaches to the saved
host whose address is the database's server, and shows under it.

Hosts and connections saved by builds before the vault (`SSHConfigs.store`)
are imported once.

## Notes storage
Notes are the vault's notes (`VaultNote`), shared with the Markdown app: they
sync through iCloud (encrypted, titles included, no iCloud Drive needed), and
Markdown keeps them as files in its notes folder. Shell edits the records
directly, on macOS and iOS. The lock button decides whether Markdown keeps a
note's file encrypted (`.mdenc`) or plain (`.md`); new notes are encrypted.
Edits made on two devices at once merge line by line.

## Authorized keys
The `key.2.on.ring` button (Local and Remote sidebar headers, before the +
button) opens the authorized-keys panel for a target machine — this Mac
(direct file access) or the selected SSH connection (headless SSH exec,
saved password used automatically, host key trusted on first use).

Every device publishes its Secure Enclave identity key's public line to the
vault (`VaultDeviceKey`, synced through iCloud). The panel lists this
device's keys plus every other device's published keys, each with its
status on the target's `~/.ssh/authorized_keys`: added keys can be
removed, keys not yet added can be added — one click each.

## Use as library
**Local terminal (forkpty, macOS only):** use the `LocalPTYTransport`
presets — `.zsh` for an interactive login shell, `.screen(name)` /
`.tmux(name)` to attach to a persistent multiplexer session:
```swift
import ShellKit

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
- Local history uses domain-separated AES-256-GCM keys derived through a device-bound Secure Enclave P-256 agreement key. It is available only while the device is unlocked.
- Run a normally code-signed build: the data-protection Keychain requires Shell's Keychain Sharing entitlement, so an app built with `CODE_SIGNING_ALLOWED=NO` cannot save encrypted history or share the vault.
- Touch ID per-sign gating is intentionally not used (the Secure Enclave ACL can't be satisfied by swift-nio-ssh's signing path on this OS); a single Secure Enclave identity key is used instead.
