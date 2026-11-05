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
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    static func executable() throws -> URL {
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex"
        ]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw MetricError(message: "未找到 Codex 程序，请安装或更新 Codex 桌面应用")
        }
        return URL(fileURLWithPath: path)
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning { process.terminate() }
    }

    func read(executable: URL? = nil, timeout: TimeInterval = 12) throws -> CodexQuota {
        let child = Process()
        child.executableURL = try executable ?? Self.executable()
        child.arguments = ["app-server", "--stdio"]
        let input = Pipe()
        let output = Pipe()
        child.standardInput = input
        child.standardOutput = output
        // Do not persist app-server diagnostics or authentication data.
        child.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        child.terminationHandler = { _ in exited.signal() }
        lock.lock()
        do {
            if cancelled { throw MetricError(message: "额度查询已取消") }
            try child.run()
            process = child
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }
        defer {
            lock.lock()
            if child.isRunning { child.terminate() }
            lock.unlock()
            if exited.wait(timeout: .now() + 1) == .timedOut, child.isRunning {
                kill(child.processIdentifier, SIGKILL)
            }
            child.waitUntilExit()
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            lock.lock()
            process = nil
            lock.unlock()
        }
        func send(_ message: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": [
            "name": "status_ring", "title": "Status Ring", "version": "0.1.0"
        ]]])
        var buffer = Data()
        var bytes = [UInt8](repeating: 0, count: 8192)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let descriptor = output.fileHandleForReading.fileDescriptor
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw MetricError(message: "Codex 额度查询超时") }
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pollDescriptor, 1, Int32(min(remaining * 1000, 500)))
            if ready < 0 {
                if errno == EINTR { continue }
                throw MetricError(message: "无法读取 Codex 额度响应")
            }
            if ready == 0 { continue }
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            guard count > 0 else { throw MetricError(message: "Codex 额度查询连接已关闭") }
            buffer.append(contentsOf: bytes.prefix(count))
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard let reply = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = reply["id"] as? Int, id == 1 || id == 2 else { continue }
                if let error = reply["error"] as? [String: Any] {
                    throw MetricError(message: error["message"] as? String ?? "Codex 拒绝了额度查询")
                }
                if id == 1 {
                    try send(["method": "initialized"])
                    try send(["id": 2, "method": "account/rateLimits/read"])
                } else {
                    guard let result = reply["result"] as? [String: Any] else {
                        throw MetricError(message: "Codex 未返回额度结果")
                    }
                    return try CodexQuota.decode(JSONSerialization.data(withJSONObject: result))
                }
            }
        }
    }
}
