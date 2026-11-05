import Foundation
import Darwin
import SystemConfiguration

struct NetworkAddress: Equatable {
    let interface: String
    let address: String
}

struct NetworkRate {
    let upload: Double
    let download: Double

    static func text(_ bytes: Double) -> String {
        if bytes >= 1_000_000 { return String(format: "%.1f MB/s", bytes / 1_000_000) }
        return String(format: "%.0f KB/s", bytes / 1_000)
    }
}

struct NetworkCounters {
    let received: Double
    let sent: Double
}

struct NetworkOutput {
    static func parse(_ text: String) throws -> [String: NetworkCounters] {
        let lines = text.split(separator: "\n")
        guard lines.first == ",bytes_in,bytes_out," else {
            throw MetricError(message: "未收到系统网速统计")
        }
        var counters: [String: NetworkCounters] = [:]
        for line in lines.dropFirst() {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 4, let received = Double(fields[fields.count - 3]),
                  let sent = Double(fields[fields.count - 2]), received >= 0, sent >= 0 else {
                throw MetricError(message: "无法解析系统网速统计")
            }
            let process = fields.dropLast(3).joined(separator: ",")
            counters[process] = NetworkCounters(received: received, sent: sent)
        }
        return counters
    }

    static func rate(from previous: [String: NetworkCounters], to current: [String: NetworkCounters],
                     elapsed: TimeInterval) -> NetworkRate {
        var received = 0.0
        var sent = 0.0
        for (process, counters) in current {
            // Closed sockets can reduce a process total. Never turn that into a spike.
            guard let before = previous[process] else { continue }
            received += max(0, counters.received - before.received)
            sent += max(0, counters.sent - before.sent)
        }
        return NetworkRate(upload: sent / elapsed, download: received / elapsed)
    }
}

// Interface RX counters stay at zero on this Mac. Take short socket snapshots instead.
// nettop's continuous mode busy-loops on this OS; one-shot sampling avoids that cost.
final class NetworkMonitor {
    private var process: Process?
    private var timer: Timer?
    private var stopped = false
    private var previous: [String: NetworkCounters]?
    private var previousTime = 0.0
    private let receive: (Result<NetworkRate, Error>) -> Void

    init(receive: @escaping (Result<NetworkRate, Error>) -> Void) {
        self.receive = receive
    }

    func start() throws {
        try sample()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            do { try self.sample() }
            catch { self.stop(); self.receive(.failure(error)) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func sample() throws {
        guard process == nil else { return }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-n", "-P", "-L", "1", "-x", "-t", "external", "-J", "bytes_in,bytes_out"]
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
        self.process = process
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let time = ProcessInfo.processInfo.systemUptime
            let result = Result {
                guard process.terminationStatus == 0 else {
                    throw MetricError(message: "网速采样失败（\(process.terminationStatus)）")
                }
                return try NetworkOutput.parse(String(decoding: data, as: UTF8.self))
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.stopped else { return }
                self.process = nil
                switch result {
                case .success(let counters):
                    if let previous = self.previous {
                        self.receive(.success(NetworkOutput.rate(from: previous, to: counters,
                                                                  elapsed: time - self.previousTime)))
                    }
                    self.previous = counters
                    self.previousTime = time
                case .failure(let error):
                    self.stop()
                    self.receive(.failure(error))
                }
            }
        }
    }

    func stop() {
        stopped = true
        timer?.invalidate()
        timer = nil
        if let process, process.isRunning { process.terminate() }
    }

    deinit { stop() }
}

final class NetworkReader {
    private let store: SCDynamicStore

    init() throws {
        guard let store = SCDynamicStoreCreate(nil, "Status Ring" as CFString, nil, nil) else {
            throw MetricError(message: "无法读取网络配置")
        }
        self.store = store
    }

    func read() throws -> NetworkAddress? {
        let ipv4 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        let ipv6 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv6" as CFString) as? [String: Any]
        guard let name = (ipv4?["PrimaryInterface"] ?? ipv6?["PrimaryInterface"]) as? String else { return nil }
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else {
            throw MetricError(message: "无法读取网络接口：\(String(cString: strerror(errno)))")
        }
        defer { freeifaddrs(head) }
        var cursor = head
        var address4: String?
        var address6: String?
        while let entry = cursor {
            let value = entry.pointee
            cursor = value.ifa_next
            guard String(cString: value.ifa_name) == name,
                  value.ifa_flags & UInt32(IFF_UP) != 0, let address = value.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            if family == AF_INET || family == AF_INET6 {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer,
                                         socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
                guard result == 0 else {
                    throw MetricError(message: "无法读取 IP：\(String(cString: gai_strerror(result)))")
                }
                let text = String(cString: buffer)
                if family == AF_INET { address4 = text }
                else if !text.hasPrefix("fe80:") { address6 = text }
            }
        }
        guard let address = address4 ?? address6 else { return nil }
        return NetworkAddress(interface: name, address: address)
    }
}
