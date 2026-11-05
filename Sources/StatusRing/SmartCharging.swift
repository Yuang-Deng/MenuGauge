import Foundation
import ObjectiveC

// PowerUI has no public charge-to-full API. Verify the runtime ABI before use.
@objc protocol PowerUICharging {
    @objc(isOBCEngaged:chargeLimit:chargingOverrideAllowed:withError:)
    func optimizedState(_ engaged: UnsafeMutablePointer<ObjCBool>, chargeLimit: UnsafeMutablePointer<UInt>,
                        chargingOverrideAllowed: UnsafeMutablePointer<ObjCBool>, withError: NSErrorPointer) -> Bool
    @objc(isMCLCurrentlyEnabled:)
    func limitEnabled(_ error: NSErrorPointer) -> UInt
    @objc(getMCLLimitWithError:)
    func limit(_ error: NSErrorPointer) -> UInt8
    @objc(temporarilyEnableCharging:)
    func overrideOptimizedCharging(_ error: NSErrorPointer) -> Bool
    @objc(temporarilyDisableMCL:)
    func overrideChargeLimit(_ error: NSErrorPointer) -> Bool
}

struct ChargingControlState {
    let limitEnabled: Bool
    let limit: Int
    let optimizedHold: Bool
    let overrideAllowed: Bool

    var canOverride: Bool { (limitEnabled && limit < 100) || (optimizedHold && overrideAllowed) }
}

final class SmartCharging {
    private let client: any PowerUICharging
    private static let framework = dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI", RTLD_NOW)

    init(client: any PowerUICharging) { self.client = client }

    convenience init() throws {
        guard Self.framework != nil,
              let type = NSClassFromString("PowerUISmartChargeClient") as? NSObject.Type else {
            throw MetricError(message: "此 macOS 不支持立即充满电")
        }
        let signatures = [
            "initWithClientName:": "@24@0:8@16",
            "isOBCEngaged:chargeLimit:chargingOverrideAllowed:withError:": "B48@0:8^B16^Q24^B32^@40",
            "isMCLCurrentlyEnabled:": "Q24@0:8^@16",
            "getMCLLimitWithError:": "C24@0:8^@16",
            "temporarilyEnableCharging:": "B24@0:8^@16",
            "temporarilyDisableMCL:": "B24@0:8^@16"
        ]
        for (name, signature) in signatures {
            guard let method = class_getInstanceMethod(type, NSSelectorFromString(name)),
                  let encoding = method_getTypeEncoding(method), String(cString: encoding) == signature else {
                throw MetricError(message: "系统充电接口已变化，需要更新应用")
            }
        }
        guard let allocated = type.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
              let instance = allocated.perform(NSSelectorFromString("initWithClientName:"),
                                               with: "Status Ring")?.takeRetainedValue() else {
            throw MetricError(message: "无法连接系统充电服务")
        }
        self.init(client: unsafeBitCast(instance, to: (any PowerUICharging).self))
    }

    func read() throws -> ChargingControlState {
        var engaged = ObjCBool(false)
        var allowed = ObjCBool(false)
        var limit: UInt = 0
        var error: NSError?
        let valid = client.optimizedState(&engaged, chargeLimit: &limit, chargingOverrideAllowed: &allowed, withError: &error)
        if let error { throw error }
        guard valid else { throw MetricError(message: "无法读取优化充电状态") }
        let enabled = client.limitEnabled(&error) != 0
        if let error { throw error }
        let configured = Int(client.limit(&error))
        if let error { throw error }
        guard !enabled || (1...100).contains(configured) else {
            throw MetricError(message: "系统返回了无效的充电上限")
        }
        return ChargingControlState(limitEnabled: enabled, limit: configured,
                                    optimizedHold: engaged.boolValue, overrideAllowed: allowed.boolValue)
    }

    func chargeToFull(battery: BatteryReading) throws {
        guard battery.mode != .battery else { throw MetricError(message: "请先连接电源适配器") }
        guard battery.fraction < 1 else { throw MetricError(message: "电池已经充满") }
        let state = try read()
        guard state.canOverride else { throw MetricError(message: "当前没有需要解除的充电限制") }
        var error: NSError?
        let accepted = state.limitEnabled && state.limit < 100
            ? client.overrideChargeLimit(&error)
            : client.overrideOptimizedCharging(&error)
        if let error { throw error }
        guard accepted else { throw MetricError(message: "系统未接受充满电请求") }
    }
}
