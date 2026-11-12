# Privacy and Security

Shell never contacts a server on its own. Everything it sends goes to a place you chose, when you ask for it.

## What Shell sends over the network

| What | Where it goes | When |
|---|---|---|
| SSH connections | The server you connect to | When you open a terminal, the Files panel, Authorized Keys, or a database or web page through a server. A dropped connection you opened dials again on its own. |
| Database connections | The database, directly or through your server over SSH | When you open the connection |
| Web pages | The site, or your server through an SSH tunnel | When you open the page |
| Images in notes | The image's server | Only after you tap **Load Images** for that note. Without cookies, and nothing is kept between loads. |
| The vault: hosts, database connections, host keys, device keys, accounts, notes, saved passwords | Your iCloud (iCloud and iCloud Keychain) | While **Use iCloud** is on (**Settings ▸ Privacy**). Everything is encrypted before it leaves the device. |
| Update check and download (Mac, Linux, Windows) | Shell's releases on GitHub | When you choose **Check for Updates…**, or once a day if you turn on **Check for Updates Automatically**. It is off until you turn it on. |
| The `session` tool (Mac) | GitHub | Only when you tap **Install** next to **Session Tool** in **Settings ▸ Sessions**. |
| DuckDB (Mac) | Its download | Only when you choose to download it from a database page. |
| A project's packages (Mac) | The hosts an Xcode project's Swift packages come from | Only when you run a smart action such as **Build** or **Run**. A terminal entering a project folder lists its schemes without fetching anything. |
| Apple's notary service and App Store Connect (Mac) | Apple | When you open the Notarization sheet, notarize an app or upload one. |

On the Mac, Shell installs an update only when it is signed by its developer and notarized by Apple. The iPhone and
iPad app updates through the App Store.

## Your SSH key

Each device has one SSH key, made inside its Secure Enclave. It never leaves the device and can't be copied or
backed up. All v57 apps on the device use the same key. Only its public half is published to your vault, so your other
devices can add it to servers.

On newer devices the key asks for Face ID, Touch ID or your password before it signs in to a server, and then signs
for 15 minutes without asking. Older keys sign without asking.

## Server keys

Shell asks before it trusts a server it hasn't met (**Untrusted host key**), and warns when a server's key changes
(**Host key changed**). Check the fingerprint before you accept. Connections without a terminal of their own ask
**Trust this server's key?** and never accept a changed key. For GitHub, GitLab and Bitbucket, Shell knows their keys
and refuses any other. See [SSH Connections](SSH-Connections.md#trust-a-servers-key).

Accepted keys are shared through the vault. To forget one, use the host in the
[Vault](https://github.com/v57/Vault/blob/main/docs/README.md) app.

## Passwords

With **Save in Keychain** on, a server's password is kept in your iCloud Keychain, where your other devices and v57
apps can use it. With it off, Shell asks each time. Editing a host with **Save in Keychain** off and no new password
deletes the saved one. **Delete Connection** deletes it too.

## Notes

Notes are encrypted in the vault, titles included, and synced through iCloud already encrypted. The lock on a note only
decides whether the Markdown app keeps its file on disk encrypted or as plain text.

Web images in a note wait for **Load Images**, because loading them would tell their servers the note was opened. A
link that isn't a web, email or Markdown link asks before it opens. On the Mac, apps and scripts are only revealed in
the Finder, never launched.

## Local history (Mac)

History is encrypted with a key tied to this Mac's Secure Enclave. It never leaves the Mac and can only be read while
the Mac is unlocked. Turn off **History** in **Settings ▸ Features** to stop recording. **Delete All History** removes
what's there.

## Dropped files (Mac)

Shell never types a dropped file name that contains control characters into a terminal, because the terminal would
read them as keys. It tells you instead.

## Databases

PostgreSQL and MySQL logins that would send a password readably are refused unless the connection uses SSH or TLS, or
you turn on **Allow insecure login** for that connection.

## Web pages through servers

All web pages that go through your servers load from your own device's local address, so they share one cookie store.
A page from one server can see cookies set by a page from another server. Open pages you don't trust directly, not
through a tunnel next to pages that hold a sign-in.

## Turn things off

Every feature can be turned off in **Settings ▸ Features**. A feature that's off is hidden and stops its background
work.

To keep your data on this device only, turn off **Use iCloud** in **Settings ▸ Privacy**. This applies to every v57
app on the device.

## Linux and Windows

On Linux and Windows, Shell keeps its secrets in the system's password store. Your other programs can read them there,
as with other password stores on those systems.
