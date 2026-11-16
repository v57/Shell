# Notes

Shell's notes are Markdown notes, encrypted and synced through your iCloud. They are the same notes the
[Markdown](https://github.com/v57/Markdown/blob/main/docs/README.md) app shows: Markdown keeps each one as a file in its
notes folder, and an edit in either app shows in the other.

## Write a note

1. Tap **+** on the **Notes** header (**New Note**).
2. Type. The first line is the note's title, and the next line is the preview under it in the sidebar.

The editor is a live Markdown editor: headings, lists, bold, links and code blocks show formatted, and the Markdown
symbols hide except on the line you're editing. Shell saves two seconds after you stop typing, and when you quit.

A new note you leave empty is removed when you move on to something else.

## Format lines

Select some lines and use the bar under the editor: **Toggle List**, **Toggle Checkbox**, **Toggle Checked Checkbox**,
**Toggle Code**, **Toggle Note** and **Toggle Numbered List**.

## Encrypt or decrypt a note

Every note is encrypted in the vault and in iCloud, title included. The lock decides how Markdown keeps the note's
file on disk:

- **Encrypt Note**: the file stays encrypted, readable only by the v57 apps. New notes start this way.
- **Decrypt Note**: the file is a plain Markdown file in Markdown's notes folder.

Use the lock button in the note's title bar, or the note's menu in the sidebar. An encrypted note's row shows a lock.

## Images and links

Images from the web aren't loaded when you open a note, because loading them tells their servers the note was opened.
A bar says "This note's images from the web aren't loaded." Tap **Load Images** to load them for this note.

Web, email and Markdown links open as usual. Any other link asks first ("Open this link?" or "Open “…”?") and names
where it leads and the app that would open it. On the Mac, apps and scripts are only shown in the Finder, never
launched.

Loaded images are fetched without cookies and kept in a cache on this device.

## Delete a note

Touch and hold (or right-click) a note and choose **Delete Note**. It is removed from Shell, from Markdown and from
your other devices. Your most recently changed note is selected.

## Edits on two devices

If you edit the same note on two devices at once, Shell merges the changes line by line.

## On the Mac

### New note and detach

<!-- only: mac -->

With a note selected, **Shell ▸ New Note** (⌘N) starts another one. **Shell ▸ Detach Session/Note** (⇧⌘D) opens the
selected note in its own window.

<!-- /only -->

<!-- only: linux windows -->

With a note selected, **New Note** in the **Shell** menu (Ctrl+N) starts another one. **Detach Session/Note**
(Ctrl+Shift+D) opens the selected note in its own window.

<!-- /only -->

<!-- only: mac -->

### Drop files on Notes

Drop text files from the Finder on the **Notes** section to copy them into new encrypted notes, or to link them (see
[Local Terminals and Sessions](Local-Terminals-and-Sessions.md#drop-files-on-shell)).

<!-- /only -->
