import Foundation
import Darwin

struct CPUTicks {
    let user: UInt32
    let system: UInt32
    let idle: UInt32
    let nice: UInt32

    func usage(since previous: CPUTicks) -> Double? {
        let active = UInt64(user &- previous.user) + UInt64(system &- previous.system) + UInt64(nice &- previous.nice)
        let total = active + UInt64(idle &- previous.idle)
        return total > 0 ? Double(active) / Double(total) * 100 : nil
    }
}

struct ResourceReading {
    let cpuPercent: Double?
    let memoryUsedBytes: UInt64
    let memoryTotalBytes: UInt64
    var memoryPressure: PressureLevel? = nil
    var memoryPressureError: String? = nil
    var memoryPercent: Double { Double(memoryUsedBytes) / Double(memoryTotalBytes) * 100 }
}

final class ResourceReader {
    private let host = mach_host_self()
    private var previousCPU: CPUTicks?

    deinit { mach_port_deallocate(mach_task_self_, host) }

    func read() throws -> ResourceReading {
        var cpu = host_cpu_load_info_data_t()
        var cpuCount = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let cpuResult = withUnsafeMutablePointer(to: &cpu) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(cpuCount)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &cpuCount)
            }
        }
        guard cpuResult == KERN_SUCCESS else { throw MetricError(message: "无法读取 CPU 使用率（\(cpuResult)）") }
        let ticks = CPUTicks(user: cpu.cpu_ticks.0, system: cpu.cpu_ticks.1, idle: cpu.cpu_ticks.2, nice: cpu.cpu_ticks.3)
        let percent = previousCPU.flatMap { ticks.usage(since: $0) }
        previousCPU = ticks

        var memory = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let memoryResult = withUnsafeMutablePointer(to: &memory) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard memoryResult == KERN_SUCCESS else { throw MetricError(message: "无法读取内存使用率（\(memoryResult)）") }
        var pageSize: vm_size_t = 0
        let pageResult = host_page_size(host, &pageSize)
        guard pageResult == KERN_SUCCESS else { throw MetricError(message: "无法读取内存页大小（\(pageResult)）") }
        // Anonymous app memory minus reclaimable pages, plus wired and physical compressed storage.
        // File-backed cache is excluded; counters can move while the kernel takes the snapshot.
        let appPages = max(0, Int64(memory.internal_page_count) - Int64(memory.purgeable_count))
        let usedPages = UInt64(appPages) + UInt64(memory.wire_count) + UInt64(memory.compressor_page_count)
        var reading = ResourceReading(cpuPercent: percent, memoryUsedBytes: usedPages * UInt64(pageSize),
                                      memoryTotalBytes: ProcessInfo.processInfo.physicalMemory)
        do { reading.memoryPressure = try PressureLevel.readMemory() }
        catch { reading.memoryPressureError = error.localizedDescription }
        return reading
    }
}
