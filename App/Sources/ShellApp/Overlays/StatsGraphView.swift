#if os(macOS) || os(Windows) || os(Linux)
import ComponentKit
import SwiftUI
import ShellMonitoring

/// The stats graphs sheet, opened by clicking the Local section header in
/// the sidebar: CPU%, GPU%, and system wattage over the last 10 minutes —
/// the full 600-slot ring buffer, oldest at the left, newest ("now") at
/// the right edge.
///
/// The newest values lead as the kit's stat cards; under them each metric's
/// graph (`KitSparkline`, a fixed 600-slot window filling from the right) fills
/// the sheet's width, so the whole window is always visible without panning.
/// Live: SwiftUI re-renders each tick through `@Observable`.
struct StatsGraphView: View {
  /// The sidebar's shared monitor — same instance the header reads.
  let monitor: SystemStatsMonitor
  @Environment(\.kitDismiss) private var dismiss

  var body: some View {
    KitSheet(
      title: "Activity", meta: "The last 10 minutes", systemImage: "gauge.with.dots.needle.33percent", hue: .green,
      width: 480, onClose: { dismiss() }
    ) {
      HStack(spacing: KitMetrics.gutter) {
        KitStatCard("CPU", value: text(monitor.latestCPU, unit: "%"), systemImage: "cpu", hue: .blue)
        KitStatCard("GPU", value: text(monitor.latestGPU, unit: "%"), systemImage: "square.stack.3d.up", hue: .purple)
        KitStatCard(
          "Power", value: text(monitor.latestWatts, unit: " W"), systemImage: "bolt", hue: .orange,
          detail: monitor.dcInWatts.map { "DC in \($0)W" })
      }
      .padding(.horizontal, KitMetrics.gutter)
      VStack(alignment: .leading, spacing: 12) {
        graph("CPU", samples: monitor.cpuHistory, hue: .blue, range: 0...100) { "\(Int($0))%" }
        graph("GPU", samples: monitor.gpuHistory, hue: .purple, range: 0...100) { "\(Int($0))%" }
        // Autoscaled: watts aren't bounded like percentages.
        graph("Power", samples: monitor.wattHistory, hue: .orange, range: nil) { "\(Int($0)) W" }
      }
      .kitCard(padding: 12)
      .padding(.horizontal, KitMetrics.gutter)
    }
  }

  private func text(_ value: Int?, unit: String) -> String {
    value.map { "\($0)\(unit)" } ?? "—"
  }

  /// One metric's graph under its name. Before the first sample lands there is no data and the graph is empty
  /// instead of a fake flat line; a partly filled ring occupies the right end ("now").
  private func graph(
    _ title: String, samples: [Int], hue: Hue, range: ClosedRange<Double>?, label: @escaping (Double) -> String
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).kitFont(.caption)
      KitSparkline(
        values: written(samples).map(Double.init), hue: hue, range: range ?? autoscale(samples),
        capacity: samples.count, axisLabel: label)
        .frame(height: 100)
    }
  }

  /// The written samples, oldest first (the ring's newest write is at `(updatesCount - 1) % capacity`).
  private func written(_ samples: [Int]) -> [Int] {
    let count = monitor.updatesCount
    guard count > 0, !samples.isEmpty else { return [] }
    let written = min(samples.count, count)
    return (0..<written).reversed().map { age in samples[(count - 1 - age) % samples.count] }
  }

  /// The scale for unbounded metrics (watts): headroom above the peak, floored so a flat zero line still shows a
  /// sane axis.
  private func autoscale(_ samples: [Int]) -> ClosedRange<Double> {
    let peak = Double(written(samples).max() ?? 0)
    return 0...max(peak * 1.2, 10)
  }
}
#endif
