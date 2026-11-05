import Foundation

// Native port of ModelTrace / is-gpt-nerfed's MIT fingerprint scorer. See THIRD_PARTY_NOTICES.txt.
struct FingerprintBank: Decodable {
    struct Model: Decodable { let id: String; let responseCount: Int }
    struct Artifact: Decodable {
        let featureMean: [Double]
        let featureScale: [Double]
        let nuisanceBasis: [[Double]]
        let centroids: [[Double]]
        let environmentCentroids: [[[Double]]]?
        let weight: Double?
    }
    struct Robust: Decodable { let hellinger: Artifact; let orderedBlocks: Artifact }
    struct Calibration: Decodable { let beta: Double; let cvAccuracy: Double?; let fallback: Bool }
    let models: [Model]
    let builtAt: String
    let robust: Robust
    let calibration: [String: Calibration]

    static func load(url: URL? = nil) throws -> FingerprintBank {
        let data = try Data(contentsOf: url ?? ModelResources.url("model-fingerprints"))
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let bank = try decoder.decode(Self.self, from: data)
        guard !bank.models.isEmpty, Set(bank.models.map(\.id)).count == bank.models.count else { throw MetricError(message: "指纹库模型清单无效") }
        for (artifact, dimension) in [(bank.robust.hellinger, 355), (bank.robust.orderedBlocks, 74)] {
            let vectors = artifact.nuisanceBasis + artifact.centroids + (artifact.environmentCentroids ?? []).flatMap { $0 }
            guard artifact.featureMean.count == dimension, artifact.featureScale.count == dimension,
                  artifact.featureScale.allSatisfy({ $0.isFinite && $0 > 0 }),
                  artifact.centroids.count == bank.models.count,
                  vectors.allSatisfy({ $0.count == dimension && $0.allSatisfy(\.isFinite) }),
                  (artifact.environmentCentroids ?? []).allSatisfy({ $0.count == bank.models.count }),
                  !(artifact.environmentCentroids ?? []).isEmpty || dimension == 355 else {
                throw MetricError(message: "指纹库特征维度无效")
            }
        }
        guard ["1", "2", "3"].allSatisfy({ key in bank.calibration[key].map { $0.beta.isFinite && $0.beta > 0 && !$0.fallback } == true }) else {
            throw MetricError(message: "指纹库尚未完成概率校准")
        }
        return bank
    }

    struct Candidate: Codable { let model: String; let probability: Double; let score: Double }
    struct Analysis { let candidates: [Candidate]; let validAnswers: Int; let margin: Double }

    func analyze(_ outputs: [String], expectedCount: Int = 310) throws -> Analysis {
        let minimum = max(80, Int(ceil(Double(expectedCount) * 0.55)))
        let samples = outputs.map(Self.parse).filter { $0.count >= minimum }.prefix(3)
        guard !samples.isEmpty else { throw MetricError(message: "没有有效的数字回答，无法判断指纹") }
        let scores = samples.map(score)
        let combined = models.indices.map { index in scores.map { $0[index] }.reduce(0, +) / Double(scores.count) }
        let beta = calibration[String(scores.count)]!.beta
        let scaled = combined.map { $0 * beta }, maximum = scaled.max()!
        let weights = scaled.map { exp($0 - maximum) }, total = weights.reduce(0, +)
        let candidates = models.indices.map { Candidate(model: models[$0].id, probability: weights[$0] / total, score: combined[$0]) }
            .sorted { $0.probability > $1.probability }
        return Analysis(candidates: candidates, validAnswers: samples.count,
                        margin: candidates.count > 1 ? candidates[0].score - candidates[1].score : 0)
    }

    static func parse(_ text: String) -> [Int] {
        let expression = try! NSRegularExpression(pattern: "\\d+")
        let source = text as NSString
        var longest: [Int] = [], current: [Int] = [], previous = 0
        for match in expression.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let separator = source.substring(with: NSRange(location: previous, length: match.range.location - previous))
            if !current.isEmpty, separator.unicodeScalars.contains(where: CharacterSet.letters.contains) {
                if current.count > longest.count { longest = current }; current = []
            }
            if let value = Int(source.substring(with: match.range)), (1...355).contains(value) { current.append(value) }
            previous = match.range.location + match.range.length
        }
        return current.count > longest.count ? current : longest
    }

    private func score(_ numbers: [Int]) -> [Double] {
        var counts = [Double](repeating: 0.5, count: 355)
        for n in numbers { counts[n - 1] += 1 }
        let total = counts.reduce(0, +)
        let marginal = projectedScores(counts.map { sqrt($0 / total) }, artifact: robust.hellinger)
        var ordered: [Double] = [], start = 0
        for block in 0..<4 {
            let size = numbers.count / 4 + (block < numbers.count % 4 ? 1 : 0)
            var bins = [Double](repeating: 0.5, count: 16)
            for n in numbers[start..<(start + size)] { bins[min(15, Int(Double(n - 1) / 355 * 16))] += 1 }
            let sum = bins.reduce(0, +); ordered += bins.map { sqrt($0 / sum) }; start += size
        }
        var digits = [Double](repeating: 0.5, count: 10)
        for n in numbers { digits[n % 10] += 1 }
        let digitSum = digits.reduce(0, +); ordered += digits.map { sqrt($0 / digitSum) }
        let artifact = robust.orderedBlocks
        let standardized = zip(zip(ordered, artifact.featureMean), artifact.featureScale).map { ($0.0.0 - $0.0.1) / $0.1 }
        let unit = Self.normalized(standardized)
        let environments = artifact.environmentCentroids!.map { $0.map { Self.dot(unit, $0) } }
        let template = Self.standardize(models.indices.map { index in environments.map { $0[index] }.max()! })
        let nuisance = projectedScores(ordered, artifact: artifact)
        let fused = Self.standardize(zip(template, nuisance).map { ($0 + $1) / 2 })
        let weight = artifact.weight ?? 0.25
        return zip(marginal, fused).map { (1 - weight) * $0 + weight * $1 }
    }

    private func projectedScores(_ feature: [Double], artifact: Artifact) -> [Double] {
        var projected = zip(zip(feature, artifact.featureMean), artifact.featureScale).map { ($0.0.0 - $0.0.1) / $0.1 }
        for basis in artifact.nuisanceBasis {
            let projection = Self.dot(projected, basis)
            projected = zip(projected, basis).map { $0 - projection * $1 }
        }
        let unit = Self.normalized(projected)
        return Self.standardize(artifact.centroids.map { Self.dot(unit, $0) })
    }

    private static func dot(_ a: [Double], _ b: [Double]) -> Double { zip(a, b).map(*).reduce(0, +) }
    private static func normalized(_ a: [Double]) -> [Double] {
        let scale = max(sqrt(dot(a, a)), 1e-12); return a.map { $0 / scale }
    }
    private static func standardize(_ a: [Double]) -> [Double] {
        let mean = a.reduce(0, +) / Double(a.count)
        let scale = max(sqrt(a.map { pow($0 - mean, 2) }.reduce(0, +) / Double(a.count)), 1e-12)
        return a.map { ($0 - mean) / scale }
    }
}

enum ModelResources {
    static func url(_ name: String) throws -> URL {
        if Bundle.main.bundleURL.pathExtension == "app" {
            guard let package = Bundle.main.url(forResource: "StatusRing_StatusRing", withExtension: "bundle"),
                  let bundle = Bundle(url: package),
                  let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Resources") else {
                throw MetricError(message: "应用缺少模型指纹资源，请重新构建或安装")
            }
            return url
        }
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        if let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Resources") { return url }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Resources/\(name).json")
        guard FileManager.default.fileExists(atPath: source.path) else { throw MetricError(message: "应用缺少模型指纹资源，请重新构建或安装") }
        return source
    }
}
