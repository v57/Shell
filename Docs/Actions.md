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

## Smart actions (Mac)

When a local terminal is in a project folder, Shell finds the project's schemes and offers their actions: **Run**,
**Build**, **Test**, **Lint** and **Clean**, plus distribution actions for Xcode projects. These come from the
[Code](https://github.com/v57/Code/blob/main/docs/README.md) app, which knows Xcode, Swift, Go, Cargo, JavaScript and
TypeScript, Python, Gradle, Maven, Docker Compose, CMake, Make, Dart, .NET, Ruby, Elixir, PHP and Zig projects.

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
