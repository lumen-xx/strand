import Foundation
import IOKit

public struct Port: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let connected: Bool?
    public let device: String
    public let transports: [String]
    public let rawIdentity: [String]
    public let capabilities: Capabilities
    public var verdict: String {
        if connected == false { return "Nothing connected" }
        guard connected == true else { return "Connection state: Not reported" }
        return transports.isEmpty ? "Connected · capabilities not reported" : "Connected · " + transports.joined(separator: ", ") + " active"
    }
    public var why: String { connected == false ? "Connect a cable or charger to inspect it." : "The weakest link cannot be determined. macOS has not reported a verified cable rating, charger limit and port limit. An active transport is not the cable’s maximum speed." }
    public var report: String {
        let base = "\(name)\n\(verdict)\nDevice: \(device)\nCable speed: \(capabilities.speed ?? "Not reported")\nCable current: \(capabilities.amps.map { number($0) + " A" } ?? "Not reported")\nCable maximum power: \(capabilities.cableWatts.map { number($0) + " W" } ?? "Not reported")\nCable vendor: \(capabilities.vendor ?? "Not reported")\n"
        var sections = [base, capabilities.summary ?? why]
        sections.append(contentsOf: rawIdentity)
        sections.append(contentsOf: capabilities.raw)
        sections.append(contentsOf: capabilities.profiles.map { "PD profile: " + $0.description })
        if let active = capabilities.active { sections.append("Selected power option: " + active.description) }
        return sections.joined(separator: "\n")
    }
}

public struct PDProfile: Equatable {
    public let index: Int
    public let raw: UInt32
    public let description: String
    public let watts: Double?
    public static func decode(_ raw: UInt32, index: Int) -> PDProfile? {
        guard raw != 0 else { return nil }
        let type = raw >> 30
        var text: String; var power: Double?
        switch type {
        case 0:
            let v = Double((raw >> 10) & 1023) * 0.05, a = Double(raw & 1023) * 0.01
            guard v > 0, a > 0 else { return nil }
            power = v * a; text = "Fixed: \(number(v)) V · \(number(a)) A · \(number(v*a)) W"
        case 1, 2:
            let minV = Double((raw >> 10) & 1023) * 0.05, maxV = Double((raw >> 20) & 1023) * 0.05
            guard minV > 0, maxV >= minV else { return nil }
            if type == 1 { let w = Double(raw & 1023) * 0.25; power = w; text = "Battery: \(number(minV))–\(number(maxV)) V · \(number(w)) W" }
            else { let a = Double(raw & 1023) * 0.01; power = maxV*a; text = "Variable: \(number(minV))–\(number(maxV)) V · \(number(a)) A" }
        default:
            if (raw >> 28) & 3 == 0 {
                let minV = Double((raw >> 8) & 255) * 0.1, maxV = Double((raw >> 17) & 255) * 0.1, a = Double(raw & 127) * 0.05
                guard minV > 0, maxV >= minV, a > 0 else { return nil }
                power = maxV*a; text = "PPS: \(number(minV))–\(number(maxV)) V · \(number(a)) A"
            } else { text = "Extended profile: decoding not supported (0x\(String(raw, radix: 16)))"; power = nil }
        }
        return PDProfile(index: index, raw: raw, description: text, watts: power)
    }
}
public func number(_ n: Double) -> String { String(format: "%.2f", n).replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression).replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression) }

public enum Parser {
    public static func nodes(_ object: Any) -> [[String: Any]] {
        if let array = object as? [Any] { return array.flatMap(nodes) }
        guard let d = object as? [String: Any] else { return [] }
        return [d] + (d["IORegistryEntryChildren"] as? [Any] ?? []).flatMap(nodes)
    }
    public static func ports(_ object: Any) -> [Port] {
        var seen = Set<String>()
        return nodes(object).compactMap { d -> Port? in
            guard let type = d["PortTypeDescription"] as? String, let index = d["PortNumber"] as? NSNumber,
                  type.contains("USB") || type.contains("MagSafe") || type.contains("Thunderbolt") else { return nil }
            let id = (d["PortDescription"] as? String) ?? "\(type)@\(index)"
            guard seen.insert(id).inserted else { return nil }
            let connected = (d["ConnectionActive"] as? NSNumber)?.boolValue
            let transports = connected == true ? (d["TransportsActive"] as? [String] ?? []) : []
            // Legacy manufacturer strings can survive a replug with a zero VID/PID. Do not present that cached identity as the current device.
            let validIdentity: Bool
            if let vid = d["SOPVID"] as? Data, vid.count == 2 { validIdentity = vid.contains { $0 != 0 } }
            else if let vid = d["SOPVID"] as? NSNumber { validIdentity = vid.uint64Value > 0 && vid.uint64Value <= 65535 }
            else { validIdentity = false }
            let manufacturer = connected == true && validIdentity ? (d["SOPMfgString"] as? String) : nil
            let rawIdentity = connected == true ? d.keys.sorted().filter { $0.hasPrefix("SOP") && (validIdentity || $0 == "SOP UVDM Update Count") }.map { "\($0): \(d[$0]!)" } : []
            return Port(id: id, name: type.contains("MagSafe") ? type : "\(type) · Port \(index)", connected: connected, device: connected == false ? "Nothing connected" : (manufacturer.flatMap { $0.isEmpty ? nil : $0 } ?? "Connected device: Not reported"), transports: transports, rawIdentity: rawIdentity, capabilities: Capabilities.parse(d))
        }.sorted { $0.id < $1.id }
    }
    public static func load(_ data: Data) throws -> Any { try PropertyListSerialization.propertyList(from: data, options: [], format: nil) }
}

/// The power adapter macOS reports for the whole Mac. It is not tied to a physical port by itself.
public struct Adapter: Equatable {
    public let name: String?
    public let manufacturer: String?
    public let watts: Double?
    public let volts: Double?
    public let amps: Double?
    public let model: String?
    public let firmware: String?
    public let wireless: Bool
    public init?(_ d: [String: Any]) {
        func text(_ key: String) -> String? { (d[key] as? String).map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 } }
        func positive(_ key: String) -> Double? { (d[key] as? NSNumber).map(\.doubleValue).flatMap { $0 > 0 && $0.isFinite ? $0 : nil } }
        name = text("Name"); manufacturer = text("Manufacturer"); model = text("Model"); firmware = text("FwVersion")
        watts = positive("Watts"); volts = positive("AdapterVoltage").map { $0 / 1000 }; amps = positive("Current").map { $0 / 1000 }
        wireless = (d["IsWireless"] as? NSNumber)?.boolValue == true
        guard name != nil || watts != nil else { return nil }
    }
}

public struct PowerSnapshot: Equatable {
    public let connected: Bool
    public let adapterWatts: Double?
    public let inputWatts: Double?
    public let adapter: Adapter?
    /// nil when the battery does not report a charging state.
    public let charging: Bool?
    public let controllerReports: [String]
    public init(_ battery: [String: Any]) {
        connected = (battery["ExternalConnected"] as? NSNumber)?.boolValue == true
        let adapter = battery["AdapterDetails"] as? [String: Any] ?? [:]
        adapterWatts = connected ? (adapter["Watts"] as? NSNumber)?.doubleValue : nil
        self.adapter = connected ? Adapter(adapter) : nil
        charging = connected ? (battery["IsCharging"] as? NSNumber)?.boolValue : nil
        let telemetry = battery["PowerTelemetryData"] as? [String: Any] ?? [:]
        inputWatts = connected ? (telemetry["SystemPowerIn"] as? NSNumber).map { $0.doubleValue / 1000 } : nil
        // Controller array order and source/sink provenance are undocumented. Never attach these to a physical port or call them the charger's full menu.
        controllerReports = connected ? (battery["PortControllerInfo"] as? [[String: Any]] ?? []).enumerated().map { index, d in
            let count = max(0, min(13, (d["PortControllerNPDOs"] as? NSNumber)?.intValue ?? 0))
            let words = d["PortControllerPortPDO"] as? [NSNumber] ?? []
            let profiles = words.prefix(count).enumerated().compactMap { PDProfile.decode($0.element.uint32Value, index: $0.offset + 1) }
            let rdo = (d["PortControllerActiveContractRdo"] as? NSNumber)?.uint32Value ?? 0
            return "Controller record \(index+1) (physical port and freshness unverified)\n" + profiles.map { "PDO \($0.index): \($0.description)" }.joined(separator: "\n") + "\nReported RDO: 0x\(String(rdo, radix: 16)); object position \((rdo >> 28) & 7). Active contract: Not reported."
        } : []
    }
    public var report: String { "System power input: \(inputWatts.map { number($0)+" W" } ?? "Not reported")\nAdapter rating: \(adapterWatts.map { number($0)+" W" } ?? "Not reported")\n" + controllerReports.joined(separator: "\n\n") }
}

public enum Registry {
    public static func properties(className: String) throws -> [[String: Any]] {
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator)
        guard result == KERN_SUCCESS else { throw NSError(domain: "IOKit", code: Int(result)) }
        defer { IOObjectRelease(iterator) }
        var rows: [[String: Any]] = []
        while true {
            let entry = IOIteratorNext(iterator); if entry == 0 { break }
            defer { IOObjectRelease(entry) }
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS, let props { var row = props.takeRetainedValue() as NSDictionary as! [String: Any]
                if className == "AppleHPMInterface" {
                    var descendants: [[String: Any]] = []
                    var children: io_iterator_t = 0
                    if IORegistryEntryCreateIterator(entry, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &children) == KERN_SUCCESS {
                        defer { IOObjectRelease(children) }
                        while case let child = IOIteratorNext(children), child != 0 {
                            defer { IOObjectRelease(child) }
                            var name = [CChar](repeating: 0, count: 128)
                            guard IOObjectGetClass(child, &name) == KERN_SUCCESS else { continue }
                            let kind = String(cString: name)
                            guard ["IOPortTransportComponentCCUSBPDSOPp", "IOPortTransportComponentCCUSBPDSOPpp", "IOPortFeaturePowerSource"].contains(kind) else { continue }
                            var value: Unmanaged<CFMutableDictionary>?
                            if IORegistryEntryCreateCFProperties(child, &value, kCFAllocatorDefault, 0) == KERN_SUCCESS, let value {
                                var d = value.takeRetainedValue() as NSDictionary as! [String: Any]
                                d["IOObjectClass"] = kind; descendants.append(d)
                            }
                        }
                    }
                    row["IORegistryEntryChildren"] = descendants
                }
                rows.append(row) }
        }
        return rows
    }
    public static func snapshot() throws -> ([Port], PowerSnapshot) {
        let ports = try properties(className: "AppleHPMInterface")
        let battery = try properties(className: "AppleSmartBattery").first ?? [:]
        return (Parser.ports(ports), PowerSnapshot(battery))
    }
}
