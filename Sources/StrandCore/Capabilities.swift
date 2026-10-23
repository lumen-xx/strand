import Foundation

public struct PowerOption: Equatable {
    public let volts: Double
    public let amps: Double
    public let watts: Double
    public let identifier: String?
    public var description: String { "\(number(volts)) V · \(number(amps)) A · \(number(watts)) W" }
    public static func parse(_ d: [String: Any]) -> PowerOption? {
        guard let mv = d["Voltage (mV)"] as? NSNumber, let ma = d["Max Current (mA)"] as? NSNumber,
              mv.doubleValue > 0, ma.doubleValue > 0, mv.doubleValue <= 50000, ma.doubleValue <= 5000 else { return nil }
        let watts = (d["Max Power (mW)"] as? NSNumber).map { $0.doubleValue / 1000 } ?? mv.doubleValue * ma.doubleValue / 1_000_000
        guard watts > 0, watts.isFinite else { return nil }
        return PowerOption(volts: mv.doubleValue / 1000, amps: ma.doubleValue / 1000, watts: watts, identifier: d["UUID"] as? String)
    }
}
public struct Capabilities: Equatable {
    public var speed: String?
    public var amps: Double?
    public var maxVoltage: Double?
    public var cableWatts: Double?
    public var vendor: String?
    public var product: String?
    public var cableType: String?
    public var profiles: [PowerOption] = []
    public var active: PowerOption?
    public var raw: [String] = []
    public var summary: String? {
        guard let cableWatts, let charger = profiles.map(\.watts).max(), let active else { return nil }
        // Only describe a cable limit when the selected contract reaches it and the same port's source offers more.
        if charger > cableWatts + 1 && active.watts >= cableWatts - 1 {
            return "The cable limits power to \(number(cableWatts)) W; the charger offers \(number(charger)) W."
        }
        return nil // Port limits and device demand are not exposed; never declare another bottleneck.
    }
    public var facts: [(String, String)] {
        var fields: [(String, String)] = []
        if let speed { fields.append(("Cable speed", speed)) }
        if let amps { fields.append(("Cable current", number(amps) + " A")) }
        if let cableWatts { fields.append(("Cable power rating", number(cableWatts) + " W")) }
        if let maxVoltage { fields.append(("Cable voltage ceiling", number(maxVoltage) + " V")) }
        if let vendor { fields.append(("Cable vendor ID", vendor)) }
        if let product { fields.append(("Cable product ID", product)) }
        if let cableType { fields.append(("Cable type", cableType)) }
        if let active { fields.append(("Selected power option", active.description)) }
        return fields
    }
    public static func parse(_ port: [String: Any]) -> Capabilities {
        var result = Capabilities()
        guard (port["ConnectionActive"] as? NSNumber)?.boolValue == true else { return result }
        let descendants = Parser.nodes(port)
        let markers = descendants.filter { ["IOPortTransportComponentCCUSBPDSOPp", "IOPortTransportComponentCCUSBPDSOPpp"].contains($0["IOObjectClass"] as? String ?? "") }
        // Keep near/far endpoints separate; conflicting identities are not merged into a fictional cable.
        if let marker = markers.first(where: { ($0["IOObjectClass"] as? String) == "IOPortTransportComponentCCUSBPDSOPp" }) ?? markers.first {
            var data = marker["Metadata"] as? [String: Any] ?? [:]
            data.merge(marker) { _, top in top }
            let words = vdos(data["VDOs"])
            let header = words.first
            let type = (data["Product Type"] as? NSNumber)?.uint32Value ?? header.map { ($0 >> 27) & 7 }
            let vid = (data["Vendor ID"] as? NSNumber)?.uint32Value ?? header.map { $0 & 0xffff }
            if let vid, vid > 0 && vid <= 65535 { result.vendor = String(format: "0x%04X", vid) }
            let pid = (data["Product ID"] as? NSNumber)?.uint32Value ?? (words.count >= 3 ? words[2] >> 16 : nil)
            if let pid, pid > 0 && pid <= 65535 { result.product = String(format: "0x%04X", pid) }
            if type == 3 || type == 4, words.count >= 4 {
                let cable = words[3], version = (cable >> 21) & 7
                result.cableType = type == 3 ? "Passive e-marked" : "Active e-marked"
                // Rev 3 passive and active Cable VDO 1 layouts. Unknown layouts remain raw.
                if version == 0 || version == 3 {
                    result.amps = [1: 3.0, 2: 5.0][(cable >> 5) & 3]
                    result.speed = [0: "USB 2.0 · 480 Mbps", 1: "USB Gen 1 · 5 Gbps", 2: "USB Gen 2 · 10–20 Gbps", 3: "USB4 Gen 3 · 40 Gbps", 4: "USB4 Gen 4 · 80 Gbps"][cable & 7]
                    if type == 4, words.count < 5 || ((words[4] >> 8) & 1) != 0 {
                        if (cable & 7) >= 3 { result.speed = nil }
                    }
                    result.maxVoltage = [20.0, 30, 40, 50][Int((cable >> 9) & 3)]
                    // Voltage tolerance is not an EPR wattage rating. Only the 20 V rating is unambiguous here.
                    if result.maxVoltage == 20, let amps = result.amps { result.cableWatts = 20 * amps }
                }
            }
            result.raw = words.enumerated().map { "Near cable identity VDO \($0.offset + 1): " + String(format: "0x%08X", $0.element) }
        }
        for marker in markers where (marker["IOObjectClass"] as? String) == "IOPortTransportComponentCCUSBPDSOPpp" {
            let metadata = marker["Metadata"] as? [String: Any] ?? [:]
            result.raw += vdos(marker["VDOs"] ?? metadata["VDOs"]).enumerated().map { "Far cable identity VDO \($0.offset + 1): " + String(format: "0x%08X", $0.element) }
        }
        let sources = descendants.filter { ($0["IOObjectClass"] as? String) == "IOPortFeaturePowerSource" && ($0["PowerSourceName"] as? String) == "USB-PD" }
        // USB-PD is distinct from the TypeC and Brick ID fallback sources on the same port.
        // Multiple USB-PD sources remain ambiguous.
        if sources.count == 1, let source = sources.first {
            result.profiles = collection(source["PowerSourceOptions"]).compactMap { ($0 as? [String: Any]).flatMap(PowerOption.parse) }.sorted { $0.volts < $1.volts }
            result.active = (source["WinningPowerSourceOption"] as? [String: Any]).flatMap(PowerOption.parse)
            result.raw += collection(source["PowerSourceOptions"]).compactMap { value in
                guard let d = value as? [String: Any], PowerOption.parse(d) == nil else { return nil }
                return "Additional PD option: " + d.keys.sorted().map { "\($0)=\(d[$0]!)" }.joined(separator: "; ")
            }
        }
        return result
    }
    public static func collection(_ value: Any?) -> [Any] { (value as? [Any]) ?? (value as? NSSet).map { Array($0) } ?? [] }
    public static func vdos(_ value: Any?) -> [UInt32] {
        let values = collection(value)
        let words = values.compactMap { value -> UInt32? in
            if let data = value as? Data, data.count == 4 { return data.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) } }
            if let number = value as? NSNumber, number.int64Value >= 0, number.uint64Value <= UInt32.max { return number.uint32Value }
            return nil
        }
        return words.count == values.count ? words : [] // Missing words must not shift VDO positions.
    }
}
