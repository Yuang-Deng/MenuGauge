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
    private var notifications: [[String: Any]] = []
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
            _ = try request("initialize", params: ["clientInfo": ["name": "menugauge", "title": "MenuGauge", "version": "0.2.0"],
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
            if message["method"] != nil { notifications.append(message) }
        }
    }

    func nextEvent(deadline: TimeInterval) throws -> [String: Any] {
        if !notifications.isEmpty { return notifications.removeFirst() }
        return try receive(deadline: deadline)
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
                    try send(["id": message["id"]!, "error": ["code": -32601, "message": "MenuGauge fingerprint probes do not grant permissions or execute tools"]])
                    throw MetricError(message: "探测请求了工具或授权，已停止")
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

    /// A turn is text-only: reject tool attempts, accept only a completed final answer.
    func answer(threadID: String, prompt: String, effort: String?, timeout: TimeInterval = 300) throws -> String {
        var params: [String: Any] = ["threadId": threadID, "input": [["type": "text", "text": prompt]],
                                   "approvalPolicy": "never", "sandboxPolicy": ["type": "readOnly"]]
        params["effort"] = effort
        let started = try request("turn/start", params: params)
        guard let turnID = (started["turn"] as? [String: Any])?["id"] as? String else { throw MetricError(message: "Codex 未返回探测轮次") }
        var final: String?, unphased: [String] = []
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        do {
            while true {
                let message = try nextEvent(deadline: deadline)
                guard let method = message["method"] as? String, let p = message["params"] as? [String: Any] else { continue }
                if method == "error", p["willRetry"] as? Bool != true,
                   p["threadId"] == nil || p["threadId"] is NSNull || p["threadId"] as? String == threadID {
                    throw MetricError(message: (p["error"] as? [String: Any])?["message"] as? String ?? "模型探测失败")
                }
                guard p["threadId"] as? String == threadID else { continue }
                if method == "item/started", let item = p["item"] as? [String: Any],
                   let type = item["type"] as? String, !["userMessage", "agentMessage", "reasoning", "hookPrompt"].contains(type) {
                    throw MetricError(message: "模型尝试调用工具，本次回答不计入指纹")
                }
                if method == "item/completed", let item = p["item"] as? [String: Any], item["type"] as? String == "agentMessage",
                   let text = item["text"] as? String {
                    if ["final_answer", "final"].contains(item["phase"] as? String ?? "") { final = text }
                    else if item["phase"] == nil || item["phase"] is NSNull { unphased.append(text) }
                }
                if method == "turn/completed", let turn = p["turn"] as? [String: Any], turn["id"] as? String == turnID {
                    guard turn["status"] as? String == "completed" else {
                        throw MetricError(message: (turn["error"] as? [String: Any])?["message"] as? String ?? "探测未完成")
                    }
                    guard let text = final ?? (unphased.count == 1 ? unphased.first : nil), !text.isEmpty else {
                        throw MetricError(message: "探测未返回完整文本回答")
                    }
                    return text
                }
            }
        } catch {
            try? send(["id": requestID + 1, "method": "turn/interrupt", "params": ["threadId": threadID, "turnId": turnID]])
            throw error
        }
    }
}
