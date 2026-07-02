import Foundation
import IOKit

// Private IOKit HID thermal-sensor symbols. They live in IOKit but aren't in the
// public headers, so we resolve them at runtime — no bridging header, no extra
// build target. This is the only route to a real temperature on Apple Silicon,
// and it needs no entitlement for a non-sandboxed app like WinHub.
private typealias HIDCreateFn   = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
private typealias HIDMatchFn    = @convention(c) (AnyObject?, CFDictionary?) -> Int32
private typealias HIDServicesFn = @convention(c) (AnyObject?) -> Unmanaged<CFArray>?
private typealias HIDPropFn     = @convention(c) (AnyObject?, CFString) -> Unmanaged<CFTypeRef>?
private typealias HIDEventFn    = @convention(c) (AnyObject?, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
private typealias HIDFloatFn    = @convention(c) (AnyObject?, Int32) -> Double

private struct ThermalAPI {
    let create: HIDCreateFn
    let setMatching: HIDMatchFn
    let copyServices: HIDServicesFn
    let copyProperty: HIDPropFn
    let copyEvent: HIDEventFn
    let getFloat: HIDFloatFn

    /// kIOHIDEventTypeTemperature, and the field selector that reads its value.
    static let temperatureType: Int64 = 15
    static let temperatureField: Int32 = Int32(15 << 16)

    static func resolve() -> ThermalAPI? {
        _ = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
        let RTLD_DEFAULT = UnsafeMutableRawPointer(bitPattern: -2)
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            guard let p = dlsym(RTLD_DEFAULT, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        guard let create = sym("IOHIDEventSystemClientCreate", HIDCreateFn.self),
              let match = sym("IOHIDEventSystemClientSetMatching", HIDMatchFn.self),
              let services = sym("IOHIDEventSystemClientCopyServices", HIDServicesFn.self),
              let prop = sym("IOHIDServiceClientCopyProperty", HIDPropFn.self),
              let event = sym("IOHIDServiceClientCopyEvent", HIDEventFn.self),
              let float = sym("IOHIDEventGetFloatValue", HIDFloatFn.self)
        else { return nil }
        return ThermalAPI(create: create, setMatching: match, copyServices: services,
                          copyProperty: prop, copyEvent: event, getFloat: float)
    }
}

/// Cheap, on-demand system readings for the menu-bar monitor. One instance is
/// reused across ticks: CPU/RAM are mach calls; the temperature sensor handles
/// are resolved once and re-read each call.
final class SystemMetrics {
    struct Memory { let usedBytes: UInt64; let totalBytes: UInt64 }

    private static let thermal = ThermalAPI.resolve()
    /// mach_host_self() returns a new send-right reference on every call —
    /// calling it per tick leaks ports. One right, reused forever.
    private let host = mach_host_self()
    private var prevCPUTicks: (busy: Double, total: Double)?

    /// Retained client + the subset of its sensors that report a die temperature
    /// (the SoC/CPU thermal zones — `tdie*`). Resolved lazily, then reused.
    private var thermalClient: AnyObject?
    private lazy var dieSensors: [AnyObject] = resolveDieSensors()

    // MARK: - CPU

    /// Whole-machine CPU busy fraction (0–1) since the previous call.
    func cpuUsage() -> Double {
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info_data_t()
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let user = Double(info.cpu_ticks.0)
        let system = Double(info.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2)
        let nice = Double(info.cpu_ticks.3)
        let busy = user + system + nice
        let total = busy + idle
        defer { prevCPUTicks = (busy, total) }
        guard let prev = prevCPUTicks else { return 0 }
        let dBusy = busy - prev.busy
        let dTotal = total - prev.total
        guard dTotal > 0 else { return 0 }
        return max(0, min(1, dBusy / dTotal))
    }

    // MARK: - Memory

    /// Used / total physical memory. "Used" ≈ Activity Monitor's footprint
    /// (active + wired + compressed) — the memory that's actually committed.
    func memory() -> Memory {
        let total = ProcessInfo.processInfo.physicalMemory
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var stats = vm_statistics64_data_t()
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &size)
            }
        }
        guard kr == KERN_SUCCESS else { return Memory(usedBytes: 0, totalBytes: total) }
        let page = UInt64(vm_kernel_page_size)
        let used = (UInt64(stats.active_count) + UInt64(stats.wire_count)
                    + UInt64(stats.compressor_page_count)) * page
        return Memory(usedBytes: min(used, total), totalBytes: total)
    }

    // MARK: - Temperature

    /// Average SoC die temperature in °C, or nil if the sensors are unavailable.
    func temperature() -> Double? {
        guard let api = Self.thermal, !dieSensors.isEmpty else { return nil }
        var sum = 0.0, count = 0
        for sensor in dieSensors {
            guard let event = api.copyEvent(sensor, ThermalAPI.temperatureType, 0, 0)?.takeRetainedValue() else { continue }
            let t = api.getFloat(event, ThermalAPI.temperatureField)
            if t.isFinite, t > 0, t < 120 { sum += t; count += 1 }
        }
        return count > 0 ? sum / Double(count) : nil
    }

    /// Find the thermal services and keep only the die-temperature sensors. These
    /// are stable for the machine's lifetime, so we resolve once and reuse.
    private func resolveDieSensors() -> [AnyObject] {
        guard let api = Self.thermal,
              let client = api.create(kCFAllocatorDefault)?.takeRetainedValue() else { return [] }
        thermalClient = client   // retained so its service clients stay valid
        // PrimaryUsagePage 0xff00 / PrimaryUsage 0x05 = Apple temperature sensors.
        let matching: [String: Int] = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 0x05]
        _ = api.setMatching(client, matching as CFDictionary)
        guard let services = api.copyServices(client)?.takeRetainedValue() as? [AnyObject] else { return [] }
        return services.filter { sensor in
            let name = (api.copyProperty(sensor, "Product" as CFString)?.takeRetainedValue() as? String) ?? ""
            return name.contains("tdie")
        }
    }
}
