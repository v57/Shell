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
    user: String = NSUserName(),
    port: Int = 22,
    authMethod: AuthMethod = .keychainKey,
    savePassword: Bool = true,
    recordID: String? = nil
  ) {
    self.id = id
    self.name = name
    self.host = host
    self.user = user
    self.port = port
    self.authMethod = authMethod
    self.savePassword = savePassword
    self.recordID = recordID
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
