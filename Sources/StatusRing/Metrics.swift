import Foundation
import IOKit.ps
import Darwin

enum BatteryReader {
    static func read() throws -> BatteryReading {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            throw MetricError(message: "无法读取电池信息")
        }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            guard let capacity = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0,
                  let charging = description[kIOPSIsChargingKey] as? Bool,
                  let sourceState = description[kIOPSPowerSourceStateKey] as? String else {
                throw MetricError(message: "电池状态不完整")
            }
            let mode: PowerMode = charging ? .charging : (sourceState == kIOPSACPowerValue ? .pluggedIn : .battery)
            return BatteryReading(fraction: min(1, max(0, Double(capacity) / Double(maximum))), mode: mode)
        }
        throw MetricError(message: "未找到内置电池")
    }
}

enum BatteryHealthReader {
    static func read() throws -> Int {
        let profiler = Process()
        let output = Pipe()
        profiler.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        profiler.arguments = ["-json", "-detailLevel", "mini", "-timeout", "5", "SPPowerDataType"]
        profiler.standardOutput = output
        profiler.standardError = FileHandle.nullDevice
        try profiler.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        profiler.waitUntilExit()
        guard profiler.terminationStatus == 0 else {
            throw MetricError(message: "系统电源报告读取失败（\(profiler.terminationStatus)）")
        }

        let report = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let entries = report?["SPPowerDataType"] as? [[String: Any]],
              let health = entries.compactMap({ $0["sppower_battery_health_info"] as? [String: Any] }).first,
              let capacity = health["sppower_battery_health_maximum_capacity"] as? String,
              capacity.hasSuffix("%"), let percent = Int(capacity.dropLast()), (0...100).contains(percent) else {
            throw MetricError(message: "系统电源报告未提供有效的电池最大容量")
        }
        return percent
    }
}
