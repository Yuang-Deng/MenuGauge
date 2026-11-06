import AppKit
import Combine
import SwiftUI
import IOKit.ps
import OSLog

@main
struct StatusRingApp {
    static func main() {
        if CommandLine.arguments.contains("--snapshot") {
            do {
                let resources = ResourceReader()
                _ = try resources.read()
                let battery = try BatteryReader.read()
                let temperature = try TemperatureReader().read()
                var result: [String: Any] = [
                    "batteryPercent": battery.percent, "powerMode": battery.mode.rawValue,
                    "cpuTemperatureCelsius": temperature
                ]
                do {
                    result["batteryHealthPercent"] = try BatteryHealthReader.read()
                } catch {
                    result["batteryHealthError"] = error.localizedDescription
                }
                let networkReader = try NetworkReader()
                if let network = try networkReader.read() {
                    result["networkInterface"] = network.interface
                    result["ipAddress"] = network.address
                }
                do {
                    let charging = try SmartCharging().read()
                    result["chargeLimitPercent"] = charging.limitEnabled ? charging.limit : 100
                    result["canChargeToFull"] = battery.mode != .battery && battery.fraction < 1 && charging.canOverride
                } catch {
                    result["chargingControlError"] = error.localizedDescription
                }
                let quota = try CodexQuotaReader().read()
                result["codexRemainingPercent"] = quota.remainingPercent
                result["codexWindows"] = quota.windows.map { window -> [String: Any] in
                    var entry: [String: Any] = ["remainingPercent": window.remainingPercent]
                    entry["windowDurationMins"] = window.windowDurationMins
                    entry["resetsAt"] = window.resetsAt
                    return entry
                }
                do {
                    let server = CodexAppServer(); defer { server.close() }
                    try server.connect()
                    let integrity = try IntegrityReader().read(server: server)
                    result["modelCheckSessions"] = integrity.sessions.count
                    result["modelCheckReadableLogs"] = integrity.sessions.filter { $0.logError == nil }.count
                    result["fingerprintModels"] = try FingerprintBank.load().models.map(\.id)
                } catch { result["modelCheckError"] = error.localizedDescription }
                Thread.sleep(forTimeInterval: 0.5)
                let usage = try resources.read()
                result["cpuUsagePercent"] = usage.cpuPercent
                result["memoryUsagePercent"] = usage.memoryPercent
                result["memoryPressure"] = usage.memoryPressure?.rawValue
                result["memoryPressureError"] = usage.memoryPressureError
                result["memoryUsedBytes"] = usage.memoryUsedBytes
                result["memoryTotalBytes"] = usage.memoryTotalBytes
                let disk = try DiskReader.read()
                result["diskUsedPercent"] = disk.usedPercent
                result["diskUsedBytes"] = disk.usedBytes
                result["diskTotalBytes"] = disk.totalBytes
                result["diskAvailableBytes"] = disk.availableBytes
                let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                print(String(decoding: data, as: UTF8.self))
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                exit(1)
            }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var item: NSStatusItem!
    private let panelModel = StatusPanelModel()
    private let temperaturePreferences = TemperaturePreferences()
    private var temperatureChanges: AnyCancellable?
    @MainActor private lazy var agenda = CalendarAgenda()
    @MainActor private lazy var modelMonitor = ModelMonitor()
    private let popover = NSPopover()
    private var outsideClickMonitor: Any?
    private var temperatureReader: TemperatureReader?
    private var metricsTimer: Timer?
    private var resourceReader = ResourceReader()
    private var resources: ResourceReading?
    private var resourceError: String?
    private var disk: DiskReading?
    private var diskError: String?
    private var networkReader: NetworkReader?
    private var networkTimer: Timer?
    private var networkMonitor: NetworkMonitor?
    private var networkAddress: NetworkAddress?
    private var exitCountry: ExitCountry?
    private var countryError: String?
    private var countryLastAttempt: Date?
    private var countryTask: Task<Void, Never>?
    private var countryRequestID = UUID()
    private var quotaReader: CodexQuotaReader?
    private var quotaTimer: Timer?
    private var quota: CodexQuota?
    private var quotaError: String?
    private var terminating = false
    private let chargingQueue = DispatchQueue(label: "local.dya.StatusRing.charging", qos: .utility)
    private var chargingState: ChargingControlState?
    private var chargingError: String?
    private var chargingRequestID = UUID()
    private var chargingActionInFlight = false
    private var powerSource: CFRunLoopSource?
    private var wakeObserver: NSObjectProtocol?
    private var battery: BatteryReading?
    private var batteryHealth: Result<Int, Error>?
    private var readingBatteryHealth = false
    private var temperature: Double?
    private var batteryError: String?
    private var temperatureError: String?
    private let logger = Logger(subsystem: "local.dya.StatusRing", category: "metrics")
    private var networkError: String?
    private var speedText = "↑ —  ↓ —"
    private var speedError: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: 46 * max(18, NSStatusBar.system.thickness) / 22)
        item.autosaveName = "StatusRing"
        item.button?.imageScaling = .scaleNone
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        let host = NSHostingController(rootView: StatusPanelView(model: panelModel, agenda: agenda, monitor: modelMonitor,
            temperaturePreferences: temperaturePreferences,
            onCharge: { [weak self] in self?.chargeToFull() },
            onQuit: { [weak self] in self?.quitApp() }))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        temperatureChanges = temperaturePreferences.$thresholds.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateDisplay() }
        refreshBattery()
        refreshBatteryHealth()
        startMetrics()
        refreshDisk()
        refreshQuota()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.refreshQuota()
            self?.refreshDisk()
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        quotaTimer = timer
        let context = Unmanaged.passUnretained(self).toOpaque()
        powerSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue().refreshBattery()
        }, context)?.takeRetainedValue()
        if let powerSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes)
        } else {
            batteryError = "无法订阅电源变化，请重新打开应用"
            updateDisplay()
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshBattery()
            self?.startMetrics()
            self?.refreshDisk()
            self?.refreshQuota()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !popover.isShown { togglePanel() }
        return false
    }

    @objc private func togglePanel() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApplication.shared.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        if popover.isShown { popover.performClose(nil) }
    }

    func popoverWillShow(_ notification: Notification) {
        agenda.open()
        modelMonitor.open()
        refreshDisk()
        refreshBattery()
        refreshBatteryHealth()
        do {
            networkReader = try NetworkReader()
            speedText = "↑ —  ↓ —"
            speedError = "正在采样网速…"
            refreshNetwork()
            let monitor = NetworkMonitor { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let rate):
                    self.speedText = "↑ " + NetworkRate.text(rate.upload) + "  ↓ " + NetworkRate.text(rate.download)
                    self.speedError = nil
                case .failure(let error):
                    self.speedText = "↑ —  ↓ —"
                    self.speedError = error.localizedDescription
                }
                self.updateNetworkDisplay()
            }
            networkMonitor = monitor
            try monitor.start()
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refreshNetwork() }
            RunLoop.main.add(timer, forMode: .common)
            networkTimer = timer
        } catch {
            showNetworkError(error)
        }
    }

    func popoverDidShow(_ notification: Notification) {
        // A status-item popover can remain visible while another app is active;
        // transient behavior alone does not reliably dismiss it on outside clicks.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            guard let self, self.popover.isShown else { return }
            if let button = self.item.button, let window = button.window,
               window.convertToScreen(button.convert(button.bounds, to: nil)).contains(NSEvent.mouseLocation) {
                // The status button already toggles the popover in its action.
                return
            }
            self.popover.performClose(nil)
        }
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
    }

    func popoverDidClose(_ notification: Notification) {
        removeOutsideClickMonitor()
        agenda.close()
        modelMonitor.close()
        networkTimer?.invalidate()
        networkTimer = nil
        networkReader = nil
        networkMonitor?.stop()
        networkMonitor = nil
    }

    private func refreshNetwork() {
        guard let networkReader else { return }
        do {
            let sample = try networkReader.read()
            networkError = nil
            if sample != networkAddress {
                countryTask?.cancel()
                countryTask = nil
                countryRequestID = UUID()
                networkAddress = sample
                exitCountry = nil
                countryError = nil
                countryLastAttempt = nil
            }
            updateNetworkDisplay()
            if sample != nil { refreshExitCountry() }
        } catch {
            showNetworkError(error)
        }
    }

    private func updateNetworkDisplay() { updatePanel() }

    private func refreshExitCountry() {
        guard countryTask == nil,
              countryLastAttempt.map({ Date().timeIntervalSince($0) >= 300 }) ?? true else { return }
        countryLastAttempt = Date()
        exitCountry = nil
        countryError = nil
        updateNetworkDisplay()
        let requestID = UUID()
        countryRequestID = requestID
        countryTask = Task { @MainActor [weak self] in
            let result: Result<ExitCountry, Error>
            do { result = .success(try await ExitCountry.fetch()) }
            catch { result = .failure(error) }
            guard let self, self.countryRequestID == requestID else { return }
            self.countryTask = nil
            switch result {
            case .success(let country): self.exitCountry = country
            case .failure(let error): self.countryError = "公网出口查询失败：\(error.localizedDescription)"
            }
            self.updateNetworkDisplay()
        }
    }

    private func showNetworkError(_ error: Error) {
        networkError = error.localizedDescription
        speedText = "↑ —  ↓ —"
        updatePanel()
        logger.error("\(error.localizedDescription, privacy: .public)")
    }

    private func updateChargingButton() { updatePanel() }

    private func refreshChargingControls() {
        guard !chargingActionInFlight, !terminating else { return }
        let requestID = UUID()
        chargingRequestID = requestID
        guard battery != nil, battery?.mode != .battery else {
            chargingState = nil
            updateChargingButton()
            return
        }
        chargingQueue.async { [weak self] in
            let result = Result { try SmartCharging().read() }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.terminating, self.chargingRequestID == requestID else { return }
                switch result {
                case .success(let state):
                    self.chargingState = state
                    self.chargingError = nil
                case .failure(let error):
                    self.chargingState = nil
                    self.chargingError = error.localizedDescription
                }
                self.updateChargingButton()
            }
        }
    }

    @objc private func chargeToFull() {
        guard !chargingActionInFlight else { return }
        chargingActionInFlight = true
        chargingRequestID = UUID()
        updateChargingButton()
        chargingQueue.async { [weak self] in
            let result = Result { try SmartCharging().chargeToFull(battery: BatteryReader.read()) }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.terminating else { return }
                self.chargingActionInFlight = false
                self.refreshBattery()
                if case .failure(let error) = result {
                    self.popover.performClose(nil)
                    let alert = NSAlert()
                    alert.messageText = "无法请求充满电"
                    alert.informativeText = error.localizedDescription
                    alert.addButton(withTitle: "好")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    alert.runModal()
                }
            }
        }
    }

    private func refreshBattery() {
        do {
            battery = try BatteryReader.read()
            batteryError = nil
        } catch {
            battery = nil
            batteryError = error.localizedDescription
            logger.error("\(error.localizedDescription, privacy: .public)")
        }
        updateDisplay()
        refreshChargingControls()
    }

    private func refreshBatteryHealth() {
        guard !readingBatteryHealth, !terminating else { return }
        readingBatteryHealth = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try BatteryHealthReader.read() }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.terminating else { return }
                self.readingBatteryHealth = false
                self.batteryHealth = result
                self.updatePanel()
            }
        }
    }

    private func startMetrics() {
        metricsTimer?.invalidate()
        resourceReader = ResourceReader()
        do {
            temperatureReader = try TemperatureReader()
        } catch {
            temperatureReader = nil
            temperature = nil
            temperatureError = error.localizedDescription
            logger.error("\(error.localizedDescription, privacy: .public)")
        }
        refreshMetrics()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refreshMetrics() }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        metricsTimer = timer
    }

    private func refreshMetrics() {
        if temperatureReader != nil { refreshTemperature() }
        do {
            resources = try resourceReader.read()
            resourceError = nil
        } catch {
            resources = nil
            resourceError = error.localizedDescription
        }
        updateDisplay()
    }

    private func refreshTemperature() {
        do {
            temperature = try temperatureReader?.read()
            temperatureError = nil
        } catch {
            temperature = nil
            temperatureError = error.localizedDescription
            logger.error("\(error.localizedDescription, privacy: .public)")
        }
    }

    private func refreshDisk() {
        do {
            disk = try DiskReader.read()
            diskError = nil
        } catch {
            disk = nil
            diskError = error.localizedDescription
        }
        updatePanel()
    }

    private func refreshQuota() {
        guard quotaReader == nil, !terminating else { return }
        let reader = CodexQuotaReader()
        quotaReader = reader
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try reader.read() }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.terminating else { return }
                self.quotaReader = nil
                switch result {
                case .success(let quota):
                    self.quota = quota
                    self.quotaError = nil
                case .failure(let error):
                    self.quotaError = error.localizedDescription
                    self.logger.error("Codex 额度查询失败")
                }
                self.updateDisplay()
            }
        }
    }

    private func updatePanel() {
        var data = StatusPanelData()
        data.batteryPercent = battery?.percent
        switch batteryHealth {
        case .success(let percent):
            data.batteryHealthText = "\(percent)%"
        case .failure(let error):
            data.batteryHealthText = "不可用"
            data.batteryHealthHint = error.localizedDescription
        case nil:
            break
        }
        data.powerText = battery?.mode.label ?? "电源状态未知"
        data.powerHint = batteryError ?? ""
        if battery?.mode == .pluggedIn, let chargingState, chargingState.limitEnabled {
            data.powerText = "已插电 · 上限 \(chargingState.limit)%"
        }
        if (battery?.fraction ?? 0) >= 1 { data.powerText = "已充满" }
        data.showChargeButton = battery?.mode != .battery
        data.chargeEnabled = !chargingActionInFlight && battery != nil
            && battery?.mode != .battery && (battery?.fraction ?? 1) < 1
            && chargingState?.canOverride == true
        data.chargeTitle = chargingActionInFlight ? "正在请求…" : "立即充满电"
        if !data.chargeEnabled && !chargingActionInFlight {
            if (battery?.fraction ?? 0) >= 1 { data.chargeTitle = "已充满" }
            else if battery?.mode == .charging && chargingState?.canOverride == false { data.chargeTitle = "充电中" }
        }
        data.chargeHint = chargingError ?? (chargingState?.canOverride == false
            ? "当前没有需要解除的充电限制" : "临时解除充电限制，充至 100%")
        data.temperature = temperature.map { String(format: "%.0f °C", $0) } ?? "— °C"
        data.temperatureCelsius = temperature
        data.temperatureHint = temperatureError ?? "CPU 传感器最高温度"
        data.cpu = resources?.cpuPercent
        data.memory = resources?.memoryPercent
        data.memoryPressure = resources?.memoryPressure
        data.resourceHint = resourceError ?? ""
        data.memoryPressureHint = resources?.memoryPressureError ?? ""
        data.memoryDetails = resources.map {
            String(format: "%.1f / %.0f GB", Double($0.memoryUsedBytes) / 1_073_741_824,
                   Double($0.memoryTotalBytes) / 1_073_741_824)
        } ?? "— / — GB"
        data.disk = disk
        data.diskHint = diskError ?? "启动磁盘空间（APFS 共享容器），不将可清理空间算作空闲。"
        data.quotaRemaining = quota?.remainingPercent
        data.quotaMessage = quotaError == nil ? "正在读取…" : "额度不可用"
        data.quotaHint = quotaError.map { "额度读取失败：" + $0 } ?? ""
        if let quota {
            let formatter = DateFormatter()
            formatter.dateFormat = Calendar.current.isDateInToday(quota.fetchedAt) ? "HH:mm" : "MM/dd HH:mm"
            data.quotaHint = "额度读取于 " + formatter.string(from: quota.fetchedAt)
            if let quotaError {
                data.quotaHint += "\n刷新失败：" + quotaError + "\n当前显示上次成功读取的额度"
            } else if quota.isStale() {
                data.quotaHint += "\n当前显示上次成功读取的额度，等待刷新"
            }
            data.quotaDetails = quota.windows.enumerated().map { index, window in
                var resetText = ""
                if let reset = window.resetsAt {
                    let date = Date(timeIntervalSince1970: reset)
                    formatter.dateFormat = Calendar.current.isDateInToday(date) ? "今天 HH:mm" : "MM/dd HH:mm"
                    resetText = formatter.string(from: date) + " 重置"
                }
                let label = quota.windows.count > 1
                    ? String(format: "%@ · 剩余 %.0f%%", window.label, window.remainingPercent)
                    : window.label + "额度"
                return QuotaDetail(id: index, window: label, reset: resetText)
            }
        }
        data.networkAddress = networkAddress.map { "\(exitCountry?.flag ?? "🌐") \($0.address)" } ?? "🌐 未连接网络"
        data.networkSpeed = speedText
        if let exitCountry {
            data.networkHint = "公网出口：\(exitCountry.ip)（\(exitCountry.code)）"
        } else { data.networkHint = countryError ?? "正在查询公网出口所在地…" }
        if let address = networkAddress { data.networkHint = "本机地址：" + address.address + "\n" + data.networkHint }
        if let speedError { data.networkHint += "\n" + speedError }
        if let networkError {
            data.networkAddress = "🌐 网络不可用"
            data.networkHint = networkError
        }
        panelModel.data = data
    }

    private func updateDisplay() {
        guard let button = item?.button else { return }
        let size = max(18, NSStatusBar.system.thickness)
        let fraction = quota.map { $0.remainingPercent / 100 }
        button.image = RingRenderer.image(size: size, battery: battery, temperature: temperature,
                                          quotaFraction: fraction,
                                          thresholds: temperaturePreferences.thresholds, appearance: button.effectiveAppearance)
        updatePanel()
        let data = panelModel.data
        let description = ["电量 " + data.batteryText, data.powerText, "CPU " + data.temperature,
                           data.cpu.map { String(format: "CPU 使用率 %.0f%%", $0) } ?? "CPU 使用率未知",
                           data.memory.map { String(format: "内存使用率 %.0f%%", $0) } ?? "内存使用率未知",
                           data.quotaRemaining.map { String(format: "Codex 剩余 %.0f%%", $0) } ?? "Codex 额度未知",
                           data.quotaHint]
            .filter { !$0.isEmpty }.joined(separator: "\n")
        button.toolTip = description
        button.setAccessibilityLabel("MenuGauge，" + description.replacingOccurrences(of: "\n", with: "，"))
    }

    @objc private func quitApp() { NSApplication.shared.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        terminating = true
        temperatureChanges?.cancel()
        removeOutsideClickMonitor()
        quotaTimer?.invalidate()
        quotaReader?.cancel()
        modelMonitor.stop()
        metricsTimer?.invalidate()
        if let powerSource { CFRunLoopSourceInvalidate(powerSource) }
        networkTimer?.invalidate()
        networkMonitor?.stop()
        countryTask?.cancel()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }
}
