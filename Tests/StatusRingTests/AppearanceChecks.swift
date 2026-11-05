import AppKit

enum AppearanceChecks {
    static func run() throws {
        let domain = "local.dya.MenuGauge.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = TemperaturePreferences(defaults: defaults)
        assert(preferences.thresholds == .standard)
        assert(preferences.thresholds.level(for: 69.4) == .low)
        assert(preferences.thresholds.level(for: 69.6) == .medium)
        assert(preferences.thresholds.level(for: 84) == .medium)
        assert(preferences.thresholds.level(for: 85) == .high)
        preferences.setWarning(75)
        preferences.setCritical(90)
        assert(TemperaturePreferences(defaults: defaults).thresholds == TemperatureThresholds(warning: 75, critical: 90))
        preferences.setWarning(95)
        assert(preferences.error != nil && preferences.thresholds.warning == 75)
        assert(TemperaturePreferences(defaults: defaults).thresholds.warning == 75)
        preferences.setWarning(70)
        assert(preferences.error == nil)
        assert(PressureLevel.remainingQuota(21) == .low)
        assert(PressureLevel.remainingQuota(20.4) == .medium)
        assert(PressureLevel.remainingQuota(5.4) == .high)

        let dark = NSAppearance(named: .darkAqua)!
        let charging = raster(battery: BatteryReading(fraction: 1, mode: .charging), temperature: 75, appearance: dark)
        let plugged = raster(battery: BatteryReading(fraction: 1, mode: .pluggedIn), temperature: 75, appearance: dark)
        assert(region(charging, 12..<102) == region(plugged, 12..<102), "Power state must not change temperature color or add a charging symbol")
        assert(region(charging, 0..<11) != region(plugged, 0..<11), "Power states must have different battery colors")
        let coolerRule = raster(battery: BatteryReading(fraction: 1, mode: .pluggedIn), temperature: 75,
                                thresholds: TemperatureThresholds(warning: 80, critical: 90), appearance: dark)
        assert(region(plugged, 12..<102) != region(coolerRule, 12..<102), "Changing the warning threshold must recolor the same temperature")
        assert(region(plugged, 0..<11) == region(coolerRule, 0..<11))
        assert(region(plugged, 104..<114) == region(coolerRule, 104..<114))
        let light = raster(battery: BatteryReading(fraction: 1, mode: .pluggedIn), temperature: 75,
                           appearance: NSAppearance(named: .aqua)!)
        assert(region(light, 12..<102) != region(plugged, 12..<102), "Temperature palette must adapt to the menu bar appearance")
        try contactSheet().write(to: URL(fileURLWithPath: ".build/menu-bar-appearance-check.png"))
        print("Temperature thresholds, preference persistence and independent native icon colors passed")
    }

    private static func raster(battery: BatteryReading, temperature: Double,
                               thresholds: TemperatureThresholds = .standard, appearance: NSAppearance) -> NSBitmapImageRep {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 114, pixelsHigh: 66,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current!.cgContext.clear(NSRect(x: 0, y: 0, width: 114, height: 66))
        RingRenderer.image(size: 22, battery: battery, temperature: temperature, quotaFraction: 0.16,
                           thresholds: thresholds, appearance: appearance)
            .draw(in: NSRect(x: 0, y: 0, width: 114, height: 66))
        return bitmap
    }

    private static func region(_ bitmap: NSBitmapImageRep, _ columns: Range<Int>) -> Data {
        var pixels = Data()
        for y in 0..<bitmap.pixelsHigh {
            let start = bitmap.bitmapData! + y * bitmap.bytesPerRow + columns.lowerBound * 4
            pixels.append(start, count: columns.count * 4)
        }
        return pixels
    }

    private static func contactSheet() throws -> Data {
        let canvas = NSImage(size: NSSize(width: 660, height: 360), flipped: false) { _ in
            let samples: [(String, BatteryReading)] = [
                ("充电中", BatteryReading(fraction: 0.63, mode: .charging)),
                ("插电未充电", BatteryReading(fraction: 1, mode: .pluggedIn)),
                ("未插电", BatteryReading(fraction: 0.68, mode: .battery)),
                ("低电量", BatteryReading(fraction: 0.12, mode: .battery))]
            for (row, name) in [NSAppearance.Name.darkAqua, .aqua].enumerated() {
                let appearance = NSAppearance(named: name)!
                (row == 0 ? NSColor(srgbRed: 0.16, green: 0.43, blue: 0.61, alpha: 1) : NSColor(white: 0.94, alpha: 1)).setFill()
                NSRect(x: 0, y: CGFloat(1 - row) * 180, width: 660, height: 180).fill()
                for (column, sample) in samples.enumerated() {
                    let x = 24 + CGFloat(column) * 164, y = CGFloat(1 - row) * 180
                    (sample.0 as NSString).draw(at: NSPoint(x: x, y: y + 150), withAttributes: [
                        .font: NSFont.systemFont(ofSize: 12), .foregroundColor: row == 0 ? NSColor.white : NSColor.black])
                    for (index, temperature) in [49.0, 75.0, 90.0].enumerated() {
                        RingRenderer.image(size: 22, battery: sample.1, temperature: temperature, quotaFraction: 0.16,
                                           thresholds: .standard, appearance: appearance)
                            .draw(in: NSRect(x: x + CGFloat(index) * 48, y: y + 102, width: 38, height: 22))
                    }
                    RingRenderer.image(size: 22, battery: sample.1, temperature: 105, quotaFraction: 0.04,
                                       thresholds: .standard, appearance: appearance)
                        .draw(in: NSRect(x: x, y: y + 35, width: 76, height: 44))
                }
            }
            return true
        }
        let bitmap = NSBitmapImageRep(data: canvas.tiffRepresentation!)!
        return bitmap.representation(using: .png, properties: [:])!
    }
}
