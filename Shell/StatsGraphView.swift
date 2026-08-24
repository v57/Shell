import SwiftUI
import Charts
import Monitoring

/// The stats graphs sheet, opened by clicking the Local section header in
/// the sidebar: CPU%, GPU%, and system wattage over the last minute (the
/// 60 newest slots of the monitor's ring buffers, oldest → newest left to
/// right; the leading zero-filled segment is simply "not sampled yet").
/// Live: SwiftUI re-renders each tick through `@Observable`.
struct StatsGraphView: View {
  /// The sidebar's shared monitor — same instance the header reads.
  let monitor: SystemStatsMonitor

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      StatChart(
        title: "CPU",
        unit: "%",
        color: .blue,
        samples: monitor.cpuHistory,
        updatesCount: monitor.updatesCount,
        yRange: 0...100
      )
      StatChart(
        title: "GPU",
        unit: "%",
        color: .purple,
        samples: monitor.gpuHistory,
        updatesCount: monitor.updatesCount,
        yRange: 0...100
      )
      StatChart(
        title: "Power",
        unit: "W",
        color: .orange,
        samples: monitor.wattHistory,
        updatesCount: monitor.updatesCount,
        yRange: nil   // autoscale — watts aren't bounded like percentages
      )
      Spacer(minLength: 0)
    }
    .padding(20)
    .frame(width: 440, height: 560)
  }
}

/// One metric's line chart over the last minute. The window ends at the
/// current second ("now") and extends back through the 60 newest ring
/// entries; x values are whole seconds before now.
private struct StatChart: View {
  let title: String
  let unit: String
  let color: Color
  let samples: [Int]
  let updatesCount: Int
  /// Fixed y domain for percentages; nil = autoscale to the data.
  let yRange: ClosedRange<Int>?

  private struct Point: Identifiable {
    let secondsAgo: Int
    let value: Int
    var id: Int { secondsAgo }
  }

  /// The last 60 written samples mapped to "seconds ago", oldest first.
  /// Before the first sample lands (`updatesCount == 0`) there is no
  /// window yet and the chart renders empty instead of a fake flat line.
  private var points: [Point] {
    guard updatesCount > 0 else { return [] }
    let count = min(60, updatesCount)
    return (0..<count).reversed().map { offset in
      let slot = (updatesCount - 1 - offset) % samples.count
      return Point(secondsAgo: count - 1 - offset, value: samples[slot])
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Text(title)
          .font(.headline)
        if let last = points.last {
          Text("\(last.value)\(unit)")
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
      Chart(points) { point in
        LineMark(
          x: .value("Seconds ago", point.secondsAgo),
          y: .value(title, point.value)
        )
        .foregroundStyle(color)
        .interpolationMethod(.catmullRom)
        AreaMark(
          x: .value("Seconds ago", point.secondsAgo),
          y: .value(title, point.value)
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
        AxisMarks(values: [0, 15, 30, 45, 59]) { value in
          AxisGridLine()
        }
      }
      .chartYAxis {
        AxisMarks(position: .trailing)
      }
      .chartYScale(domain: yRange.map { Double($0.lowerBound)...Double($0.upperBound) } ?? domainForPoints)
      .chartXScale(domain: 0...59.0)
      .frame(height: 140)
    }
  }

  /// Autoscale domain for unbounded metrics (watts): headroom above the
  /// peak, floored so a flat zero line still shows a sane axis.
  private var domainForPoints: ClosedRange<Double> {
    let peak = Double(points.map(\.value).max() ?? 0)
    return 0...max(peak * 1.2, 10)
  }
}
