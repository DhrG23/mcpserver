//
//  SystemInfo.swift
//  Node
//
//  Core/Services/SystemInfo.swift
//  Low-level helpers (sysctl, mach, IOKit, Metal) + samplers +
//  SnapshotCollector, which assembles a DeviceSnapshot from them.
//

import Foundation
import Metal

#if os(iOS)
import UIKit
#else
import AppKit
import IOKit
#endif

// ─────────────────────────────────────────────
// MARK: - SystemInfo
// ─────────────────────────────────────────────

enum SystemInfo {
    
    // ── sysctl ─────────────────────────────────────────────────────────
    private static func sysctlString(_ key: String) -> String? {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
    
    /// Hardware identifier, e.g. "iPhone15,2" or "Mac14,5". Never changes, so it is read once.
    static let modelIdentifier: String = {
#if targetEnvironment(simulator)
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return sim
        }
#endif
#if os(macOS)
        return sysctlString("hw.model") ?? "Unknown"
#else
        return sysctlString("hw.machine") ?? "Unknown"
#endif
    }()
    
    /// "Apple M3 Pro" etc. (macOS only). Read once.
    static let cpuBrand: String? = {
#if os(macOS)
        return sysctlString("machdep.cpu.brand_string")
#else
        return nil
#endif
    }()
    
    /// 1 / 5 / 15 minute load averages.
    static var loadAverage: [Double] {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) == 3 ? loads : []
    }
    
    // ── Memory ─────────────────────────────────────────────────────────
    
    /// Memory footprint of this app (same number Xcode's memory gauge shows).
    static var appMemoryBytes: Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }
    
    /// System-wide memory, calculated like Activity Monitor's "Memory Used":
    /// app memory + wired + compressed.
    static func systemMemory() -> (used: Int64, wired: Int64, compressed: Int64)? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), host_flavor_t(HOST_VM_INFO64), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        
        let page       = Int64(getpagesize())
        let app        = max(0, Int64(stats.internal_page_count) - Int64(stats.purgeable_count))
        let wired      = Int64(stats.wire_count)
        let compressed = Int64(stats.compressor_page_count)
        return ((app + wired + compressed) * page, wired * page, compressed * page)
    }
    
    /// The kernel's current memory-pressure level (macOS), as used by Activity Monitor's graph.
    /// `kern.memorystatus_vm_pressure_level`: 1 = normal, 2 = warning, 4 = critical.
    /// Returns nil where the sysctl doesn't exist (iOS); MemoryPressureMonitor then relies on events.
    static func kernelPressureLevel() -> String? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            return nil
        }
        switch level {
        case 4:  return "critical"
        case 2:  return "elevated"
        default: return "nominal"
        }
    }
    
    /// Swap in use (macOS only; iOS has no swap file).
    static var swapUsedBytes: Int64? {
#if os(macOS)
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return Int64(usage.xsu_used)
#else
        return nil
#endif
    }
    
    // ── GPU ────────────────────────────────────────────────────────────
#if os(macOS)
    /// GPU utilisation (0...1) and GPU memory in use, read from the IOKit registry.
    /// Returns nil if the OS doesn't expose it (e.g. some sandboxed builds).
    static func gpuStats() -> (utilization: Double, memoryInUse: Int64?)? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        
        var utilization: Double?
        var memory: Int64?
        
        var service = IOIteratorNext(iterator)
        while service != 0 {
            var unmanaged: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let props = unmanaged?.takeRetainedValue() as? [String: Any],
               let stats = props["PerformanceStatistics"] as? [String: Any] {
                
                if let u = (stats["Device Utilization %"] as? NSNumber)?.doubleValue {
                    utilization = max(utilization ?? 0, u / 100)
                }
                if let m = (stats["In use system memory"] as? NSNumber)?.int64Value {
                    memory = max(memory ?? 0, m)
                }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        
        guard let utilization else { return nil }
        return (min(1, max(0, utilization)), memory)
    }
#endif
    
    // ── Storage ────────────────────────────────────────────────────────
    
    /// Total / available disk space for the volume the app lives on.
    static func storage() -> (total: Int64, available: Int64) {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return (0, 0) }
        return (
            Int64(values.volumeTotalCapacity ?? 0),
            Int64(values.volumeAvailableCapacityForImportantUsage ?? 0)
        )
    }
    
    // ── Identity ───────────────────────────────────────────────────────
    
    /// Stable per-install ID (survives launches, not reinstalls).
    static let installationID: String = {
        let key = "node.installationID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }()
    
    /// Version / build / bundle ID never change while the app runs, so they are read once.
    static let appInfo: DeviceSnapshot.AppInfo = {
        let dict = Bundle.main.infoDictionary
        return .init(
            version:  dict?["CFBundleShortVersionString"] as? String ?? "0",
            build:    dict?["CFBundleVersion"] as? String ?? "0",
            bundleID: Bundle.main.bundleIdentifier ?? "unknown"
        )
    }()
    
    static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

// ─────────────────────────────────────────────
// MARK: - Samplers (need two readings to compute a rate)
// ─────────────────────────────────────────────

/// Values that are computed as a change between two readings.
struct LiveSamples: Sendable {
    var cpuUsage: Double = 0
    var downBytesPerSec: Double = 0
    var upBytesPerSec: Double = 0
    var memoryPressure: String = "nominal"     // nominal | elevated | critical
}

/// System-wide CPU usage since the previous call (first call returns 0).
final class CPUSampler {
    
    private var previous: (busy: UInt64, total: UInt64)?
    
    func sample() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), host_flavor_t(HOST_CPU_LOAD_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        
        let user = UInt64(info.cpu_ticks.0)
        let sys  = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)
        let busy  = user + sys + nice
        let total = busy + idle
        
        defer { previous = (busy, total) }
        guard let prev = previous, total > prev.total else { return 0 }
        let usage = Double(busy &- prev.busy) / Double(total &- prev.total)
        return min(1, max(0, usage))
    }
}

/// Real memory-pressure level from the system's own notifications
/// (the same signal apps get before the OS starts killing processes).
@MainActor
final class MemoryPressureMonitor {
    
    private(set) var level: String = "nominal"
    private var source: DispatchSourceMemoryPressure?
    
    func start() {
        guard source == nil else { return }
        level = SystemInfo.kernelPressureLevel() ?? "nominal"
        
        let s = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: .main
        )
        s.setEventHandler { [weak self, weak s] in
            guard let event = s?.data else { return }
            Task { @MainActor [weak self] in self?.apply(event) }
        }
        s.resume()
        source = s
    }
    
    func stop() {
        source?.cancel()
        source = nil
    }
    
    private func apply(_ event: DispatchSource.MemoryPressureEvent) {
        if event.contains(.critical)     { level = "critical" }
        else if event.contains(.warning) { level = "elevated" }
        else                             { level = "nominal" }
    }
}

/// Download / upload speed across the physical network interfaces.
///
/// - Only `en*` (Wi-Fi / Ethernet) and `pdp_ip*` (cellular) are counted. VPN tunnels
///   (`utun*`), bridges, AirDrop (`awdl*`) etc. carry the same traffic again and would
///   double-count it.
/// - The kernel byte counters from `getifaddrs` are 32-bit and wrap around, so each
///   interface is diffed on its own with wrapping arithmetic.
final class NetworkThroughputSampler {
    
    private var previous: [String: (rx: UInt32, tx: UInt32)] = [:]
    private var previousTime: Date?
    
    private static func isPhysical(_ name: String) -> Bool {
        name.hasPrefix("en") || name.hasPrefix("pdp_ip")
    }
    
    func sample() -> (down: Double, up: Double) {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return (0, 0) }
        defer { freeifaddrs(addrs) }
        
        var current: [String: (rx: UInt32, tx: UInt32)] = [:]
        var rxDelta: UInt64 = 0
        var txDelta: UInt64 = 0
        
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            let ifa = entry.pointee
            cursor = ifa.ifa_next
            
            guard let addr = ifa.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_LINK),
                  let data = ifa.ifa_data else { continue }
            let name = String(cString: ifa.ifa_name)
            guard Self.isPhysical(name) else { continue }
            
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            let rx = UInt32(truncatingIfNeeded: stats.ifi_ibytes)
            let tx = UInt32(truncatingIfNeeded: stats.ifi_obytes)
            current[name] = (rx, tx)
            
            if let prev = previous[name] {
                rxDelta += UInt64(rx &- prev.rx)      // wraps correctly across 2^32
                txDelta += UInt64(tx &- prev.tx)
            }
        }
        
        let now = Date()
        let before = previousTime
        previous = current
        previousTime = now
        
        guard let before else { return (0, 0) }
        let dt = now.timeIntervalSince(before)
        guard dt > 0.1 else { return (0, 0) }
        return (Double(rxDelta) / dt, Double(txDelta) / dt)
    }
}

// ─────────────────────────────────────────────
// MARK: - SnapshotCollector
// ─────────────────────────────────────────────

@MainActor
enum SnapshotCollector {
    
    private static let metalDevice = MTLCreateSystemDefaultDevice()
    
    // Values that never (or almost never) change are computed once, not every second.
    // `Host.current().localizedName` in particular can block the main thread on macOS.
    private static let cachedDevice: DeviceSnapshot.DeviceInfo = deviceInfo()
    private static let cachedGPUName: String = metalDevice?.name ?? "Unknown GPU"
    
    /// Region is cached for a minute so a time-zone or language change is still picked up.
    private static var regionCache: (info: DeviceSnapshot.RegionInfo, date: Date)?
    private static func cachedRegion(now: Date) -> DeviceSnapshot.RegionInfo {
        if let cache = regionCache, now.timeIntervalSince(cache.date) < 60 { return cache.info }
        let fresh = regionInfo()
        regionCache = (fresh, now)
        return fresh
    }
    
    static func collect(
        network: NetworkMonitor.State,
        samples: LiveSamples,
        location: LocationStatus,
        coordinates: DeviceSnapshot.Coordinates? = nil,
        sources: SourcesInfo? = nil
    ) -> DeviceSnapshot {
        
        let info = ProcessInfo.processInfo
        let uptime: TimeInterval = info.systemUptime
        let now = Date()
        let disk = SystemInfo.storage()
        let mem = SystemInfo.systemMemory()
        let appMemory: Int64 = SystemInfo.appMemoryBytes
        
        // One IOKit registry read per sample (it used to run twice).
#if os(macOS)
        let gpuIO = SystemInfo.gpuStats()
#else
        // iOS has no public API for GPU load; only Metal memory figures exist.
        let gpuIO: (utilization: Double, memoryInUse: Int64?)? = nil
#endif
        let gpuActivity: Double = gpuIO?.utilization ?? 0
        
        // ProcessInfo.thermalState is deliberately conservative on macOS and can stay
        // at .nominal for long periods even while an MLX workload is active. Keep the
        // real system thermal state, but also expose a live workload signal so the UI
        // reacts every sampling cycle. This is an activity estimate, not a temperature.
        let thermalActivity = max(samples.cpuUsage, gpuActivity)
        
        let power = DeviceSnapshot.PowerInfo(
            isLowPowerMode: info.isLowPowerModeEnabled,
            thermalState: SystemInfo.thermalName(info.thermalState),
            thermalActivity: thermalActivity
        )
        let cpu = DeviceSnapshot.CPUInfo(
            usage: samples.cpuUsage,
            cores: info.activeProcessorCount,
            brand: SystemInfo.cpuBrand,
            loadAverage: SystemInfo.loadAverage
        )
        let totalMemory = Int64(info.physicalMemory)
        let systemUsedMemory = mem?.used ?? appMemory
        let compressedMemory = mem?.compressed ?? 0
        let swapUsed = SystemInfo.swapUsedBytes
        let memoryPressure = samples.memoryPressure
        
        let memory = DeviceSnapshot.MemoryInfo(
            totalBytes: totalMemory,
            usedBytes: systemUsedMemory,
            wiredBytes: mem?.wired ?? 0,
            compressedBytes: compressedMemory,
            swapUsedBytes: swapUsed,
            appUsedBytes: appMemory,
            pressure: memoryPressure
        )
        let storage = DeviceSnapshot.StorageInfo(
            totalBytes: disk.total,
            usedBytes: max(0, disk.total - disk.available),
            availableBytes: disk.available
        )
        let net = DeviceSnapshot.NetworkInfo(
            isConnected: network.isConnected,
            interface: network.interface.rawValue,
            isExpensive: network.isExpensive,
            isConstrained: network.isConstrained,
            downBytesPerSec: samples.downBytesPerSec,
            upBytesPerSec: samples.upBytesPerSec
        )
        
        return DeviceSnapshot(
            installationID: SystemInfo.installationID,
            capturedAt: now,
            uptimeSeconds: Int(uptime),
            bootedAt: now.addingTimeInterval(-uptime),
            device: cachedDevice,
            app: SystemInfo.appInfo,
            battery: batteryInfo(),
            power: power,
            cpu: cpu,
            memory: memory,
            gpu: gpuInfo(io: gpuIO),
            storage: storage,
            network: net,
            display: displayInfo(),
            region: cachedRegion(now: now),
            location: location,
            coordinates: coordinates,
            sources: sources
        )
    }
    
    // ── GPU ────────────────────────────────────────────────────────────
    private static func gpuInfo(io: (utilization: Double, memoryInUse: Int64?)?) -> DeviceSnapshot.GPUInfo {
        let device = metalDevice
        return .init(
            name: cachedGPUName,
            utilization: io?.utilization,
            memoryInUseBytes: io?.memoryInUse,
            appAllocatedBytes: Int64(device?.currentAllocatedSize ?? 0),
            recommendedWorkingSetBytes: Int64(device?.recommendedMaxWorkingSetSize ?? 0),
            hasUnifiedMemory: device?.hasUnifiedMemory ?? true
        )
    }
    
    // ── Device ─────────────────────────────────────────────────────────
    private static func deviceInfo() -> DeviceSnapshot.DeviceInfo {
#if os(iOS)
        let dev = UIDevice.current
        return .init(
            name: dev.name,
            model: dev.model,
            modelIdentifier: SystemInfo.modelIdentifier,
            platform: dev.systemName,
            osVersion: dev.systemVersion,
            vendorID: dev.identifierForVendor?.uuidString
        )
#else
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return .init(
            name: Host.current().localizedName ?? "Mac",
            model: "Mac",
            modelIdentifier: SystemInfo.modelIdentifier,
            platform: "macOS",
            osVersion: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        )
#endif
    }
    
    // ── Battery ────────────────────────────────────────────────────────
    private static func batteryInfo() -> DeviceSnapshot.BatteryInfo? {
#if os(iOS)
        let dev = UIDevice.current
        let raw = dev.batteryLevel                 // -1 when unknown
        let state: String
        switch dev.batteryState {
        case .charging:  state = "charging"
        case .full:      state = "full"
        case .unplugged: state = "unplugged"
        default:         state = "unknown"
        }
        return .init(
            level: raw >= 0 ? Double(raw) : nil,
            state: state,
            isCharging: dev.batteryState == .charging
        )
#else
        return nil
#endif
    }
    
    // ── Display ────────────────────────────────────────────────────────
    private static func displayInfo() -> DeviceSnapshot.DisplayInfo {
#if os(iOS)
        guard let screen = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first?.screen else {
            // Provide a fallback or return a default value if no active scene screen is found
            return .init(widthPx: 0, heightPx: 0, scale: 1.0, brightness: 1.0)
        }
        
        let px = screen.nativeBounds
        return .init(
            widthPx: Int(px.width),
            heightPx: Int(px.height),
            scale: Double(screen.nativeScale),
            brightness: Double(screen.brightness)
        )
#else
        guard let screen = NSScreen.main else {
            return .init(widthPx: 0, heightPx: 0, scale: 1, brightness: nil)
        }
        let scale = screen.backingScaleFactor
        return .init(
            widthPx: Int(screen.frame.width * scale),
            heightPx: Int(screen.frame.height * scale),
            scale: Double(scale),
            brightness: nil
        )
#endif
    }
    
    // ── Region ─────────────────────────────────────────────────────────
    private static func regionInfo() -> DeviceSnapshot.RegionInfo {
        let tz = TimeZone.current
        return .init(
            localeIdentifier: Locale.current.identifier,
            language: Locale.preferredLanguages.first ?? "en",
            timeZone: tz.identifier,
            utcOffsetSeconds: tz.secondsFromGMT()
        )
    }
}
