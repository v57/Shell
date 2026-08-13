import SwiftUI
import Terminal

/// The authorized-keys panel (opened by the `key.2.on.ring` button in the
/// Local and Remote sidebar headers).
///
/// Shows this device's Secure Enclave keys and every other device's keys
/// published through iCloud, each with its status on the target machine's
/// `~/.ssh/authorized_keys` (local file or remote via SSH). Added keys can
/// be removed; keys not yet added can be added — one click each.
struct AuthorizedKeysView: View {
  @Environment(AppModel.self) private var model
  let target: AuthorizedKeysManager.Target

  @State private var manager: AuthorizedKeysManager?
  @State private var entries: [AuthorizedKeysManager.KeyEntry] = []
  @State private var isLoading = false
  @State private var errorMessage: String?
  @State private var busyKeyIDs: Set<String> = []

  private var targetTitle: String {
    switch target {
    case .local:
      return "This Mac"
    case .ssh(let config):
      return config.displayName
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label("Authorized Keys", systemImage: "key.2.on.ring")
          .font(.headline)
        Text("· \(targetTitle)")
          .foregroundStyle(.secondary)
        Spacer()
        Button {
          Task { await load() }
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .disabled(isLoading)
        .help("Reload")
      }

      if let errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.red)
          .font(.callout)
      }

      if isLoading {
        HStack(spacing: 8) {
          ProgressView()
          Text("Connecting…")
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 24)
      } else {
        List {
          if entries.isEmpty {
            Text("No keys. Add this device's key to get started.")
              .foregroundStyle(.secondary)
          }
          ForEach(entries) { entry in
            KeyRow(
              entry: entry,
              isBusy: busyKeyIDs.contains(entry.id),
              onToggle: { await toggle(entry) }
            )
          }
        }
        .listStyle(.inset)
      }
    }
    .padding(16)
    .frame(minWidth: 420, minHeight: 340)
    .task { await load() }
  }

  // MARK: - Loading

  private func load() async {
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }

    let manager = AuthorizedKeysManager(target: target)
    self.manager = manager

    // Publish this device's key first so it appears in iCloud right away
    // (and freshens the record after a long time away).
    model.deviceKeys.publishThisDevice()

    // This device's keys (Secure Enclave).
    var deviceEntries: [AuthorizedKeysManager.KeyEntry] = []
    for identity in [SSHKeychain.Identity.default, .sensitive] {
      if let key = try? model.key(for: identity) {
        let fingerprint = SSHKeychain.publicKeyFingerprint(for: key)
        let comment = "Shell (\(NSUserName())@\(Self.deviceName))"
        let line = SSHKeychain.publicKeyOpenSSHLine(for: key, comment: comment)
        deviceEntries.append(AuthorizedKeysManager.KeyEntry(
          keyMaterial: String(line.split(separator: " ").prefix(2).joined(separator: " ")),
          fullLine: line,
          displayName: identity == .default ? "Default key" : "Sensitive key",
          fingerprint: fingerprint,
          source: .device,
          added: false
        ))
      }
    }

    // iCloud keys from OTHER devices (this device's own fingerprint is
    // already shown under "This device").
    let ownFingerprint = deviceEntries.first?.fingerprint
    let cloudEntries: [AuthorizedKeysManager.KeyEntry] = model.deviceKeys.all.compactMap { record in
      guard let fingerprint = record.fingerprint, fingerprint != ownFingerprint,
            let keyLine = record.keyLine,
            let material = AuthorizedKeysManager.keyMaterial(of: keyLine) else { return nil }
      return AuthorizedKeysManager.KeyEntry(
        keyMaterial: material,
        fullLine: keyLine,
        displayName: record.deviceName ?? fingerprint,
        fingerprint: fingerprint,
        source: .icloud,
        added: false
      )
    }

    // Status on the target: which key materials are already in the file.
    let added: Set<String>
    do {
      added = try await manager.readKeyMaterials()
    } catch {
      errorMessage = error.localizedDescription
      return
    }

    var all = deviceEntries + cloudEntries
    for index in all.indices {
      all[index].added = added.contains(all[index].keyMaterial)
    }
    entries = all
  }

  // MARK: - Add / remove

  private func toggle(_ entry: AuthorizedKeysManager.KeyEntry) async {
    guard let manager else { return }
    busyKeyIDs.insert(entry.id)
    defer { busyKeyIDs.remove(entry.id) }
    do {
      if entry.added {
        try await manager.remove(keyMaterials: [entry.keyMaterial])
      } else {
        try await manager.append(keyLine: entry.fullLine)
      }
      await load()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private static var deviceName: String {
    #if os(macOS)
    Host.current().localizedName ?? "Mac"
    #else
    UIDevice.current.name
    #endif
  }
}

// MARK: - Row

private struct KeyRow: View {
  let entry: AuthorizedKeysManager.KeyEntry
  let isBusy: Bool
  let onToggle: () async -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: entry.source == .device ? "macbook" : "icloud")
        .foregroundStyle(entry.source == .device ? Color.accentColor : Color.blue)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 2) {
        Text(entry.displayName)
          .font(.callout)
        Text(entry.fingerprint)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer()
      Text(entry.added ? "Added" : "Not added")
        .font(.caption)
        .foregroundStyle(entry.added ? Color.secondary : Color.orange)
      Button(entry.added ? "Remove" : "Add") {
        Task { await onToggle() }
      }
      .disabled(isBusy)
      .buttonStyle(.bordered)
      .tint(entry.added ? .red : .blue)
    }
    .padding(.vertical, 2)
  }
}
