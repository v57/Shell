#if os(macOS)
import SwiftUI
import Charts
import Monitoring

/// The stats graphs sheet, opened by clicking the Local section header in
/// the sidebar: CPU%, GPU%, and system wattage over the last 10 minutes —
/// the full 600-slot ring buffer, oldest at the left, newest ("now") at
/// the right edge.
///
/// Each metric is a leading-aligned title row above its chart; the three
/// charts fill the container width (no horizontal scrolling) so the whole
/// 600-sample window is always visible without panning. Live: SwiftUI
/// re-renders each tick through `@Observable`.
struct StatsGraphView: View {
  /// The sidebar's shared monitor — same instance the header reads.
  let monitor: SystemStatsMonitor

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      StatTitle(title: "CPU", unit: "%", value: monitor.latestCPU)
      StatChart(
        color: .blue,
        samples: monitor.cpuHistory,
        updatesCount: monitor.updatesCount,
        yRange: 0...100
      )
      StatTitle(title: "GPU", unit: "%", value: monitor.latestGPU)
      StatChart(
        color: .purple,
        samples: monitor.gpuHistory,
        updatesCount: monitor.updatesCount,
        yRange: 0...100
      )
      StatTitle(title: "Power", unit: "W", value: monitor.latestWatts)
      StatChart(
        color: .orange,
        samples: monitor.wattHistory,
        updatesCount: monitor.updatesCount,
        yRange: nil   // autoscale — watts aren't bounded like percentages
      )
    }
    .padding(20)
    .frame(width: 440, height: 620)
  }
}

/// One metric's header: title plus the newest sample (absent until
/// the first tick lands).
private struct StatTitle: View {
  let title: String
  let unit: String
  let value: Int?

  var body: some View {
    HStack(spacing: 6) {
      Text(title)
        .font(.headline)
      if let value {
        Text("\(value)\(unit)")
          .font(.callout.monospacedDigit())
          .foregroundStyle(.secondary)
      }
    }
  }
}

/// One metric's line chart over the full ring: all written samples mapped
/// onto the 600-position window (0 = ten minutes ago, 599 = now), plotted
/// across the container width. Before the first sample lands
/// (`updatesCount == 0`) there is no data yet and the chart renders empty
/// instead of a fake flat line; a partially filled ring occupies the right
/// end ("now") with an empty left region.
private struct StatChart: View {
  let color: Color
  let samples: [Int]
  let updatesCount: Int
  /// Fixed y domain for percentages; nil = autoscale to the data.
  let yRange: ClosedRange<Int>?

  private struct Point: Identifiable {
    /// Axis position: 0 = oldest end of the window, `count-1` = now.
    let position: Int
    let value: Int
    var id: Int { position }
  }

  /// The newest written samples, oldest first, mapped onto the full
  /// window so the newest sample is always the right edge ("now").
  private var points: [Point] {
    guard updatesCount > 0 else { return [] }
    let written = min(samples.count, updatesCount)
    return (0..<written).map { age in
      let slot = (updatesCount - 1 - age) % samples.count
      return Point(position: samples.count - 1 - age, value: samples[slot])
    }
  }

  var body: some View {
    Chart(points) { point in
      LineMark(
        x: .value("Position", point.position),
        y: .value("Value", point.value)
      )
      .foregroundStyle(color)
      .interpolationMethod(.catmullRom)
      AreaMark(
        x: .value("Position", point.position),
        y: .value("Value", point.value)
      )
      .foregroundStyle(
        .linearGradient(
          colors: [color.opacity(0.25), color.opacity(0.02)],
          startPoint: .top, endPoint: .bottom
        )
      )
      .interpolationMethod(.catmullRom)
    }
    .chartXAxis {
      
    }
    .chartYAxis {
      AxisMarks(position: .trailing)
    }
    .chartYScale(domain: yRange.map { Double($0.lowerBound)...Double($0.upperBound) } ?? domainForPoints)
    .chartXScale(domain: 0...Double(samples.count - 1))
    .frame(maxWidth: .infinity)
    .frame(height: 140)
  }

  /// Minute marks across the window plus the final "now" tick.
  private var xMarkPositions: [Int] {
    let last = samples.count - 1
    let step = 60
    var marks = Array(stride(from: 0, through: last - (last % step), by: step))
    if marks.last != last { marks.append(last) }
    return marks
  }

  /// Autoscale domain for unbounded metrics (watts): headroom above the
  /// peak, floored so a flat zero line still shows a sane axis.
  private var domainForPoints: ClosedRange<Double> {
    let peak = Double(points.map(\.value).max() ?? 0)
    return 0...max(peak * 1.2, 10)
  }
}
#endif
