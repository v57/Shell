# Actions

An action is a saved set of commands that you run with one tap, locally or on one of your servers. Actions are kept
on this device.

## Open the actions palette

- On the Mac: **Shell ▸ Actions…** (⌘R).
- On iPhone and iPad: **Settings ▸ Actions ▸ Actions ▸ Show**.

The palette reads "Run an action or search". Type to filter, use ↑ and ↓ to move, Return to run and Esc to close.

The menu at the top picks the terminal the action runs in. With no terminal selected, it reads **Local** on the Mac.
On iPhone and iPad it reads **Choose a Terminal**, and actions can't run until you pick one.

## Create an action

1. In the palette, tap **New Action** (the **+** next to **Your actions**).
2. In **New Action**, fill in:
   - **Name**, and a **Category** if you like. Actions are grouped by category.
   - **Where to display**: **Local**, and each of your servers. **Apply to future sessions** adds servers you save
     later.
   - **Focus window when run**: off, the action runs in the background and shows in the sidebar's **Running**
     section.
   - **Keep after completion**: keeps the run in the sidebar after it finishes.
   - **Commands**: one per line. They run in a new terminal, with zsh locally or your shell on the server.
   - **Address** under **Web** (optional): if the commands start a web server, this page opens when the action runs.
     On a server, the page goes through that server.
   - **Dependencies**: other actions to start first. They all start together, and this action starts one second
     after them.
3. Tap **Create**.

You can also turn what you just typed into an action. Select a terminal where you ran some commands, then choose
**Shell ▸ Create Action from Session** (⇧⌘R) on the Mac, or **Settings ▸ Actions ▸ Create Action from Session ▸ Create**.
The **New Action** sheet opens with those commands filled in.

To change or remove an action, touch and hold (or right-click) it in the palette and choose **Edit…** or **Remove**.

## Follow a run

A running action shows in the sidebar's **Running** section, with a live icon. When it finishes, it shows a green
check and leaves the section, unless **Keep after completion** is on. A failed run stays, in red, with its exit code.

Tap a run to see its output, one block per command. **Terminal** in the title bar shows the run's terminal so you can
type into it; **Run Output** switches back.

Touch and hold (or right-click) a run for **Cancel (Ctrl+C)** while it runs, **Close** and **Close All**.

## Sync a folder to a server (Mac)

An action can upload a local folder to a folder on one of your servers, like `rsync --delete`, to deploy a website for
example. It goes over Shell's own connection to the server: the server's key or password stays in Shell and is never
handed to `ssh`, `rsync`, `~/.ssh/config` or any other app.

1. In **New Action**, under **Folder sync**, turn on **Sync a folder**.
2. Fill in:
   - **Local folder**: type its path or use **Choose…**.
   - **Folder on the host**: an absolute path (`/var/www/site`) or one relative to your login folder (`~/site`).
     Shell refuses `/`, an empty path, `..`, and the login folder itself while deleting is on.
   - **Delete removed files** (on by default): files and folders on the server that the local folder doesn't have are
     deleted. Only inside that folder, and a symbolic link is removed as a link, never followed.
   - **Exclude**: comma-separated patterns that are neither uploaded nor deleted. The default `.*` leaves out
     dotfiles (`.git`, `.env`, the server's `.htaccess`). A pattern without `/` matches a name anywhere
     (`node_modules`, `*.log`); with one it matches from the folder (`/drafts`, `docs/*.md`); a trailing `/` matches
     folders only; `**` matches across folders.
3. Under **Where to display**, pick the servers (a sync never runs locally). **Commands** are optional: they run on
   the server after the sync, for example to reload the web server.

Running it first shows a dry run: the run lists every file to upload (new, size changed, content changed), delete or
create, and nothing on the server has changed yet. **Apply** under the run (or Return or `y` in its terminal) makes the
changes; **Cancel** (or `n`, Ctrl+C) leaves the server as it was. While it applies, the run shows each step and how
many are done; then a summary, with any file that failed listed as an error. A sync's run stays in **Running** until
you close it.

Files of the same size are compared by SHA-256 when the server has `sha256sum` or `shasum`, else by modification time
(Shell sets each uploaded file's time to the local one, so the next run sees it unchanged). Each file is uploaded
under a temporary name beside it and then renamed over the old one, so a page is never half-written.

A folder sync is offered in the actions palette whatever terminal is selected, and it opens its own connection, so
no terminal on the server is needed. With a terminal on one of its servers selected, it syncs to that server;
otherwise it syncs to each of its servers, one run per server.

## Smart actions (Mac)

When a local terminal is in a project folder, Shell finds the project's schemes and offers their actions: **Run**,
**Build**, **Test**, **Lint** and **Clean**, plus distribution actions for Xcode projects. These come from the
[Code](https://github.com/v57/Code/blob/main/docs/README.md) app, which knows Xcode, Swift, Go, Cargo, JavaScript and
TypeScript, Python, Gradle, Maven, Docker Compose, CMake, Make, Dart, .NET, Ruby, Elixir, PHP and Zig projects.

Entering an Xcode project's folder doesn't download anything. Shell lists the schemes from the project's files, or
with Xcode's own list when every package the project pins is already checked out on the Mac. The project's Swift
packages are fetched only when you run an action such as **Build** or **Run**.

- The title bar shows the scheme picker and the action buttons. **Distribute** holds the distribution actions and
  **Notarization Settings…**.
- The palette lists each scheme's actions too. Run one again to stop it.
- To keep a copy you can edit, choose **Add to Your Actions…** in an action's menu, or use the **+** on the scheme's
  group in the palette.

Turn smart actions off with **Smart Actions** in **Settings ▸ Features**.

## Open With (Mac)

For a local terminal's folder, the title bar has buttons that open the folder in the other v57 apps you have
installed: [Code](https://github.com/v57/Code/blob/main/docs/README.md),
[Markdown](https://github.com/v57/Markdown/blob/main/docs/README.md),
[Git](https://github.com/v57/Git/blob/main/docs/README.md) and Dev. The palette lists them too, as
**Open … in**.
