import Foundation
import IOKit

/// Read-only AppleSMC client. Sensor keys are the M4 CPU mapping documented by Stats:
/// https://github.com/exelban/stats/blob/master/Modules/Sensors/values.swift
final class TemperatureReader {
    private var connection: io_connect_t = 0
    private var keys: [String] = []
    private static let candidates = ["Te05", "Te0S", "Te09", "Te0H", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"]

    init() throws {
        var modelSize = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &modelSize, nil, 0) == 0 else {
            throw MetricError(message: "无法识别 CPU 型号")
        }
        var model = [CChar](repeating: 0, count: modelSize)
        guard sysctlbyname("machdep.cpu.brand_string", &model, &modelSize, nil, 0) == 0,
              String(cString: model).hasPrefix("Apple M4") else {
            throw MetricError(message: "当前温度读取仅适配 Apple M4 系列")
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw MetricError(message: "未找到温度传感器服务") }
        defer { IOObjectRelease(service) }
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == KERN_SUCCESS else { throw MetricError(message: "无法打开温度传感器：\(result)") }
        do {
            for key in Self.candidates {
                let info = try request(key, command: 9)
                if info[40] == 0x84 { continue } // This sensor does not exist on this chip variant.
                guard info[40] == 0 else { throw MetricError(message: "温度传感器 \(key) 不可用：\(info[40])") }
                let size = info.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 28, as: UInt32.self) }
                let type = info.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 32, as: UInt32.self) }
                guard size == 4, type == 0x666c7420 else {
                    throw MetricError(message: "温度传感器 \(key) 使用了未支持的格式")
                }
                keys.append(key)
            }
            guard !keys.isEmpty else { throw MetricError(message: "未找到支持的 CPU 温度传感器") }
        } catch {
            IOServiceClose(connection)
            connection = 0
            throw error
        }
    }

    deinit { if connection != 0 { IOServiceClose(connection) } }

    func read() throws -> Double {
        var temperatures: [Double] = []
        for key in keys {
            let data = try request(key, command: 5, size: 4)
            guard data[40] == 0 else { throw MetricError(message: "无法读取温度传感器 \(key)：\(data[40])") }
            let value = Double(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 48, as: Float.self) })
            // Inactive sensors can publish zero; never display them as a measured CPU temperature.
            if value.isFinite && value > 0 && value < 150 { temperatures.append(value) }
        }
        guard let temperature = temperatures.max(), temperature >= 10 else {
            throw MetricError(message: "CPU 温度传感器暂未返回有效数值")
        }
        return temperature
    }

    private func request(_ key: String, command: UInt8, size: UInt32 = 0) throws -> Data {
        // AppleSMC's 80-byte ABI: key 0, data size 28, type 32, result 40,
        // command 42, payload 48. Only read-info (9) and read-bytes (5) are used.
        var input = Data(count: 80)
        var output = Data(count: 80)
        let code = key.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        input.withUnsafeMutableBytes { bytes in
            bytes.storeBytes(of: code, toByteOffset: 0, as: UInt32.self)
            bytes.storeBytes(of: size, toByteOffset: 28, as: UInt32.self)
            bytes[42] = command
        }
        var outputSize = output.count
        let result = input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                IOConnectCallStructMethod(connection, 2, source.baseAddress, input.count,
                                          destination.baseAddress, &outputSize)
            }
        }
        guard result == KERN_SUCCESS, outputSize == 80 else {
            throw MetricError(message: "温度读取失败：\(result)")
        }
        return output
    }
}
