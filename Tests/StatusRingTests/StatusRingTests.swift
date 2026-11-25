import Foundation

final class FakeChargingClient: NSObject, PowerUICharging {
    var limited = true
    var optimized = false
    var allowed = false
    var queryFails = false
    var accepts = true
    var temporarilyDisabled = false
    var appliesRestoration = true
    var limitCalls = 0
    var optimizedCalls = 0
    var restoreCalls = 0
    func optimizedState(_ engaged: UnsafeMutablePointer<ObjCBool>, chargeLimit: UnsafeMutablePointer<UInt>,
                        chargingOverrideAllowed: UnsafeMutablePointer<ObjCBool>, withError: NSErrorPointer) -> Bool {
        engaged.pointee = ObjCBool(optimized)
        chargeLimit.pointee = 80
        chargingOverrideAllowed.pointee = ObjCBool(allowed)
        return !queryFails
    }
    func limitEnabled(_ error: NSErrorPointer) -> UInt {
        guard limited else { return 0 }
        return temporarilyDisabled ? 3 : 1
    }
    func limit(_ error: NSErrorPointer) -> UInt8 { temporarilyDisabled ? 100 : 80 }
    func overrideOptimizedCharging(_ error: NSErrorPointer) -> Bool { optimizedCalls += 1; return accepts }
    func overrideChargeLimit(_ error: NSErrorPointer) -> Bool { limitCalls += 1; return accepts }
    func restoreChargeLimit(_ error: NSErrorPointer) -> Bool {
        restoreCalls += 1
        if accepts && appliesRestoration { temporarilyDisabled = false }
        return accepts
    }
}

@main
struct StatusRingTests {
    static func main() throws {
        try AppearanceChecks.run()
        checkEyeReminderCycle()
        checkHolidayCountdown()
        checkHolidayPanelPlacement()
        assert(TemperatureText.compact(54.2) == "54°")
        assert(TemperatureText.compact(54.8) == "55°")
        assert(TemperatureText.compact(99.8) == "100°")
        let first = try! NetworkOutput.parse(",bytes_in,bytes_out,\ntest.1,1000,500,\ntest.2,5000,4000,\n")
        let next = try! NetworkOutput.parse(",bytes_in,bytes_out,\ntest.1,7000,2500,\ntest.2,10,10,\n")
        let rate = NetworkOutput.rate(from: first, to: next, elapsed: 2)
        assert(rate.upload == 1000 && rate.download == 3000)
        do {
            _ = try NetworkOutput.parse("bad input")
            assertionFailure("Malformed samples must fail")
        } catch {}
        assert(NetworkRate.text(128_000) == "128 KB/s")
        assert(NetworkRate.text(2_400_000) == "2.4 MB/s")
        let country = try! ExitCountry.decode(Data(#"{"success":true,"ip":"203.0.113.1","country_code":"HK"}"#.utf8))
        assert(country.flag == "🇭🇰")
        for invalid in [#"{"success":false,"message":"rate limited"}"#,
                        #"{"success":true,"ip":"203.0.113.1","country_code":""}"#] {
            do {
                _ = try ExitCountry.decode(Data(invalid.utf8))
                assertionFailure("Failed lookups must not produce a country flag")
            } catch {}
        }
        let now = Date(timeIntervalSince1970: 1_000)
        let weekly = try CodexQuota.decode(Data(#"{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":77,"windowDurationMins":10080,"resetsAt":2000},"secondary":null}}}"#.utf8), now: now)
        assert(weekly.remainingPercent == 23 && weekly.windows[0].label == "7 天")
        assert(!weekly.isStale(at: now))
        assert(weekly.isStale(at: now.addingTimeInterval(181)))
        let twoWindows = try CodexQuota.decode(Data(#"{"rateLimits":{"primary":{"usedPercent":90,"windowDurationMins":300},"secondary":{"usedPercent":77,"windowDurationMins":10080}}}"#.utf8))
        assert(twoWindows.remainingPercent == 10 && twoWindows.windows.count == 2)
        let reset = try CodexQuota.decode(Data(#"{"rateLimits":{"primary":{"usedPercent":77,"resetsAt":900}}}"#.utf8), now: now)
        assert(reset.isStale(at: now))
        for missing in [#"{"rateLimits":{"primary":null,"secondary":null}}"#,
                        #"{"rateLimitsByLimitId":{"other":{"primary":{"usedPercent":0}}}}"#] {
            do {
                _ = try CodexQuota.decode(Data(missing.utf8))
                assertionFailure("Unavailable quota must not become full quota")
            } catch {}
        }
        // Exercise the real subprocess handshake, notification handling and bounded cleanup.
        let fixture = URL(fileURLWithPath: ".build/quota-test-server.py")
        defer { try? FileManager.default.removeItem(at: fixture) }
        func server(_ body: String) throws {
            try ("#!/usr/bin/env python3\n" + body).write(to: fixture, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        }
        try server("""
        import json,sys,time
        assert json.loads(input())["method"] == "initialize"
        print(json.dumps({"id":1,"result":{}}),flush=True)
        assert json.loads(input())["method"] == "initialized"
        assert json.loads(input())["method"] == "account/rateLimits/read"
        print(json.dumps({"method":"account/updated","params":{}}),flush=True)
        print(json.dumps({"id":2,"result":{"rateLimits":{"primary":{"usedPercent":77,"windowDurationMins":10080}}}}),flush=True)
        time.sleep(30)
        """)
        let fromServer = try CodexQuotaReader().read(executable: fixture)
        assert(fromServer.remainingPercent == 23)
        try server("""
        import json,time
        r=json.loads(input())
        print(json.dumps({"id":r["id"],"result":{}}),flush=True)
        input()
        input()
        print(json.dumps({"id":77,"method":"item/commandExecution/requestApproval","params":{}}),flush=True)
        rejection=json.loads(input())
        assert rejection["id"]==77 and "error" in rejection
        time.sleep(30)
        """)
        do {
            _ = try CodexQuotaReader().read(executable: fixture)
            assertionFailure("Quota reads must reject tool and approval requests")
        } catch { assert(error.localizedDescription.contains("工具或授权")) }
        try server("import time\ntime.sleep(30)\n")
        let started = Date()
        do {
            _ = try CodexQuotaReader().read(executable: fixture, timeout: 0.2)
            assertionFailure("Unresponsive readers must time out")
        } catch {
            assert(error.localizedDescription.contains("超时"))
            assert(Date().timeIntervalSince(started) < 3)
        }
        try server("""
        import json
        input()
        print(json.dumps({"id":1,"error":{"code":-1,"message":"需要登录"}}),flush=True)
        """)
        do {
            _ = try CodexQuotaReader().read(executable: fixture)
            assertionFailure("Authentication errors must be surfaced")
        } catch { assert(error.localizedDescription == "需要登录") }
        let fake = FakeChargingClient()
        let charging = SmartCharging(client: fake)
        let plugged = BatteryReading(fraction: 0.8, mode: .pluggedIn)
        let chargingState = try charging.read()
        assert(chargingState.canOverride)
        try charging.chargeToFull(battery: plugged)
        assert(fake.limitCalls == 1 && fake.optimizedCalls == 0)
        // MCL override does not depend on the optimized-charging override flag.
        fake.limited = false
        fake.optimized = true
        fake.allowed = true
        try charging.chargeToFull(battery: plugged)
        assert(fake.limitCalls == 1 && fake.optimizedCalls == 1)
        for battery in [BatteryReading(fraction: 0.8, mode: .battery),
                        BatteryReading(fraction: 1, mode: .pluggedIn)] {
            do {
                try charging.chargeToFull(battery: battery)
                assertionFailure("Cannot override while unplugged or full")
            } catch {}
        }
        assert(fake.limitCalls == 1 && fake.optimizedCalls == 1)
        fake.queryFails = true
        do {
            try charging.chargeToFull(battery: plugged)
            assertionFailure("Must not charge after a failed state query")
        } catch {}
        assert(fake.optimizedCalls == 1)
        fake.queryFails = false
        fake.accepts = false
        do {
            try charging.chargeToFull(battery: plugged)
            assertionFailure("System rejection must be reported")
        } catch { assert(error.localizedDescription == "系统未接受充满电请求") }
        fake.accepts = true
        fake.limited = true
        fake.optimized = false
        fake.temporarilyDisabled = true
        let full = BatteryReading(fraction: 1, mode: .pluggedIn)
        let override = try charging.read()
        assert(override.action(for: full) == .restoreLimit(80))
        let unplugged = BatteryReading(fraction: 0.9, mode: .battery)
        assert(override.action(for: unplugged) == nil)
        do {
            _ = try charging.restoreChargeLimit(80, battery: unplugged)
            assertionFailure("Cannot restore the limit while unplugged")
        } catch { assert(fake.restoreCalls == 0) }
        let restored = try charging.restoreChargeLimit(80, battery: full)
        assert(restored.limitEnabled && restored.limit == 80 && restored.action(for: full) == nil)
        assert(restored.action(for: plugged) == .chargeToFull)
        fake.temporarilyDisabled = true
        fake.appliesRestoration = false
        do {
            _ = try charging.restoreChargeLimit(80, battery: full)
            assertionFailure("An accepted request must not count as a restored limit without readback")
        } catch { assert(error.localizedDescription == "系统未确认恢复 80% 充电上限") }
        let before = CPUTicks(user: 100, system: 50, idle: 800, nice: 0)
        let after = CPUTicks(user: 120, system: 60, idle: 870, nice: 0)
        assert(after.usage(since: before) == 30)
        assert(before.usage(since: before) == nil)
        let memory = ResourceReading(cpuPercent: nil, memoryUsedBytes: 18 * 1_073_741_824,
                                     memoryTotalBytes: 24 * 1_073_741_824)
        assert(memory.memoryPercent == 75)
        assert(PressureLevel.cpu(16) == .low)
        assert(PressureLevel.cpu(62) == .medium)
        assert(PressureLevel.cpu(93) == .high)
        let normalPressure = try PressureLevel.memory(systemValue: 1)
        let warningPressure = try PressureLevel.memory(systemValue: 2)
        let criticalPressure = try PressureLevel.memory(systemValue: 4)
        assert(normalPressure == .low && warningPressure == .medium && criticalPressure == .high)
        do {
            _ = try PressureLevel.memory(systemValue: 99)
            assertionFailure("Unknown system pressure must not display green")
        } catch {}
        let drive = DiskReading(totalBytes: 1000, availableBytes: 150)
        assert(drive.usedBytes == 850 && drive.usedPercent == 85 && drive.level == .medium)
        assert(DiskReading(totalBytes: 1000, availableBytes: 50).level == .high)
        print("Metrics, disk, pressure, quota, charging, reminders and holiday countdown checks passed")
    }

    private static func checkEyeReminderCycle() {
        var cycle = EyeReminderCycle()
        let start: TimeInterval = 1_000
        assert(!cycle.tick(at: start, interval: .twenty))
        assert(cycle.remainingMinutes(at: start) == 20)
        assert(!cycle.tick(at: start + 1_199, interval: .twenty))
        let firstReminder = start + 1_200
        assert(cycle.tick(at: firstReminder, interval: .twenty))
        assert(!cycle.tick(at: firstReminder, interval: .twenty))
        let later = firstReminder + 3_600
        assert(!cycle.tick(at: later, interval: .twenty))
        assert(cycle.remainingMinutes(at: later) == nil)

        cycle.snooze(at: later)
        assert(cycle.remainingMinutes(at: later) == 5)
        assert(!cycle.tick(at: later + 299, interval: .twenty))
        assert(cycle.tick(at: later + 300, interval: .twenty))
        assert(cycle.remainingMinutes(at: later + 300) == nil)

        cycle.reset()
        assert(cycle.remainingMinutes(at: later + 301) == nil)
        let nextSession = start + 8 * 3_600
        assert(!cycle.tick(at: nextSession, interval: .thirty))
        assert(cycle.remainingMinutes(at: nextSession) == 30)
        cycle.reset()
        assert(!cycle.tick(at: nextSession + 65, interval: .fortyFive))
        assert(cycle.remainingMinutes(at: nextSession + 65) == 45)
    }

    private static func checkHolidayCountdown() {
        let format = ISO8601DateFormatter()
        func holiday(at timestamp: String) -> HolidayCountdown? {
            HolidayCountdown.current(at: format.date(from: timestamp)!)
        }

        let november = holiday(at: "2026-11-25T15:59:59Z")
        assert(november?.name == "元旦" && november?.daysUntilStart == 37 && november?.dates == "1 月 1–3 日")
        assert(holiday(at: "2026-11-25T16:00:00Z")?.daysUntilStart == 36)
        assert(holiday(at: "2026-12-31T15:59:59Z")?.daysUntilStart == 1)
        assert(holiday(at: "2026-12-31T16:00:00Z")?.daysUntilStart == 0)
        assert(holiday(at: "2027-01-03T15:59:59Z")?.name == "元旦")

        let afterNewYear = holiday(at: "2027-01-03T16:00:00Z")
        assert(afterNewYear?.name == "春节" && afterNewYear?.daysUntilStart == 32 && afterNewYear?.dates == "2 月 5–13 日")
        let afterMayDay = holiday(at: "2027-05-08T02:00:00Z")
        assert(afterMayDay?.name == "端午节" && afterMayDay?.dates == "6 月 9 日")
        assert(holiday(at: "2027-10-07T16:00:00Z") == nil)

        func year(at timestamp: String) -> HolidayCountdown.Year {
            HolidayCountdown.year(at: format.date(from: timestamp)!)
        }
        let upcoming = year(at: "2026-11-25T15:59:59Z")
        assert(upcoming.dates == "2026.11.25–2027.11.25")
        assert(upcoming.holidays.map(\.daysUntilStart) == [37, 72, 129, 157, 196, 294, 310])
        assert(upcoming.holidays.map(\.daysOff) == [3, 9, 3, 5, 1, 1, 7])
        let inProgress = year(at: "2027-01-03T15:59:59Z")
        assert(inProgress.holidays.first?.name == "元旦" && inProgress.holidays.first?.daysUntilStart == 0)
        assert(year(at: "2027-01-03T16:00:00Z").holidays.first == afterNewYear)
        assert(year(at: "2026-01-01T00:00:00Z").holidays.isEmpty)
    }

    private static func checkHolidayPanelPlacement() {
        let screen = CGRect(x: -1512, y: 20, width: 1512, height: 940)
        let center = CGRect(x: -880, y: 210, width: 336, height: 625)
        let right = HolidayPanelPlacement(nextTo: center, on: screen)!.frame(height: 424)
        assert(screen.contains(right) && right.minX > center.maxX && right.maxY == center.maxY)

        let nearRightEdge = CGRect(x: -356, y: 210, width: 336, height: 625)
        let left = HolidayPanelPlacement(nextTo: nearRightEdge, on: screen)!.frame(height: 1_100)
        assert(screen.contains(left) && left.maxX < nearRightEdge.minX && left.height == screen.height)
    }
}
