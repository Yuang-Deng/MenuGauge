import AppKit

enum RingRenderer {
    static func image(size: CGFloat, battery: BatteryReading?, temperature: Double?,
                      quotaFraction: Double? = nil, quotaStale: Bool = false,
                      thresholds: TemperatureThresholds, appearance: NSAppearance) -> NSImage {
        let scale = size / 22
        let palette = Palette(appearance: appearance)
        let batteryColor: NSColor
        if battery?.mode == .charging { batteryColor = palette.green }
        else if let battery, battery.percent <= 20 { batteryColor = palette.red }
        else if battery?.mode == .pluggedIn { batteryColor = palette.blue }
        else { batteryColor = palette.neutral }
        let temperatureColor = temperature.map { palette.color(thresholds.level(for: $0), normal: palette.neutral) } ?? palette.neutral
        let quotaColor = quotaStale ? palette.neutral.withAlphaComponent(0.5)
            : quotaFraction.map { palette.color(.remainingQuota($0 * 100), normal: palette.green) } ?? palette.neutral
        let image = NSImage(size: NSSize(width: 38 * scale, height: size), flipped: false) { _ in
            let context = NSGraphicsContext.current!.cgContext
            context.saveGState()
            defer { context.restoreGState() }
            context.scaleBy(x: scale, y: scale)
            func bar(x: CGFloat, fraction: Double?, color: NSColor) {
                let box = NSRect(x: x, y: 1, width: 3.5, height: 20)
                guard let fraction else {
                    palette.neutral.withAlphaComponent(0.65).setFill()
                    for y in stride(from: 2.0, through: 18.0, by: 4) {
                        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: 3.5, height: 2),
                                     xRadius: 1, yRadius: 1).fill()
                    }
                    return
                }
                color.withAlphaComponent(0.24).setFill()
                NSBezierPath(roundedRect: box, xRadius: 1.75, yRadius: 1.75).fill()
                if fraction > 0 {
                    let fill = NSRect(x: x, y: 1, width: 3.5, height: 20 * fraction)
                    color.setFill()
                    NSBezierPath(roundedRect: fill, xRadius: 1.75, yRadius: min(1.75, fill.height / 2)).fill()
                }
            }
            bar(x: 0, fraction: battery?.fraction, color: batteryColor)
            bar(x: 34.5, fraction: quotaFraction, color: quotaColor)
            let text = temperature.map(TemperatureText.compact) ?? "—"
            var fontSize: CGFloat = text.count > 3 ? 15 : 18
            var font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold)
            let width = (text as NSString).size(withAttributes: [.font: font]).width
            if width > 29 {
                fontSize *= 29 / width
                font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold)
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: temperatureColor
            ]
            let textSize = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(at: NSPoint(x: (38 - textSize.width) / 2,
                                               y: (22 - textSize.height) / 2), withAttributes: attributes)
            return true
        }
        image.isTemplate = false
        return image
    }

    private struct Palette {
        let neutral: NSColor
        let green: NSColor
        let blue: NSColor
        let yellow: NSColor
        let red: NSColor

        init(appearance: NSAppearance) {
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            neutral = Self.color(dark ? 0xffffff : 0x1b2838)
            green = Self.color(dark ? 0x9bf8b2 : 0x167c38)
            blue = Self.color(dark ? 0xb3e9ff : 0x0767be)
            yellow = Self.color(dark ? 0xffdf85 : 0x996000)
            red = Self.color(dark ? 0xffb8b0 : 0xca302a)
        }

        func color(_ level: PressureLevel, normal: NSColor) -> NSColor {
            switch level { case .low: return normal; case .medium: return yellow; case .high: return red }
        }

        private static func color(_ rgb: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                    green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
        }
    }
}
