# Local Terminals and Sessions

Terminals on your own computer: the Mac, Linux and Windows. iPhone and iPad have no local terminal.

## On the Mac

### Open a local terminal

The **This Mac** section lists the terminals running on this computer. It is **This Computer** on Linux and
**This PC** on Windows.

<!-- only: mac -->

- **Shell ▸ New Local Terminal** (⌘N) opens a new terminal. With a terminal selected, ⌘N opens a new one of the same
  kind: another local terminal, another terminal on the same server, or another persistent session.
- **Shell ▸ New Terminal in Same Directory** (⌘T) opens a terminal in the folder the selected one is in.

<!-- /only -->

<!-- only: linux windows -->

- **New Local Terminal** in the **Shell** menu (Ctrl+N) opens a new terminal. With a terminal selected, Ctrl+N opens a
  new one of the same kind: another local terminal, another terminal on the same server, or another persistent
  session.
- **New Terminal in Same Directory** (Ctrl+T) opens a terminal in the folder the selected one is in.

<!-- /only -->

- **New Terminal** at the bottom of the sidebar opens a new terminal too.
- The **+** on the section's header has **New Session**, **Web Session** and **Database**.

<!-- only: mac -->

New terminals run zsh as a login shell.

<!-- /only -->

<!-- only: linux -->

New terminals run your login shell (`$SHELL`), or bash.

<!-- /only -->

<!-- only: windows -->

New terminals run PowerShell 7 when it's installed, else Windows PowerShell.

<!-- /only -->

Touch and hold (or right-click) a terminal for **Rename…**, **Authorized Keys** (the keys that can sign in to this
computer) and **Close Terminal**.

<!-- only: mac -->

### Open a folder in Shell

Open a folder with Shell from the Finder, or drop it on Shell's Dock icon, and a terminal opens in that folder. A text
file (`.txt`, `.conf`, `.md`, `.yml`, `.yaml`) opened the same way shows under **Text Files**, where you can read and
edit it.

<!-- /only -->

### Keep terminals running with persistent sessions

A persistent session keeps running when you close its terminal, and you can attach to it again later. Shell uses
v57's `session` tool when it is installed, otherwise `tmux`, otherwise GNU `screen`.

<!-- only: windows -->

Persistent sessions aren't on Windows: `session`, tmux and screen don't run there.

<!-- /only -->

<!-- only: mac -->

- **Shell ▸ New Persistent Session** (⇧⌘N) starts one and attaches a terminal to it.

<!-- /only -->

<!-- only: linux -->

- **New Persistent Session** in the **Shell** menu (Ctrl+Shift+N) starts one and attaches a terminal to it.

<!-- /only -->

- Persistent sessions are listed under the computer's section. Touch and hold (or right-click) one for **Rename…**,
  **Attach** (when no terminal is attached to it) and **Close Session**, which ends the session and anything still
  running in it.
- To make every new terminal a persistent session, turn on **Settings ▸ Sessions ▸ Always Start Persistent
  Sessions**.

On a server, a host's menu has **Persistent Session** (the host must be connected) and **Refresh Sessions**. Remote
persistent sessions show with the server's name, with **Attach** and **Close Session**.

<!-- only: mac -->

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

<!-- /only -->

### Look back at local history

With **History** on, Shell keeps an encrypted record of each local terminal's commands and their output on this
computer.

- The clock button on the section's header (**Show Local History**) swaps the terminals for your past sessions, each
  with when its last command ran. The same button (**Show Local Terminals**) switches back. It shows once there is
  a past session.
- Open a past session to read its commands and output. Its toolbar has **Replay Commands** (runs the commands again in
  a new terminal), **Create Action** (makes an action from them) and **Delete History**.
- **Delete All History** on the header deletes every past session.

<!-- only: mac -->

History never leaves this Mac and can only be read while the Mac is unlocked.

<!-- /only -->

<!-- only: mac -->

### Watch CPU, GPU and power

With **Monitoring** on, the This Mac header shows live CPU and GPU use and the system's power draw, without any helper
or administrator password. Click it for graphs of the last 10 minutes.

### Drop files on Shell

Drag files from the Finder (or from the Files panel) onto a terminal, a terminal's row, a server, or the Notes section.
A menu asks what to do. The choices depend on where you drop:

- on a local terminal: **Copy Here** or **Copy to “folder”** (into the folder the terminal is in);
- on an SSH terminal: **Upload Here** or **Upload to “folder”**;
- on a server's row: **Upload to Home Folder**;
- on a terminal that can reach the files (a local terminal with files from this Mac, or an SSH terminal with files from
  that server's Files panel): also **Insert Path** (types the path) and, for one file, **Go to Folder** or **Go to
  Enclosing Folder**;
- on Notes: **Copy to Encrypted Note** (the file's text becomes a new encrypted note; the file stays as it is) or
  **Link File** (opens the file under **Text Files**, where your edits change the file itself).

Folders can't be uploaded to a server yet.

Shell never types a file name that contains control characters into a terminal. It says so instead, because the
terminal would read those characters as keys.

### Add projects and databases to the vault

Drop folders or database files on the sidebar itself, and Shell offers to add the projects and databases it finds to
your vault, for the v57 apps that open them.

<!-- /only -->

### Detach a terminal or a note

<!-- only: mac -->

**Shell ▸ Detach Session/Note** (⇧⌘D) moves the selected terminal or note into its own window. Its **Always on Top**
button keeps that window above other apps. Choose the command again to bring it back to the main window.

<!-- /only -->

<!-- only: linux windows -->

**Detach Session/Note** in the **Shell** menu (Ctrl+Shift+D) moves the selected terminal or note into its own window.
Choose the command again to bring it back to the main window.

<!-- /only -->

While an item is detached, its sidebar row has a **Return to Main Window** button.

## On iPhone and iPad

iPhone and iPad have no local terminal, so there are no local terminals, persistent sessions or history there. Open
terminals on your servers instead (see [SSH Connections](SSH-Connections.md)).
