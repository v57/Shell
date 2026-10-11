# Security review (2026-10-11)

A read-through of how Shell stores and moves secrets: SSH keys, passwords, host keys, notes, history,
synced configs. Scope: this repo at `claude/nervous-wilson-411597`. All crypto is CryptoKit and the
Security framework; libssh2 + mbedTLS only carry the SSH transport.

## Verified

**SSH identity key** (`Sources/Terminal/SSHKeychain.swift`)
- P-256 signing key generated inside the Secure Enclave; only its device-bound `dataRepresentation`
  is stored (generic password `dev.v57.sh` / `ssh-sep-key`). The private scalar is never in memory
  or on disk, and the key can't be exported or restored on another device.
- The published line is `ecdsa-sha2-nistp256` with the X9.63 point (RFC 5656); fingerprint is
  OpenSSH `SHA256:`. Signing goes through libssh2's external-signer callback.
- No user-presence ACL: signing needs no Touch ID (a documented choice).

**Encrypted files: history, smart actions, device-key SSH configs** (`Shell/SecureFileStore.swift`)
- A Secure Enclave P-256 key-agreement key (`.privateKeyUsage`, `WhenUnlockedThisDeviceOnly`) does
  ECDH with a stored peer public key; HKDF-SHA256 with a fixed salt and a per-domain `sharedInfo`
  gives four independent AES-256 keys (notes, history, ssh-configs, smart-actions).
- AES-GCM, random 96-bit nonce per seal, combined format. Files hold only ciphertext.
- The key envelope sits in the data-protection Keychain, `WhenUnlockedThisDeviceOnly`.

**Notes** (`Shell/Notes/`)
- Title, subtitle and text are three separate AES-GCM ciphertexts. Local notes use the
  `SecureFileStore` notes key; iCloud notes use a random 256-bit key in iCloud Keychain
  (synchronizable, `AfterFirstUnlock`). CloudKit records carry only id, dates, key id and ciphertext.

**Synced SSH and database connections** (`SSHConfigStore`, `DatabaseConnectionStore`)
- Each config is one AES-GCM payload (iCloud Keychain key, device key as fallback); CloudKit sees no
  host, user or port.
- Passwords stay in the device Keychain (`AfterFirstUnlockThisDeviceOnly`, never synchronizable)
  and are deleted with their connection.

**Authorized keys** (`AuthorizedKeysManager`, `DeviceKeyStore`)
- Device records are public keys only, plaintext by design.
- Local `~/.ssh` is set to 700, `authorized_keys` to 600. Remote writes quote the line
  (`printf '%s\n' '…'`) or use a random quoted heredoc delimiter.

**Leak sweep**
- Logging: `NSLog` on error paths only; no note, history, password or key content is logged.
- No libssh2 trace, no `print` of secrets, no `fatalError` carrying data.
- No `NSUserActivity`, Spotlight indexing or state restoration of notes or sessions; `@AppStorage`
  holds UI flags only.
- Pasteboard writes are user-initiated (copy selection, ⌘⇧C public key).

## Fixed in this pass

| Issue | Commit |
|---|---|
| A changed host key got the same "can't be established" alert as a new host, Accept as default. The file browser, web/database tunnels and the authorized-keys panel accepted any key silently, sent the saved password and replaced the remembered key. Now: background connections trust first use only; terminals show "Host key changed" with Disconnect as default. | `SSH: Refused changed host keys…` |
| Input typed at a password prompt (`sudo`, `ssh`, `read -s`) was recorded as a command, saved to history and offered by ⌘⇧R. Now dropped when the pty has echo off or the prompt asks for a password/passphrase/PIN. | `History: Stopped recording input typed at password prompts` |
| A history load failure (keychain locked, damaged file) followed by a save replaced or deleted the encrypted history. | `History: Kept the history file when it fails to load` |
| A synced key line with a newline or options (`command=`) could add more than one key to `authorized_keys`. | `SSH: Validated synced key lines…` |
| Two error logs named the host. | `Shell: Removed host names from logged errors` |
| History kept recording with the History feature off. | `Features: Made the Sessions, History, Files…` |

## Open findings (recommended next)

1. **Saved Actions are plaintext** in UserDefaults (`ActionsStore`, `~/Library/Preferences/dev.v57.sh.plist`),
   including actions made from encrypted history with ⌘⇧R. Move them to a `SecureFileStore` domain, keeping the
   defaults copy until the encrypted file reads back. Needs a signed build to test.
2. **Known hosts live in UserDefaults** (`KnownHostsStore`): a plaintext list of every `host:port` connected to,
   and any process running as the user can rewrite a fingerprint and remove the changed-key warning. Move to
   the Keychain or an encrypted file.
3. **Legacy Keychain on macOS**: `SSHKeychain` doesn't set `kSecUseDataProtectionKeychain`, so the identity key
   blob and SSH/database passwords live in the login keychain, guarded by ACL prompts rather than the app's
   access group. Also, `save` deletes before adding: a failed add loses the item. Migrate (copy to the
   data-protection keychain, then delete) and use `SecItemUpdate`. Must keep the existing Secure Enclave key,
   or every server's `authorized_keys` entry stops working. Needs a signed build to test.
4. **Images in notes leak**: Markdown's `MarkdownImageCache` fetches remote images and caches them unencrypted in
   `~/Library/Caches/<bundle>/MarkdownImages` (URL and content); the fetch also tells the image host when a note
   is opened. Fix in the Markdown repo (a memory-only cache, or no remote loads, for notes).
5. **Drag-out temp copies**: SFTP downloads for drag-out stay in `$TMPDIR/shell-drag` until reboot.
6. **Web sessions** use WebKit's default persistent data store (cookies, cache, local storage on disk).
7. **No associated data in AES-GCM**: ciphertexts aren't bound to their record id or field, so whoever can write
   the CloudKit private database could swap fields between records. Low risk.
8. **SSHConfigs.store** is at the root of `~/Library/Application Support` under a generic name (notes are under
   `dev.v57.sh/`).
9. **ShellTests run inside the app**: the test host opens the real stores and Keychain, and an unsigned run traps
   in CloudKit setup. A separate test host (or hermetic stores under test) would make the suite safe to run
   anywhere.

## Not verified here

- Anything needing a signed build: the real Keychain/Secure Enclave paths, CloudKit sync, ShellTests (app-hosted).
  Package tests (`swift test`, 261 tests) pass.
- Runtime behavior on macOS 14 / iOS 17 (no such machine or simulator runtime here).
- A CVE audit of the C libraries. Bundled: libssh2 `1.11.1_DEV` (a pre-release snapshot) and mbedTLS `3.6.2`;
  mbedTLS 3.6.3 and later carry security fixes, so rebuilding `Binary/SSH-libssh2` (and the Database C-drivers
  that merge it) on the latest 3.6 LTS and a tagged libssh2 release is worth doing before launch.
