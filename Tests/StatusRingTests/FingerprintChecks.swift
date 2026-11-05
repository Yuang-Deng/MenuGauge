import Foundation

enum FingerprintChecks {
    static func run() throws {
        struct Fixture: Decodable { let outputs: [String]; let prediction: String; let probabilities: [String: Double] }
        let bank = try FingerprintBank.load()
        for suffix in ["", "-max"] {
            let currentBank = try FingerprintBank.load(url: ModelResources.url("model-fingerprints" + suffix))
            assert(currentBank.reasoningEffort == (suffix.isEmpty ? "low" : "max"))
            let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: URL(fileURLWithPath: "Tests/Fixtures/model-fingerprint-parity" + suffix + ".json")))
            for fixture in fixtures {
                let analysis = try currentBank.analyze(fixture.outputs, expectedCount: 0)
                assert(analysis.candidates[0].model == fixture.prediction)
                for candidate in analysis.candidates { assert(abs(candidate.probability - fixture.probabilities[candidate.model]!) < 1e-9) }
            }
        }
        do { _ = try bank.analyze(["I cannot provide that."]); assertionFailure("Refusals cannot produce a fingerprint verdict") } catch {}
        assert(FingerprintBank.parse("1,2,3 explanation 4,5") == [1,2,3])
        let file = URL(fileURLWithPath: ".build/rollout-check.jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(#"{"type":"turn_context","payload":{"model":"gpt-6-astra","effort":"high"}}"#.utf8).write(to: file)
        let inspector = RolloutInspector()
        do { _ = try inspector.read(url: file); assertionFailure("A partially written record must not claim a successful scan") } catch {}
        let append = try FileHandle(forWritingTo: file)
        try append.seekToEnd(); try append.write(contentsOf: Data("\n".utf8)); try append.close()
        let first = try inspector.read(url: file)
        assert(first.model == "gpt-6-astra" && first.findings.isEmpty)
        let secondLine = #"{"type":"turn_context","payload":{"model":"gpt-6-sol","effort":"low"}}"# + "\n"
        let appendSecond = try FileHandle(forWritingTo: file)
        try appendSecond.seekToEnd(); try appendSecond.write(contentsOf: Data(secondLine.utf8)); try appendSecond.close()
        let changed = try inspector.read(url: file)
        assert(changed.model == "gpt-6-sol" && changed.findings.count == 2)
        let session = IntegritySession(id: "thread", title: "Test", model: "gpt-6-astra", effort: "high", provider: "openai", cwd: "/tmp", updatedAt: Date(), findings: [], logError: nil)
        let record = ProbeRecord(threadID: "thread", accountHash: "account-a", model: "gpt-6-astra", effort: "high", finishedAt: Date(), bankBuiltAt: bank.builtAt,
                                 candidates: [FingerprintBank.Candidate(model: "gpt-6-astra", probability: 0.99, score: 2)], validAnswers: 3, margin: 1)
        assert(record.isCurrent(session: session, account: "account-a"))
        assert(!record.isCurrent(session: session, account: "account-b"))
        assert(!record.isCurrent(session: session, account: "account-a", now: Date().addingTimeInterval(1801)))
        assert(record.verdict(experimental: true, bank: bank) == "实验基线相近")
        print("Fingerprint parity, invalid samples, incremental rollout and account freshness checks passed")
    }
}
