import Foundation

struct DiskReading {
    let totalBytes: Int64
    let availableBytes: Int64
    var usedBytes: Int64 { totalBytes - availableBytes }
    var usedPercent: Double { Double(usedBytes) / Double(totalBytes) * 100 }
    var level: PressureLevel { usedPercent >= 90 ? .high : (usedPercent >= 80 ? .medium : .low) }
    var label: String {
        switch level { case .low: return "空间充足"; case .medium: return "空间偏少"; case .high: return "空间紧张" }
    }
}

enum DiskReader {
    static func read() throws -> DiskReading {
        let values = try URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        guard let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacity,
              total > 0, available >= 0, available <= total else {
            throw MetricError(message: "无法读取启动磁盘容量")
        }
        return DiskReading(totalBytes: Int64(total), availableBytes: Int64(available))
    }
}
