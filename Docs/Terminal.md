# Terminal

Shell's terminal works with full-screen programs such as `vim`, `htop` and `less`, with 256 colours and 24-bit
colour. When the window or the screen changes size, the text reflows: wrapped lines join up again.

## Select text

Drag across text to select it. Drag past the top or bottom edge to scroll while you select.

A tap or click without dragging chooses the line the terminal's sidebar row shows (see
[SSH Connections](SSH-Connections.md#the-sidebar-row)).

## Scroll back

Scroll up to read earlier output. A round ↓ button (**Scroll to Bottom**) appears; tap it to return to the live
bottom. Typing also takes you back to the bottom.

The scrollback keeps the last 10,000 lines.

## Insert text into a terminal

**Insert into Terminal** sends a block of text to the selected terminal.

1. Select a terminal.
2. Open **Insert into Terminal** (see below for where it is on your device).
3. Paste or type the text.
4. With **Send as separate commands** on (it starts on), each line runs as its own command. Off, the text is pasted
   as it is.
5. Tap **Apply**.

## Animations

With **Animations** on (in **Settings ▸ Features**), new output types itself out while you are at the bottom, and the
cursor glides. Turn Animations off, or turn on Reduce Motion in your system settings, and output appears at once.

## Text size and colours

Change these in **Settings ▸ Appearance**:

- **Text Size**: 9 to 24 pt. Open terminals resize and reflow.
- **Color Scheme**: **System**, **Dark** or **Light**, for the whole app.
- **Disable Background Colors**: terminals stop drawing character backgrounds, and low-contrast text gets the
  default text colour.

## Close a terminal

Touch and hold (or right-click) the terminal's row and choose **Close Connection** for a server's terminal, or
**Close Terminal** for a local one.

## On the Mac

<!-- only: mac -->

### Copy, paste and clear

⌘C copies the selection. With nothing selected, it copies what is on the screen. ⌘V pastes. ⌘K clears the
scrollback.

<!-- /only -->

### Insert text

<!-- only: mac -->

Choose **Shell ▸ Insert into Terminal…** (⌘E).

<!-- /only -->

<!-- only: linux windows -->

Choose **Insert into Terminal…** in the **Shell** menu (Ctrl+E).

<!-- /only -->

### Appearance

<!-- only: mac -->

**Shell ▸ Appearance…** (⇧⌘H) opens **Settings ▸ Appearance**.

<!-- /only -->

<!-- only: linux windows -->

**Appearance…** in the **Shell** menu (Ctrl+Shift+H) opens **Settings ▸ Appearance**.

<!-- /only -->

### Close with the keyboard

<!-- only: mac -->

**Shell ▸ Close Connection** (⌘W) closes the selected SSH terminal. The label follows what is selected:
**Close Terminal**, **Close Session**, **Close Web Page**, **Close Note**, **Close Action**, **Close Database**. ⌘W
never closes the main window.

<!-- /only -->

<!-- only: linux windows -->

The **Shell** menu's close command (Ctrl+W) closes the selected item. Its label follows what is selected:
**Close Terminal**, **Close Connection**, **Close Session**, **Close Web Page** and so on.

<!-- /only -->

## On iPhone and iPad

### Type

When you open an SSH terminal, the keyboard comes up on its own. If you hide it, tap the terminal to bring it back.

Above the keyboard is a bar of special keys:

- **⌃ ⌥ ⇧**: tap one and it stays highlighted for the next key only. For example, tap ⌃ and then `c` to interrupt
  a running command.
- **Tab** for completion and **esc**.
- The arrows button shows **↑ ↓ ← →**, for shell history and moving the cursor.
- **Fn** shows **F1** to **F12**. Scroll the row sideways to reach them all.

While the on-screen keyboard is up, the terminal has only the rows above it and the special-keys bar, and the server
is told that size, so the prompt stays in view. Opening the arrows or Fn rows takes rows away the same way.

With a hardware keyboard on iPad, the arrows, Tab, Esc, Control and Option keys go straight to the terminal, the
on-screen keyboard stays down, and the special-keys bar sits at the bottom of the window.

### Copy and paste

With a hardware keyboard on iPad, ⌘C copies the selection (or what is on the screen when nothing is selected), ⌘V
pastes and ⌘K clears the scrollback.

On iPhone, and on iPad without a keyboard, there is no copy or paste menu in the terminal yet. To send text to a
terminal, use **Insert into Terminal**.

### Insert text

Open **Settings ▸ Actions** and tap **Insert…** next to **Insert into Terminal**.

### Appearance

**Settings ▸ Actions ▸ Appearance ▸ Show** opens **Settings ▸ Appearance**.
