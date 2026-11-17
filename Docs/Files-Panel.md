# Files Panel

The Files panel shows the files in the folder a terminal is in. For an SSH terminal, those are the server's files.

## Show the files

Select a terminal and tap the folder button in the title bar (**Show Files**). The panel takes the terminal's place,
and the button turns into a terminal icon (**Show Terminal**) to go back.

## Move around

The path bar shows where you are, with `~` for your home folder. Tap or click a folder in it to go there; the last
one lists the current folder again. **Up** (the chevron) goes to the parent folder.

Open a folder to go into it, or choose **Open Folder** from its menu. Opening a file runs the computer's opener, as
**Open in Default App** does (below).

An empty folder shows **Empty Folder**. A folder Shell can't read shows **Couldn't Load Folder** with the reason and
**Retry**. So does a server that doesn't answer for 30 seconds.

The panel follows the terminal's folder when you `cd`. On a server, Shell asks the server every few seconds which
folder the terminal's shell is in, so the panel catches up a moment after a `cd`. This works on Linux and macOS
servers; where Shell can't tell (a Windows server, for example), the panel opens in your login folder and you move
around in the panel itself. Once you've opened a folder in the panel, it stays there until the terminal changes
folder again.

If you haven't accepted the server's key yet, the panel doesn't ask about it. It tells you to accept the key in the
terminal, and lists the folder once you have.

## Work with files

Touch and hold (or right-click) a file or folder:

- **Open Folder**, or **Open in Default App** for a file: runs the opener (`open` or `xdg-open`). On a server
  without a desktop, this fails with a message.
- **Move…** and **Copy…**: the **Move to…** or **Copy to…** sheet asks for the destination path. Switch between
  **Move** and **Copy** at the top, then confirm. **Copy…** opens with **Copy** selected, **Move…** with **Move**.
- **Delete**: asks "Delete 1 item?" ("This cannot be undone."), then deletes it.

Moving and copying use `rsync` on the computer that has the files. If a move, copy or delete fails, a banner over the
list says why, with **Reload**.

## On the Mac

### Open the panel

<!-- only: mac -->

**Shell ▸ Toggle Files Panel** (⇧⌘F) shows or hides the panel, and **Shell ▸ Navigate Up** (⇧⌘U) goes to the parent
folder.

<!-- /only -->

<!-- only: linux windows -->

**Toggle Files Panel** in the **Shell** menu (Ctrl+Shift+F) shows or hides the panel, and **Navigate Up**
(Ctrl+Shift+U) goes to the parent folder.

<!-- /only -->

The panel is part of the **Files** feature: with Files off in **Settings ▸ Features**, it's hidden.

<!-- only: mac -->

### The table

The panel is a table with **Name**, **Type**, **Size** and **Modified** columns. Click a column to sort by it.
Double-click a folder to go into it.

- Select several items to move, copy or delete them together.
- Select an item and press Return to rename it in place.
- Drag items onto a folder in the panel to move them there, or select several items and choose **Move Here** or
  **Copy Here** in a folder's menu.
- Drag items out to the Finder, to a terminal or to Notes. Drag files from the Finder into the panel to copy them
  into the current folder (on a server, they're uploaded).

See [Local Terminals and Sessions](Local-Terminals-and-Sessions.md#drop-files-on-shell) for what dropping on a terminal
does.

<!-- /only -->

<!-- only: linux windows -->

### The list

The panel is a list of names, with each item's date and size. Click to select an item and double-click to open it.
Its menu acts on that one item.

<!-- /only -->

## On iPhone and iPad

### Open the panel

The panel is always there for SSH terminals. Besides the folder button, **Settings ▸ Actions ▸ Files Panel ▸ Show** or
**Hide** shows or hides it, and **Settings ▸ Actions ▸ Navigate Up ▸ Go Up** goes to the parent folder.

### The list

The panel is a list of names, with each item's date and size.

- On iPhone, tap a folder to go into it, or a file to open it.
- On iPad, tap to select an item and double-tap to open it.
- Pull the list down to list the folder again, with what changed on the server since.

### Edit a file

Opening a file shows it in an editor on the iPhone or iPad, read over the session's SSH login (the server's screen
isn't involved). Code is colored as in Code, and Markdown opens in the Markdown editor. Return keeps the line's
indentation. Tap **Save** (or press ⌘S on a keyboard) to write the file back to the server: Shell writes a hidden file
beside it and renames it into place, keeping the file's permissions. **Close** with unsaved changes asks whether to
save them. While the editor is open, the terminal behind it lets the keyboard go, so keys never reach it.

- If the file changed on the server since you opened it (its size or modification time), saving says so, and
  **Save Anyway** replaces it with your text.
- A file over 512 KB opens read-only with its first 512 KB, as does a file that isn't UTF-8 text. A binary file
  isn't shown.
- In a folder where you can't create files, the file itself is written over.
