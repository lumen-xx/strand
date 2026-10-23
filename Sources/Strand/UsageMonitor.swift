import Foundation
import IOKit
import StrandCore

struct StorageCounter {
    let id: UInt64
    let name: String
    let read: UInt64
    let written: UInt64
    var portID: String? = nil
}
struct StorageUsage: Identifiable {
    let id: UInt64
    let name: String
    let readRate: Double?
    let writeRate: Double?
    var portID: String? = nil
    static func rate(_ current: UInt64, previous: UInt64, elapsed: Double) -> Double? {
        guard elapsed > 0, current >= previous else { return nil }
        return Double(current - previous) / elapsed
    }
    static func formatted(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value >= 1_000_000 { return String(format: "%.1f MB/s", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1f KB/s", value / 1_000) }
        return String(format: "%.0f B/s", value)
    }
}
enum GraphRouting {
    static func storage(_ usage: [StorageUsage], portID: String) -> [StorageUsage] {
        usage.filter { $0.portID == portID }
    }
    static func powerPortID(ports: [StrandCore.Port], power: PowerSnapshot) -> String? {
        guard power.connected, power.inputWatts != nil else { return nil }
        let candidates = ports.filter { $0.connected == true && $0.capabilities.active != nil }
        return candidates.count == 1 ? candidates[0].id : nil
    }
}
// Read-only storage counters. UsbIOPort resolves the physical port directly; no location-ID arithmetic.
enum UsageMonitor {
    /// Answers that can't change while a device stays connected, keyed by IORegistry entry ID. These lookups climb
    /// the registry and used to run for every disk and USB device every two seconds, which kept Strand busy while idle.
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var portIDs: [UInt64: String] = [:]
        var ancestry: [UInt64: (name: String, portID: String?)] = [:]
        var notUSB: Set<UInt64> = []
        var detailsKey: [UInt64]?
        var detailsTime: TimeInterval = 0
        var details: [String: ConnectionMetadata] = [:]
        func with<T>(_ body: (Cache) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(self) }
    }
    private static let cache = Cache()
    private static let detailClasses = ["IOPortTransportComponentCCUSBPDSOP", "IOUSBHostDevice", "IOPortTransportStateDisplayPort", "IOThunderboltSwitch"]

    /// Device details per port. Rebuilt when the connected hardware changes (entries appear or disappear, a port or
    /// DisplayPort link becomes active, media is inserted) and at least every 20 seconds as a safety net.
    static func connectionDetails() -> [String: ConnectionMetadata] {
        let key = hardwareKey()
        let now = ProcessInfo.processInfo.systemUptime
        if let cached = cache.with({ $0.detailsKey == key && now - $0.detailsTime < 20 ? $0.details : nil }) { return cached }
        let details = readConnectionDetails()
        let live = Set(key)
        cache.with { cache in
            cache.detailsKey = key; cache.detailsTime = now; cache.details = details
            cache.portIDs = cache.portIDs.filter { live.contains($0.key) }
        }
        return details
    }
    private static func hardwareKey() -> [UInt64] {
        var key: [UInt64] = []
        for className in detailClasses + ["IOMedia", "AppleHPMInterface"] {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }
            key.append(UInt64.max) // Separates the classes.
            while case let entry = IOIteratorNext(iterator), entry != 0 {
                defer { IOObjectRelease(entry) }
                var id: UInt64 = 0
                guard IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS else { continue }
                key.append(id)
                if className == "IOPortTransportStateDisplayPort" { key.append((property(entry, "Active") as? NSNumber)?.boolValue == true ? 1 : 0) }
                if className == "AppleHPMInterface" { key.append((property(entry, "ConnectionActive") as? NSNumber)?.boolValue == true ? 1 : 0) }
            }
        }
        return key
    }
    private static func readConnectionDetails() -> [String: ConnectionMetadata] {
        var result: [String: ConnectionMetadata] = [:]
        var deviceNames: [String: Set<String>] = [:]
        // Per physical port: hub chips (USB class 9), other devices behind the port and a Thunderbolt device name.
        var hubs: [String: [Double]] = [:], devices: [String: [DockDevice]] = [:], thunderbolt: [String: (maker: String, model: String)] = [:]
        // A hub's own functions (video output, card reader) report the vendor ID of the hub's USB-PD identity.
        var partnerVendor: [String: Int] = [:], builtIn: [String: [String]] = [:]
        for className in detailClasses {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }
            while case let entry = IOIteratorNext(iterator), entry != 0 {
                defer { IOObjectRelease(entry) }
                guard let portID = physicalPortID(entry) else { continue }
                let props = properties(entry)
                var metadata = result[portID] ?? ConnectionMetadata()
                if className == "IOPortTransportComponentCCUSBPDSOP" {
                    if let vendor = ((props["Metadata"] as? [String: Any])?["Vendor ID"] as? NSNumber)?.intValue, vendor > 0 { partnerVendor[portID] = vendor }
                    continue
                }
                if className == "IOUSBHostDevice" {
                    let deviceClass = (props["bDeviceClass"] as? NSNumber)?.intValue
                    let rate = (props["UsbLinkSpeed"] as? NSNumber)?.doubleValue ?? 0
                    if deviceClass == 9 { hubs[portID, default: []].append(rate); result[portID] = metadata; continue }
                    // Billboard devices (class 17) only announce alternate modes; they are not something the user plugged in.
                    if deviceClass == 17 { result[portID] = metadata; continue }
                    guard let name = props["USB Product Name"] as? String, !name.isEmpty else { continue }
                    let kind = category(entry, deviceClass: deviceClass, name: name)
                    // Functions built into the hub: same vendor as the hub itself, or a card reader with no card inserted.
                    let sameVendor = (props["idVendor"] as? NSNumber)?.intValue == partnerVendor[portID]
                    if sameVendor || (kind == "storage" && !hasMedia(entry)) {
                        builtIn[portID, default: []].append(kind == "storage" ? "Card reader" : name)
                        result[portID] = metadata; continue
                    }
                    deviceNames[portID, default: []].insert(name)
                    let vendor = (props["USB Vendor Name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    devices[portID, default: []].append(DockDevice(name: name, value: [rate > 0 ? speed(rate) : nil, vendor].compactMap { $0 }.joined(separator: " · "), kind: kind, wireless: wireless(name) ? true : nil))
                    if rate > 0 { metadata.facts.append(CableFact(name: name + " · USB link", value: speed(rate))) }
                    if let vendor { metadata.facts.append(CableFact(name: name + " · Manufacturer", value: vendor)) }
                } else if className == "IOPortTransportStateDisplayPort" {
                    guard (props["Active"] as? NSNumber)?.boolValue == true else { continue }
                    let details = props["Metadata"] as? [String: Any] ?? [:]
                    if let name = (props["ProductName"] ?? details["ProductName"]) as? String, !name.isEmpty { metadata.name = name }
                    if let rate = props["LinkRateDescription"] as? String { metadata.facts.append(CableFact(name: "DisplayPort link", value: rate)) }
                    if let lanes = props["LaneCount"] as? NSNumber { metadata.facts.append(CableFact(name: "DisplayPort lanes", value: lanes.stringValue)) }
                    if let tunneled = props["Tunneled"] as? NSNumber { metadata.facts.append(CableFact(name: "DisplayPort tunnelling", value: tunneled.boolValue ? "On" : "Off")) }
                } else {
                    // Thunderbolt devices report their own maker and model; the Mac's built-in controllers report Apple.
                    guard let maker = props["Device Vendor Name"] as? String, let model = props["Device Model Name"] as? String,
                          !maker.isEmpty, !model.isEmpty, !maker.hasPrefix("Apple") else { continue }
                    thunderbolt[portID] = (maker, model)
                }
                result[portID] = metadata
            }
        }
        for (id, names) in deviceNames where names.count == 1 && result[id]?.name == nil && hubs[id] == nil {
            result[id]?.name = names.first
            // A mouse, keyboard, headset or receiver plugged straight into the port is shown with its own photo.
            result[id]?.device = devices[id]?.first
        }
        for (id, device) in thunderbolt where hubs[id] == nil { result[id]?.name = device.maker + " " + device.model }
        for (id, links) in hubs {
            let device = thunderbolt[id]
            // Most USB-C hubs drive displays too, and macOS cannot tell a powered USB-C dock from a hub. Thunderbolt docks
            // identify themselves, so only they are docks.
            let kind = device != nil ? "dock" : "hub"
            let fastest = links.max().flatMap { $0 > 0 ? speed($0) : nil }
            result[id]?.dock = DockInfo(kind: kind, maker: device?.maker, model: device?.model, link: fastest, devices: devices[id] ?? [], builtIn: builtIn[id].map { Array(Set($0)).sorted() })
            // Per-device lines move into the dock section; display link facts stay.
            result[id]?.facts.removeAll { $0.name.hasSuffix(" · USB link") || $0.name.hasSuffix(" · Manufacturer") }
        }
        return result
    }
    /// Category from USB class codes (audio 1, mass storage 8, video 14, CDC 2/10) and the device's first HID interface:
    /// a name saying mouse or keyboard decides; a wireless receiver offering both is a receiver; otherwise the first HID
    /// interface decides, because wired keyboards list their keyboard first and gaming mice their mouse, with extra keys or
    /// media controls on later interfaces. Boot protocol (1 keyboard, 2 mouse) comes before declared usages.
    private static func category(_ device: io_registry_entry_t, deviceClass: Int?, name: String) -> String? {
        var classes: [Int] = deviceClass.map { [$0] } ?? []
        var hid: [(number: Int, protocol: Int, usages: Set<Int>)] = []
        var descendants: io_iterator_t = 0
        if IORegistryEntryCreateIterator(device, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &descendants) == KERN_SUCCESS {
            defer { IOObjectRelease(descendants) }
            while case let child = IOIteratorNext(descendants), child != 0 {
                defer { IOObjectRelease(child) }
                guard IOObjectConformsTo(child, "IOUSBHostInterface") != 0 else { continue }
                let props = properties(child)
                guard let value = (props["bInterfaceClass"] as? NSNumber)?.intValue else { continue }
                classes.append(value)
                if value == 3 { hid.append(((props["bInterfaceNumber"] as? NSNumber)?.intValue ?? 99, (props["bInterfaceProtocol"] as? NSNumber)?.intValue ?? 0, usages(child))) }
            }
        }
        if classes.contains(1) { return "audio" }
        if classes.contains(8) { return "storage" }
        if classes.contains(14) { return "camera" }
        if classes.contains(2) || classes.contains(10) { return "network" }
        guard let first = hid.min(by: { $0.number < $1.number }) else { return nil }
        // A name that says what the device is wins: receivers often list a keyboard interface before the mouse.
        let lower = name.lowercased()
        if lower.contains("mouse") { return "mouse" }
        if lower.contains("keyboard") || lower.contains("keeb") { return "keyboard" }
        let anyMouse = hid.contains { $0.protocol == 2 || $0.usages.contains(2) }, anyKeyboard = hid.contains { $0.protocol == 1 || $0.usages.contains(6) }
        if wireless(name), anyMouse, anyKeyboard { return "receiver" }
        if first.protocol == 1 { return "keyboard" }
        if first.protocol == 2 { return "mouse" }
        let mouse = first.usages.contains(2), keyboard = first.usages.contains(6)
        return mouse ? "mouse" : keyboard ? "keyboard" : "input"
    }
    /// Generic Desktop usages (page 1) declared below a USB interface.
    private static func usages(_ interface: io_registry_entry_t) -> Set<Int> {
        var result: Set<Int> = []
        var descendants: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(interface, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &descendants) == KERN_SUCCESS else { return result }
        defer { IOObjectRelease(descendants) }
        while case let child = IOIteratorNext(descendants), child != 0 {
            defer { IOObjectRelease(child) }
            for pair in properties(child)["DeviceUsagePairs"] as? [[String: Any]] ?? [] where (pair["DeviceUsagePage"] as? NSNumber)?.intValue == 1 {
                if let usage = (pair["DeviceUsage"] as? NSNumber)?.intValue { result.insert(usage) }
            }
        }
        return result
    }
    /// USB receivers for 2.4 GHz or Bluetooth LE devices name themselves this way; the radio type is not reported.
    static func wireless(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["receiver", "dongle", "wireless", "unifying", "lightspeed", "2.4", "bolt", "nano receiver"].contains { lower.contains($0) }
    }
    /// Whether a storage device currently has media, such as a card in a reader.
    private static func hasMedia(_ device: io_registry_entry_t) -> Bool {
        var descendants: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(device, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &descendants) == KERN_SUCCESS else { return true }
        defer { IOObjectRelease(descendants) }
        while case let child = IOIteratorNext(descendants), child != 0 {
            defer { IOObjectRelease(child) }
            if IOObjectConformsTo(child, "IOMedia") != 0 { return true }
        }
        return false
    }
    private static func speed(_ rate: Double) -> String {
        rate >= 1_000_000_000 ? number(rate / 1_000_000_000) + " Gbps" : number(rate / 1_000_000) + " Mbps"
    }
    static func usbStorage() -> [StorageCounter] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var counters: [StorageCounter] = []
        var seen: Set<UInt64> = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS else { continue }
            seen.insert(id)
            // Internal and other non-USB disks are skipped without climbing the registry again.
            if cache.with({ $0.notUSB.contains(id) }) { continue }
            let device: (name: String, portID: String?)
            if let known = cache.with({ $0.ancestry[id] }) { device = known }
            else if let found = usbAncestry(service) {
                device = found
                // A port that wasn't active yet is looked up again next time.
                if found.portID != nil { cache.with { $0.ancestry[id] = found } }
            } else { cache.with { _ = $0.notUSB.insert(id) }; continue }
            guard let stats = property(service, "Statistics") as? [String: Any],
                  let read = stats["Bytes (Read)"] as? NSNumber,
                  let written = stats["Bytes (Write)"] as? NSNumber else { continue }
            counters.append(StorageCounter(id: id, name: device.name, read: read.uint64Value, written: written.uint64Value, portID: device.portID))
        }
        cache.with { cache in
            cache.ancestry = cache.ancestry.filter { seen.contains($0.key) }
            cache.notUSB.formIntersection(seen)
        }
        return counters.sorted { $0.id < $1.id }
    }
    /// One property, instead of copying every property of an entry.
    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
    private static func properties(_ entry: io_registry_entry_t) -> [String: Any] {
        var value: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &value, kCFAllocatorDefault, 0) == KERN_SUCCESS, let value else { return [:] }
        return value.takeRetainedValue() as NSDictionary as? [String: Any] ?? [:]
    }
    private static func physicalPortID(_ entry: io_registry_entry_t) -> String? {
        var entryID: UInt64 = 0
        let identified = IORegistryEntryGetRegistryEntryID(entry, &entryID) == KERN_SUCCESS
        if identified, let known = cache.with({ $0.portIDs[entryID] }) { return known }
        guard let port = findPhysicalPort(entry) else { return nil }
        if identified { cache.with { $0.portIDs[entryID] = port } }
        return port
    }
    private static func findPhysicalPort(_ entry: io_registry_entry_t) -> String? {
        var current = entry
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }
        for _ in 0..<64 {
            if IOObjectConformsTo(current, "AppleHPMInterface") != 0,
               (property(current, "ConnectionActive") as? NSNumber)?.boolValue == true { return property(current, "PortDescription") as? String }
            if let path = property(current, "UsbIOPort") as? String {
                let physical = IORegistryEntryFromPath(kIOMainPortDefault, path)
                if physical != 0 {
                    defer { IOObjectRelease(physical) }
                    if (property(physical, "ConnectionActive") as? NSNumber)?.boolValue == true, let id = property(physical, "PortDescription") as? String { return id }
                }
            }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else { break }
            IOObjectRelease(current); current = parent
        }
        return nil
    }
    private static func usbAncestry(_ entry: io_registry_entry_t) -> (name: String, portID: String?)? {
        var current = entry
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }
        var name: String?
        var portID: String?
        for _ in 0..<64 {
            if name == nil, IOObjectConformsTo(current, "IOUSBHostDevice") != 0 {
                name = property(current, "USB Product Name") as? String ?? property(current, "Product Name") as? String ?? "USB storage"
            }
            if let path = property(current, "UsbIOPort") as? String {
                let physical = IORegistryEntryFromPath(kIOMainPortDefault, path)
                if physical != 0 {
                    if (property(physical, "ConnectionActive") as? NSNumber)?.boolValue == true {
                        portID = property(physical, "PortDescription") as? String
                    }
                    IOObjectRelease(physical)
                }
            }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else { break }
            IOObjectRelease(current)
            current = parent
        }
        return name.map { ($0, portID) }
    }
}
