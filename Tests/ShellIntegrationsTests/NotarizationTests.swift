import Foundation
import Testing
@testable import ShellIntegrations

struct NotarizationTests {
  @Test func parsesOnlyDeveloperIDApplicationIdentities() {
    let output = """
      1) 0123456789ABCDEF0123456789ABCDEF01234567 "Apple Development: Jane Doe (N97KT34BX7)"
      2) 1123456789ABCDEF0123456789ABCDEF01234567 "Developer ID Application: Jane Doe (AUCR797TMH)"
      3) 2123456789ABCDEF0123456789ABCDEF01234567 "Apple Distribution: Example Ltd. (T8BYC53S7N)"
      4) 3123456789ABCDEF0123456789ABCDEF01234567 "Developer ID Application: Дмитрий (Personal) (ZZZZ99ZZZZ)"
         4 valid identities found
    """
    #expect(Notarization.parseDeveloperIDIdentities(output) == [
      DeveloperIDIdentity(name: "Developer ID Application: Jane Doe (AUCR797TMH)", teamID: "AUCR797TMH"),
      DeveloperIDIdentity(name: "Developer ID Application: Дмитрий (Personal) (ZZZZ99ZZZZ)", teamID: "ZZZZ99ZZZZ"),
    ])
  }

  @Test func parsesNoIdentities() {
    #expect(Notarization.parseDeveloperIDIdentities("     0 valid identities found\n").isEmpty)
  }

  @Test func profileStatusReadsHistoryResult() {
    #expect(Notarization.profileStatus(exitCode: 0, output: "{\"history\":[]}") == .valid)
    #expect(Notarization.profileStatus(
      exitCode: 69,
      output: "Error: No Keychain password item found for profile: notary\n"
    ) == .missing)
    #expect(Notarization.profileStatus(exitCode: 1, output: "Error: HTTP status code: 401. Invalid credentials.\n")
      == .failed("Error: HTTP status code: 401. Invalid credentials."))
    #expect(Notarization.profileStatus(exitCode: 3, output: "") == .failed("notarytool exited with status 3."))
  }

  @Test func storeArgumentsPerMethod() {
    #expect(Notarization.storeArguments(
      profile: "notary",
      credentials: .apiKey(path: "/k/AuthKey_ABC.p8", keyID: "ABC", issuerID: "1-2-3")
    ) == ["notarytool", "store-credentials", "notary", "--key", "/k/AuthKey_ABC.p8", "--key-id", "ABC", "--issuer", "1-2-3"])
    #expect(Notarization.storeArguments(
      profile: "notary",
      credentials: .apiKey(path: "/k/AuthKey_ABC.p8", keyID: "ABC", issuerID: "")
    ) == ["notarytool", "store-credentials", "notary", "--key", "/k/AuthKey_ABC.p8", "--key-id", "ABC"])
    #expect(Notarization.storeArguments(
      profile: "work",
      credentials: .appleID(appleID: "jane@example.com", teamID: "AUCR797TMH")
    ) == ["notarytool", "store-credentials", "work", "--apple-id", "jane@example.com", "--team-id", "AUCR797TMH"])
  }
}
