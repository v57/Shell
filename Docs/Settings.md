# Settings

On the Mac, open Settings with **Shell ▸ Settings…** (⌘,). On iPhone and iPad, tap the gear at the bottom of the
sidebar. Shell reopens the pane you used last.

## Sessions (Mac)

- **Always Start Persistent Sessions**: new terminals keep running after you close them, and you reopen them from the
  sidebar. It needs **Sessions** and **Screen sessions** on in Features.
- **Session Tool**, **Keep Sessions Running After Quit** and **Session Daemon**: see
  [Local Terminals and Sessions](Local-Terminals-and-Sessions.md#keep-sessions-running-after-shell-quits).

## Appearance

- **Text Size**: the terminal's text, 9 to 24 pt.
- **Color Scheme**: **System**, **Dark** or **Light**. The previews show both, and outline the one in use.
- **Disable Background Colors**: terminals and the sidebar's status lines stop drawing character backgrounds, and
  low-contrast text gets the default colour.

## Features

Turn each feature on or off (see [Getting Started](Getting-Started.md#choose-your-features)). The pane shows how many
are on. "Turned-off features are hidden and stop their background work; their data is kept."

## Actions

One row per Shell command, each with its button. On the Mac the same commands are in the **Shell** menu; on iPhone
and iPad this pane is where you find them:

| Row | Button | What it does |
|---|---|---|
| **New Connection** | **New…** | Opens the New Connection sheet |
| **Actions** | **Show** | Opens the actions palette |
| **Create Action from Session** | **Create** | Makes an action from the commands you typed in the selected terminal |
| **Insert into Terminal** | **Insert…** | Sends text to the selected terminal |
| **Appearance** | **Show** | Opens the Appearance pane |
| **Files Panel** | **Show** / **Hide** | Shows or hides the Files panel |
| **Navigate Up** | **Go Up** | Goes to the parent folder in the Files panel |
| **SSH Public Key** | **Copy** | Copies this device's public key |
| **Authorized Keys** | **Show** | Opens the Authorized Keys panel for this device |

A row is disabled when it can't act, for example when no terminal is selected. A row whose feature is off is hidden.

## Privacy

**Use iCloud** turns iCloud sync on or off for every v57 app on this device. Turning it off asks first
("Turn Off iCloud?"). With it off, your changes stay on this device and nothing more goes to iCloud or iCloud
Keychain. What's already there stays, and your other devices keep it.

## Accounts

The same pane as in every v57 app:

- **This iPhone** / **This iPad** / **This Mac** ▸ **Rename…**: the device's name on your Hub, in its SSH key and on the
  servers that let it in.
- **New Account…**, and **Edit…** or **Delete…** for each account. Deleting an account asks first: its projects, hosts,
  passwords and settings are deleted on every device. **Personal** can't be deleted.
- **Your Name** ▸ **Set…** or **Edit…**: the name and email that go in your key's comment and in Git commits.
- **Apple Teams** ▸ **Add…** and **Remove**: for Xcode projects that sign with an account's keys.

See [Vault's guide](https://github.com/v57/Vault/blob/main/docs/README.md) for more on accounts.

## Devices (iPhone and iPad)

Lists this device first, then your other devices. Touch and hold a device for **Rename…**, **Lost Device…** and
**Remove…**. A lost device moves to **Not Trusted**, where **Trust Again…** brings it back.

## Remote (Mac)

Whether your other devices may sign in to this Mac over SSH, which devices and app keys may, and the other keys in
the Mac's `authorized_keys`. It needs Remote Login on in System Settings. This pane is the same in every v57 Mac app;
see [Vault's guide](https://github.com/v57/Vault/blob/main/docs/README.md).
