# Getting Started

## Choose your features

The first time you open Shell, it shows **Choose your features**. Each feature has a switch:

| Feature | What it does |
|---|---|
| **Animations** | Page, cursor and output animations |
| **Sessions** | Local terminal sessions (Mac) |
| **Screen sessions** | GNU screen / tmux persistent sessions (Mac) |
| **SSH** | SSH connections and remote terminals |
| **Notes** | Encrypted notes |
| **History** | Local command history (Mac) |
| **Actions** | Saved commands and actions |
| **Smart Actions** | Per-directory project actions (Mac) |
| **Monitoring** | Live CPU / GPU / wattage stats (Mac) |
| **Files** | Files panel and file browsing (Mac) |
| **Authorized Keys** | SSH authorized keys |
| **Web** | In-app web sessions |
| **Database** | Database connections |

On iPhone and iPad the list has only the features that exist there: Animations, SSH, Notes, Actions, Authorized Keys,
Web and Database. The Files panel is always on there.

Turn off what you don't need, then tap **Continue**. The welcome doesn't show again. You can change your choice any
time in **Settings ▸ Features**. A feature you turn off is hidden and stops its background work. Its data is kept,
so turning it back on brings everything back.

## Find your way around

The sidebar lists everything in sections. Tap or click a row to open it.

- **This Mac** (Mac only; it shows your Mac's name): local terminals and persistent sessions.
- **Remote**: your saved SSH servers, with their open terminals under them.
- **Databases**: your saved database connections.
- **Web**: your web pages. It shows once you have one.
- **Notes**: your encrypted notes.
- **Running**: actions that are running or just finished.
- **Text Files** (Mac only): text files you opened with Shell.

Each section's header has a **+** button for a new item, and a summary such as "1 online · 2 offline". Tap a header to
collapse the section. Shell remembers which sections are collapsed.

Type in the sidebar's filter field to narrow every section to matching names. A server stays in the list when one of
its terminals matches.

Each row has a menu with what you can do to it. On the Mac, right-click the row. On iPhone and iPad, touch and hold it.
With a trackpad or mouse, hover a row to see its address or state.

You can drag servers, terminals and web pages to reorder them. Shell keeps the order.

On iPhone, a row opens its page, and Back returns to the sidebar. On iPad, the sidebar and the page sit side by side,
and the sidebar's toggle hides it. With nothing selected, the page reads **No Terminal Selected**.

## Open Settings

- On the Mac, choose **Shell ▸ Settings…** (⌘,). Settings is its own window.
- On iPhone and iPad, tap the gear at the bottom of the sidebar. On iPhone, tap **Done** to close it. On iPad, tap
  outside it or press Esc.

See [Settings](Settings.md) for each pane.

## Use accounts

Accounts keep separate sets of servers, database connections and notes, for example your own and a team's. They are
the same accounts in every v57 app.

When you have more than one account, a picker shows at the top of the sidebar with the number of hosts. Pick another
account and its servers, connections and notes replace the current ones. With only **Personal**, the picker is hidden.

The picker's menu has **New Account…** and **Manage Accounts…**, which opens **Settings ▸ Accounts**.

On the Mac and on iPad with a keyboard, ⌃⌘1 to ⌃⌘9 switch between accounts.

## Your data on other devices

Servers, database connections, accepted host keys and notes are saved in the shared vault and sync through your iCloud
to your other devices and the other v57 apps. A change you make in Shell, Database or Markdown shows in the others.

Some things stay on the device where you made them: web pages, actions, appearance and feature choices. On the Mac, local history also stays on the Mac.

To keep everything on this device, turn off **Use iCloud** in **Settings ▸ Privacy**. See
[Privacy and Security](Privacy-and-Security.md).
