import Foundation

final class FakeChargingClient: NSObject, PowerUICharging {
    var limited = true
    var optimized = false
    var allowed = false
    var queryFails = false
    var accepts = true
    var limitCalls = 0
    var optimizedCalls = 0
    func optimizedState(_ engaged: UnsafeMutablePointer<ObjCBool>, chargeLimit: UnsafeMutablePointer<UInt>,
                        chargingOverrideAllowed: UnsafeMutablePointer<ObjCBool>, withError: NSErrorPointer) -> Bool {
        engaged.pointee = ObjCBool(optimized)
        chargeLimit.pointee = 80
        chargingOverrideAllowed.pointee = ObjCBool(allowed)
        return !queryFails
    }
    func limitEnabled(_ error: NSErrorPointer) -> UInt { limited ? 1 : 0 }
    func limit(_ error: NSErrorPointer) -> UInt8 { 80 }
    func overrideOptimizedCharging(_ error: NSErrorPointer) -> Bool { optimizedCalls += 1; return accepts }
    func overrideChargeLimit(_ error: NSErrorPointer) -> Bool { limitCalls += 1; return accepts }
}

@main
struct StatusRingTests {
    static func main() throws {
        try AppearanceChecks.run()
        try FingerprintChecks.run()
        try ModelRPCChecks.run()
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
        print("Metrics, disk, pressure, quota, RPC lifecycle and charging-control checks passed")
    }
}
