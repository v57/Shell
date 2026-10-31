import ComponentKit
import SwiftUI
import ShellKit

/// The authorized-keys panel (opened by the `key.2.on.ring` button in the
/// Local and Remote sidebar headers).
///
/// Shows this device's Secure Enclave key, every other device's keys and the
/// custom keys published through iCloud, and any other key already in the
/// target machine's `~/.ssh/authorized_keys` (local file or remote via SSH),
/// each with its status there. Added keys can be removed; keys not yet added
/// can be added — one click each. "+" adds a pasted public key.
struct AuthorizedKeysView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.kitDismiss) private var dismiss
  let target: AuthorizedKeysManager.Target

  @State private var manager: AuthorizedKeysManager?
  @State private var entries: [AuthorizedKeysManager.KeyEntry] = []
  @State private var isLoading = false
  @State private var errorMessage: String?
  @State private var busyKeyIDs: Set<String> = []
  @State private var showingAddKey = false

  private var targetTitle: String {
    switch target {
    case .local:
      return thisComputerName
    case .ssh(let config):
      return config.displayName
    }
  }

  var body: some View {
    KitSheet(
      title: "Authorized Keys", meta: targetTitle, systemImage: "key.2.on.ring", hue: .indigo,
      status: isLoading ? .working : .idle, width: 520
    ) {
      if isLoading && entries.isEmpty {
        EmptyState(systemImage: "key.2.on.ring", title: "Connecting…", status: .working)
          .frame(height: 200)
      } else {
        FormCard(footer: entries.isEmpty ? "No keys. Add this device's key to get started." : nil) {
          ForEach(entries) { entry in
            KeyRow(
              entry: entry,
              isBusy: busyKeyIDs.contains(entry.id),
              onToggle: { await toggle(entry) }
            )
            .kitContextMenu { menu(for: entry) }
          }
        }
      }
    } footer: {
      if let errorMessage {
        SheetStatus(errorMessage, systemImage: "exclamationmark.triangle", hue: .red, status: .failed(errorMessage))
      } else if isLoading {
        SheetStatus("Connecting…", systemImage: "network", status: .working)
      }
      Button("Reload", systemImage: "arrow.clockwise") {
        Task { await load() }
      }
      .disabled(isLoading)
      .help("Reload")
      Button("Add Key…", systemImage: "plus") {
        showingAddKey = true
      }
      .disabled(isLoading || manager == nil)
      .help("Add a pasted public key")
      Button("Done") { dismiss() }
        .buttonStyle(.kitPrimary)
        .keyboardShortcut(.defaultAction)
    }
    .task { await load() }
    .kitSheet(isPresented: $showingAddKey) {
      AddKeySheet { line, name, saveToICloud in
        try await addCustomKey(line: line, name: name, saveToICloud: saveToICloud)
      }
    }
  }

  @ViewBuilder
  private func menu(for entry: AuthorizedKeysManager.KeyEntry) -> some View {
    switch entry.source {
    case .icloud, .custom:
      Button("Remove from iCloud", systemImage: "icloud.slash") {
        forget(entry)
      }
    case .file:
      Button("Save to iCloud", systemImage: "icloud.and.arrow.up") {
        saveToICloud(entry)
      }
    case .device:
      EmptyView()
    }
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

    // This device's key (Secure Enclave).
    var deviceEntries: [AuthorizedKeysManager.KeyEntry] = []
    if let key = try? SSHKeychain.loadOrCreateDefaultKey() {
      let fingerprint = SSHKeychain.publicKeyFingerprint(for: key)
      let comment = "Shell (\(NSUserName())@\(Self.deviceName))"
      let line = SSHKeychain.publicKeyOpenSSHLine(for: key, comment: comment)
      deviceEntries.append(AuthorizedKeysManager.KeyEntry(
        keyMaterial: String(line.split(separator: " ").prefix(2).joined(separator: " ")),
        fullLine: line,
        displayName: "Default key",
        fingerprint: fingerprint,
        source: .device,
        added: false
      ))
    }

    // iCloud keys from OTHER devices and custom keys (this device's own
    // fingerprint is already shown as "Default key"). Records arrive newest
    // first; a key synced twice is listed once.
    var seen = Set(deviceEntries.map(\.keyMaterial))
    var cloudEntries: [AuthorizedKeysManager.KeyEntry] = []
    for record in model.deviceKeys.all {
      guard let fingerprint = record.fingerprint,
            let keyLine = record.keyLine,
            let material = AuthorizedKeysManager.keyMaterial(of: keyLine),
            seen.insert(material).inserted else { continue }
      cloudEntries.append(AuthorizedKeysManager.KeyEntry(
        keyMaterial: material,
        fullLine: keyLine,
        displayName: record.deviceName ?? fingerprint,
        fingerprint: fingerprint,
        source: record.isDeviceKey ? .icloud : .custom,
        added: false
      ))
    }

    // Status on the target: which keys are already in the file.
    let lines: [String]
    do {
      lines = try await manager.readLines()
    } catch {
      errorMessage = error.localizedDescription
      return
    }
    let added = Set(lines.compactMap(AuthorizedKeysManager.keyMaterial(of:)))

    // Keys in the file that Shell doesn't know (added by hand or by another
    // tool), so they can be removed too.
    var fileEntries: [AuthorizedKeysManager.KeyEntry] = []
    for line in lines {
      guard let material = AuthorizedKeysManager.keyMaterial(of: line),
            seen.insert(material).inserted else { continue }
      let fingerprint = SSHKeychain.publicKeyFingerprint(forKeyLine: material) ?? material
      fileEntries.append(AuthorizedKeysManager.KeyEntry(
        keyMaterial: material,
        fullLine: line,
        displayName: DeviceKeyStore.comment(of: line) ?? "Unnamed key",
        fingerprint: fingerprint,
        source: .file,
        added: true
      ))
    }

    var all = deviceEntries + cloudEntries
    for index in all.indices {
      all[index].added = added.contains(all[index].keyMaterial)
    }
    entries = all + fileEntries
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

  // MARK: - Custom keys

  /// Saves a pasted key to iCloud (optional) and adds it to the target.
  /// A key without a comment gets the name as its comment, so the file
  /// says whose key it is.
  private func addCustomKey(line: String, name: String, saveToICloud: Bool) async throws {
    guard let manager else { return }
    let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard AuthorizedKeysManager.isPlainKeyLine(line),
          let material = AuthorizedKeysManager.keyMaterial(of: line) else {
      throw AuthorizedKeysError.invalidKeyLine
    }
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let fullLine = DeviceKeyStore.comment(of: line) == nil && !name.isEmpty ? "\(material) \(name)" : line
    if saveToICloud {
      try model.deviceKeys.addCustomKey(line: fullLine, name: name)
    }
    if !(try await manager.readKeyMaterials()).contains(material) {
      try await manager.append(keyLine: fullLine)
    }
    await load()
  }

  private func forget(_ entry: AuthorizedKeysManager.KeyEntry) {
    do {
      try model.deviceKeys.forget(fingerprint: entry.fingerprint)
      Task { await load() }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func saveToICloud(_ entry: AuthorizedKeysManager.KeyEntry) {
    do {
      try model.deviceKeys.addCustomKey(line: entry.fullLine, name: nil)
      Task { await load() }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private static var deviceName: String {
    #if os(macOS)
    Host.current().localizedName ?? "Mac"
    #elseif os(iOS)
    UIDevice.current.name
    #else
    ProcessInfo.processInfo.hostName
    #endif
  }
}

// MARK: - Row

private struct KeyRow: View {
  let entry: AuthorizedKeysManager.KeyEntry
  let isBusy: Bool
  let onToggle: () async -> Void

  var body: some View {
    FormRow(entry.displayName, help: entry.fingerprint, systemImage: symbol, hue: hue) {
      HStack(spacing: 8) {
        Chip(entry.added ? "Added" : "Not added", hue: entry.added ? nil : .orange)
        Button(entry.added ? "Remove" : "Add", role: entry.added ? .destructive : nil) {
          Task { await onToggle() }
        }
        .buttonStyle(.kit)
        .disabled(isBusy)
      }
    }
    .help(sourceHelp)
  }

  private var hue: Hue {
    switch entry.source {
    case .device: return .accent
    case .file: return .gray
    case .icloud, .custom: return .blue
    }
  }

  private var symbol: String {
    switch entry.source {
    case .device: return "macbook"
    case .icloud: return "icloud"
    case .custom: return "key"
    case .file: return "doc.text"
    }
  }

  private var sourceHelp: String {
    switch entry.source {
    case .device: return "This device"
    case .icloud: return "Another device, from iCloud"
    case .custom: return "Added by hand, saved in iCloud"
    case .file: return "Only in authorized_keys"
    }
  }
}

// MARK: - Add key

/// Paste a public key ("ssh-ed25519 AAAA… comment"), name it, and choose
/// whether to keep it in iCloud for the other machines.
private struct AddKeySheet: View {
  @Environment(\.kitDismiss) private var dismiss
  let onAdd: (_ line: String, _ name: String, _ saveToICloud: Bool) async throws -> Void

  @State private var line = ""
  @State private var name = ""
  @State private var saveToICloud = true
  @State private var isAdding = false
  @State private var errorMessage: String?

  private var trimmedLine: String { line.trimmingCharacters(in: .whitespacesAndNewlines) }
  private var isValid: Bool { AuthorizedKeysManager.isPlainKeyLine(trimmedLine) }

  var body: some View {
    KitSheet(
      title: "Add Key", meta: "A public key for this machine's authorized_keys", systemImage: "key", hue: .indigo,
      width: 480
    ) {
      FormCard {
        FormRow(
          "Public key", systemImage: "key", hue: .indigo,
          error: !trimmedLine.isEmpty && !isValid
            ? "Paste one public key line, e.g. the contents of ~/.ssh/id_ed25519.pub." : nil,
          field: keyField)
        FormRow(
          "Name", help: "Optional", systemImage: "character.cursor.ibeam", hue: .indigo,
          field: TextField("Name (optional)", text: $name))
        FormRow("Save to iCloud", help: "For other machines", systemImage: "icloud", hue: .blue) {
          Toggle("Save to iCloud for other machines", isOn: $saveToICloud)
            .labelsHidden()
            .toggleStyle(.kitSwitch)
        }
      }
    } footer: {
      if let errorMessage {
        SheetStatus(errorMessage, systemImage: "exclamationmark.triangle", hue: .red, status: .failed(errorMessage))
      }
      Button("Cancel") { dismiss() }
        .keyboardShortcut(.cancelAction)
      Button("Add") {
        Task { await add() }
      }
      .buttonStyle(.kitPrimary)
      .keyboardShortcut(.defaultAction)
      .disabled(!isValid || isAdding)
    }
  }

  private var keyField: some View {
    TextField("Public key", text: $line, prompt: Text("ssh-ed25519 AAAA… user@host"), axis: .vertical)
      .kitFont(.mono)
      .lineLimit(3...6)
      .autocorrectionDisabled()
      #if os(iOS)
      .textInputAutocapitalization(.never)
      #endif
      .onChange(of: line) { _, newValue in
        // Fill the name from the pasted key's comment.
        if name.isEmpty, let comment = DeviceKeyStore.comment(of: newValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
          name = comment
        }
      }
  }

  private func add() async {
    isAdding = true
    errorMessage = nil
    defer { isAdding = false }
    do {
      try await onAdd(trimmedLine, name, saveToICloud)
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}
