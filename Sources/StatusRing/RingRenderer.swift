import AppKit

enum RingRenderer {
    static func image(size: CGFloat, battery: BatteryReading?, temperature: Double?,
                      quotaFraction: Double? = nil, quotaStale: Bool = false) -> NSImage {
        let scale = size / 22
        let image = NSImage(size: NSSize(width: 38 * scale, height: size), flipped: false) { _ in
            let context = NSGraphicsContext.current!.cgContext
            context.saveGState()
            defer { context.restoreGState() }
            context.scaleBy(x: scale, y: scale)
            func bar(x: CGFloat, fraction: Double?, stale: Bool = false) {
                let box = NSRect(x: x, y: 1, width: 3.5, height: 20)
                guard let fraction else {
                    NSColor.white.withAlphaComponent(0.65).setFill()
                    for y in stride(from: 2.0, through: 18.0, by: 4) {
                        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: 3.5, height: 2),
                                     xRadius: 1, yRadius: 1).fill()
                    }
                    return
                }
                NSColor.white.withAlphaComponent(0.24).setFill()
                NSBezierPath(roundedRect: box, xRadius: 1.75, yRadius: 1.75).fill()
                if fraction > 0 {
                    let fill = NSRect(x: x, y: 1, width: 3.5, height: 20 * fraction)
                    NSColor.white.withAlphaComponent(stale ? 0.5 : 1).setFill()
                    NSBezierPath(roundedRect: fill, xRadius: 1.75, yRadius: min(1.75, fill.height / 2)).fill()
                }
            }
            bar(x: 0, fraction: battery?.fraction)
            bar(x: 34.5, fraction: quotaFraction, stale: quotaStale)
            let text = temperature.map(TemperatureText.compact) ?? "—"
            let unplugged = battery?.mode == .battery
            var fontSize: CGFloat = unplugged ? (text.count > 3 ? 15 : 18) : (text.count > 3 ? 12 : 15)
            var font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold)
            let width = (text as NSString).size(withAttributes: [.font: font]).width
            if width > 29 {
                fontSize *= 29 / width
                font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold)
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.white
            ]
            let textSize = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(at: NSPoint(x: (38 - textSize.width) / 2,
                                               y: unplugged ? (22 - textSize.height) / 2 : 25 - textSize.height), withAttributes: attributes)
            if let name = battery?.mode.symbol {
                drawSymbol(name, in: NSRect(x: 12, y: 0, width: 14, height: 9))
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func drawSymbol(_ name: String, in box: NSRect) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 64, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)!
            .withSymbolConfiguration(configuration)!
        let scale = min(box.width / symbol.size.width, box.height / symbol.size.height)
        let size = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
        symbol.draw(in: NSRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2,
                              width: size.width, height: size.height))
    }
}
