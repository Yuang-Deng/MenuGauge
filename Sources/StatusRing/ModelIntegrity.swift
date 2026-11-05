import Foundation
import CryptoKit

struct IntegritySession: Identifiable {
    let id: String
    let title: String
    let model: String?
    let effort: String?
    let provider: String
    let cwd: String
    let updatedAt: Date
    let findings: [String]
    let logError: String?
    var caption: String { [model ?? "模型未知", effort ?? "推理级别未知"].joined(separator: " · ") }
}

struct ProbeRecord: Codable {
    let threadID: String
    let accountHash: String
    let model: String
    let effort: String
    let finishedAt: Date
    let bankBuiltAt: String
    let candidates: [FingerprintBank.Candidate]
    let validAnswers: Int
    let margin: Double

    func isCurrent(session: IntegritySession, account: String?, now: Date = Date()) -> Bool {
        accountHash == account && model == session.model && effort == session.effort
            && now.timeIntervalSince(finishedAt) <= 1800
    }
    func verdict(experimental: Bool, bank: FingerprintBank) -> String {
        guard bank.models.contains(where: { $0.id == model }) else { return "模型未收录" }
        let top = candidates[0]
        if experimental { return top.model == model ? "实验基线相近" : "实验指纹可疑" }
        if top.model == model { return top.probability >= 0.8 && validAnswers >= 2 ? "指纹一致" : "指纹可疑" }
        guard let expected = candidates.first(where: { $0.model == model })?.probability else { return "指纹可疑" }
        return top.probability >= 0.8 && expected <= 0.2 && margin >= 0.5 && validAnswers >= 2 ? "指纹不一致" : "指纹可疑"
    }
}

struct IntegritySnapshot {
    let accountHash: String
    let sessions: [IntegritySession]
    let fetchedAt: Date
}

/// Incremental, local inspection of the model/effort metadata; never treats a change as proof of a silent downgrade.
final class RolloutInspector {
    private var offset: UInt64 = 0
    private var pending = Data()
    private var model: String?
    private var effort: String?
    private var window: Int?
    private var changes: [String: String] = [:]
    private var sawContext = false

    func read(url: URL) throws -> (model: String?, effort: String?, findings: [String]) {
        do { return try readIncrement(url: url) }
        catch {
            // Never turn a previously rejected/truncated scan into an apparently clean incremental result.
            offset = 0; pending = Data(); model = nil; effort = nil; window = nil; changes = [:]; sawContext = false
            throw error
        }
    }

    private func readIncrement(url: URL) throws -> (model: String?, effort: String?, findings: [String]) {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let size = try file.seekToEnd()
        if size < offset { offset = 0; pending = Data(); model = nil; effort = nil; window = nil; changes = [:]; sawContext = false }
        try file.seek(toOffset: offset)
        while let data = try file.read(upToCount: 65536), !data.isEmpty {
            offset += UInt64(data.count); pending.append(data)
            while let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline]); pending.removeSubrange(...newline)
                if !line.isEmpty { try consume(line) }
            }
            guard pending.count < 32 * 1024 * 1024 else { throw MetricError(message: "会话日志单条记录过大") }
        }
        guard sawContext else { throw MetricError(message: "会话日志尚无模型上下文记录") }
        return (model, effort, changes.keys.sorted().compactMap { changes[$0] })
    }

    func consume(_ line: Data) throws {
        guard let event = try JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = event["payload"] as? [String: Any] else { return }
        if event["type"] as? String == "turn_context", let next = payload["model"] as? String {
            sawContext = true
            let nextEffort = payload["effort"] as? String ?? payload["reasoning_effort"] as? String
            if let model, model != next { changes["model"] = "模型设置变更：\(model) → \(next)" }
            if let effort, let nextEffort, effort != nextEffort { changes["effort"] = "推理级别变更：\(effort) → \(nextEffort)" }
            model = next; effort = nextEffort
        }
        if payload["type"] as? String == "token_count",
           let info = payload["info"] as? [String: Any], let next = info["model_context_window"] as? Int {
            if let window, next < window { changes["context"] = "记录中的上下文窗口缩小：\(window) → \(next)" }
            window = next
        }
    }
}

// Its rollout inspectors are accessed only by ModelMonitor's serial worker queue.
final class IntegrityReader: @unchecked Sendable {
    private var inspectors: [String: RolloutInspector] = [:]
    func read(server: CodexAppServer) throws -> IntegritySnapshot {
        let account = try Self.account(server)
        let result = try server.request("thread/list", params: ["limit": 12, "sortKey": "updated_at", "sourceKinds": ["cli", "appServer", "vscode"]])
        guard let threads = result["data"] as? [[String: Any]] else { throw MetricError(message: "Codex 未返回会话列表") }
        let cutoff = Date().addingTimeInterval(-48 * 3600)
        let sessions = try threads.filter { $0["ephemeral"] as? Bool != true && $0["parentThreadId"] is NSNull }.prefix(8).map { thread -> IntegritySession in
            guard let id = thread["id"] as? String, let cwd = thread["cwd"] as? String,
                  let provider = thread["modelProvider"] as? String, let timestamp = thread["updatedAt"] as? Double else {
                throw MetricError(message: "Codex 会话元数据不完整")
            }
            var model = thread["model"] as? String, effort = thread["reasoningEffort"] as? String
            var findings: [String] = [], logError: String?
            do {
                guard let path = thread["path"] as? String else { throw MetricError(message: "会话未提供本地日志路径") }
                let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
                let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex").standardizedFileURL.resolvingSymlinksInPath()
                guard url.path.hasPrefix(home.path + "/"), url.pathExtension == "jsonl" else { throw MetricError(message: "会话未使用可读取的 Codex 日志") }
                let inspector = inspectors[id] ?? RolloutInspector(); inspectors[id] = inspector
                let scan = try inspector.read(url: url)
                // Metadata describes the current selected configuration; a rollout may lag a settings change.
                if model == nil { model = scan.model }; if effort == nil { effort = scan.effort }
                findings = scan.findings
            } catch { logError = error.localizedDescription }
            let title = (thread["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "会话 " + id.prefix(8)
            return IntegritySession(id: id, title: title, model: model, effort: effort, provider: provider, cwd: cwd,
                                    updatedAt: Date(timeIntervalSince1970: timestamp), findings: findings, logError: logError)
        }.filter { $0.updatedAt >= cutoff }
        return IntegritySnapshot(accountHash: account, sessions: sessions, fetchedAt: Date())
    }

    static func account(_ server: CodexAppServer) throws -> String {
        let response = try server.request("account/read")
        guard let account = response["account"] as? [String: Any], account["type"] as? String == "chatgpt",
              let email = account["email"] as? String, !email.isEmpty else { throw MetricError(message: "模型检测需要登录 Codex 的 ChatGPT 账户") }
        // account/read exposes account/workspace metadata, never credentials. Persist only its hash.
        var identity: [String: Any] = ["account": account]
        identity["workspaceRouting"] = response["workspaceRouting"]
        let data = try JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func checkQuota(_ server: CodexAppServer) throws {
        let response = try server.request("account/rateLimits/read")
        let quota = try CodexQuota.decode(JSONSerialization.data(withJSONObject: response))
        guard !quota.isStale(), quota.remainingPercent > 5 else { throw MetricError(message: "Codex 额度不足或已过期，已停止探测") }
    }

    static func fork(_ session: IntegritySession, server: CodexAppServer) throws -> String {
        guard let model = session.model, let effort = session.effort else { throw MetricError(message: "无法确认会话的模型和推理级别") }
        guard effort != "ultra" else { throw MetricError(message: "Ultra 会启用任务协作，暂不支持指纹探测") }
        let turns = try server.request("thread/turns/list", params: ["threadId": session.id, "limit": 8, "itemsView": "notLoaded", "sortDirection": "desc"])
        guard let turn = (turns["data"] as? [[String: Any]])?.first(where: { $0["status"] as? String == "completed" }),
              let turnID = turn["id"] as? String else { throw MetricError(message: "会话尚无已完成轮次，请稍后检测") }
        let result = try server.request("thread/fork", params: ["threadId": session.id, "lastTurnId": turnID, "ephemeral": true,
            "excludeTurns": true, "model": model, "modelProvider": session.provider, "cwd": session.cwd,
            "approvalPolicy": "never", "sandbox": "read-only", "config": ["model_reasoning_effort": effort]], timeout: 45)
        guard let thread = result["thread"] as? [String: Any], let id = thread["id"] as? String,
              id != session.id, thread["ephemeral"] as? Bool == true, thread["path"] is NSNull,
              thread["forkedFromId"] as? String == session.id, result["model"] as? String == model,
              result["modelProvider"] as? String == session.provider,
              result["reasoningEffort"] as? String == effort else { throw MetricError(message: "临时副本的模型或推理设置与原会话不一致") }
        return id
    }

    static func prompt(index: Int) -> String {
        if index % 2 == 0 {
            return "直接选择 310 个 1 到 355（含边界）的整数。允许重复；不要排序、平衡频数、修复重复，也不要刻意构造等差规律。\n直接回答一个 JSON 整数数组，不要解释。不要调用工具、读文件、运行代码或让其他模型代答；不要继续之前的任务。"
        }
        return "Directly choose 310 integers from 1 through 355, inclusive. Allow repeats. Do not sort, balance frequencies, repair duplicates, or deliberately create an arithmetic pattern.\nReply directly with one JSON integer array and no explanation. Do not call tools, read files, execute code or ask another model. Do not continue the preceding task."
    }
}

struct EnrollmentChallenge: Decodable {
    let condition: String
    let system: String
    let userPrefix: String
    let challengeId: String
    let expectedCount: Int
    let prompt: String
    var input: String { userPrefix.isEmpty ? prompt : userPrefix + "\n\nFinal task:\n" + prompt }
}

struct BaselineSample: Codable {
    let model: String
    let challengeID: String
    let accountHash: String
    let numbers: [Int]
    let capturedAt: Date?
}

enum ModelCheckStorage {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MenuGauge/ModelChecks", isDirectory: true)
    }
    static func save<T: Encodable>(_ value: T, name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let file = directory.appendingPathComponent(name)
        try encoder.encode(value).write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    static func load<T: Decodable>(_ type: T.Type, name: String) throws -> T? {
        let file = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: file))
    }
}
