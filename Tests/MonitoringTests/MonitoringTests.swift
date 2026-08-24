import Testing
import Foundation
@testable import Monitoring

/// The stats history ring buffers: one Int per metric per tick, written at
/// `updatesCount % 600`, with the newest sample readable as the last
/// minute-window entry.
@MainActor
struct MonitoringTests {
  /// Each record() writes cpu/gpu/watts into the slot updatesCount%600
  /// and bumps the counter — the exact contract StatsGraphView reads.
  @Test func recordWritesAtUpdatesCountModuloSlot() {
    let monitor = SystemStatsMonitor()
    #expect(monitor.updatesCount == 0)
    monitor.record(cpu: 11, gpu: 22, watts: 33)
    #expect(monitor.updatesCount == 1)
    #expect(monitor.cpuHistory[0] == 11)
    #expect(monitor.gpuHistory[0] == 22)
    #expect(monitor.wattHistory[0] == 33)

    // Slot index follows the counter, not the array position.
    monitor.record(cpu: 44, gpu: 55, watts: 66)
    #expect(monitor.updatesCount == 2)
    #expect(monitor.cpuHistory[1] == 44)
    #expect(monitor.gpuHistory[1] == 55)
    #expect(monitor.wattHistory[1] == 66)
  }

  /// After wrapping (updatesCount ≥ 600) writes land back at slot 0 and
  /// overwrite the oldest sample; arrays never grow past 600 entries.
  @Test func ringWrapsAndOverwritesOldest() {
    let monitor = SystemStatsMonitor()
    for second in 0..<610 {
      monitor.record(cpu: second, gpu: 0, watts: 0)
    }
    #expect(monitor.cpuHistory.count == 600)   // fixed size
    #expect(monitor.updatesCount == 610)
    #expect(monitor.cpuHistory[9] == 609)      // 609 % 600 → wrapped to slot 9
    #expect(monitor.cpuHistory[10] == 10)      // untouched old sample
    // The stale first-pass value in slot 9 is gone.
    #expect(monitor.cpuHistory[9] != 9)
  }

  /// The graph window: the 60 newest written samples, oldest of those
  /// first. With fewer than 60 recorded, only the written ones appear.
  @Test func lastMinuteWindowIsNewestSixtyInOrder() {
    let monitor = SystemStatsMonitor()
    let total = 150
    for second in 0..<total {
      monitor.record(cpu: second, gpu: second * 2, watts: total - second)
    }
    let window = (0..<60).map {
      monitor.cpuHistory[(total - 60 + $0) % 600]
    }
    #expect(window == Array(90..<150))         // samples 90…149, oldest first

    // GPU/watts follow the same window from their buffers.
    let gpuWindow = (0..<60).map {
      monitor.gpuHistory[(total - 60 + $0) % 600]
    }
    #expect(gpuWindow == Array((90..<150).map { $0 * 2 }))
    let wattNewest = monitor.wattHistory[(total - 1) % 600]
    #expect(wattNewest == 1)                   // watts count down: 150-149
  }

  /// A brand-new monitor has an all-zero history and an empty window
  /// (nothing sampled yet) — no fake data before the first tick.
  @Test func freshMonitorHasEmptyWindow() {
    let monitor = SystemStatsMonitor()
    #expect(monitor.updatesCount == 0)
    #expect(monitor.cpuHistory.count == 600)
    #expect(monitor.cpuHistory.allSatisfy { $0 == 0 })
    #expect(monitor.gpuHistory.allSatisfy { $0 == 0 })
    #expect(monitor.wattHistory.allSatisfy { $0 == 0 })
  }

}
