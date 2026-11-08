# Shell user guide

Shell is a terminal app. On the Mac it runs local terminals and persistent sessions. On every platform it opens SSH
terminals, keeps your servers in one list, opens database connections and web pages through those servers, runs
saved actions and holds encrypted notes.

You choose the features you want. Anything you turn off is hidden and stops its background work, and its data is
kept.

## Platforms

- **Mac** (macOS 14 or later, Apple silicon): everything in this guide.
- **iPhone and iPad** (iOS and iPadOS 17 or later): SSH terminals, the Files panel, databases, web pages, actions,
  authorized keys and notes. There is no local terminal, so local terminals, persistent sessions, history,
  monitoring, smart actions, Open With and file drops are Mac only. Settings opens from the gear at the bottom of the
  sidebar.
- **Linux and Windows**: Shell builds and runs there from source, with local terminals and SSH. There is no download
  yet, and some Mac features are missing (file drops, Open With; on Windows also web pages, which open in your
  browser, smart actions and persistent sessions). Saved secrets there are readable by your other programs, like
  other password stores on those systems.

Each page says when something works differently on one platform.

## Pages

- [Getting Started](Getting-Started.md): first launch, choosing features, the sidebar and accounts.
- [SSH Connections](SSH-Connections.md): saving servers, connecting, host keys, passwords and this device's key.
- [Terminal](Terminal.md): typing, the special-keys bar on iPhone and iPad, selection, copy and paste, scrollback.
- [Local Terminals and Sessions](Local-Terminals-and-Sessions.md): the Mac's own terminals, persistent sessions,
  history, live stats, file drops and detached windows.
- [Files Panel](Files-Panel.md): browsing, moving, copying and deleting files on the server a terminal is on.
- [Databases](Databases.md): database connections inside Shell, over SSH.
- [Web Pages](Web-Pages.md): web pages, including pages on a server's localhost through SSH.
- [Notes](Notes.md): encrypted Markdown notes, shared with the Markdown app.
- [Actions](Actions.md): saved commands, runs, smart actions and Open With.
- [Authorized Keys](Authorized-Keys.md): adding and removing keys on a server's `authorized_keys`.
- [Settings](Settings.md): Appearance, Features, Actions, Privacy, Accounts and Devices.
- [Privacy and Security](Privacy-and-Security.md): what Shell stores, what it sends and when.
- [Keyboard Shortcuts](Keyboard-Shortcuts.md): menu shortcuts on the Mac, hardware keyboard keys on iPad.

## Works with other v57 apps

- **[Vault](https://github.com/v57/Vault/blob/main/docs/README.md)**: your servers, database connections, accepted
  host keys, device keys, accounts and notes are records in the shared vault. Every v57 app on your devices sees the
  same list, synced through your iCloud.
- **[Database](https://github.com/v57/Database/blob/main/docs/README.md)**: Shell's database pages are Database's own
  interface, and the two apps share their saved connections.
- **[Markdown](https://github.com/v57/Markdown/blob/main/docs/README.md)**: Shell's notes are Markdown's notes. Markdown
  keeps each one as a file in its notes folder.
- **[Code](https://github.com/v57/Code/blob/main/docs/README.md)**: on the Mac, the smart actions (Run, Build, Test and
  so on for a project) come from Code, and Open With opens a terminal's folder in Code.
- **[Git](https://github.com/v57/Git/blob/main/docs/README.md)** and **Dev**: Open With opens a terminal's folder in
  them on the Mac.
- **[Hub](https://github.com/v57/hub-app/blob/main/docs/README.md)**: the devices on your Hub appear as SSH hosts.
- **session**: v57's `session` tool keeps Mac terminals running after Shell quits (see
  [Local Terminals and Sessions](Local-Terminals-and-Sessions.md)).

## Network

Shell contacts only what you ask it to: the servers you connect to, the web pages you open, and your iCloud for the
vault. It checks for updates only when you ask or turn automatic checks on. See
[Privacy and Security](Privacy-and-Security.md) for the full list.

For developers: [security-review.md](security-review.md) is a 2026-10-11 review of how Shell stores and moves secrets.

The package's libraries have pages here too: [ShellKit](ShellKit.md), [ShellIntegrations](ShellIntegrations.md),
[ShellMonitoring](ShellMonitoring.md) and [ShellDatabaseEngines](ShellDatabaseEngines.md). The
[README](../README.md#libraries) lists them.
