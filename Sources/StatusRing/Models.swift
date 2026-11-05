import Foundation

enum PowerMode: String {
    case charging, pluggedIn, battery

    var symbol: String? {
        switch self {
        case .charging: return "bolt.fill"
        case .pluggedIn: return "powerplug.fill"
        case .battery: return nil
        }
    }

    var label: String {
        switch self {
        case .charging: return "正在充电"
        case .pluggedIn: return "已插电，未充电"
        case .battery: return "使用电池"
        }
    }
}

struct BatteryReading {
    let fraction: Double
    let mode: PowerMode
    var percent: Int { Int((fraction * 100).rounded()) }
}

struct MetricError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum TemperatureText {
    static func compact(_ celsius: Double) -> String { "\(Int(celsius.rounded()))°" }
}
