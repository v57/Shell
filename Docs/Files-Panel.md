# Files Panel

The Files panel shows the files in the folder a terminal is in. For an SSH terminal, those are the server's files.

## Show the files

Select a terminal and tap the folder button in the title bar (**Show Files**). The panel takes the terminal's place,
and the button turns into a terminal icon (**Show Terminal**) to go back.

- On the Mac: **Shell ▸ Toggle Files Panel** (⇧⌘F).
- On iPhone and iPad: also **Settings ▸ Actions ▸ Files Panel ▸ Show** or **Hide**.

On the Mac, the panel is part of the **Files** feature. On iPhone and iPad it is always there for SSH terminals.

## Move around

The path bar shows where you are, with `~` for your home folder. Tap or click a folder in it to go there; the last
one lists the current folder again.

- Open a folder to go into it: tap it on iPhone, double-click it on the Mac, or choose **Open Folder** from its menu.
  Opening a file runs the server's opener, as **Open in Default App** does (below).
- **Up** (the chevron) goes to the parent folder. On the Mac: **Shell ▸ Navigate Up** (⇧⌘U). On iPhone and iPad: also
  **Settings ▸ Actions ▸ Navigate Up ▸ Go Up**.
- On iPhone and iPad, pull the list down to list the folder again, with what changed on the server since.

An empty folder shows **Empty Folder**. A folder Shell can't read shows **Couldn't Load Folder** with the reason and
**Retry**.

If you haven't accepted the server's key yet, the panel doesn't ask about it. It tells you to accept the key in the
terminal, and lists the folder once you have.

## Work with files

Touch and hold (or right-click) a file or folder:

- **Open Folder**, or **Open in Default App** for a file: runs the server's opener (`open` or `xdg-open`). On a server
  without a desktop, this fails with a message.
- **Move…** and **Copy…**: the **Move to…** or **Copy to…** sheet asks for the destination path. Switch between
  **Move** and **Copy** at the top, then confirm.
- **Delete**: asks "Delete 1 item?" ("This cannot be undone."), then deletes it on the server.

## On the Mac

The Mac's panel is a table with **Name**, **Type**, **Size** and **Modified** columns. Click a column to sort by it.

- Select several items to move, copy or delete them together.
- Rename an item in place.
- Drag items onto a folder in the panel, and choose **Move Here** or **Copy Here**.
- Drag items out to the Finder, to a terminal or to Notes. Drag files from the Finder into the panel.

See [Local Terminals and Sessions](Local-Terminals-and-Sessions.md#drop-files-on-shell) for what dropping on a terminal
does.
