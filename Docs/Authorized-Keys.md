# Authorized Keys

A server lets a key sign in when the key's line is in the server's `~/.ssh/authorized_keys`. The Authorized Keys
panel shows those keys and adds or removes them with one tap, so you don't have to edit the file by hand.

Every device that runs a v57 app publishes its public key to your vault. The panel lists all of them, so you can let
your Mac, iPhone and iPad into a server from any one of them.

## Open the panel for a server

Touch and hold (or right-click) a server in **Remote** and choose **Authorized Keys**. The panel **Authorized Keys**
opens with the server's name and connects to it (**Connecting…**). If you haven't accepted the server's key yet, Shell
asks first, before it sends anything.

On the Mac, **Authorized Keys** in a local terminal's menu, and **Settings ▸ Actions ▸ Authorized Keys ▸ Show**, open
the panel for this Mac: the keys that can sign in to it.

## Add or remove a key

The panel lists:

- this device's key;
- your other devices' keys;
- keys you saved to iCloud before;
- keys that are already in the server's file.

Each one shows **Added** or **Not added**, with **Add** or **Remove**. **Remove** takes only that line out of the
file; the other lines stay.

The first time you add this device's key anywhere, Shell asks for your name and email. They go in the key's comment,
"so the server shows whose key it is". You set them once per account.

## Add another key

1. Tap **Add Key…**.
2. Paste one public key line into **Public key**, for example the contents of an `id_ed25519.pub` file. The **Name**
   fills in from the key's comment.
3. Leave **Save to iCloud for other machines** on to keep the key in your vault, so you can add it to other servers
   later.
4. Tap **Add**. Shell adds the key to the server.

**Add** stays disabled until the line is a valid public key.

## Keep or drop keys in iCloud

Touch and hold (or right-click) a key:

- **Save to iCloud** for a key that's only in the server's file: you can then add it to other servers.
- **Remove from iCloud** for a key you saved: it stops syncing. It stays on the servers it was added to.

**Reload** reads the server's file again. **Done** closes the panel.
