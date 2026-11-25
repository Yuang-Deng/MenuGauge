import AppKit
import Combine
import CoreGraphics
import SwiftUI

enum EyeReminderInterval: Int, CaseIterable {
    case twenty = 20
    case thirty = 30
    case fortyFive = 45

    var duration: TimeInterval { TimeInterval(rawValue * 60) }
}

struct EyeReminderCycle {
    private enum Phase {
        case idle
        case counting(until: TimeInterval)
        case awaitingResponse
    }

    private var phase = Phase.idle

    mutating func reset() { phase = .idle }

    mutating func tick(at now: TimeInterval, interval: EyeReminderInterval) -> Bool {
        switch phase {
        case .idle:
            phase = .counting(until: now + interval.duration)
        case .counting(let deadline) where deadline <= now:
            phase = .awaitingResponse
            return true
        case .counting, .awaitingResponse:
            break
        }
        return false
    }

    mutating func snooze(at now: TimeInterval) { phase = .counting(until: now + 5 * 60) }

    func remainingMinutes(at now: TimeInterval) -> Int? {
        guard case .counting(let deadline) = phase else { return nil }
        return max(1, Int(ceil((deadline - now) / 60)))
    }
}

@MainActor
final class EyeReminder: ObservableObject {
    enum RestState: Equatable {
        case ready, counting(Int), complete
    }

    enum State: Equatable {
        case off, waitingForScreen, counting(Int), reminding(RestState)
    }

    static let restSeconds = 20
    private static let enabledKey = "eyeReminder.enabled"
    private static let intervalKey = "eyeReminder.interval"

    @Published private(set) var enabled: Bool
    @Published private(set) var interval: EyeReminderInterval
    @Published private(set) var state: State = .off

    private let defaults: UserDefaults
    private var cycle = EyeReminderCycle()
    private var activityChanges: AnyCancellable?
    private var panel: EyeReminderPanel?
    private var restDeadline: TimeInterval?
    private var restTimer: Timer?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: Self.enabledKey)
        interval = EyeReminderInterval(rawValue: defaults.integer(forKey: Self.intervalKey)) ?? .twenty
    }

    func start() {
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
        resetForScreenChange()
        tick()
    }

    func stop() {
        activityChanges?.cancel()
        activityChanges = nil
        resetForScreenChange()
    }

    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        defaults.set(value, forKey: Self.enabledKey)
        resetForScreenChange()
        tick()
    }

    func setInterval(_ value: EyeReminderInterval) {
        guard interval != value else { return }
        interval = value
        defaults.set(value.rawValue, forKey: Self.intervalKey)
        if panel == nil {
            cycle.reset()
            tick()
        }
    }

    func resetForScreenChange() {
        cycle.reset()
        hidePanel()
        let next: State = enabled ? .waitingForScreen : .off
        if state != next { state = next }
    }

    func tick() {
        guard enabled else { return }
        guard let screen = Self.activeScreen() else {
            if state != .waitingForScreen { resetForScreenChange() }
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if let restDeadline {
            let remaining = Int(ceil(restDeadline - now))
            if remaining <= 0 {
                stopRestTimer()
                updateRest(.complete)
            } else {
                updateRest(.counting(remaining))
            }
            return
        }
        if cycle.tick(at: now, interval: interval) {
            let panel = EyeReminderPanel(
                onStart: { [weak self] in self?.startRest() },
                onClose: { [weak self] in self?.dismiss(snooze: false) },
                onSnooze: { [weak self] in self?.dismiss(snooze: true) }
            )
            self.panel = panel
            state = .reminding(.ready)
            panel.show(on: screen)
        } else if let minutes = cycle.remainingMinutes(at: now), state != .counting(minutes) {
            state = .counting(minutes)
        }
    }

    private func startRest() {
        guard state == .reminding(.ready) else { return }
        restDeadline = ProcessInfo.processInfo.systemUptime + Double(Self.restSeconds)
        updateRest(.counting(Self.restSeconds))
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        restTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updateRest(_ rest: RestState) {
        let next = State.reminding(rest)
        guard state != next else { return }
        state = next
        panel?.update(rest)
    }

    private func stopRestTimer() {
        restTimer?.invalidate()
        restTimer = nil
        restDeadline = nil
    }

    private func dismiss(snooze: Bool) {
        hidePanel()
        if snooze {
            cycle.snooze(at: ProcessInfo.processInfo.systemUptime)
        } else {
            cycle.reset()
        }
        tick()
    }

    private func hidePanel() {
        stopRestTimer()
        panel?.orderOut(nil)
        panel = nil
    }

    private static func activeScreen() -> NSScreen? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session[kCGSessionOnConsoleKey] as? Bool == true,
              session[kCGSessionLoginDoneKey] as? Bool == true,
              session["CGSSessionScreenIsLocked"] as? Bool != true else { return nil }
        let screens = NSScreen.screens.filter { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return CGDisplayIsAsleep(number.uint32Value) == 0
        }
        let pointer = NSEvent.mouseLocation
        return screens.first { $0.frame.contains(pointer) } ?? screens.first
    }
}

@MainActor
private final class EyeReminderPanel: NSPanel {
    private let host: EyeReminderHostingView

    init(onStart: @escaping () -> Void, onClose: @escaping () -> Void, onSnooze: @escaping () -> Void) {
        host = EyeReminderHostingView(rootView: EyeReminderCard(
            icon: NSApplication.shared.applicationIconImage,
            onStart: onStart, onClose: onClose, onSnooze: onSnooze
        ))
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        title = "MenuGauge 用眼提醒"
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        host.sizingOptions = [.intrinsicContentSize]
        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(on screen: NSScreen) {
        let frame = screen.visibleFrame.insetBy(dx: 14, dy: 14)
        host.rootView.width = min(host.rootView.width, frame.width)
        fit(topRight: CGPoint(x: frame.maxX, y: frame.maxY))
        orderFrontRegardless()
    }

    func update(_ rest: EyeReminder.RestState) {
        host.rootView.rest = rest
        fit(topRight: CGPoint(x: frame.maxX, y: frame.maxY))
    }

    private func fit(topRight: CGPoint) {
        let width = host.rootView.width
        let height = ceil(host.fittingSize.height)
        let rect = NSRect(x: topRight.x - width, y: topRight.y - height, width: width, height: height)
        if frame != rect { setFrame(rect, display: true) }
    }
}

private final class EyeReminderHostingView: NSHostingView<EyeReminderCard> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct EyeReminderCard: View {
    let icon: NSImage
    let onStart: () -> Void
    let onClose: () -> Void
    let onSnooze: () -> Void
    var rest: EyeReminder.RestState = .ready
    var width: CGFloat = 320

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(heading).font(.system(size: 14, weight: .semibold))
                    if let detail {
                        Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("关闭用眼提醒")
                .help("关闭用眼提醒")
            }
            switch rest {
            case .ready:
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("5 分钟后提醒", action: onSnooze).buttonStyle(.bordered)
                    primaryButton("开始休息", action: onStart)
                }
                .controlSize(.small)
            case .counting(let seconds):
                VStack(spacing: 5) {
                    Text(String(format: "00:%02d", seconds))
                        .font(.system(size: 30, weight: .semibold))
                        .monospacedDigit()
                        .accessibilityLabel("剩余 \(seconds) 秒")
                    UsageBar(fraction: Double(seconds) / Double(EyeReminder.restSeconds),
                             tint: Color.accentColor, label: "休息剩余时间", height: 4)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity)
            case .complete:
                HStack {
                    Spacer(minLength: 0)
                    primaryButton("继续工作", action: onClose)
                }
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor), in: shape)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 1).allowsHitTesting(false)
        }
    }

    private func primaryButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(nsColor: .alternateSelectedControlTextColor))
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private var heading: String {
        switch rest {
        case .ready: return "眼睛休息一下"
        case .counting: return "看向远处"
        case .complete: return "休息完成"
        }
    }

    private var detail: String? {
        switch rest {
        case .ready: return "看向远处 \(EyeReminder.restSeconds) 秒"
        case .counting: return nil
        case .complete: return "\(EyeReminder.restSeconds) 秒到了"
        }
    }
}
