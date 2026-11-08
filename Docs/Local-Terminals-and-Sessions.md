# Local Terminals and Sessions

Everything on this page is on the Mac only. iPhone and iPad have no local terminal. Most of it also works in the
Linux build; the Windows build has local terminals (PowerShell) but no persistent sessions.

## Open a local terminal

The **This Mac** section (it shows your Mac's name) lists the terminals running on this Mac.

- **Shell ▸ New Local Terminal** (⌘N) opens a new terminal. With a terminal selected, ⌘N opens a new one of the same
  kind: another local terminal, another terminal on the same server, or another persistent session.
- **Shell ▸ New Terminal in Same Directory** (⌘T) opens a terminal in the folder the selected one is in.
- The **+** on the This Mac header has **New Session**, **Web Session** and **Database**.

New terminals run your login shell. Touch and hold (or right-click) a terminal for **Rename…**,
**Authorized Keys** (the keys that can sign in to this Mac) and **Close Terminal**.

## Open a folder in Shell

Open a folder with Shell from the Finder, or drop it on Shell's Dock icon, and a terminal opens in that folder. A text
file opened the same way shows under **Text Files**, where you can read and edit it.

## Keep terminals running with persistent sessions

A persistent session keeps running when you close its terminal, and you can attach to it again later. Shell uses
v57's `session` tool when it is installed, otherwise `tmux`, otherwise GNU `screen`.

- **Shell ▸ New Persistent Session** (⇧⌘N) starts one and attaches a terminal to it.
- Persistent sessions are listed under **This Mac**. Touch and hold (or right-click) one for **Rename…**, **Attach**
  and **Close Session**, which ends the session and anything still running in it.
- To make every new terminal a persistent session, turn on **Settings ▸ Sessions ▸ Always Start Persistent
  Sessions**.

On a server, a host's menu has **Persistent Session** (the host must be connected) and **Refresh Sessions**. Remote
persistent sessions show with the server's name, with **Attach** and **Close Session**.

### Keep sessions running after Shell quits

macOS ends an app's processes when it quits. To keep `session` sessions running after you quit Shell, Shell installs a
login item for the session daemon.

In **Settings ▸ Sessions**:

- **Session Tool** ▸ **Install** downloads the `session` tool to `~/.local/bin`. This is the only time Shell downloads
  it.
- **Keep Sessions Running After Quit** shows the login item's state, with **Install**, **Update**,
  **Open Login Items** (when it's off in System Settings), **Start** or **Remove**.
- **Session Daemon** ▸ **Stop** ends every persistent session. Shell asks first.

When a session would end with Shell, its terminal shows **This session ends when Shell quits**, with a button to fix
it (**Keep Running**, **Start** or **Open Login Items**).

## Look back at local history

With **History** on, Shell keeps an encrypted record of each local terminal's commands and their output on this Mac.

- The clock button on the This Mac header (**Show Local History**) swaps the terminals for your past sessions, each
  with when its last command ran. The same button (**Show Local Terminals**) switches back.
- Open a past session to read its commands and output. Its toolbar has **Replay Commands** (runs the commands again in
  a new terminal), **Create Action** (makes an action from them) and **Delete History**.
- **Delete All History** on the header deletes every past session.

History never leaves this Mac and can only be read while the Mac is unlocked.

## Watch CPU, GPU and power

With **Monitoring** on, the This Mac header shows live CPU and GPU use and the system's power draw, without any helper
or administrator password. Click it for graphs of the last minute.

## Drop files on Shell

Drag files from the Finder (or from the Files panel) onto a terminal, a terminal's row, a server, or the Notes section.
A menu asks what to do. The choices depend on where you drop:

- on a local terminal: **Copy Here** or **Copy to “folder”** (into the folder the terminal is in);
- on an SSH terminal: **Upload Here** or **Upload to “folder”**;
- on a server's row: **Upload to Home Folder**. Folders can't be uploaded yet;
- on a terminal that can reach the files (a local terminal with files from this Mac, or an SSH terminal with files from
  that server's Files panel): also **Insert Path** (types the path) and, for one file, **Go to Folder** or **Go to
  Enclosing Folder**;
- on Notes: **Copy to Encrypted Note** (the file's text becomes a new encrypted note; the file stays as it is) or
  **Link File** (opens the file under **Text Files**, where your edits change the file itself).

Shell never types a file name that contains control characters into a terminal. It says so instead, because the
terminal would read those characters as keys.

Drop folders or database files on the sidebar itself, and Shell offers to add the projects and databases it finds to
your vault, for the v57 apps that open them.

## Detach a terminal or a note

**Shell ▸ Detach Session/Note** (⇧⌘D) moves the selected terminal or note into its own window. Its **Always on Top**
button keeps that window above other apps. Choose the command again to bring it back to the main window.
