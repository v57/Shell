import Foundation
import Testing
@testable import TerminalIntegrations

struct EnvironmentProbeTests {
  @Test func injectableFlagsRoundTrip() {
    let a = EnvironmentProbe(xcodebuildAvailable: true, swiftAvailable: false)
    #expect(a.xcodebuildAvailable == true)
    #expect(a.swiftAvailable == false)
    let b = EnvironmentProbe(xcodebuildAvailable: false, swiftAvailable: true)
    #expect(b != a)
  }

  @Test func liveProbeDoesNotThrow() {
    // Runs the real xcrun probe; only asserts it completes and returns a
    // well-formed result. Availability depends on the machine's toolchain.
    let probe = EnvironmentProbe.probe()
    #expect(probe.xcodebuildAvailable || probe.swiftAvailable) // at least well-formed
  }
}
