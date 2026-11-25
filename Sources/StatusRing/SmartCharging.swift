import Foundation
import ObjectiveC

// Verify the ABI of the private PowerUI selectors before use.
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
    @objc(enableMCL:)
    func restoreChargeLimit(_ error: NSErrorPointer) -> Bool
}

enum ChargingAction: Equatable {
    case chargeToFull
    case restoreLimit(Int)

    var title: String {
        switch self {
        case .chargeToFull: return "立即充满电"
        case .restoreLimit(let limit): return "恢复 \(limit)% 上限"
        }
    }

    var pendingTitle: String {
        switch self {
        case .chargeToFull: return "正在请求…"
        case .restoreLimit: return "正在恢复…"
        }
    }

    var help: String {
        switch self {
        case .chargeToFull: return "临时解除充电限制，充至 100%"
        case .restoreLimit(let limit): return "取消临时充满，恢复 \(limit)% 充电上限"
        }
    }
}

struct ChargingControlState {
    let limitEnabled: Bool
    let limit: Int
    let restorableLimit: Int?
    let optimizedHold: Bool
    let overrideAllowed: Bool

    var canOverride: Bool { (limitEnabled && limit < 100) || (optimizedHold && overrideAllowed) }

    func action(for battery: BatteryReading) -> ChargingAction? {
        guard battery.mode != .battery else { return nil }
        if let restorableLimit { return .restoreLimit(restorableLimit) }
        return battery.fraction < 1 && canOverride ? .chargeToFull : nil
    }
}

final class SmartCharging {
    private let client: any PowerUICharging
    private static let framework = dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI", RTLD_NOW)
    private static let temporarilyDisabled: UInt = 3
    private let supportsRestoration: Bool

    init(client: any PowerUICharging) {
        self.client = client
        let method = class_getInstanceMethod(object_getClass(client), #selector(PowerUICharging.restoreChargeLimit(_:)))
        supportsRestoration = method.flatMap(method_getTypeEncoding).map { String(cString: $0) == "B24@0:8^@16" } ?? false
    }

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
        var reportedLimit: UInt = 0
        var error: NSError?
        let valid = client.optimizedState(&engaged, chargeLimit: &reportedLimit, chargingOverrideAllowed: &allowed, withError: &error)
        if let error { throw error }
        guard valid else { throw MetricError(message: "无法读取优化充电状态") }
        let mode = client.limitEnabled(&error)
        if let error { throw error }
        let effectiveLimit = Int(client.limit(&error))
        if let error { throw error }
        guard mode == 0 || (1...100).contains(effectiveLimit) else {
            throw MetricError(message: "系统返回了无效的充电上限")
        }
        // During a manual override the effective limit is 100, while PowerUI still reports the prior limit.
        let temporarilyDisabled = mode == Self.temporarilyDisabled
        let restorableLimit = temporarilyDisabled && supportsRestoration && (80..<100).contains(reportedLimit)
            ? Int(reportedLimit) : nil
        return ChargingControlState(limitEnabled: mode != 0 && !temporarilyDisabled, limit: effectiveLimit,
                                    restorableLimit: restorableLimit,
                                    optimizedHold: engaged.boolValue, overrideAllowed: allowed.boolValue)
    }

    func chargeToFull(battery: BatteryReading) throws {
        guard battery.mode != .battery else { throw MetricError(message: "请先连接电源适配器") }
        guard battery.fraction < 1 else { throw MetricError(message: "电池已经充满") }
        let state = try read()
        guard state.action(for: battery) == .chargeToFull else { throw MetricError(message: "当前没有需要解除的充电限制") }
        var error: NSError?
        let accepted = state.limitEnabled && state.limit < 100
            ? client.overrideChargeLimit(&error)
            : client.overrideOptimizedCharging(&error)
        if let error { throw error }
        guard accepted else { throw MetricError(message: "系统未接受充满电请求") }
    }

    func restoreChargeLimit(_ limit: Int, battery: BatteryReading) throws -> ChargingControlState {
        guard battery.mode != .battery else { throw MetricError(message: "请先连接电源适配器") }
        let state = try read()
        guard state.restorableLimit == limit else {
            throw MetricError(message: "充电状态已变化，请重新查看上限")
        }
        var error: NSError?
        let accepted = client.restoreChargeLimit(&error)
        if let error { throw error }
        guard accepted else { throw MetricError(message: "系统未接受恢复上限请求") }
        let restored = try read()
        guard restored.limitEnabled, restored.limit == limit else {
            throw MetricError(message: "系统未确认恢复 \(limit)% 充电上限")
        }
        return restored
    }
}
