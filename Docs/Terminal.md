# Terminal

Shell's terminal works with full-screen programs such as `vim`, `htop` and `less`, and with 256 colours. When the
window or the screen changes size, the text reflows: wrapped lines join up again.

## Type on iPhone and iPad

When you open an SSH terminal, the keyboard comes up on its own. If you hide it, tap the terminal to bring it back.

Above the keyboard is a bar of special keys:

- **⌃ ⌥ ⇧**: tap one and it stays highlighted for the next key only. For example, tap ⌃ and then `c` to interrupt
  a running command.
- **Tab** for completion and **esc**.
- The arrows button shows **↑ ↓ ← →**, for shell history and moving the cursor.
- **Fn** shows **F1** to **F12**. Scroll the row sideways to reach them all.

With a hardware keyboard on iPad, the arrows, Tab, Esc, Control and Option keys go straight to the terminal, and the
on-screen keyboard stays down.

## Select and copy text

Drag across text to select it. Drag past the top edge to scroll while you select.

- On the Mac, and on iPad with a hardware keyboard: ⌘C copies the selection. With nothing selected, it copies what
  is on the screen. ⌘V pastes. ⌘K clears the scrollback.
- On iPhone, and on iPad without a keyboard, there is no copy or paste menu in the terminal yet. To send text to a
  terminal, use **Insert into Terminal** (below).

## Scroll back

Scroll up to read earlier output. A round ↓ button appears; tap it to return to the live bottom. Typing also takes
you back to the bottom.

## Insert text into a terminal

**Insert into Terminal** sends a block of text to the selected terminal.

1. Select a terminal.
2. On the Mac, choose **Shell ▸ Insert into Terminal…** (⌘E). On iPhone and iPad, open **Settings ▸ Actions** and tap
   **Insert…** next to **Insert into Terminal**.
3. Paste or type the text.
4. With **Send as separate commands** on, each line runs as its own command. Off, the text is pasted as it is.
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

On the Mac, **Shell ▸ Appearance…** (⇧⌘H) opens this pane.

## Close a terminal

- On the Mac, **Shell ▸ Close Connection** (⌘W) closes the selected SSH terminal. The label follows what is selected:
  **Close Terminal**, **Close Session**, **Close Web Page**, **Close Note** and so on. ⌘W never closes the main window.
- Everywhere, touch and hold (or right-click) the terminal's row and choose **Close Connection**.
