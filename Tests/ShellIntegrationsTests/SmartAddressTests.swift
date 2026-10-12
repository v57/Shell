import Foundation
import Testing
@testable import ShellIntegrations

struct SmartAddressTests {
  // The four cases from the action web-field spec.
  @Test func barePortDefaultsToLocalhostHTTP() {
    #expect(SmartAddress.resolve("1997") == "http://localhost:1997")
  }

  @Test func localhostWithPortIsHTTP() {
    #expect(SmartAddress.resolve("localhost:1997") == "http://localhost:1997")
  }

  @Test func dotLocalNameIsHTTP() {
    #expect(SmartAddress.resolve("mac.local") == "http://mac.local")
    #expect(SmartAddress.resolve("printer.local:3000") == "http://printer.local:3000")
  }

  @Test func nonLocalHostIsHTTPS() {
    #expect(SmartAddress.resolve("v57.dev") == "https://v57.dev")
    #expect(SmartAddress.resolve("v57.dev:8443") == "https://v57.dev:8443")
  }

  @Test func explicitSchemeIsUnchanged() {
    #expect(SmartAddress.resolve("http://localhost:1997") == "http://localhost:1997")
    #expect(SmartAddress.resolve("https://v57.dev") == "https://v57.dev")
  }

  @Test func bareLocalhostWithoutPort() {
    #expect(SmartAddress.resolve("localhost") == "http://localhost")
  }

  @Test func loopbackAddressesAreLocal() {
    #expect(SmartAddress.resolve("127.0.0.1:8080") == "http://127.0.0.1:8080")
  }

  @Test func emptyAndWhitespaceResolveEmpty() {
    #expect(SmartAddress.resolve("") == "")
    #expect(SmartAddress.resolve("   ") == "")
  }

  @Test func surroundingWhitespaceIsTrimmed() {
    #expect(SmartAddress.resolve("  1997  ") == "http://localhost:1997")
  }

  @Test func plainHostnameDefaultsHTTPS() {
    #expect(SmartAddress.resolve("example.com") == "https://example.com")
  }
}
