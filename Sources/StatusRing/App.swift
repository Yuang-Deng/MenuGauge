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
                    let action = charging.action(for: battery)
                    result["canChargeToFull"] = action == .chargeToFull
                    if case .restoreLimit(let limit)? = action { result["restorableChargeLimitPercent"] = limit }
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
    @MainActor private lazy var eyeReminder = EyeReminder()
    private let popover = NSPopover()
    private var outsideClickMonitor: Any?
    private var panelEventMonitor: Any?
    private var holidayPanel: HolidaySidePanel?
    private var holidayPanelUpdates: AnyCancellable?
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
    private var pendingChargeAction: ChargingAction?
    private var chargingNotice: (id: UUID, text: String)?
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
        // The status popover and its holiday panel share an outside-click boundary.
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.delegate = self
        let host = NSHostingController(rootView: StatusPanelView(model: panelModel, agenda: agenda, eyeReminder: eyeReminder,
            temperaturePreferences: temperaturePreferences,
            onCharge: { [weak self] action in self?.performChargeAction(action) },
            onToggleHolidays: { [weak self] in self?.toggleHolidayPanel() },
            onQuit: { [weak self] in self?.quitApp() }))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        temperatureChanges = temperaturePreferences.$thresholds.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateDisplay() }
        eyeReminder.start()
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
            MainActor.assumeIsolated {
                self?.eyeReminder.resetForScreenChange()
                self?.refreshBattery()
                self?.startMetrics()
                self?.refreshDisk()
                self?.refreshQuota()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !popover.isShown { togglePanel() }
        return false
    }

    @MainActor
    @objc private func togglePanel() {
        guard let button = item.button else { return }
        if popover.isShown {
            closePanel()
        } else {
            NSApplication.shared.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        closePanel()
    }

    @MainActor
    private func closePanel() {
        guard popover.isShown else { return }
        // AppKit won't performClose while a child window is attached.
        closeHolidayPanel()
        popover.performClose(nil)
    }

    @MainActor
    private func toggleHolidayPanel() {
        if holidayPanel != nil {
            closeHolidayPanel(restoreFocus: true)
            return
        }
        guard popover.isShown, let anchor = popover.contentViewController?.view.window else { return }
        let panel = HolidaySidePanel { [weak self] in self?.closeHolidayPanel(restoreFocus: true) }
        guard panel.position(nextTo: anchor) else {
            NSSound.beep()
            return
        }
        holidayPanel = panel
        anchor.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panelModel.showingHolidays = true
        holidayPanelUpdates = panelModel.$data.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self, weak panel, weak anchor] _ in
                guard let panel, let anchor else { return }
                if !panel.position(nextTo: anchor) { self?.closeHolidayPanel(restoreFocus: true) }
            }
    }

    @MainActor
    private func closeHolidayPanel(restoreFocus: Bool = false) {
        guard let panel = holidayPanel else { return }
        let anchor = panel.parent
        let wasKey = panel.isKeyWindow
        holidayPanelUpdates?.cancel()
        holidayPanelUpdates = nil
        holidayPanel = nil
        panelModel.showingHolidays = false
        panel.orderOut(nil)
        if restoreFocus && wasKey { anchor?.makeKey() }
    }

    func popoverWillShow(_ notification: Notification) {
        agenda.open()
        eyeReminder.refreshPermission()
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
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            self?.dismissIfOutside(at: NSEvent.mouseLocation)
        }
        panelEventMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks.union(.keyDown)) { [weak self] event in
            guard let self, self.popover.isShown else { return event }
            if event.type == .keyDown {
                guard event.keyCode == 53 else { return event }
                if self.holidayPanel != nil { self.closeHolidayPanel(restoreFocus: true) }
                else { self.closePanel() }
                return nil
            }
            let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
            self.dismissIfOutside(at: point)
            return event
        }
    }

    @MainActor
    private func dismissIfOutside(at point: NSPoint) {
        guard popover.isShown,
              popover.contentViewController?.view.window?.frame.contains(point) != true,
              holidayPanel?.frame.contains(point) != true else { return }
        if let button = item.button, let window = button.window,
           window.convertToScreen(button.convert(button.bounds, to: nil)).contains(point) { return }
        closePanel()
    }

    private func removePanelEventMonitors() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let panelEventMonitor { NSEvent.removeMonitor(panelEventMonitor) }
        outsideClickMonitor = nil
        panelEventMonitor = nil
    }

    func popoverWillClose(_ notification: Notification) {
        closeHolidayPanel()
    }

    func popoverDidClose(_ notification: Notification) {
        removePanelEventMonitors()
        agenda.close()
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

    private func refreshChargingControls() {
        guard pendingChargeAction == nil, !terminating else { return }
        let requestID = UUID()
        chargingRequestID = requestID
        guard battery != nil, battery?.mode != .battery else {
            chargingState = nil
            updatePanel()
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
                self.updatePanel()
            }
        }
    }

    private func performChargeAction(_ action: ChargingAction) {
        guard pendingChargeAction == nil, !terminating else { return }
        let requestID = UUID()
        pendingChargeAction = action
        chargingNotice = nil
        chargingRequestID = requestID
        updatePanel()
        chargingQueue.async { [weak self] in
            let result = Result { () -> ChargingControlState in
                let controller = try SmartCharging()
                let battery = try BatteryReader.read()
                switch action {
                case .chargeToFull:
                    try controller.chargeToFull(battery: battery)
                    return try controller.read()
                case .restoreLimit(let limit):
                    return try controller.restoreChargeLimit(limit, battery: battery)
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.terminating else { return }
                self.pendingChargeAction = nil
                if case .success(let state) = result {
                    self.chargingState = state
                    self.chargingError = nil
                    let message: String
                    switch action {
                    case .chargeToFull: message = "已请求充满电"
                    case .restoreLimit(let limit): message = "已恢复 \(limit)% 充电上限"
                    }
                    self.chargingNotice = (requestID, message)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                        guard let self, self.chargingNotice?.id == requestID else { return }
                        self.chargingNotice = nil
                        self.updatePanel()
                    }
                }
                self.refreshBattery()
                if case .failure(let error) = result {
                    self.closePanel()
                    let alert = NSAlert()
                    alert.messageText = "无法\(action.title)"
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

    @MainActor
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
        let refresh: @MainActor @Sendable () -> Void = { [weak self] in self?.refreshMetrics() }
        let timer = Timer(timeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { refresh() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        metricsTimer = timer
    }

    @MainActor
    private func refreshMetrics() {
        eyeReminder.tick()
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
        if let battery, battery.mode != .battery {
            data.showChargeButton = true
            if battery.fraction >= 1 { data.powerText = "已充满" }
            if let chargingState, chargingState.restorableLimit != nil {
                data.powerText += " · 临时充满"
            } else if let chargingState, chargingState.limitEnabled && chargingState.limit < 100 {
                let power = battery.mode == .charging ? "正在充电" : "已插电"
                data.powerText = "\(power) · 上限 \(chargingState.limit)%"
            }
            if let pendingChargeAction {
                data.chargeTitle = pendingChargeAction.pendingTitle
                data.chargeHint = pendingChargeAction.pendingTitle
            } else if let action = chargingState?.action(for: battery) {
                data.chargeAction = action
                data.chargeTitle = action.title
                data.chargeHint = action.help
            } else {
                if battery.fraction >= 1 { data.chargeTitle = "已充满" }
                else if battery.mode == .charging { data.chargeTitle = "充电中" }
                data.chargeHint = chargingError ?? (chargingState == nil ? "正在读取充电状态…" : "当前没有需要解除的充电限制")
            }
            data.chargeNotice = chargingNotice?.text
        }
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
            let now = Date()
            let formatter = DateFormatter()
            formatter.dateFormat = Calendar.current.isDateInToday(quota.fetchedAt) ? "HH:mm" : "MM/dd HH:mm"
            data.quotaHint = "额度读取于 " + formatter.string(from: quota.fetchedAt)
            if let quotaError {
                data.quotaHint += "\n刷新失败：" + quotaError + "\n当前显示上次成功读取的额度"
            } else if quota.isStale(at: now) {
                data.quotaHint += "\n当前显示上次成功读取的额度，等待刷新"
            }
            data.quotaDetails = quota.windows.enumerated().map { index, window in
                let label = quota.windows.count > 1
                    ? String(format: "%@ · 剩余 %.0f%%", window.label, window.remainingPercent)
                    : window.label + "额度"
                return QuotaDetail(id: index, window: label, reset: window.resetCountdown(at: now))
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
        removePanelEventMonitors()
        closeHolidayPanel()
        quotaTimer?.invalidate()
        quotaReader?.cancel()
        metricsTimer?.invalidate()
        eyeReminder.stop()
        if let powerSource { CFRunLoopSourceInvalidate(powerSource) }
        networkTimer?.invalidate()
        networkMonitor?.stop()
        countryTask?.cancel()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }
}
