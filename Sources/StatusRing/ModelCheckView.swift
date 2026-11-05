import SwiftUI

struct ModelCheckView: View {
    @ObservedObject var monitor: ModelMonitor
    @State private var expanded = false
    @State private var library = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("模型检测").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(library ? "返回检测" : "模型库") { library.toggle() }
                    .font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(Color.accentColor)
            }
            if library { libraryView } else { summary }
        }
        .padding(.top, 8)
        .overlay(alignment: .top) { Divider() }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Button { expanded.toggle() } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Image(systemName: monitor.symbol).foregroundStyle(monitor.tint)
                            Text(monitor.label).fontWeight(.medium)
                            Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 9)).foregroundStyle(.secondary)
                        }.font(.system(size: 12))
                        Text(monitor.operation?.model ?? monitor.selected?.caption ?? "最近 48 小时的会话")
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("模型检测详情，" + monitor.label)
                Spacer(minLength: 2)
                if monitor.operation != nil {
                    Button("停止", action: monitor.cancel).controlSize(.small)
                } else {
                    Button(monitor.selected?.model.map { monitor.enrolled($0) } == false ? "建立基线" : "检测") {
                        if let model = monitor.selected?.model, !monitor.enrolled(model) { library = true }
                        else { monitor.probe(); expanded = true }
                    }.controlSize(.small).disabled(monitor.selected == nil || monitor.refreshing || monitor.bank == nil)
                }
            }
            if let operation = monitor.operation {
                UsageBar(fraction: Double(operation.completed) / Double(operation.total), tint: .accentColor, label: "检测进度", height: 3)
                Text("\(operation.completed) / \(operation.total) 份回答 · 使用 Codex 额度")
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            if expanded { detail }
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider()
            if let snapshot = monitor.snapshot, !snapshot.sessions.isEmpty {
                Picker("会话", selection: $monitor.selectedID) {
                    ForEach(snapshot.sessions) { session in
                        Text(session.title).tag(Optional(session.id))
                    }
                }.pickerStyle(.menu).labelsHidden().controlSize(.small)
                    .font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(monitor.operation != nil)
            }
            if let error = monitor.error {
                Text(error).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                if monitor.operation == nil { Button("重新读取", action: monitor.refresh).controlSize(.small) }
            }
            if let session = monitor.selected {
                fact("请求模型", session.model ?? "未知")
                fact("推理级别", session.effort ?? "未知")
                if let record = monitor.record {
                    fact(monitor.currentRecord == nil ? "上次指纹更接近" : "指纹更接近", record.candidates.first?.model ?? "未知")
                    fact("库内归因", record.candidates.first.map { String(format: "%.0f%%", $0.probability * 100) } ?? "未知")
                    fact("有效回答", "\(record.validAnswers) / 3")
                    fact("结果时间", record.finishedAt.formatted(date: .numeric, time: .shortened))
                    if monitor.experimental(record.model), monitor.profile(record.model, effort: record.effort) == nil {
                        Text("当前 \(record.effort) 级别尚未独立验证。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if monitor.currentRecord == nil { Text("结果已过期、设置变更或来自其他账户，请重新检测。") .font(.system(size: 11)).foregroundStyle(.secondary) }
                } else { Text("尚未做指纹检测").font(.system(size: 11)).foregroundStyle(.secondary) }
                if let error = session.logError { Text(error).font(.system(size: 11)).foregroundStyle(.secondary) }
                else if session.findings.isEmpty { Label("日志未见模型或推理级别变化", systemImage: "doc.text.magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary) }
                else {
                    Text("历史配置变更").font(.system(size: 11, weight: .medium))
                    ForEach(session.findings, id: \.self) { Text($0).font(.system(size: 11)).foregroundStyle(.secondary) }
                    Text("设置变化可能来自主动调整，不能据此认定降配。") .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text("指纹为统计参考 · 手动检测通常使用 3 份回答")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.secondary).fixedSize()
            Spacer(minLength: 0)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }.font(.system(size: 11)).monospacedDigit()
    }

    private var libraryView: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(["gpt-6-astra"] + ModelMonitor.newModels, id: \.self) { model in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model).font(.system(size: 12, weight: .medium))
                        let profiles = monitor.profiles.filter { $0.model == model }.sorted { $0.effort < $1.effort }
                        if !profiles.isEmpty {
                            ForEach(profiles, id: \.effort) { profile in
                                Text(profile.validationTotal > 0
                                     ? "\(profile.effort) · \(profile.samples)份参考 · 验证\(profile.validationCorrect)/\(profile.validationTotal)组匹配"
                                     : "\(profile.effort) · \(profile.samples) 份参考 · 待独立验证")
                                    .font(.system(size: 11)).foregroundStyle(.secondary).help(profile.source)
                            }
                        } else if let count = monitor.baselineCounts[model], count > 0 {
                            Text(count >= 36 ? "36 份参考已采集 · 待校准验证" : "已采集 \(count) / 36 份")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            if let validation = monitor.validationCounts[model], validation > 0 {
                                Text("另有 \(validation) 份独立回答待验证")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer(minLength: 2)
                    if monitor.enrolled(model) {
                        HStack(spacing: 4) {
                            Circle().fill(monitor.experimental(model) ? Color(nsColor: .systemYellow) : Color(nsColor: .systemGreen))
                                .frame(width: 5, height: 5).accessibilityHidden(true)
                            Text(monitor.experimental(model) ? "实验基线" : "已收录")
                        }.font(.system(size: 11))
                    } else if (monitor.baselineCounts[model] ?? 0) >= 36 {
                        Text("待校准").font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                        Button((monitor.baselineCounts[model] ?? 0) > 0 ? "继续采集" : "采集基线") { monitor.enroll(model) }
                            .controlSize(.small).disabled(monitor.operation != nil || monitor.refreshing || monitor.snapshot == nil)
                    }
                }
            }
            if let operation = monitor.operation {
                UsageBar(fraction: Double(operation.completed) / Double(operation.total), tint: .accentColor, label: "采样进度", height: 3)
                HStack { Text("\(operation.completed) / \(operation.total) 份回答"); Spacer(); Button("停止", action: monitor.cancel).controlSize(.small) }
                    .font(.system(size: 11)).monospacedDigit()
            }
            if let error = monitor.error { Text(error).font(.system(size: 11)).foregroundStyle(.secondary) }
            Text("基线采样最多使用 36 次回答，可停止并继续。采集后还需校准和独立验证。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}
