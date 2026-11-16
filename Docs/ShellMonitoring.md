# ShellMonitoring

ShellMonitoring reads live system load for the header of Shell's This Mac (This Computer, This PC) section: CPU use,
GPU use and the power the computer draws, once a second, with ten minutes of history for the graphs.

## Purpose

A small, dependency-free sampler for a status line. The reads run on a background thread and need no helper or root
rights; the monitor only publishes the results on the main actor.

It is not a process monitor or a profiler, and it keeps nothing on disk.

## Platforms

<!-- platforms: macos linux=partial windows=partial -->

- **macOS:** CPU from `host_processor_info` (performance cores only on Apple silicon), GPU from IOAccelerator, power
  from the SMC's system-total key, DC-in from the SMC on Macs with a battery.
- **Linux:** CPU from `/proc/stat` through the Platform repository's `PlatformSystem` (all cores). GPU and power stay
  0.
- **Windows:** CPU from `GetSystemTimes` (all cores). GPU and power stay 0.
- **iOS, iPadOS:** the library is empty there (`SystemStatsMonitor` isn't compiled).
- **Android:** not yet.

## Getting started

```swift
// Package.swift
dependencies: [
  .package(url: "https://github.com/v57/Shell.git", branch: "main"),
],
targets: [
  .target(name: "MyApp", dependencies: [.product(name: "ShellMonitoring", package: "Shell")]),
]
```

```swift
import ShellMonitoring
import SwiftUI

struct LoadView: View {
  @State private var stats = SystemStatsMonitor()

  var body: some View {
    Text("CPU \(Int(stats.cpuPercent))%  GPU \(Int(stats.gpuPercent))%  \(stats.watts) W")
      .onAppear { stats.start() }
      .onDisappear { stats.stop() }
  }
}
```

## Main API

`SystemStatsMonitor` (`@Observable`, main actor):

- `init()`, then `start()`: takes a first reading at once and then one a second (calling it again does nothing).
  `stop()` stops it.
- `cpuPercent`, `gpuPercent` (0 to 100), `watts` (the whole system), `dcInWatts` (power from the adapter, on Macs
  with a battery; nil elsewhere and before the first reading).
- `cpuHistory`, `gpuHistory`, `wattHistory`: 600 samples each (ten minutes), written as a ring at
  `updatesCount % 600`; `latestCPU`, `latestGPU`, `latestWatts` read the newest.

## Testing

```bash
swift test --filter ShellMonitoringTests
```

The tests cover the history ring and need no hardware access.

## Related

- [ShellKit](ShellKit.md): the terminal library the rest of Shell is built on.
- Shell's guide: [Local Terminals and Sessions](Local-Terminals-and-Sessions.md#watch-cpu-gpu-and-power).
