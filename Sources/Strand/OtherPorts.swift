import Foundation
import IOKit
import CoreAudio
import StrandCore

/// Connections outside the USB-C/MagSafe port controller: the 3.5 mm headphone jack and built-in HDMI ports.
enum OtherPorts {
    static func connections() -> [ConnectionItem] { hdmi() + headphones() }

    // MARK: Headphone jack

    /// Apple silicon publishes a separate built-in headphone device while something is plugged in; Intel Macs switch the
    /// built-in output's data source to headphones. The jack cannot identify what is plugged in.
    static func headphones() -> [ConnectionItem] {
        let devices = audioDevices().filter { value($0, kAudioDevicePropertyTransportType, UInt32(0)) == kAudioDeviceTransportTypeBuiltIn }
        let headphone: UInt32 = 0x6864706E // 'hdpn'
        let externalMic: UInt32 = 0x656D6963 // 'emic'
        guard let output = devices.first(where: { device in
            hasStreams(device, kAudioObjectPropertyScopeOutput) && (uid(device).localizedCaseInsensitiveContains("Headphone") || value(device, kAudioDevicePropertyDataSource, UInt32(0), scope: kAudioObjectPropertyScopeOutput) == headphone)
        }) else { return [] }
        let microphone = devices.contains { device in
            hasStreams(device, kAudioObjectPropertyScopeInput) && (uid(device).localizedCaseInsensitiveContains("Headphone") || value(device, kAudioDevicePropertyDataSource, UInt32(0), scope: kAudioObjectPropertyScopeInput) == externalMic)
        }
        let current = value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, AudioDeviceID(0)) == output
        var facts = [CableFact(name: "Audio output", value: current ? "Current output" : "Available, not selected")]
        if let rate = value(output, kAudioDevicePropertyNominalSampleRate, Float64(0)), rate > 0 { facts.append(CableFact(name: "Sample rate", value: number(rate / 1000) + " kHz")) }
        if microphone { facts.append(CableFact(name: "Microphone", value: "Headset microphone detected")) }
        return [ConnectionItem(id: "audio:headphones", name: "Headphones", port: "3.5 mm headphone jack", kind: "headphones",
                               chip: current ? "Current output" : "Connected", verdict: "Connected", link: "Analog audio", facts: facts,
                               details: facts.map { $0.name + ": " + $0.value }.joined(separator: "\n"))]
    }
    private static func audioDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }
    private static func value<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var result = initial, size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr ? result : nil
    }
    private static func uid(_ device: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var result: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &result) == noErr, let result else { return "" }
        return result.takeRetainedValue() as String
    }
    private static func hasStreams(_ device: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    // MARK: HDMI

    /// Built-in HDMI ports, found by the port type macOS reports. HDMI on a dock or adapter is converted from DisplayPort
    /// and appears under its USB-C port instead.
    static func hdmi() -> [ConnectionItem] {
        var ports: [Int: (name: String?, facts: [CableFact])] = [:]
        for port in services([kIOPropertyMatchKey: ["PortTypeDescription": "HDMI"]] as NSDictionary) where (port["ConnectionActive"] as? NSNumber)?.boolValue == true {
            ports[(port["PortNumber"] as? NSNumber)?.intValue ?? 1, default: (nil, [])] = (nil, [])
        }
        for className in ["IOPortTransportStateDisplayPort", "IOPortTransportStateHDMI"] {
            for state in services(IOServiceMatching(className)) {
                guard (state["Active"] as? NSNumber)?.boolValue == true, (state["ParentPortTypeDescription"] as? String)?.contains("HDMI") == true else { continue }
                var facts: [CableFact] = []
                if let rate = state["LinkRateDescription"] as? String { facts.append(CableFact(name: "Display link", value: rate)) }
                if let lanes = state["LaneCount"] as? NSNumber, lanes.intValue > 0 { facts.append(CableFact(name: "Display lanes", value: lanes.stringValue)) }
                if let maker = state["ManufacturerName"] as? String, !maker.isEmpty { facts.append(CableFact(name: "Display manufacturer ID", value: maker)) }
                let name = (state["ProductName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ports[(state["ParentPortNumber"] as? NSNumber)?.intValue ?? 1] = (name, facts)
            }
        }
        return ports.keys.sorted().map { number in
            let port = ports[number]!
            return ConnectionItem(id: "hdmi:\(number)", name: port.name ?? "HDMI display", port: ports.count > 1 ? "HDMI · Port \(number)" : "HDMI port", kind: "hdmi",
                                  chip: port.name == nil ? "Connected" : "Display connected", verdict: "Connected", link: "HDMI", facts: port.facts,
                                  details: (["Port: HDMI \(number)"] + port.facts.map { $0.name + ": " + $0.value }).joined(separator: "\n"))
        }
    }
    private static func services(_ matching: NSDictionary) -> [[String: Any]] {
        var iterator: io_iterator_t = 0
        // IOServiceGetMatchingServices consumes one reference to the matching dictionary.
        guard IOServiceGetMatchingServices(kIOMainPortDefault, (matching.mutableCopy() as! CFMutableDictionary), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var rows: [[String: Any]] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var value: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(entry, &value, kCFAllocatorDefault, 0) == KERN_SUCCESS, let value, let row = value.takeRetainedValue() as NSDictionary as? [String: Any] { rows.append(row) }
        }
        return rows
    }
    private static func services(_ matching: CFMutableDictionary?) -> [[String: Any]] {
        guard let matching else { return [] }
        return services(matching as NSDictionary)
    }
}
