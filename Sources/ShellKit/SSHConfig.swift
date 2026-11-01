import Foundation

// SSH connection configuration + persistence.
// Extracted from the Shell app (SSHConfig.swift) into the Terminal library.

/// Configuration for an SSH connection. Stored in UserDefaults (non-secret
/// fields only); passwords and keys live in the Keychain.
public struct SSHConfig: Identifiable, Codable, Hashable {
  public enum AuthMethod: String, Codable, CaseIterable, Identifiable {
    case keychainKey
    case password
    
    public var id: String { rawValue }
    
    public var label: String {
      switch self {
      case .keychainKey:
        return "SSH Key (Keychain)"
      case .password:
        return "Password"
      }
    }
  }
  
  public var id: UUID
  public var name: String
  public var host: String
  /// Other addresses of the same machine the user added, tried in order when `host` doesn't answer
  /// (`VaultHost.fallbacks`).
  public var fallbacks: [String]
  /// The ways to one of the user's own devices the vault adds after `fallbacks` (the name the Mac published, its
  /// Bonjour name, its Hub Network address: `Vault.fallbackAddresses(of:)`). Read from the vault, never saved.
  public var automaticFallbacks: [String]
  public var user: String
  public var port: Int
  public var authMethod: AuthMethod
  public var savePassword: Bool
  /// The shared record's id when it isn't `id` (a host another app made, such as a Hub device's), nil otherwise.
  public var recordID: String?
  
  public init(
    id: UUID = UUID(),
    name: String = "",
    host: String,
    fallbacks: [String] = [],
    automaticFallbacks: [String] = [],
    user: String = NSUserName(),
    port: Int = 22,
    authMethod: AuthMethod = .keychainKey,
    savePassword: Bool = true,
    recordID: String? = nil
  ) {
    self.id = id
    self.name = name
    self.host = host
    self.fallbacks = fallbacks
    self.automaticFallbacks = automaticFallbacks
    self.user = user
    self.port = port
    self.authMethod = authMethod
    self.savePassword = savePassword
    self.recordID = recordID
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, host, fallbacks, automaticFallbacks, user, port, authMethod, savePassword, recordID
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    name = try values.decode(String.self, forKey: .name)
    host = try values.decode(String.self, forKey: .host)
    // Configs saved before fallback addresses have none.
    fallbacks = try values.decodeIfPresent([String].self, forKey: .fallbacks) ?? []
    automaticFallbacks = try values.decodeIfPresent([String].self, forKey: .automaticFallbacks) ?? []
    user = try values.decode(String.self, forKey: .user)
    port = try values.decode(Int.self, forKey: .port)
    authMethod = try values.decode(AuthMethod.self, forKey: .authMethod)
    savePassword = try values.decode(Bool.self, forKey: .savePassword)
    recordID = try values.decodeIfPresent(String.self, forKey: .recordID)
  }

  /// Every address to try, in order, each once: `host`, the user's fallbacks, then the vault's.
  public var addresses: [String] {
    var seen = Set<String>()
    return ([host] + fallbacks + automaticFallbacks).filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
  }

  /// The id of the shared record (`VaultHost`) this connection is.
  public var vaultID: String { recordID ?? id.uuidString }
  
  /// Name if given, otherwise user@host.
  public var displayName: String {
    if !name.isEmpty {
      return name
    }
    return user.isEmpty ? host : "\(user)@\(host)"
  }
  
  /// Keychain account used for this connection's saved password.
  public var passwordAccount: String {
    "ssh-password-\(vaultID)"
  }
}
