import ComponentKit
import ShellIntegrations

extension ActionKind {
  /// Whether Shell offers this kind on this system: an Export notarizes, which needs Apple's notarytool, so Linux
  /// leaves it (and the Notarization sheet) out.
  var isOfferedHere: Bool {
    #if os(Linux)
    !needsNotarization
    #else
    true
    #endif
  }
}

#if os(macOS) || os(Windows) || os(Linux)
import SwiftUI
import ShellKit
import UniformTypeIdentifiers

/// What opened the Notarization sheet: a scheme's Export waiting to run, or
/// the Distribute menu's settings item (no scheme).
struct NotarizationSetupRequest: Identifiable {
  let id = UUID()
  let scheme: ActionScheme?
  let directory: URL?

  init(scheme: ActionScheme? = nil, directory: URL? = nil) {
    self.scheme = scheme
    self.directory = directory
  }
}

/// Sets up what the Export smart action needs: a Developer ID Application
/// certificate, and a notarytool keychain profile, either an existing one
/// (checked with notarytool) or a new one saved from an app-specific password
/// or an App Store Connect API key. The credentials go straight to notarytool,
/// which keeps them in the keychain; the app stores only the profile name.
struct NotarizationSetupView: View {
  let request: NotarizationSetupRequest
  @Environment(AppModel.self) private var model
  @Environment(\.kitDismiss) private var dismiss

  private enum Mode: Hashable { case existing, new }
  private enum Method: Hashable { case appleID, apiKey }
  private enum ProfileCheck: Equatable {
    case idle, checking
    case done(NotaryProfileStatus)
  }

  /// nil while `security find-identity` runs.
  @State private var identities: [DeveloperIDIdentity]?
  @State private var mode: Mode = .existing
  @State private var profile = ""
  /// The last check, for `checkedProfile`; editing the name makes it stale.
  @State private var lastCheck: ProfileCheck = .idle
  @State private var checkedProfile = ""

  @State private var method: Method = .appleID
  @State private var newProfile = Notarization.defaultProfile
  @State private var appleID = ""
  @State private var teamID = ""
  @State private var password = ""
  @State private var keyURL: URL?
  @State private var keyID = ""
  @State private var issuerID = ""
  @State private var showingKeyImporter = false
  @State private var saving = false
  @State private var saveError: String?

  private var hasDeveloperID: Bool { !(identities ?? []).isEmpty }
  private var check: ProfileCheck { checkedProfile == trimmed(profile) ? lastCheck : .idle }
  private var profileIsValid: Bool { mode == .existing && check == .done(.valid) }

  private var canSave: Bool {
    guard !saving, !trimmed(newProfile).isEmpty else { return false }
    switch method {
    case .appleID: return !trimmed(appleID).isEmpty && !trimmed(teamID).isEmpty && !password.isEmpty
    case .apiKey: return keyURL != nil && !trimmed(keyID).isEmpty
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      Text("Notarization")
        .font(.headline)
        .padding(.top, 16)
        .padding(.bottom, 8)

      Form {
        developerIDSection
        profileSection
        if mode == .new {
          newProfileSection
        }
      }
      .formStyle(.grouped)

      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
        Button(request.scheme == nil ? "Done" : "Export") { finish() }
          .keyboardShortcut(.defaultAction)
          .disabled(!hasDeveloperID || !profileIsValid)
      }
      .padding()
    }
    .frame(width: 480, height: 580)
    .task {
      let saved = model.notaryProfile ?? Notarization.defaultProfile
      profile = saved
      newProfile = saved
      await loadIdentities()
      await checkProfile()
      // Nothing saved under that name yet: go straight to creating it.
      if check == .done(.missing) { mode = .new }
    }
    .fileImporter(
      isPresented: $showingKeyImporter,
      allowedContentTypes: [UTType(filenameExtension: "p8") ?? .data]
    ) { result in
      if case .success(let url) = result {
        keyURL = url
        // AuthKey_<KEYID>.p8 is how App Store Connect names the download.
        let name = url.deletingPathExtension().lastPathComponent
        if keyID.isEmpty, name.hasPrefix("AuthKey_") { keyID = String(name.dropFirst("AuthKey_".count)) }
      }
    }
  }

  // MARK: - Sections

  private var developerIDSection: some View {
    Section {
      if let identities {
        if identities.isEmpty {
          Label("No Developer ID Application certificate in the keychain", systemImage: "xmark.octagon.fill")
            .foregroundStyle(.red)
          Button("Check Again") { Task { await loadIdentities() } }
        } else {
          ForEach(identities, id: \.self) { identity in
            Label(identity.name, systemImage: "checkmark.seal.fill")
              .foregroundStyle(.green)
          }
        }
      } else {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Looking for certificates…")
        }
      }
    } header: {
      Text("Developer ID")
    } footer: {
      if identities?.isEmpty == true {
        Text("Create one in Xcode: Settings → Accounts → your team → Manage Certificates → + → Developer ID Application. Only the team's Account Holder can create it.")
      } else {
        Text("Export signs the app with the certificate of the project's team.")
      }
    }
  }

  private var profileSection: some View {
    Section {
      Picker("Profile", selection: $mode) {
        Text("Use existing").tag(Mode.existing)
        Text("Create new").tag(Mode.new)
      }
      .pickerStyle(.segmented)
      .labelsHidden()

      if mode == .existing {
        HStack {
          TextField("Profile name", text: $profile)
            .onSubmit { Task { await checkProfile() } }
          Button("Check") { Task { await checkProfile() } }
            .disabled(trimmed(profile).isEmpty || check == .checking)
        }
        checkStatus
      }
    } header: {
      Text("Notary profile")
    } footer: {
      Text("A notarytool keychain profile, the one `xcrun notarytool store-credentials` saves. Checking it asks Apple's notary service, so it needs a network connection.")
    }
  }

  @ViewBuilder
  private var checkStatus: some View {
    switch check {
    case .idle:
      EmptyView()
    case .checking:
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Checking with Apple…")
      }
    case .done(.valid):
      Label("Profile works", systemImage: "checkmark.seal.fill")
        .foregroundStyle(.green)
    case .done(.missing):
      HStack {
        Label("No profile named “\(trimmed(profile))” in the keychain", systemImage: "questionmark.diamond.fill")
          .foregroundStyle(.orange)
        Spacer()
        Button("Create It") {
          newProfile = trimmed(profile)
          mode = .new
        }
      }
    case .done(.failed(let message)):
      VStack(alignment: .leading, spacing: 4) {
        Label("The profile doesn't work", systemImage: "xmark.octagon.fill")
          .foregroundStyle(.red)
        Text(message)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .lineLimit(6)
      }
    }
  }

  private var newProfileSection: some View {
    Section {
      TextField("Profile name", text: $newProfile)
      Picker("Sign in with", selection: $method) {
        Text("App-specific password").tag(Method.appleID)
        Text("App Store Connect API key").tag(Method.apiKey)
      }

      switch method {
      case .appleID:
        TextField("Apple ID", text: $appleID)
          .textContentType(.username)
        TextField("Team ID", text: $teamID)
        SecureField("App-specific password", text: $password)
        Link("Create an app-specific password…", destination: URL(string: "https://account.apple.com/account/manage")!)
      case .apiKey:
        LabeledContent("Key file") {
          HStack {
            Text(keyURL?.lastPathComponent ?? "None")
              .foregroundStyle(keyURL == nil ? .secondary : .primary)
            Button("Choose…") { showingKeyImporter = true }
          }
        }
        TextField("Key ID", text: $keyID)
        TextField("Issuer ID (team keys)", text: $issuerID)
        Link("Create an API key in App Store Connect…", destination: URL(string: "https://appstoreconnect.apple.com/access/integrations/api")!)
      }

      HStack {
        if saving {
          ProgressView().controlSize(.small)
          Text("Checking with Apple and saving…")
        }
        Spacer()
        Button("Save to Keychain") { Task { await save() } }
          .disabled(!canSave)
      }
      if let saveError {
        Text(saveError)
          .font(.caption.monospaced())
          .foregroundStyle(.red)
          .textSelection(.enabled)
          .lineLimit(8)
      }
    } header: {
      Text("New profile")
    } footer: {
      Text("notarytool checks the credentials with Apple, then keeps them in your keychain. Shell doesn't store them.")
    }
  }

  // MARK: - Actions

  private func loadIdentities() async {
    identities = nil
    let found = await Notarization.developerIDIdentities()
    identities = found
    if teamID.isEmpty, let team = found.first?.teamID { teamID = team }
  }

  private func checkProfile() async {
    let name = trimmed(profile)
    guard !name.isEmpty else { return }
    checkedProfile = name
    lastCheck = .checking
    let status = await Notarization.checkProfile(name)
    // A newer check (another name) owns the status now.
    guard checkedProfile == name else { return }
    lastCheck = .done(status)
  }

  private func save() async {
    let name = trimmed(newProfile)
    saving = true
    saveError = nil
    let result: (exitCode: Int32, output: String)
    switch method {
    case .appleID:
      result = await NotaryProfileWriter.storeAppleID(
        profile: name, appleID: trimmed(appleID), teamID: trimmed(teamID), password: password
      )
    case .apiKey:
      guard let keyURL else { saving = false; return }
      let scoped = keyURL.startAccessingSecurityScopedResource()
      result = await Notarization.storeAPIKeyProfile(
        name, path: keyURL.path, keyID: trimmed(keyID), issuerID: trimmed(issuerID)
      )
      if scoped { keyURL.stopAccessingSecurityScopedResource() }
    }
    saving = false
    guard result.exitCode == 0 else {
      let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
      saveError = message.isEmpty ? "notarytool exited with status \(result.exitCode)." : message
      return
    }
    password = ""
    // notarytool validated the credentials before saving them.
    profile = name
    checkedProfile = name
    lastCheck = .done(.valid)
    mode = .existing
  }

  private func finish() {
    model.notaryProfile = trimmed(profile)
    dismiss()
    if let scheme = request.scheme, let directory = request.directory {
      model.runSmartAction(.export, scheme: scheme, in: directory)
    }
  }

  private func trimmed(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// Saves an Apple ID notarytool profile. notarytool reads the app-specific
/// password only from its terminal's secure prompt, so it runs in a pty and
/// gets the password typed there: it never appears in the process's arguments.
@MainActor
final class NotaryProfileWriter {
  private let transport: LocalPTYTransport
  private let password: String
  private var output = ""
  private var sentPassword = false
  private var continuation: CheckedContinuation<(exitCode: Int32, output: String), Never>?

  private init(profile: String, appleID: String, teamID: String, password: String) {
    transport = LocalPTYTransport(
      executable: "/usr/bin/xcrun",
      argv: ["xcrun"] + Notarization.storeArguments(profile: profile, credentials: .appleID(appleID: appleID, teamID: teamID))
    )
    self.password = password
  }

  static func storeAppleID(profile: String, appleID: String, teamID: String, password: String) async -> (exitCode: Int32, output: String) {
    let writer = NotaryProfileWriter(profile: profile, appleID: appleID, teamID: teamID, password: password)
    return await withCheckedContinuation { continuation in
      writer.start(continuation)
    }
  }

  private func start(_ continuation: CheckedContinuation<(exitCode: Int32, output: String), Never>) {
    self.continuation = continuation
    // The writer stays alive through these closures until `finish` drops them.
    transport.onOutput = { data in self.received(data) }
    transport.onExit = { code in self.finish(code) }
    transport.onTerminated = { message in
      self.output += message
      self.finish(-1)
    }
    transport.start()
    // notarytool asking something unexpected would otherwise wait forever.
    Task {
      try? await Task.sleep(for: .seconds(120))
      guard self.continuation != nil else { return }
      self.output += "\nTimed out waiting for notarytool."
      self.finish(-1)
    }
  }

  private func received(_ data: Data) {
    output += String(decoding: data, as: UTF8.self)
    if !sentPassword, output.range(of: "password", options: .caseInsensitive) != nil {
      sentPassword = true
      transport.write(Data((password + "\n").utf8))
    }
  }

  private func finish(_ code: Int32) {
    guard let continuation else { return }
    self.continuation = nil
    transport.onOutput = nil
    transport.onExit = nil
    transport.onTerminated = nil
    transport.close()
    continuation.resume(returning: (code, displayText()))
  }

  /// The pty output without escape sequences, carriage returns or the password.
  private func displayText() -> String {
    var text = output.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
      .replacingOccurrences(of: "\r", with: "")
    if !password.isEmpty { text = text.replacingOccurrences(of: password, with: "••••") }
    return text
  }
}
#endif
