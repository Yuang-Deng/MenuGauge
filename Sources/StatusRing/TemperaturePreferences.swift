import Combine
import Foundation

struct TemperatureThresholds: Equatable {
    let warning: Int
    let critical: Int
    static let standard = TemperatureThresholds(warning: 70, critical: 85)

    var isValid: Bool { warning >= 30 && critical <= 110 && warning < critical }

    func level(for celsius: Double) -> PressureLevel {
        let displayed = Int(celsius.rounded())
        return displayed >= critical ? .high : displayed >= warning ? .medium : .low
    }
}

final class TemperaturePreferences: ObservableObject {
    private static let key = "menuBar.temperatureThresholds"
    private let defaults: UserDefaults
    @Published private(set) var thresholds = TemperatureThresholds.standard
    @Published private(set) var error: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let stored = defaults.object(forKey: Self.key) else { return }
        guard let values = stored as? [String: Int], let warning = values["warning"],
              let critical = values["critical"], TemperatureThresholds(warning: warning, critical: critical).isValid else {
            error = "温度颜色设置无效，已恢复 70°C / 85°C；调整阈值可重新保存。"
            return
        }
        thresholds = TemperatureThresholds(warning: warning, critical: critical)
    }

    func setWarning(_ value: Int) { save(TemperatureThresholds(warning: value, critical: thresholds.critical)) }
    func setCritical(_ value: Int) { save(TemperatureThresholds(warning: thresholds.warning, critical: value)) }

    private func save(_ value: TemperatureThresholds) {
        guard value.isValid else {
            error = "黄色阈值须低于红色阈值，范围为 30–110°C。"
            return
        }
        defaults.set(["warning": value.warning, "critical": value.critical], forKey: Self.key)
        thresholds = value
        error = nil
    }
}
