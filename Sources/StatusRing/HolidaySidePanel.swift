import AppKit
import SwiftUI

struct HolidayPanelPlacement {
    let width: CGFloat
    private let x: CGFloat
    private let top: CGFloat
    private let screen: CGRect

    init?(nextTo anchor: CGRect, on screen: CGRect) {
        let gap: CGFloat = 12
        let preferredWidth: CGFloat = 320
        let right = screen.maxX - anchor.maxX - gap
        let left = anchor.minX - screen.minX - gap
        let useRight = right >= preferredWidth || right >= left
        width = min(preferredWidth, useRight ? right : left)
        guard width >= 200 else { return nil }
        x = useRight ? anchor.maxX + gap : anchor.minX - gap - width
        top = min(anchor.maxY, screen.maxY)
        self.screen = screen
    }

    func frame(height: CGFloat) -> CGRect {
        let height = min(height, screen.height)
        return CGRect(x: x, y: max(screen.minY, top - height), width: width, height: height)
    }
}

@MainActor
final class HolidaySidePanel: NSPanel {
    private struct Layout: Equatable {
        let year: HolidayCountdown.Year
        let width: CGFloat
        let maximumHeight: CGFloat
    }

    private let onDismiss: () -> Void
    private var layout: Layout?
    private var fittedHeight: CGFloat = 0

    init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        title = "未来一年假期"
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
    }

    override var canBecomeKey: Bool { true }

    func position(nextTo anchor: NSWindow, at now: Date = Date()) -> Bool {
        guard let screen = anchor.screen?.visibleFrame,
              let placement = HolidayPanelPlacement(nextTo: anchor.frame, on: screen) else { return false }
        let layout = Layout(year: HolidayCountdown.year(at: now), width: placement.width, maximumHeight: screen.height)
        if layout != self.layout {
            let view = HolidayYearView(year: layout.year, width: layout.width, heightLimit: nil, onDismiss: onDismiss)
            let host: NSHostingController<HolidayYearView>
            if let existing = contentViewController as? NSHostingController<HolidayYearView> {
                existing.rootView = view
                host = existing
            } else {
                host = NSHostingController(rootView: view)
                host.sizingOptions = []
                contentViewController = host
            }
            let idealHeight = ceil(host.sizeThatFits(in: CGSize(width: layout.width, height: layout.maximumHeight)).height)
            fittedHeight = min(idealHeight, layout.maximumHeight)
            if idealHeight > layout.maximumHeight {
                host.rootView = HolidayYearView(year: layout.year, width: layout.width,
                                                heightLimit: fittedHeight, onDismiss: onDismiss)
            }
            self.layout = layout
        }
        let targetFrame = placement.frame(height: fittedHeight)
        if frame != targetFrame { setFrame(targetFrame, display: true) }
        return true
    }
}

private struct HolidayYearView: View {
    let year: HolidayCountdown.Year
    let width: CGFloat
    let heightLimit: CGFloat?
    let onDismiss: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16)
        Group {
            if let heightLimit {
                content { ScrollView { holidayRows } }.frame(height: heightLimit)
            } else {
                content { holidayRows }.fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: width)
        .background(Color(nsColor: .windowBackgroundColor), in: shape)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 1).allowsHitTesting(false)
        }
    }

    private func content<Rows: View>(@ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("未来一年假期").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .background(Color.primary.opacity(0.07), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("关闭假期列表")
                .help("关闭假期列表")
            }
            HStack {
                Text(year.dates).monospacedDigit()
                Spacer(minLength: 4)
                Text("中国大陆")
            }
            .font(.system(size: 11.5)).foregroundStyle(.secondary)
            Divider()
            rows()
        }
        .padding(14)
    }

    private var holidayRows: some View {
        VStack(spacing: 0) {
            if year.holidays.isEmpty {
                Text("假期安排待更新").font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ForEach(year.holidays) { holiday in
                    if holiday.id != year.holidays.first?.id { Divider() }
                    holidayRow(holiday)
                }
            }
        }
    }

    private func holidayRow(_ holiday: HolidayCountdown) -> some View {
        let isNext = holiday.id == year.holidays.first?.id
        return HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                Text(holiday.name).font(.system(size: 13, weight: .semibold))
                Text("\(holiday.dates) · 休 \(holiday.daysOff) 天")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 2)
            if holiday.daysUntilStart == 0 {
                Text("假期中").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.accentColor)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(holiday.daysUntilStart)").font(.system(size: 15, weight: .semibold))
                        .monospacedDigit().foregroundStyle(isNext ? Color.accentColor : Color.primary)
                    Text("天后").font(.system(size: 11.5))
                        .foregroundStyle(isNext ? Color.accentColor : Color.secondary)
                }
                .fixedSize()
            }
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }
}
