import Foundation

struct ExitCountry {
    let ip: String
    let code: String

    var flag: String {
        String(String.UnicodeScalarView(code.unicodeScalars.map { UnicodeScalar($0.value + 127397)! }))
    }

    static func decode(_ data: Data) throws -> ExitCountry {
        struct Response: Decodable {
            let success: Bool
            let ip: String?
            let country_code: String?
            let message: String?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.success else {
            throw MetricError(message: response.message ?? "公网出口查询失败")
        }
        guard let ip = response.ip, !ip.isEmpty, let code = response.country_code,
              code.utf8.count == 2, code.utf8.allSatisfy({ (65...90).contains($0) }) else {
            throw MetricError(message: "公网出口查询未返回有效地区")
        }
        return ExitCountry(ip: ip, code: code)
    }

    static func fetch() async throws -> ExitCountry {
        let url = URL(string: "https://ipwho.is/?fields=success,ip,country_code,message")!
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw MetricError(message: "公网出口查询服务暂不可用")
        }
        return try decode(data)
    }
}
