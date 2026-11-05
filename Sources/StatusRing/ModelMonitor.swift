import Foundation
import SwiftUI

struct FingerprintProfile: Decodable {
    let model: String
    let effort: String
    let experimental: Bool
    let samples: Int
    let validationCorrect: Int
    let validationTotal: Int
    let source: String
}

@MainActor
final class ModelMonitor: ObservableObject {
    struct Operation {
        let model: String
        let sessionID: String?
        let total: Int
        var completed: Int
        var isEnrollment: Bool { sessionID == nil }
    }
    @Published private(set) var snapshot: IntegritySnapshot?
    @Published private(set) var records: [ProbeRecord] = []
    @Published private(set) var operation: Operation?
    @Published private(set) var error: String?
    @Published private(set) var refreshing = false
    @Published private(set) var baselineCounts: [String: Int] = [:]
    @Published private(set) var validationCounts: [String: Int] = [:]
    @Published var selectedID: String?
    private(set) var bank: FingerprintBank?
    private(set) var maxBank: FingerprintBank?
    private(set) var profiles: [FingerprintProfile] = []
    private let queue = DispatchQueue(label: "local.dya.MenuGauge.model-checks", qos: .utility)
    private let reader = IntegrityReader()
    private var server: CodexAppServer?
    private var timer: Timer?

    init() {
        do {
            let primaryBank = try FingerprintBank.load()
            let maximumBank = try FingerprintBank.load(url: ModelResources.url("model-fingerprints-max"))
            guard primaryBank.reasoningEffort == "low", maximumBank.reasoningEffort == "max" else {
                throw MetricError(message: "指纹库与推理级别不一致")
            }
            profiles = try JSONDecoder().decode([FingerprintProfile].self, from: Data(contentsOf: ModelResources.url("fingerprint-profiles")))
            records = try ModelCheckStorage.load([ProbeRecord].self, name: "results.json") ?? []
            for model in Self.newModels {
                baselineCounts[model] = try ModelCheckStorage.load([BaselineSample].self, name: model + "-samples.json")?.count ?? 0
                validationCounts[model] = try ModelCheckStorage.load([BaselineSample].self, name: model + "-validation.json")?.count ?? 0
            }
            bank = primaryBank
            maxBank = maximumBank
        } catch { self.error = "模型检测初始化失败：" + error.localizedDescription }
    }

    static let newModels = ["gpt-6.1-sol", "gpt-6.1-terra"]
    var selected: IntegritySession? { snapshot?.sessions.first { $0.id == selectedID } }
    var record: ProbeRecord? { records.first { $0.threadID == selectedID } }
    func experimental(_ model: String) -> Bool { profiles.contains { $0.model == model && $0.experimental } }
    func profile(_ model: String, effort: String) -> FingerprintProfile? { profiles.first { $0.model == model && $0.effort == effort } }
    func bank(for effort: String) -> FingerprintBank? { effort == "max" ? maxBank : bank }
    func enrolled(_ model: String) -> Bool { bank?.models.contains { $0.id == model } == true }
    var currentRecord: ProbeRecord? {
        guard let selected, let record, record.bankBuiltAt == bank(for: record.effort)?.builtAt,
              record.isCurrent(session: selected, account: snapshot?.accountHash) else { return nil }
        return record
    }

    var label: String {
        if let operation { return operation.isEnrollment ? "正在采集基线…" : "正在检测…" }
        if refreshing { return "正在读取会话…" }
        if let error { return error.contains("取消") ? "检测已停止" : "检测不可用" }
        guard let selected else { return snapshot == nil ? "正在读取…" : "暂无近期会话" }
        if let record = currentRecord, let bank = bank(for: record.effort) {
            if experimental(record.model), profile(record.model, effort: record.effort) == nil {
                return "实验结果待验证"
            }
            return record.verdict(experimental: experimental(record.model), bank: bank)
        }
        if record != nil { return "上次结果已过期" }
        if let model = selected.model, !enrolled(model) { return "模型未收录" }
        return selected.logError == nil ? "尚未做指纹检测" : "日志不可用"
    }
    var tint: Color {
        if operation != nil || refreshing { return Color(nsColor: .systemBlue) }
        if error != nil { return .secondary }
        switch label {
        case "指纹一致": return Color(nsColor: .systemGreen)
        case "指纹不一致": return Color(nsColor: .systemRed)
        case "指纹可疑", "实验基线相近", "实验指纹可疑": return Color(nsColor: .systemYellow)
        default: return .secondary
        }
    }
    var symbol: String {
        switch label {
        case "指纹一致": return "checkmark.circle"
        case "指纹不一致": return "exclamationmark.triangle"
        case "指纹可疑": return "questionmark.circle"
        case "实验基线相近", "实验指纹可疑", "实验结果待验证": return "testtube.2"
        case "模型未收录", "上次结果已过期": return "circle.dashed"
        default: return operation == nil ? "doc.text.magnifyingglass" : "ellipsis.circle"
        }
    }

    func open() {
        refresh()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    func close() { timer?.invalidate(); timer = nil }
    func stop() { close(); server?.cancel() }
    func cancel() { server?.cancel() }

    func refresh() {
        guard !refreshing, operation == nil, bank != nil else { return }
        refreshing = true
        let server = CodexAppServer(), reader = self.reader
        self.server = server
        queue.async { [weak self] in
            let result = Result { () -> IntegritySnapshot in
                defer { server.close() }
                try server.connect()
                return try reader.read(server: server)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.server = nil; self.refreshing = false
                switch result {
                case .success(let snapshot):
                    self.snapshot = snapshot; self.error = nil
                    if !snapshot.sessions.contains(where: { $0.id == self.selectedID }) { self.selectedID = snapshot.sessions.first?.id }
                case .failure(let error): self.error = error.localizedDescription
                }
            }
        }
    }

    func probe() {
        guard operation == nil, !refreshing, let session = selected, let model = session.model,
              let effort = session.effort, let account = snapshot?.accountHash, let bank = bank(for: effort), enrolled(model) else { return }
        let server = CodexAppServer()
        self.server = server; error = nil
        operation = Operation(model: model, sessionID: session.id, total: 3, completed: 0)
        queue.async { [weak self] in
            let result = Result { () -> ProbeRecord in
                defer { server.close() }
                try server.connect()
                var outputs: [String] = []
                for index in 0..<3 {
                    guard try IntegrityReader.account(server) == account else { throw MetricError(message: "账户已切换，请重新检测") }
                    try IntegrityReader.checkQuota(server)
                    let fork = try IntegrityReader.fork(session, server: server)
                    outputs.append(try server.answer(threadID: fork, prompt: IntegrityReader.prompt(index: index), effort: effort))
                    DispatchQueue.main.async { [weak self] in self?.operation?.completed = index + 1 }
                }
                guard try IntegrityReader.account(server) == account else { throw MetricError(message: "账户已切换，本次结果未采用") }
                let current = try server.request("thread/read", params: ["threadId": session.id, "includeTurns": false])["thread"] as? [String: Any]
                guard current?["model"] as? String == model, current?["reasoningEffort"] as? String == effort else {
                    throw MetricError(message: "会话设置已变更，请重新检测")
                }
                let analysis = try bank.analyze(outputs)
                guard analysis.validAnswers >= 2 else { throw MetricError(message: "有效回答不足两份，无法判断") }
                return ProbeRecord(threadID: session.id, accountHash: account, model: model, effort: effort, finishedAt: Date(), bankBuiltAt: bank.builtAt,
                                   candidates: analysis.candidates, validAnswers: analysis.validAnswers, margin: analysis.margin)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.operation = nil; self.server = nil
                switch result {
                case .success(let record):
                    self.records.removeAll { $0.threadID == record.threadID }
                    self.records.insert(record, at: 0)
                    self.records = Array(self.records.prefix(100))
                    do { try ModelCheckStorage.save(self.records, name: "results.json") }
                    catch { self.error = "结果未能保存：" + error.localizedDescription }
                case .failure(let error): self.error = error.localizedDescription
                }
            }
        }
    }

    func enroll(_ model: String) {
        guard operation == nil, !refreshing, Self.newModels.contains(model), let account = snapshot?.accountHash else { return }
        let server = CodexAppServer()
        self.server = server; error = nil
        operation = Operation(model: model, sessionID: nil, total: 36, completed: baselineCounts[model] ?? 0)
        queue.async { [weak self] in
            let result = Result { () -> Int in
                defer { server.close() }
                let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
                let challenges = try decoder.decode([EnrollmentChallenge].self, from: Data(contentsOf: ModelResources.url("enrollment-challenges")))
                var samples = try ModelCheckStorage.load([BaselineSample].self, name: model + "-samples.json") ?? []
                guard samples.allSatisfy({ $0.model == model && $0.accountHash == account }) else {
                    throw MetricError(message: "已有样本来自其他账户，请使用原账户继续采集")
                }
                try server.connect()
                let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("MenuGauge-Probes", isDirectory: true)
                try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                for challenge in challenges where !samples.contains(where: { $0.challengeID == challenge.challengeId }) {
                    guard try IntegrityReader.account(server) == account else { throw MetricError(message: "账户已切换，采样已停止") }
                    try IntegrityReader.checkQuota(server)
                    let response = try server.request("thread/start", params: ["ephemeral": true, "model": model, "modelProvider": "openai",
                        "allowProviderModelFallback": false, "cwd": workspace.path, "approvalPolicy": "never", "sandbox": "read-only",
                        "dynamicTools": [], "environments": [], "developerInstructions": challenge.system,
                        "config": ["model_reasoning_effort": "low"]], timeout: 45)
                    guard let thread = response["thread"] as? [String: Any], let id = thread["id"] as? String,
                          thread["ephemeral"] as? Bool == true, response["model"] as? String == model,
                          response["modelProvider"] as? String == "openai" else { throw MetricError(message: "采样模型与请求不一致") }
                    let text = try server.answer(threadID: id, prompt: challenge.input, effort: "low")
                    let numbers = FingerprintBank.parse(text)
                    guard numbers.count >= max(80, Int(ceil(Double(challenge.expectedCount) * 0.55))) else { throw MetricError(message: "数字回答不完整，采样已停止，可稍后继续") }
                    samples.append(BaselineSample(model: model, challengeID: challenge.challengeId, accountHash: account, numbers: numbers, capturedAt: Date()))
                    try ModelCheckStorage.save(samples, name: model + "-samples.json")
                    let count = samples.count
                    DispatchQueue.main.async { [weak self] in self?.operation?.completed = count; self?.baselineCounts[model] = count }
                }
                return samples.count
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.operation = nil; self.server = nil
                switch result {
                case .success(let count): self.baselineCounts[model] = count
                case .failure(let error): self.error = error.localizedDescription
                }
            }
        }
    }
}
