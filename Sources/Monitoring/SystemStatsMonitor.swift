import Foundation
#if os(macOS)
import IOKit

/// Live system stats for the sidebar's Local section header: CPU usage %,
/// GPU usage %, and total system wattage. All reads run on a background
/// thread inside `SystemStatsSampler`; this monitor only publishes results.
/// Sources (all user space, no root helper needed):
///  - CPU%:  `host_processor_info` tick deltas, P-cores only on Apple
///           Silicon (E-cores excluded)
///  - GPU%:  IOAccelerator `PerformanceStatistics["Device Utilization %"]`
///  - Watts: AppleSMC `PSTR` key (System Total, float watts) via the
///           SMC user-space protocol (mirrors exelban/stats' SMC reader —
///           the SMCKeyData_t layout must include the `padding` field or
///           IOConnectCallStructMethod returns bad-argument)
@MainActor
@Observable
public final class SystemStatsMonitor {
  /// CPU usage 0-100.
  public private(set) var cpuPercent: Double = 0
  /// GPU usage 0-100.
  public private(set) var gpuPercent: Double = 0
  /// Total system power draw in watts (Int so the rounded value doesn't
  /// fire SwiftUI updates when unchanged).
  public private(set) var watts: Int = 0

  // MARK: - History (ring buffers for the stats graphs)

  /// Ring size: one slot per second for the visible minute, padded so a
  /// slow reader can never race a writer into an inconsistent window.
  static let historyCapacity = 600
  /// CPU% samples, most recent write at `(updatesCount - 1) % capacity`.
  public private(set) var cpuHistory: [Int] = Array(repeating: 0, count: historyCapacity)
  /// GPU% samples, same indexing as `cpuHistory`.
  public private(set) var gpuHistory: [Int] = Array(repeating: 0, count: historyCapacity)
  /// Wattage samples, same indexing as `cpuHistory`.
  public private(set) var wattHistory: [Int] = Array(repeating: 0, count: historyCapacity)
  /// Total samples written since start. `updatesCount % capacity` is the
  /// next slot to overwrite; the newest sample sits at index
  /// `(updatesCount - 1) % capacity` once at least one tick has landed.
  public private(set) var updatesCount = 0

  private var timer: Timer?
  private let sampler = SystemStatsSampler()
  /// Monotonic tick counter: a slow background sample from an older tick
  /// must not overwrite a newer one.
  private var generation = 0

  public init() {}

  /// Starts the 1-second polling loop (idempotent).
  public func start() {
    guard timer == nil else { return }
    let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.tick()
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
    tick()   // immediate first reading
  }

  /// Stops the polling loop.
  public func stop() {
    timer?.invalidate()
    timer = nil
  }

  /// Kicks a background sample; publishes the result on the main actor,
  /// dropping it if a newer tick has already published.
  private func tick() {
    generation += 1
    let gen = generation
    let sampler = self.sampler
    Task.detached(priority: .utility) {
      let result = sampler.sample()
      await MainActor.run {
        guard gen == self.generation else { return }   // stale sample
        self.cpuPercent = result.cpu
        self.gpuPercent = result.gpu
        self.watts = result.watts
        self.record(cpu: Int(result.cpu.rounded()), gpu: Int(result.gpu.rounded()), watts: result.watts)
      }
    }
  }

  /// Appends one sample to the three history ring buffers at slot
  /// `updatesCount % capacity`, then bumps `updatesCount`. Also used by
  /// tests to drive the buffers deterministically.
  func record(cpu: Int, gpu: Int, watts: Int) {
    let slot = updatesCount % Self.historyCapacity
    cpuHistory[slot] = cpu
    gpuHistory[slot] = gpu
    wattHistory[slot] = watts
    updatesCount += 1
  }
}

/// Performs the IOKit/SMC reads off the main thread. Owns the previous-CPU
/// tick buffer and the SMC connection, guarded by a lock; `@unchecked
/// Sendable` so it can cross into a detached task.
nonisolated final class SystemStatsSampler: @unchecked Sendable {
  private let lock = NSLock()
  /// Previous per-core tick counts (nil until first sample).
  private var previousCPU: (info: processor_info_array_t?, count: mach_msg_type_number_t)?
  private let smc = SystemStatsSMC()
  /// Logical CPU indices of performance cores, used to exclude E-cores
  /// from the CPU% read. Empty on non-Apple-Silicon (fall back to all).
  let performanceCoreIndices: Set<Int>

  init() {
    performanceCoreIndices = Self.readPerformanceCoreIndices()
  }

  /// Reads CPU/GPU/wattage in one locked pass.
  func sample() -> (cpu: Double, gpu: Double, watts: Int) {
    lock.lock()
    defer { lock.unlock() }
    let cpu = Self.readCPUUsage(previous: &previousCPU, coreFilter: performanceCoreIndices)
    let gpu = Self.readGPUUsage()
    let watts = Int((smc.read("PSTR") ?? 0).rounded())
    return (cpu, gpu, watts)
  }

  /// Enumerates Apple Silicon performance cores from the AppleARMPE
  /// registry (`cluster-type` = "P"). The logical indices match the CPU
  /// order in host_processor_info. Non-empty only on Apple Silicon.
  private static func readPerformanceCoreIndices() -> Set<Int> {
    var result = Set<Int>()
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMPE"), &iterator) == kIOReturnSuccess else {
      return result
    }
    defer { IOObjectRelease(iterator) }
    while case let service = IOIteratorNext(iterator), service != 0 {
      var entry: io_iterator_t = 0
      if IORegistryEntryGetChildIterator(service, kIOServicePlane, &entry) == kIOReturnSuccess {
        defer { IOObjectRelease(entry) }
        while case let child = IOIteratorNext(entry), child != 0 {
          defer { IOObjectRelease(child) }
          var nameBuf = [CChar](repeating: 0, count: 128)
          IORegistryEntryGetName(child, &nameBuf)
          let name = String(cString: nameBuf)
          guard name.hasPrefix("cpu"), let index = Int(name.dropFirst(3)) else { continue }
          if let rawType = IORegistryEntryCreateCFProperty(child, "cluster-type" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data,
            let type = String(data: rawType, encoding: .utf8),
            type.hasPrefix("P") {
            result.insert(index)
          }
        }
      }
      IOObjectRelease(service)
    }
    return result
  }

  /// CPU usage from host_processor_info deltas. When `coreFilter` is
  /// non-empty, only those logical CPUs are aggregated (P-cores only).
  private static func readCPUUsage(previous: inout (info: processor_info_array_t?, count: mach_msg_type_number_t)?, coreFilter: Set<Int>) -> Double {
    var numCPUs: natural_t = 0
    var info: processor_info_array_t?
    var count: mach_msg_type_number_t = 0
    let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUs, &info, &count)
    guard result == KERN_SUCCESS, let info else { return 0 }

    // Aggregate the current buffer only (single loop, += only — the
    // compiler-miscompile-safe shape), then subtract the previous
    // tick's stored totals as scalars.
    var total: UInt64 = 0
    var idle: UInt64 = 0
    for i in 0..<Int(numCPUs) where (coreFilter.isEmpty || coreFilter.contains(i)) {
      let base = Int(CPU_STATE_MAX) * i
      total += UInt64(info[base + Int(CPU_STATE_USER)])
        + UInt64(info[base + Int(CPU_STATE_SYSTEM)])
        + UInt64(info[base + Int(CPU_STATE_NICE)])
        + UInt64(info[base + Int(CPU_STATE_IDLE)])
      idle += UInt64(info[base + Int(CPU_STATE_IDLE)])
    }

    var usage: Double = 0
    if let prev = previous, let prevInfo = prev.info {
      var prevTotal: UInt64 = 0
      var prevIdle: UInt64 = 0
      for i in 0..<Int(numCPUs) where (coreFilter.isEmpty || coreFilter.contains(i)) {
        let base = Int(CPU_STATE_MAX) * i
        prevTotal += UInt64(prevInfo[base + Int(CPU_STATE_USER)])
          + UInt64(prevInfo[base + Int(CPU_STATE_SYSTEM)])
          + UInt64(prevInfo[base + Int(CPU_STATE_NICE)])
          + UInt64(prevInfo[base + Int(CPU_STATE_IDLE)])
        prevIdle += UInt64(prevInfo[base + Int(CPU_STATE_IDLE)])
      }
      let dTotal = Double(total - prevTotal)
      let dIdle = Double(idle - prevIdle)
      if dTotal > 0 {
        usage = min(100, max(0, (1 - dIdle / dTotal) * 100))
      }
      let prevSize = Int(prev.count) * MemoryLayout<integer_t>.stride
      vm_deallocate(mach_task_self_, vm_address_t(bitPattern: prevInfo), vm_size_t(prevSize))
    }
    previous = (info, count)
    return usage
  }

  /// GPU usage from the first IOAccelerator's "Device Utilization %".
  private static func readGPUUsage() -> Double {
    var iterator: io_iterator_t = 0
    let result = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator)
    guard result == kIOReturnSuccess else { return 0 }
    defer { IOObjectRelease(iterator) }

    var usage: Double = 0
    while case let entry = IOIteratorNext(iterator), entry != 0 {
      if let props = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? [String: Any],
        let util = props["Device Utilization %"] as? Int {
        usage = max(usage, Double(util))
      }
      IOObjectRelease(entry)
    }
    return min(100, max(0, usage))
  }
}

/// Minimal user-space AppleSMC key reader. Layout mirrors exelban/stats'
/// `SMCKeyData_t` exactly (the `padding` UInt16 after keyInfo is required).
private struct SystemStatsSMC {
  private let conn: io_connect_t

  init() {
    var conn: io_connect_t = 0
    var iterator: io_iterator_t = 0
    let matching = IOServiceMatching("AppleSMC")
    if IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess {
      let device = IOIteratorNext(iterator)
      IOObjectRelease(iterator)
      if device != 0 {
        _ = IOServiceOpen(device, mach_task_self_, 0, &conn)
        IOObjectRelease(device)
      }
    }
    self.conn = conn
  }

  /// Reads a 4-char SMC key as Double. Returns nil when the key doesn't
  /// exist or has an unsupported type.
  func read(_ key: String) -> Double? {
    guard conn != 0, key.utf8.count == 4 else { return nil }
    var input = SMCKeyData_t()
    var output = SMCKeyData_t()
    input.key = Self.fourCharCode(key)
    input.data8 = 9   // SMCKeys.readKeyInfo
    var result = Self.call(conn, 2, &input, &output)
    guard result == kIOReturnSuccess else { return nil }
    let dataSize = output.keyInfo.dataSize
    let dataType = output.keyInfo.dataType
    input.keyInfo.dataSize = dataSize
    input.data8 = 5   // SMCKeys.readBytes
    result = Self.call(conn, 2, &input, &output)
    guard result == kIOReturnSuccess else { return nil }

    var bytes: [UInt8] = []
    withUnsafeBytes(of: output.bytes) { raw in
      for i in 0..<min(Int(dataSize), 32) { bytes.append(raw[raw.startIndex + i]) }
    }
    return Self.decode(dataType, bytes: bytes)
  }

  private static func call(_ conn: io_connect_t, _ index: UInt8, _ input: inout SMCKeyData_t, _ output: inout SMCKeyData_t) -> kern_return_t {
    let inputSize = MemoryLayout<SMCKeyData_t>.stride
    var outputSize = MemoryLayout<SMCKeyData_t>.stride
    return IOConnectCallStructMethod(conn, UInt32(index), &input, inputSize, &output, &outputSize)
  }

  private static func fourCharCode(_ s: String) -> UInt32 {
    s.utf8.reduce(0) { $0 << 8 | UInt32($1) }
  }

  private static func decode(_ type: UInt32, bytes: [UInt8]) -> Double? {
    let t = String(
      bytes: [UInt8(type >> 24 & 0xff), UInt8(type >> 16 & 0xff), UInt8(type >> 8 & 0xff), UInt8(type & 0xff)],
      encoding: .utf8
    ) ?? ""
    switch t {
    case "flt ", "flt":
      guard bytes.count >= 4 else { return nil }
      return Double(bytes.withUnsafeBytes { $0.load(as: Float.self) })
    case "sp78":
      guard bytes.count >= 2 else { return nil }
      return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 256
    case "sp87":
      guard bytes.count >= 2 else { return nil }
      return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 128
    default:
      return nil
    }
  }
}

/// The 80-byte SMC exchange struct. `padding` is critical: without it the
/// struct misaligns and IOConnectCallStructMethod returns bad-argument.
private struct SMCKeyData_t {
  typealias SMCBytes_t = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                          UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                          UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                          UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                          UInt8, UInt8, UInt8, UInt8)
  var key: UInt32 = 0
  var vers = SMCVersion_t()
  var pLimitData = SMCPLimitData_t()
  var keyInfo = SMCKeyInfo_t()
  var padding: UInt16 = 0
  var result: UInt8 = 0
  var status: UInt8 = 0
  var data8: UInt8 = 0
  var data32: UInt32 = 0
  var bytes: SMCBytes_t = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}

private struct SMCVersion_t { var major: UInt8 = 0; var minor: UInt8 = 0; var build: UInt8 = 0; var reserved: UInt8 = 0; var release: UInt16 = 0 }
private struct SMCPLimitData_t { var version: UInt16 = 0; var length: UInt16 = 0; var cpuPLimit: UInt32 = 0; var gpuPLimit: UInt32 = 0; var memPLimit: UInt32 = 0 }
private struct SMCKeyInfo_t { var dataSize: UInt32 = 0; var dataType: UInt32 = 0; var dataAttributes: UInt8 = 0 }
#endif // os(macOS)
