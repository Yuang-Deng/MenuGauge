import AppKit
import SwiftUI

struct QuotaDetail: Identifiable {
    let id: Int
    let window: String
    let reset: String
}

struct StatusPanelData {
    var batteryPercent: Int?
    var batteryHealthText = "正在读取…"
    var batteryHealthHint = "相对于新电池的最大容量"
    var powerText = "正在读取电源…"
    var powerHint = ""
    var showChargeButton = true
    var chargeTitle = "立即充满电"
    var chargeEnabled = false
    var chargeHint = "正在读取充电状态…"
    var temperature = "— °C"
    var temperatureHint = ""
    var cpu: Double?
    var memory: Double?
    var memoryPressure: PressureLevel?
    var resourceHint = ""
    var memoryPressureHint = ""
    var memoryDetails = "— / — GB"
    var disk: DiskReading?
    var diskHint = ""
    var quotaRemaining: Double?
    var quotaStale = false
    var quotaMessage = "正在读取…"
    var quotaHint = ""
    var quotaDetails: [QuotaDetail] = []
    var networkAddress = "🌐 正在读取…"
    var networkSpeed = "↑ —  ↓ —"
    var networkHint = ""

    var batteryText: String { batteryPercent.map { "\($0)%" } ?? "—" }

    var batterySymbol: String {
        switch batteryPercent ?? 0 {
        case 100: return "battery.100percent"
        case 63...99: return "battery.75percent"
        case 38...62: return "battery.50percent"
        case 1...37: return "battery.25percent"
        default: return "battery.0percent"
        }
    }
}

final class StatusPanelModel: ObservableObject {
    @Published var data = StatusPanelData()
}

private extension PressureLevel {
    var color: Color {
        switch self { case .low: return Color(nsColor: .systemGreen)
        case .medium: return Color(nsColor: .systemYellow)
        case .high: return Color(nsColor: .systemRed) }
    }
}

struct UsageBar: View {
    let fraction: Double?
    let tint: Color
    let label: String
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                if let fraction {
                    Capsule().fill(tint)
                        .frame(width: geometry.size.width * min(1, max(0, fraction)))
                }
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(fraction.map { String(format: "%.0f%%", $0 * 100) } ?? "不可用")
    }
}

private struct GaugeArc: Shape {
    let fraction: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = min(rect.width / 2 - 4, rect.height - 8)
        guard radius > 0, fraction > 0 else { return path }
        path.addArc(center: CGPoint(x: rect.midX, y: rect.maxY - 4),
                    radius: radius, startAngle: .degrees(180),
                    endAngle: .degrees(180 + min(1, fraction) * 180), clockwise: false)
        return path
    }
}

private struct PressureGauge: View {
    let name: String
    let percent: Double?
    let level: PressureLevel?
    let state: String
    let detail: String?
    let hint: String

    var body: some View {
        let value = percent.map { String(format: "%.0f%%", $0) } ?? "—"
        let stroke = StrokeStyle(lineWidth: 5, lineCap: .round)
        VStack(spacing: 4) {
            Text(name).fontWeight(.semibold)
            ZStack(alignment: .bottom) {
                GaugeArc(fraction: 1).stroke(Color.primary.opacity(0.12), style: stroke)
                if let percent {
                    GaugeArc(fraction: percent / 100).stroke(level?.color ?? .secondary, style: stroke)
                }
                Text(value).font(.system(size: 16, weight: .semibold)).monospacedDigit()
                    .padding(.bottom, 5)
            }
            .frame(width: 80, height: 44)
            Text(state).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            if let detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .help(hint)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name + "使用率")
        .accessibilityValue([value, state, detail].compactMap { $0 }.joined(separator: "，"))
    }
}

struct StatusPanelView: View {
    @ObservedObject var model: StatusPanelModel
    var agenda: CalendarAgenda
    var onCharge: () -> Void
    var onQuit: () -> Void

    var body: some View {
        let data = model.data
        let quotaPercent = data.quotaRemaining.map { Int($0.rounded()) }
        let quotaTint = quotaPercent.map { percent in
            switch percent {
            case ...5: return PressureLevel.high.color
            case ...20: return PressureLevel.medium.color
            default: return PressureLevel.low.color
            }
        } ?? .secondary
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 8) {
                HStack {
                    Label("电池", systemImage: data.batterySymbol).fontWeight(.semibold)
                    Spacer()
                    Text(data.batteryText).fontWeight(.semibold).monospacedDigit()
                }
                HStack(spacing: 8) {
                    Text(data.powerText).font(.system(size: 12)).foregroundStyle(.secondary)
                        .help(data.powerHint)
                    Spacer(minLength: 4)
                    if data.showChargeButton {
                        Button(data.chargeTitle, action: onCharge)
                            .controlSize(.small).disabled(!data.chargeEnabled)
                            .help(data.chargeHint)
                    }
                }.frame(minHeight: 24)
                HStack {
                    Text("电池健康度").foregroundStyle(.secondary)
                    Spacer()
                    Text(data.batteryHealthText).monospacedDigit()
                }.font(.system(size: 12)).help(data.batteryHealthHint)
            }
            Divider()
            VStack(spacing: 10) {
                HStack {
                    Text("性能").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    Label(data.temperature, systemImage: "thermometer.medium")
                        .font(.system(size: 12)).monospacedDigit().help(data.temperatureHint)
                }
                HStack(alignment: .top, spacing: 4) {
                    PressureGauge(name: "CPU", percent: data.cpu, level: data.cpu.map(PressureLevel.cpu),
                                  state: data.cpu.map { PressureLevel.cpu($0).cpuLabel } ?? (data.resourceHint.isEmpty ? "采样中…" : "不可用"),
                                  detail: nil, hint: data.resourceHint.isEmpty ? "全部 CPU 核心的平均使用率" : data.resourceHint)
                    PressureGauge(name: "内存", percent: data.memory, level: data.memoryPressure,
                                  state: data.memoryPressure?.memoryLabel ?? "压力未知",
                                  detail: data.memoryDetails,
                                  hint: ["弧长表示使用率，颜色表示系统内存压力；不含文件缓存。", data.resourceHint, data.memoryPressureHint]
                                      .filter { !$0.isEmpty }.joined(separator: "\n"))
                    PressureGauge(name: "硬盘", percent: data.disk?.usedPercent, level: data.disk?.level,
                                  state: data.disk?.label ?? "不可用",
                                  detail: data.disk.map {
                                      String(format: "%.0f / %.0f GB", Double($0.usedBytes) / 1_000_000_000,
                                             Double($0.totalBytes) / 1_000_000_000)
                                  } ?? "— / — GB", hint: data.diskHint)
                }
            }
            Divider()
            VStack(spacing: 6) {
                HStack {
                    Text("Codex").fontWeight(.semibold)
                    Spacer()
                    if let quotaPercent {
                        Text("\(quotaPercent)%").fontWeight(.semibold).monospacedDigit()
                            .foregroundStyle(quotaPercent == 0 && !data.quotaStale ? quotaTint : Color.primary)
                        Text(data.quotaStale ? "已过期" : "剩余").font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        Text(data.quotaMessage).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                UsageBar(fraction: data.quotaRemaining.map { $0 / 100 },
                         tint: quotaTint.opacity(data.quotaStale ? 0.4 : 1), label: "Codex 剩余额度", height: 4)
                ForEach(data.quotaDetails) { detail in
                    HStack { Text(detail.window); Spacer(); Text(detail.reset) }
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
            }.help(data.quotaHint)
            Divider()
            HStack(spacing: 6) {
                Text(data.networkAddress).lineLimit(1).truncationMode(.middle)
                    .layoutPriority(0)
                Spacer(minLength: 2)
                Text(data.networkSpeed).fixedSize().layoutPriority(1)
            }.font(.system(size: 11)).monospacedDigit().help(data.networkHint)
            Divider()
            WeekAgendaView(model: agenda)
            Divider()
            Button(action: onQuit) {
                HStack { Text("退出 MenuGauge"); Spacer(); Text("⌘ Q").font(.system(size: 11)).foregroundStyle(.secondary) }
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).keyboardShortcut("q", modifiers: .command)
        }
        .font(.system(size: 13))
        .padding(14)
        .frame(width: 336)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
