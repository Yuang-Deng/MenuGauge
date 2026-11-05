import Foundation
import Darwin

struct CodexQuota {
    struct Window: Decodable {
        let usedPercent: Double
        let windowDurationMins: Int?
        let resetsAt: TimeInterval?

        var remainingPercent: Double { min(100, max(0, 100 - usedPercent)) }
        var label: String {
            guard let minutes = windowDurationMins else { return "额度" }
            if minutes % 1440 == 0 { return "\(minutes / 1440) 天" }
            if minutes % 60 == 0 { return "\(minutes / 60) 小时" }
            return "\(minutes) 分钟"
        }
    }

    let windows: [Window]
    let fetchedAt: Date
    var remainingPercent: Double { windows.map(\.remainingPercent).min()! }

    static func decode(_ data: Data, now: Date = Date()) throws -> CodexQuota {
        struct Bucket: Decodable { let primary: Window?; let secondary: Window? }
        struct Response: Decodable {
            let rateLimits: Bucket?
            let rateLimitsByLimitId: [String: Bucket]?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        let bucket = response.rateLimitsByLimitId.map { $0["codex"] } ?? response.rateLimits
        guard let bucket else { throw MetricError(message: "当前账号未返回 Codex 额度") }
        let windows = [bucket.primary, bucket.secondary].compactMap { $0 }
        guard !windows.isEmpty else { throw MetricError(message: "当前账号未返回额度周期") }
        guard windows.allSatisfy({ $0.usedPercent.isFinite && ($0.windowDurationMins.map { $0 > 0 } ?? true) }) else {
            throw MetricError(message: "Codex 返回了无效的额度数据")
        }
        return CodexQuota(windows: windows, fetchedAt: now)
    }

    func isStale(at now: Date = Date()) -> Bool {
        now.timeIntervalSince(fetchedAt) > 180 || windows.contains {
            $0.resetsAt.map { Date(timeIntervalSince1970: $0) <= now } ?? false
        }
    }
}

// Reads only the documented account/rateLimits/read RPC. No threads, turns, or resets.
final class CodexQuotaReader {
    private let server = CodexAppServer()
    static func executable() throws -> URL { try CodexAppServer.executable() }
    func cancel() { server.cancel() }
    func read(executable: URL? = nil, timeout: TimeInterval = 12) throws -> CodexQuota {
        defer { server.close() }
        try server.connect(executable: executable, timeout: timeout)
        let result = try server.request("account/rateLimits/read", timeout: timeout)
        return try CodexQuota.decode(JSONSerialization.data(withJSONObject: result))
    }
}
