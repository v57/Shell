import Testing
import Foundation
@testable import Monitoring

/// The stats history ring buffers: one Int per metric per tick, written at
/// `updatesCount % 600`, with the newest sample readable as the right edge
/// of the 600-slot graph window (10 minutes at 1 sample/sec).
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

  /// The graph window: the FULL 600-slot ring (10 minutes), newest write
  /// at slot `(updatesCount - 1) % 600`, oldest visible sample first
  /// after the ring has wrapped. With fewer than 600 recorded, only the
  /// written samples appear (oldest written first).
  @Test func fullWindowIsNewestSixHundredInOrder() {
    let monitor = SystemStatsMonitor()
    let total = 750
    for second in 0..<total {
      monitor.record(cpu: second, gpu: second * 2, watts: total - second)
    }
    let window = (0..<600).map {
      monitor.cpuHistory[(total - 600 + $0) % 600]
    }
    #expect(window == Array(150..<750))        // samples 150…749, oldest first

    // GPU/watts follow the same window from their buffers.
    let gpuWindow = (0..<600).map {
      monitor.gpuHistory[(total - 600 + $0) % 600]
    }
    #expect(gpuWindow == Array((150..<750).map { $0 * 2 }))
    let wattNewest = monitor.wattHistory[(total - 1) % 600]
    #expect(wattNewest == 1)                   // watts count down: 750-749
  }

  /// The newest sample of each metric (`latestCPU`/`latestGPU`/`latestWatts`):
  /// nil before the first tick, then the newest ring slot, following the
  /// wrap once updatesCount passes 600.
  @Test func latestSampleFollowsNewestRingSlot() {
    let monitor = SystemStatsMonitor()
    #expect(monitor.latestCPU == nil)
    #expect(monitor.latestGPU == nil)
    #expect(monitor.latestWatts == nil)

    monitor.record(cpu: 11, gpu: 22, watts: 33)
    #expect(monitor.latestCPU == 11)
    #expect(monitor.latestGPU == 22)
    #expect(monitor.latestWatts == 33)

    for second in 0..<605 {
      monitor.record(cpu: second, gpu: 0, watts: 0)
    }
    #expect(monitor.updatesCount == 606)
    #expect(monitor.latestCPU == 604)          // 604 % 600 → slot 4, wrapped
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
