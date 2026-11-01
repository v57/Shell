import ComponentKit
import Foundation
import SwiftUI
import VaultKit

/// One fallback address as the connection editor edits it: a row of its own (`VaultHost.fallbacks`).
struct FallbackAddress: Identifiable, Hashable {
  let id = UUID()
  var address = ""
}

/// A host's fallback addresses as the connection editor edits them.
enum FallbackAddresses {
  static func rows(_ addresses: [String]) -> [FallbackAddress] { addresses.map { FallbackAddress(address: $0) } }

  /// The addresses as typed, in order: trimmed, without blank rows, repeats and the host's own address.
  static func addresses(_ rows: [FallbackAddress], host: String) -> [String] {
    var seen: Set<String> = [host.trimmingCharacters(in: .whitespaces).lowercased()]
    return rows.map { $0.address.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
  }

  /// What's wrong with a row: a space inside the address, or one tried already (the host's address, a row above).
  static func issues(_ rows: [FallbackAddress], host: String) -> [UUID: String] {
    var issues: [UUID: String] = [:]
    var seen: Set<String> = [host.trimmingCharacters(in: .whitespaces).lowercased()]
    for row in rows {
      let value = row.address.trimmingCharacters(in: .whitespaces)
      guard !value.isEmpty else { continue }
      if value.contains(where: \.isWhitespace) {
        issues[row.id] = "An address has no spaces"
      } else if !seen.insert(value.lowercased()).inserted {
        issues[row.id] = "Tried already"
      }
    }
    return issues
  }
}

/// An address the vault tries on top of the ones the user typed, for a host that is one of the user's devices: the
/// name the Mac published (its Bonjour name) or its Hub Network address (`Vault.addresses(of:)`).
struct AutomaticAddress: Hashable {
  var address: String
  /// Which way it is, for the editor's read-only row.
  var source: String

  /// The ones for `host` as edited (its address and fallbacks as typed), from Personal's devices and Hubs.
  @MainActor static func list(for host: VaultHost, in vault: Vault) -> [AutomaticAddress] {
    let personal = vault.personalVault
    return SSHConfigStore.automaticFallbacks(of: host, in: vault).map { address in
      let viaHub = personal.hubHosts.contains { $0.hostname.caseInsensitiveCompare(address) == .orderedSame }
      let source =
        viaHub
        ? "Its Hub Network address, wherever the Hub reaches"
        : address.lowercased().hasSuffix(".local") ? "Its Bonjour name, on the same network" : "Another address it published"
      return AutomaticAddress(address: address, source: source)
    }
  }
}

/// The editor's fallback rows, inside a `FormCard`: Add, a field per address the user adds (in the order they're
/// tried), then the ones tried for a device of the user's anyway, read-only.
struct FallbackAddressRows: View {
  @Binding var rows: [FallbackAddress]
  /// The host's address, which the fallbacks come after.
  var host: String
  var automatic: [AutomaticAddress]
  /// The row just added, which takes the keyboard.
  @FocusState private var focused: UUID?
  var hue: Hue = .blue

  var body: some View {
    let issues = FallbackAddresses.issues(rows, host: host)
    FormRow(
      "Fallback Addresses", help: "Tried in order when the address doesn't answer", systemImage: "arrow.triangle.branch",
      hue: hue
    ) {
      Button("Add Address", systemImage: "plus") {
        let row = FallbackAddress()
        withKitAnimation { rows.append(row) }
        // Once the row's field exists (the form row keeps its own focus binding on it too).
        Task { @MainActor in focused = row.id }
      }
        .buttonStyle(.kit)
        .help("Add another address of this host")
    }
    ForEach($rows) { $row in
      FormRow(
        "Fallback \((rows.firstIndex { $0.id == row.id } ?? 0) + 1)", systemImage: "arrow.turn.down.right", hue: hue,
        error: issues[row.id], field: addressField($row.address).focused($focused, equals: row.id)
      ) {
        Button("Remove", systemImage: "minus.circle") {
          withKitAnimation { rows.removeAll { $0.id == row.id } }
        }
        .buttonStyle(.kitIcon)
        .help("Remove this address")
      }
    }
    ForEach(automatic, id: \.address) { address in
      FormRow(address.address, help: address.source, systemImage: "checkmark.circle", hue: .gray)
        .titleAccessory { Chip("Automatic", style: .quiet) }
    }
  }

  private func addressField(_ text: Binding<String>) -> some View {
    #if os(iOS)
    TextField("studio.local", text: text).textContentType(.URL).textInputAutocapitalization(.never)
      .autocorrectionDisabled()
    #else
    TextField("studio.local", text: text).autocorrectionDisabled()
    #endif
  }
}
