# ShellDatabaseEngines

ShellDatabaseEngines is how Shell's app takes in Database's interface and engines: it depends on Database's
`DatabaseKit` and `DatabaseUI` products and re-exports both, so one `import ShellDatabaseEngines` brings the
connection tree, browsers, query tabs, pipelines, inspector and connection sheets, and the ten engines under them.
It adds no API of its own (the module declares only an empty `ShellDatabaseEngines` namespace).

Another app that wants Database's interface should depend on Database directly. The pages that document it are in
the Database repository:

- [DatabaseUI](https://github.com/v57/Database/blob/main/docs/DatabaseUI.md): the interface and the hooks a host app
  sets (`DatabaseModel.opener`, `onDisconnect`, `WindowModel.onSelect`, `databaseSidebarTag`,
  `DatabaseCommands(includesFileItems:)`, `DatabaseUI.accent`).
- [DatabaseKit](https://github.com/v57/Database/blob/main/docs/DatabaseKit.md): connections, sessions and the engines.

## Getting started

```swift
// Package.swift
dependencies: [
  .package(url: "https://github.com/v57/Shell.git", branch: "main"),
],
targets: [
  .target(name: "MyApp", dependencies: [.product(name: "ShellDatabaseEngines", package: "Shell")]),
]
```

```swift
import ShellDatabaseEngines

let model = DatabaseModel.live()      // DatabaseUI
let engines = EngineKind.available    // DatabaseKit
```

## How Shell uses it

- A saved database connection's sidebar row expands into DatabaseUI's `ConnectionContents`; the tree's rows tag
  Shell's own selection type through the `databaseSidebarTag` environment value.
- The detail pane shows DatabaseUI's `DetailView` for Shell's `WindowModel`, the sheets are `databaseSheets(_:)` and
  the Data menu is `DatabaseCommands(includesFileItems: false)`.
- `DatabaseModel.opener` opens each connection over Shell's own SSH login for that host: ShellKit's
  `SSHSession.dialer` hands DatabaseKit a dialer whose connections are SSH channels, so no local port is opened.
- `WindowModel.onSelect` and `DatabaseModel.onDisconnect` keep Shell's sidebar and sessions in step with what happens
  inside the interface.

What people see is in the user guide's [Databases](Databases.md) page.

## Platform notes

The same as Database's libraries: every engine on macOS (DuckDB once downloaded), every engine but DuckDB on iOS and
iPadOS, and builds on Linux and Windows through v57/SwiftUI. Android: not yet.

## Testing

ShellDatabaseEngines has no tests of its own. The engines are tested in the Database repository, against its Docker
test servers ([Engines](https://github.com/v57/Database/blob/main/docs/Engines.md#test-servers)). Build Shell after
changing DatabaseUI's hooks:

```bash
xcodebuild -workspace Shell-Local.xcworkspace -scheme Shell -destination 'platform=macOS' build
```
