import AppKit
import Combine
import CoreGraphics
import UserNotifications

enum EyeReminderInterval: Int, CaseIterable {
    case twenty = 20
    case thirty = 30
    case fortyFive = 45

    var duration: TimeInterval { TimeInterval(rawValue * 60) }
}

struct EyeReminderCycle {
    private var deadline: TimeInterval?

    mutating func reset() { deadline = nil }

    mutating func tick(at now: TimeInterval, interval: EyeReminderInterval) -> Bool {
        if let deadline, deadline > now { return false }
        let isDue = deadline != nil
        deadline = now + interval.duration
        return isDue
    }

    mutating func snooze(at now: TimeInterval) { deadline = now + 5 * 60 }

    func remainingMinutes(at now: TimeInterval) -> Int? {
        deadline.map { max(1, Int(ceil(($0 - now) / 60))) }
    }
}

@MainActor
final class EyeReminder: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    enum State: Equatable {
        case off, checking, awaitingPermission, needsNotifications, waitingForScreen, counting(Int), failed(String)

        var canCount: Bool {
            switch self {
            case .waitingForScreen, .counting: return true
            default: return false
            }
        }
    }

    private enum PermissionAction { case check, enable, settings }

    private static let enabledKey = "eyeReminder.enabled"
    private static let intervalKey = "eyeReminder.interval"
    private static let categoryID = "eyeReminder.break"
    private static let snoozeID = "eyeReminder.snooze"

    @Published private(set) var enabled: Bool
    @Published private(set) var interval: EyeReminderInterval
    @Published private(set) var state: State = .off

    private let defaults: UserDefaults
    private let center = UNUserNotificationCenter.current()
    private var cycle = EyeReminderCycle()
    private var activityChanges: AnyCancellable?
    private var permissionTask: Task<Void, Never>?
    private var noticeID: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: Self.enabledKey)
        interval = EyeReminderInterval(rawValue: defaults.integer(forKey: Self.intervalKey)) ?? .twenty
        super.init()
    }

    func start() {
        center.delegate = self
        let snooze = UNNotificationAction(identifier: Self.snoozeID, title: "5 分钟后提醒", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.categoryID, actions: [snooze], intentIdentifiers: [], options: [])
        ])
        let workspace = NSWorkspace.shared.notificationCenter
        let events: [Notification.Name] = [
            NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification
        ]
        let distributed = DistributedNotificationCenter.default()
        let lockEvents = ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"]
        activityChanges = Publishers.MergeMany(
            events.map { workspace.publisher(for: $0) } +
                lockEvents.map { distributed.publisher(for: Notification.Name($0)) }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in self?.resetForScreenChange() }
        refreshPermission()
    }

    func stop() {
        activityChanges?.cancel()
        permissionTask?.cancel()
        clearNotice()
    }

    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        defaults.set(value, forKey: Self.enabledKey)
        resetForScreenChange()
        if value {
            checkPermission(.enable)
        } else {
            permissionTask?.cancel()
            permissionTask = nil
            state = .off
        }
    }

    func setInterval(_ value: EyeReminderInterval) {
        guard interval != value else { return }
        interval = value
        defaults.set(value.rawValue, forKey: Self.intervalKey)
        resetForScreenChange()
        tick()
    }

    func refreshPermission() { checkPermission(.check) }
    func enableNotifications() { checkPermission(.settings) }

    func resetForScreenChange() {
        cycle.reset()
        clearNotice()
        if state.canCount { state = .waitingForScreen }
    }

    func tick() {
        guard state.canCount else { return }
        guard Self.isScreenActive() else {
            if state != .waitingForScreen { resetForScreenChange() }
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let isDue = cycle.tick(at: now, interval: interval)
        if let minutes = cycle.remainingMinutes(at: now), state != .counting(minutes) {
            state = .counting(minutes)
        }
        if isDue { deliverNotice() }
    }

    private static func isScreenActive() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session[kCGSessionOnConsoleKey] as? Bool == true,
              session[kCGSessionLoginDoneKey] as? Bool == true,
              session["CGSSessionScreenIsLocked"] as? Bool != true else { return false }
        return NSScreen.screens.contains { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsAsleep(number.uint32Value) == 0
        }
    }

    private static func alertsEnabled(_ settings: UNNotificationSettings) -> Bool {
        settings.authorizationStatus == .authorized && settings.alertSetting == .enabled && settings.alertStyle != .none
    }

    private func checkPermission(_ action: PermissionAction) {
        guard enabled, permissionTask == nil else { return }
        if !state.canCount { state = .checking }
        permissionTask = Task { [weak self, center] in
            var settings = await center.notificationSettings()
            guard let self, !Task.isCancelled else { return }
            defer { if !Task.isCancelled { self.permissionTask = nil } }
            let shouldPrompt = action != .check && settings.authorizationStatus == .notDetermined
            if shouldPrompt {
                self.state = .awaitingPermission
                do {
                    _ = try await center.requestAuthorization(options: [.alert])
                    settings = await center.notificationSettings()
                } catch {
                    if !Task.isCancelled { self.state = .failed(error.localizedDescription) }
                    return
                }
            }
            guard !Task.isCancelled else { return }
            if Self.alertsEnabled(settings) {
                if !self.state.canCount { self.state = .waitingForScreen }
                self.tick()
            } else {
                self.resetForScreenChange()
                self.state = .needsNotifications
                if action == .settings, !shouldPrompt,
                   let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"),
                   !NSWorkspace.shared.open(url) {
                    self.state = .failed("无法打开系统通知设置")
                }
            }
        }
    }

    private func deliverNotice() {
        clearNotice()
        let id = UUID().uuidString
        noticeID = id
        Task { [weak self, center] in
            let settings = await center.notificationSettings()
            guard let self, self.noticeID == id else { return }
            guard Self.isScreenActive() else {
                self.resetForScreenChange()
                return
            }
            guard Self.alertsEnabled(settings) else {
                self.resetForScreenChange()
                self.state = .needsNotifications
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "眼睛休息一下"
            content.body = "看向远处 20 秒。"
            content.categoryIdentifier = Self.categoryID
            do {
                try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
                if self.noticeID != id { self.removeNotice(id) }
            } catch {
                guard self.noticeID == id else { return }
                self.resetForScreenChange()
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    private func clearNotice() {
        guard let id = noticeID else { return }
        noticeID = nil
        removeNotice(id)
    }

    private func removeNotice(_ id: String) {
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                             willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        await presentationOptions(for: notification.request.identifier)
    }

    private func presentationOptions(for id: String) -> UNNotificationPresentationOptions {
        noticeID == id && state.canCount && Self.isScreenActive() ? [.banner, .list] : []
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let id = response.notification.request.identifier
        await handleAction(action, notice: id)
    }

    private func handleAction(_ action: String, notice id: String) {
        guard action == Self.snoozeID, noticeID == id, state.canCount, Self.isScreenActive() else { return }
        clearNotice()
        cycle.snooze(at: ProcessInfo.processInfo.systemUptime)
        tick()
    }
}
