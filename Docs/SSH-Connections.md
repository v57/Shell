# SSH Connections

Your saved servers are listed in the sidebar's **Remote** section. Each one is a host: an address, a user and a way to
sign in. Hosts are shared with the other v57 apps through the vault.

## Add a server

1. Tap **+** on the **Remote** header. The **New Connection** sheet opens.
2. Fill in **Host** (a name or an address, like `my-server.example.com`) and **User**.
3. Optionally give it a **Name** for the sidebar, and change the **Port** (22 by default).
4. Under **Authentication**, pick the **Method**:
   - **SSH Key (Keychain)**: sign in with this device's key. The **Default key** row shows its fingerprint, and
     **Copy** copies its public key. The server needs this key in its `~/.ssh/authorized_keys` (see
     [Authorized Keys](Authorized-Keys.md)).
   - **Password**: type the **Password**. With **Save in Keychain** on, Shell remembers it.
5. Tap **Connect**. Shell saves the host and opens a terminal on it.

**Connect** stays disabled until there is a host and a user.

You can also open the sheet from **Settings ▸ Actions ▸ New Connection ▸ New…**.

## Add fallback addresses

A server can have more than one address, for example its name at home and its address on another network.

1. Edit the host (see below) and tap **Add Address** under **Fallback Addresses**.
2. Type the other address. Add as many as you like. They are tried in order when the main address doesn't answer.
3. **Remove** deletes an address.

For one of your own devices, Shell also lists the addresses it knows already (on the local network or on your Hub
Network) with an **Automatic** label. You can't edit those.

## Connect

Tap a saved host to open a terminal on it. The terminal shows under the host, slightly indented, and the host gets a
green dot. Tap the host again for a second terminal. On the Mac, with a server's terminal selected,
**Shell ▸ New Connection to …** (⌘N) opens another terminal on the same server.

While a host is connected, its row has a **+** button: **Web Session** opens a web page through it (see
[Web Pages](Web-Pages.md)) and **Database** starts a database connection through it (see [Databases](Databases.md)).

The page's title bar shows the terminal's name and where it is. While Shell connects or reconnects, a live icon shows
there.

## Trust a server's key

The first time you connect to a server, Shell shows **Untrusted host key** with the server's fingerprint.

- Tap **Accept** only if the fingerprint is the server's. Shell remembers the key and doesn't ask again.

The question names the address that answered. For a host with fallback addresses, that may be a fallback rather than
its main address. A key you accepted at any of a host's addresses is known at the others, so Shell doesn't ask again
when the same server answers at another one.
- Tap **Cancel**, or tap outside the dialog, to stop.

If a server shows a different key from the one Shell remembers, Shell shows **Host key changed** with the
**Remembered** and the **Presented** fingerprints. Someone could be intercepting the connection, or the server was
reinstalled. **Cancel** stops; **Trust New Key** replaces the remembered key and connects.

Connections that have no terminal of their own (the Files panel, Authorized Keys, database and web tunnels) ask
**Trust this server's key?** in the window instead, with **Trust and Connect**. They never accept a changed key: open
a terminal on the server to see both keys and decide there.

Accepted keys are saved in the vault, so your other devices and v57 apps know them too. To forget a key, use the host
in the [Vault](https://github.com/v57/Vault/blob/main/docs/README.md) app.

For GitHub, GitLab and Bitbucket, the keys come with the app, and any other key is refused.

## Sign in with a password

If a server asks for a password and none is saved, Shell shows **Password required** with `user@host`. Type the
password and tap **Connect**. Leave **Save in Keychain** on to keep it. **Cancel** ends the login.

Saved passwords are kept in your iCloud Keychain, so your other devices can use them.

## Sign in with this device's key

Each device has its own SSH key, made and kept in the device's Secure Enclave. It can't be copied off the device. All
v57 apps on the device use the same key, so you add it to a server once.

On newer devices, signing in with the key asks for Face ID, Touch ID or your password first ("Confirms it's you
before this device's SSH key signs in to a server."). After you confirm, the key can sign for 15 minutes without
asking again. When a dropped connection reconnects on its own, Shell doesn't ask. Keys made before this protection
existed sign without asking.

To copy the public key: **Copy Public Key** in a host's menu, **Copy** in the New Connection sheet,
**Settings ▸ Actions ▸ SSH Public Key ▸ Copy**, or on the Mac **Shell ▸ Copy SSH Public Key** (⇧⌘C).

## When the connection drops

Shell keeps your terminals connected with keepalives. If the network drops, the terminal's row shows
**Reconnecting…**, keeps its scrollback and dials again. While a terminal isn't connected, the title bar shows
**Reconnect**, which dials at once.

On iPhone and iPad, Shell doesn't run in the background. When you come back to it after a while, a terminal may need to
reconnect.

## Manage a host

Touch and hold (or right-click) a host:

- **Connect**: open a terminal.
- **Web Session** and **Database**: open a page or a database through this host.
- **Persistent Session** and **Refresh Sessions** (Mac): start or list sessions on the server that keep running after
  you disconnect. See [Local Terminals and Sessions](Local-Terminals-and-Sessions.md).
- **Edit…**: change it in **Edit Connection**, then **Save**. Open terminals stay open.
- **Copy Public Key**: copy this device's public key.
- **Authorized Keys**: see [Authorized Keys](Authorized-Keys.md).
- **Delete Connection**: removes the host at once, without asking. It closes its terminals, deletes its saved password
  and removes it from your other devices too.

Touch and hold (or right-click) a terminal under a host:

- **Rename…**: type a new title and press Return.
- **Close Connection**: ends this terminal. The host stays in your list.

## Hub devices

If you use [Hub](https://github.com/v57/hub-app/blob/main/docs/README.md), the devices on your Hub show in **Remote**
with the Hub icon. Hover one to see "… via Hub · At its Hub Network address". Tap it to connect. You can edit, remove
and reorder them like your other hosts.

## The sidebar row

A terminal's row shows a line of its output in its own colours:

- a green dot while there is recent output;
- gray once the shell has ended;
- a live icon while it connects or reconnects;
- red, with the error, when it fails.

To choose which line the row shows, tap that line in the terminal (without dragging). Tap its first character again
to show it from there.
