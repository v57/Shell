# ShellMonitoring

ShellMonitoring reads live system load for the header of Shell's This Computer section: CPU use, GPU use and the
power the computer draws, once a second, with ten minutes of history for the graphs. The reads run on a background
thread and need no helper or root rights.

It is not a process monitor or a profiler, and it keeps nothing on disk.

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

- `start()` starts the one-second polling (calling it again does nothing); `stop()` stops it.
- `cpuPercent`, `gpuPercent` (0 to 100), `watts` (the whole system), `dcInWatts` (power from the adapter, on Macs
  with a battery; nil elsewhere).
- `cpuHistory`, `gpuHistory`, `wattHistory`: 600 samples each (ten minutes), written as a ring at
  `updatesCount % 600`; `latestCPU`, `latestGPU`, `latestWatts` read the newest.

## Platform notes

- **macOS:** CPU from `host_processor_info` (performance cores only on Apple silicon), GPU from IOAccelerator, power
  from the SMC's system-total key, DC-in from the SMC on Macs with a battery.
- **Linux:** CPU from `/proc/stat` through the Platform repository's `PlatformSystem` (all cores). GPU and power stay
  0.
- **Windows:** CPU from `GetSystemTimes` (all cores). GPU and power stay 0.
- **iOS, iPadOS:** the library is empty there (`SystemStatsMonitor` isn't compiled).
- **Android:** not yet.

## Testing

```bash
swift test --filter ShellMonitoringTests
```

The tests cover the history ring and need no hardware access.
