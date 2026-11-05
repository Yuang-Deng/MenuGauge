import Foundation
import Darwin

enum PressureLevel: String {
    case low, medium, high

    static func cpu(_ percent: Double) -> PressureLevel {
        percent >= 80 ? .high : (percent >= 50 ? .medium : .low)
    }

    static func memory(systemValue: Int32) throws -> PressureLevel {
        switch systemValue {
        case 1: return .low
        case 2: return .medium
        case 4: return .high
        default: throw MetricError(message: "系统返回了未知内存压力状态")
        }
    }

    static func readMemory() throws -> PressureLevel {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0 else {
            throw MetricError(message: "无法读取系统内存压力：\(String(cString: strerror(errno)))")
        }
        return try memory(systemValue: value)
    }

    var cpuLabel: String {
        switch self { case .low: return "低负载"; case .medium: return "忙碌"; case .high: return "高负载" }
    }
    var memoryLabel: String {
        switch self { case .low: return "压力正常"; case .medium: return "压力偏高"; case .high: return "压力紧张" }
    }
}
