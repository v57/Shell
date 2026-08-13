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
  /// Uses the separate "sensitive" Secure Enclave key instead of the
  /// main identity key. Defaults to false for existing saved configs
  /// (Codable falls back to the default when the key is missing).
  public var useSensitiveKey: Bool
  
  public init(
    id: UUID = UUID(),
    name: String = "",
    host: String,
    user: String = NSUserName(),
    port: Int = 22,
    authMethod: AuthMethod = .keychainKey,
    savePassword: Bool = true,
    useSensitiveKey: Bool = false
  ) {
    self.id = id
    self.name = name
    self.host = host
    self.user = user
    self.port = port
    self.authMethod = authMethod
    self.savePassword = savePassword
    self.useSensitiveKey = useSensitiveKey
  }
  
  /// Name if given, otherwise user@host.
  public var displayName: String {
    if !name.isEmpty {
      return name
    }
    return user.isEmpty ? host : "\(user)@\(host)"
  }
  
  /// Backward-compatible decode: configs saved before `useSensitiveKey`
  /// existed have no such key — decodeIfPresent keeps them loadable
  /// (the synthesized decoder throws keyNotFound instead).
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    name = try c.decode(String.self, forKey: .name)
    host = try c.decode(String.self, forKey: .host)
    user = try c.decode(String.self, forKey: .user)
    port = try c.decode(Int.self, forKey: .port)
    authMethod = try c.decode(AuthMethod.self, forKey: .authMethod)
    savePassword = try c.decode(Bool.self, forKey: .savePassword)
    useSensitiveKey = try c.decodeIfPresent(Bool.self, forKey: .useSensitiveKey) ?? false
  }
  
  /// Keychain account used for this connection's saved password.
  public var passwordAccount: String {
    "ssh-password-\(id.uuidString)"
  }
}

