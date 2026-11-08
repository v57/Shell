# ShellIntegrations

ShellIntegrations holds the logic behind Shell's integrations, kept free of AppKit and of process spawning so it can
be tested on its own: the Files panel's listing and file commands, persistent sessions (tmux, screen and the
`session` tool), which apps Open With offers for a folder, how an opened path is handled, the smart actions' scan
cache, and the address field of web actions.

It runs nothing by itself. Commands are strings you run with your own `FileCommandExecutor` (a local process, an SSH
session), and launching apps is the app's job. The smart actions themselves come from Code's `CodeActions` library,
which this library re-exports.

## Getting started

```swift
// Package.swift
dependencies: [
  .package(url: "https://github.com/v57/Shell.git", branch: "main"),
],
targets: [
  .target(name: "MyApp", dependencies: [.product(name: "ShellIntegrations", package: "Shell")]),
]
```

In the v57 checkout, `Shell-Local.xcworkspace` builds against the sibling repositories instead of GitHub's, and
SwiftPM does the same with `V57_LOCAL=1`.

List a folder through a command runner, and read the `session` tool's sessions:

```swift
import Foundation
import ShellIntegrations

struct LocalExecutor: FileCommandExecutor {
  func run(inDirectory dir: String, _ command: String) async throws -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    process.currentDirectoryURL = URL(fileURLWithPath: dir)
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return CommandResult(output: String(decoding: data, as: UTF8.self), exitCode: process.terminationStatus)
  }
}

let rows = try await DirectoryLister.list(directory: "/tmp", executor: LocalExecutor())
for row in rows where row.isDirectory { print(row.name) }

let sessions = ScreenSessionsParser.parseSessionOutput(sessionListJSON)  // the output of `session list`
```

## Main API

### Files

- `FileCommandExecutor`: runs a command in a directory and returns a `CommandResult` (`output`, `exitCode`).
- `FileCommandBuilder`: command strings with every path shell-quoted: `list(directory:)`,
  `open(path:isDirectory:remotePlatform:)`, `delete(path:isDirectory:)`, `moveCopy(source:destination:mode:)`
  (rsync), `shellQuote(_:)`, `terminalWord(_:)`.
- `DirectoryLister.list(directory:executor:parser:)`: runs `ls -la` through an executor and parses it; throws
  `DirectoryListingError.commandFailed` with the output when the command fails.
- `LSOutputParser.parse(_:)`: `ls -la` text to `FileRow`s (`name`, `isDirectory`, `size`, `modified`, `permissions`,
  `symlinkTarget`).
- `LocalDirectoryLister.list(directory:)`: the same rows from `FileManager`, without a process, for folders on this
  device.
- `IntegrationFileLister.list(directory:)`: a folder's top-level `DirectoryEntry`s.

### Persistent sessions

- `ScreenSessionsParser`: the list commands (`tmuxListCommand`, `screenListCommand`, `sessionListCommand`) and their
  parsers (`parseTmuxOutput(_:)`, `parseScreenOutput(_:)`, `parseSessionOutput(_:)`, or
  `parse(command:text:origin:)` for a remote host), plus `nextSessionName(existing:)`.
- `ScreenSessionInfo`: one session: `name`, `pid`, `state`, `kind` (`PersistentSessionKind`: `screen`, `tmux`,
  `session`), `remoteOrigin` (`ScreenRemoteOrigin`: the saved SSH connection it lives on), `isAttached`,
  `isProtected`, `directoryCommand`.
- `SessionAgent` (macOS): installs the `session` tool's daemon as a LaunchAgent so persistent sessions outlive Shell:
  `status()`, `install(environment:bundleIdentifier:)`, `startIfStopped()`, `remove()`. Its calls run `launchctl` and
  block, so call them off the main thread.

The `session` tool is a separate program ([v57/session](https://github.com/v57/session)); Shell runs it and parses
`session list`'s JSON, so a change to that output needs a change here too.

### Opening things

- `OpenWithResolver.kinds(for:isRepository:)`: which apps to offer for a folder (`OpenWithKind`: Xcode, Code, Zed,
  VS Code, Markdown, Git, Dev, Finder), from its top-level entries.
- `OpenPathResolver.target(for:)`: what Shell does with a path opened into it (`OpenPathTarget`: a terminal in a
  folder, a text file in the editor pane, or nothing).
- `SmartAddress.resolve(_:)`: a typed web address to a URL: a bare port becomes `http://localhost:<port>`, a local
  host `http://`, anything else `https://`.

### Smart actions

- `SmartActionsCoordinator(cacheStore:scan:)` and `refresh(directory:)`: a folder's `ActionScheme`s from Code's
  `ProjectScanner`, read from the cache while the folder's fingerprint is unchanged. Scanning can take a while
  (`xcodebuild -list`), so call it off the main actor.
- `IntegrationCacheStore` (`entry(forDirectory:)`, `save(_:forDirectory:)`) and `IntegrationCacheEntry`: the cache,
  stored as the app chooses (Shell encrypts it).

## Platform notes

- **macOS, iOS, Linux, Windows:** everything but `SessionAgent` is plain Foundation. The commands it builds assume a
  POSIX shell (`ls`, `rsync`, `rm`).
- **`SessionAgent`:** macOS only (launchd).
- **Smart actions:** whatever Code's `CodeActions` supports on the platform.
- **Android:** not yet.

## Testing

```bash
swift test --filter ShellIntegrationsTests
```

The tests need no servers: the listers run against fake executors and temporary folders, and the parsers against
recorded output. `DirectoryLister` takes any `FileCommandExecutor` and `SmartActionsCoordinator` any
`IntegrationCacheStore` and `scan` closure, so your own tests can pass fakes the same way.
