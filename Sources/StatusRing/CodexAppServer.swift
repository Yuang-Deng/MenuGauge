import Foundation
import Darwin

/// One private stdio connection. It never handles approvals or invokes tools on behalf of a model.
// I/O stays on one worker queue; only cancel() crosses threads, protected by lock.
final class CodexAppServer: @unchecked Sendable {
    private let lock = NSLock()
    private var child: Process?
    private var cancelled = false
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var requestID = 0
    private let exited = DispatchSemaphore(value: 0)

    static func executable() throws -> URL {
        let roots = ["/Applications", NSHomeDirectory() + "/Applications"]
        let paths = roots.flatMap { root in
            ["ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
             "Codex.app/Contents/Resources/codex-cli/bin/codex",
             "Codex.app/Contents/Resources/codex"].map { root + "/" + $0 }
        }
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw MetricError(message: "未找到 Codex 程序，请安装或更新 Codex 桌面应用")
        }
        return URL(fileURLWithPath: path)
    }

    func connect(executable: URL? = nil, timeout: TimeInterval = 12) throws {
        let process = Process(), stdin = Pipe(), stdout = Pipe()
        process.executableURL = try executable ?? Self.executable()
        process.arguments = ["app-server", "--stdio", "-c", "notify=[]", "-c", "features.hooks=false",
                             "-c", "features.shell_tool=false", "-c", "features.apply_patch_freeform=false", "-c", "web_search=\"disabled\""]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [exited] _ in exited.signal() }
        lock.lock()
        do {
            if cancelled { throw MetricError(message: "Codex 操作已取消") }
            try process.run()
            child = process
            input = stdin.fileHandleForWriting
            output = stdout.fileHandleForReading
            lock.unlock()
        } catch { lock.unlock(); throw error }
        do {
            _ = try request("initialize", params: ["clientInfo": ["name": "menugauge", "title": "MenuGauge", "version": "0.3.8"],
                                                 "capabilities": ["experimentalApi": true]], timeout: timeout)
            try send(["method": "initialized"])
        } catch { close(); throw error }
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let child, child.isRunning { child.terminate() }
    }

    func close() {
        lock.lock()
        let process = child
        child = nil
        if let process, process.isRunning { process.terminate() }
        lock.unlock()
        if let process {
            if exited.wait(timeout: .now() + 1) == .timedOut, process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        try? input?.close(); try? output?.close()
        input = nil; output = nil
    }

    deinit { close() }

    func request(_ method: String, params: [String: Any] = [:], timeout: TimeInterval = 20) throws -> [String: Any] {
        requestID += 1
        let id = requestID
        try send(["id": id, "method": method, "params": params])
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            let message = try receive(deadline: deadline)
            if let replyID = message["id"] as? Int, replyID == id {
                if let error = message["error"] as? [String: Any] {
                    throw MetricError(message: error["message"] as? String ?? "Codex 拒绝了请求")
                }
                guard let result = message["result"] as? [String: Any] else { throw MetricError(message: "Codex 返回了无效响应") }
                return result
            }
        }
    }

    private func send(_ message: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(10)
        guard let input else { throw MetricError(message: "Codex 连接已关闭") }
        try input.write(contentsOf: data)
    }

    private func receive(deadline: TimeInterval) throws -> [String: Any] {
        while true {
            lock.lock(); let stopped = cancelled; lock.unlock()
            if stopped { throw MetricError(message: "Codex 操作已取消") }
            if let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw MetricError(message: "Codex 返回了无效消息")
                }
                if message["id"] != nil, message["method"] != nil {
                    try send(["id": message["id"]!, "error": ["code": -32601, "message": "MenuGauge does not accept tool or permission requests"]])
                    throw MetricError(message: "Codex 请求了工具或授权，已停止读取")
                }
                return message
            }
            guard buffer.count < 32 * 1024 * 1024 else { throw MetricError(message: "Codex 响应超过大小限制") }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw MetricError(message: "Codex 请求超时") }
            guard let output else { throw MetricError(message: "Codex 连接已关闭") }
            let fd = output.fileDescriptor
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(min(remaining * 1000, 250)))
            if ready < 0 {
                if errno == EINTR { continue }
                throw MetricError(message: "无法读取 Codex 响应")
            }
            if ready == 0 { continue }
            var bytes = [UInt8](repeating: 0, count: 16384)
            let count = Darwin.read(fd, &bytes, bytes.count)
            guard count > 0 else { throw MetricError(message: "Codex 连接已关闭") }
            buffer.append(contentsOf: bytes.prefix(count))
        }
    }
}
