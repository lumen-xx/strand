import Foundation
import StrandCore
func check(_ condition: @autoclosure () -> Bool, _ message: String) { if !condition() { fatalError(message) } }
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Fixtures")
let ports = Parser.ports(try Parser.load(Data(contentsOf: root.appendingPathComponent("ports-disconnected.plist"))))
check(ports.count == 3, "Physical ports")
check(ports.allSatisfy { $0.connected == false && $0.verdict == "Nothing connected" && $0.rawIdentity.isEmpty }, "Disconnected suppresses stale identity")
let batteryNodes = Parser.nodes(try Parser.load(Data(contentsOf: root.appendingPathComponent("battery-disconnected.plist"))))
let battery = batteryNodes.first { $0["PortControllerInfo"] != nil }!
let power = PowerSnapshot(battery)
check(!power.connected && power.controllerReports.isEmpty && power.inputWatts == nil, "Suppress retained PDO/RDO after disconnect")
let connected = Parser.ports(try Parser.load(Data(contentsOf: root.appendingPathComponent("synthetic-connected.plist"))))
check(connected.count == 1 && connected[0].connected == true && connected[0].transports == ["USB2"], "Connected transport")
check(!connected[0].verdict.contains("480") && connected[0].report.contains("Cable speed: Not reported"), "Active USB2 must not imply cable rating")
let unknown = Parser.ports([["PortTypeDescription":"USB-C", "PortNumber":1]])
check(unknown[0].connected == nil, "Missing state stays unknown")
check(Parser.ports([["PortTypeDescription":"USB-C", "PortNumber":1],["PortTypeDescription":"USB-C", "PortNumber":1]]).count == 1, "Deduplication")
let pdo = UInt32(400 << 10 | 300)
check(PDProfile.decode(pdo, index: 1)?.watts == 60, "20 V 3 A PDO")
check(PDProfile.decode(0, index: 1) == nil, "Zero PDO")
check(PDProfile.decode(0xF0000001, index: 1)?.watts == nil, "Unknown APDO")
check(number(100) == "100", "Number formatting")
print("PASS: recorded physical ports, stale identity and PD suppression, unknown state, deduplication, synthetic connection, fixed PDO and unsupported profiles")
let dangling = Parser.ports(try Parser.load(Data(contentsOf: root.appendingPathComponent("ports-dangling.plist"))))
check(dangling.count == 3 && dangling.allSatisfy { $0.connected == false }, "Recorded dangling cable remains inactive")
let pps = UInt32(3 << 30 | 110 << 17 | 33 << 8 | 60)
check(PDProfile.decode(pps, index: 1)?.watts == 33, "PPS 3.3–11 V 3 A")
let connectedPower = PowerSnapshot(["ExternalConnected":true, "AdapterDetails":["Watts":60], "PowerTelemetryData":["SystemPowerIn":30000]])
check(connectedPower.inputWatts == 30 && connectedPower.adapterWatts == 60, "System power is distinct from rating")
let live = try Registry.snapshot()
check(!live.0.isEmpty, "Live read reports physical ports on this Mac")
for port in live.0 { print("LIVE: \(port.name): \(port.verdict)") }
print("PASS: recorded dangling cable, PPS decoder, power units and live IOKit access")
let capabilityPorts = Parser.ports(try Parser.load(Data(contentsOf: root.appendingPathComponent("synthetic-emarker-pd.plist"))))
let capable = capabilityPorts[0].capabilities
check(capable.speed?.contains("40 Gbps") == true && capable.amps == 3 && capable.cableWatts == 60, "SOP prime VDO rating")
check(capable.vendor == "0x1234" && capable.product == "0x5678", "Cable identity VID/PID")
check(capable.profiles.count == 2 && capable.active?.watts == 60 && capable.summary?.contains("96 W") == true, "Per-port PD options, winner and cable bottleneck")
var syntheticPort = (try Parser.load(Data(contentsOf: root.appendingPathComponent("synthetic-emarker-pd.plist"))) as! [[String: Any]])[0]
syntheticPort["ConnectionActive"] = false
check(Capabilities.parse(syntheticPort).facts.isEmpty && Capabilities.parse(syntheticPort).profiles.isEmpty, "Suppress cached capability tree on disconnect")
check(Capabilities.vdos([Data([1,2,3,4])]) == [0x04030201], "VDO little endian")
check(Capabilities.vdos([Data([1]), NSNumber(value: 1)]).isEmpty, "Malformed VDO must not shift positions")
check(PowerOption.parse(["Voltage (mV)":0,"Max Current (mA)":3000]) == nil, "Invalid power option")
let capturedIOPorts = Parser.ports(try Parser.load(Data(contentsOf: root.appendingPathComponent("ioport-cc-recorded.plist"))))
check(capturedIOPorts.allSatisfy { $0.capabilities.speed == nil && $0.capabilities.profiles.isEmpty }, "Recorded CC transport has no fabricated cable ratings")
var synthetic = syntheticPort
synthetic["ConnectionActive"] = true
var marker = ["IOObjectClass":"IOPortTransportComponentCCUSBPDSOPp", "VDOs": [UInt32(3<<27)|0x1234, 0, 0, UInt32(3<<21|2<<5|4)]] as [String:Any]
synthetic["IORegistryEntryChildren"] = [marker]
check(Capabilities.parse(synthetic).speed?.contains("80 Gbps") == true, "Gen4 cable identity")
marker["VDOs"] = [UInt32(3<<27),0,0,UInt32(7<<21|2<<5|3)]
synthetic["IORegistryEntryChildren"] = [marker]
check(Capabilities.parse(synthetic).speed == nil, "Unknown VDO revision stays raw")
print("PASS: recorded IOPort subtree, SOP prime decoding, little endian and malformed identities, stale suppression, PD options/active profile, 80 Gbps, bottleneck and unknown versions")
let recordedPD = Parser.ports(try Parser.load(Data(contentsOf: root.appendingPathComponent("ports-pd-recorded.plist"))))
let recordedSource = recordedPD.first { !$0.capabilities.profiles.isEmpty }!
check(recordedSource.capabilities.profiles.count == 2 && recordedSource.capabilities.active?.volts == 9, "Actual USB-PD source options and winning profile")
check(recordedSource.capabilities.active?.amps == 2.22 && recordedSource.capabilities.active?.watts == 19.98, "Actual selected 9 V / 2.22 A contract")
check(recordedSource.capabilities.speed == nil && recordedSource.capabilities.vendor == nil, "Real PD source does not fabricate cable identity")
check(recordedSource.report.contains("Selected power option: 9 V"), "Copy report includes capabilities")
print("PASS: real API recording has two PD options, 9 V/2.22 A winner, no e-marker; fallback sources excluded")
let twoCables = Parser.ports(try Parser.load(Data(contentsOf: root.appendingPathComponent("ports-two-cables-recorded.plist"))))
let monitorCable = twoCables.first { $0.id == "Port-USB-C@1" }!
let ssdCable = twoCables.first { $0.id == "Port-USB-C@2" }!
check(monitorCable.transports.contains("DisplayPort") && ssdCable.transports.contains("USB3"), "Recorded monitor and SSD transports stay distinct")
check(monitorCable.capabilities.amps == 5 && monitorCable.capabilities.cableWatts == 100, "Actual 5 A / 20 V cable identity")
check(monitorCable.capabilities.speed == "USB Gen 2 · 10–20 Gbps", "USB signaling identity is not inferred Thunderbolt certification")
check(monitorCable.capabilities.profiles.count == 4 && monitorCable.capabilities.active?.watts == 90, "Actual monitor has four PD profiles and selected 90 W option")
check(ssdCable.capabilities.speed == nil && ssdCable.capabilities.amps == nil, "SSD USB3 transport does not fabricate an e-marker rating")
print("PASS: real two-cable recording preserves USB/DisplayPort links, 5 A / 100 W identity, 90 W monitor PD option and missing SSD cable identity")
let staleManufacturer = Parser.ports([["PortTypeDescription": "USB-C", "PortNumber": 2, "ConnectionActive": true, "SOPMfgString": "DJI", "SOPVID": Data([0, 0]), "SOPPID": Data([0, 0]), "SOP UVDM Update Count": 0]])[0]
check(staleManufacturer.device.contains("Not reported") && !staleManufacturer.report.contains("DJI"), "Suppress actual stale manufacturer pattern with zero vendor identity")
check(staleManufacturer.rawIdentity == ["SOP UVDM Update Count: 0"], "Keep connection counter while suppressing invalid legacy identity")
print("PASS: invalid legacy vendor identity does not mislabel a newly connected device")
let socketFixture = "p42\ncExample App\nf7\nPTCP\nn[::1]:5432\nTST=LISTEN\np99\ncBrowser\nf8\nPTCP\nn192.0.2.10:50000->198.51.100.1:443\nTST=ESTABLISHED\nf9\nPUDP\nn*:5353\n"
let socketRecords = NetworkSockets.parse(socketFixture)
check(socketRecords.count == 3, "Parse TCP and UDP socket fields")
check(socketRecords.first { $0.listening }?.local == "[::1]:5432", "Preserve IPv6 listening address")
check(socketRecords.first { $0.remote != nil }?.remote == "198.51.100.1:443", "Separate local and remote endpoints")
check(socketRecords.first { $0.transport == "UDP" }?.listening == false, "UDP bound socket is not a TCP listener")
check(Set(socketRecords.map(\.id)).count == 3, "Stable distinct socket identifiers")
check(NetworkSockets.parse("").isEmpty, "Empty socket capture is valid")
print("PASS: network sockets preserve owners, IPv6, TCP state, UDP binding and endpoints")
check(socketRecords.first { $0.listening }?.context == "This Mac only", "IPv6 loopback scope")
let wildcard = NetworkSockets.parse("p1\ncnode\nf1\nPTCP\nn*:7000\nTST=LISTEN\n")[0]
check(wildcard.context == "Node.js process · All interfaces", "Wildcard binding scope and process context")
let unnamed = NetworkSockets.parse("p1\ncOtherApp\nf1\nPTCP\nn127.0.0.1:5432\nTST=LISTEN\n")[0]
check(unnamed.context == "This Mac only", "Port number does not invent database service")
print("PASS: network context distinguishes binding scopes without guessing services from ports")
let dualStack = NetworkSockets.parse("p5\ncControlCenter\nf3\ntIPv4\nPTCP\nn*:5000\nTST=LISTEN\nf4\ntIPv6\nPTCP\nn*:5000\nTST=LISTEN\nf5\ntIPv4\nPTCP\nn*:7000\nTST=LISTEN\np6\ncHelper\nf1\ntIPv4\nPUDP\nn*:5353\np7\ncHelper\nf1\ntIPv4\nPUDP\nn*:5353\nf2\ntIPv4\nPUDP\nn*:*\n")
let dualGroups = NetworkSockets.grouped(dualStack)
check(dualGroups.count == 2 && dualGroups[0].process == "ControlCenter", "Group sockets by process name")
check(dualGroups[0].entries.count == 2 && dualGroups[0].entries[0].families == ["IPv4", "IPv6"] && dualGroups[0].entries[0].sample.localPort == "5000", "Merge IPv4 and IPv6 bindings of the same port, sorted by port")
check(dualGroups[1].pids == [6, 7] && dualGroups[1].entries.first { $0.local == "*:5353" }?.count == 2, "Merge identical sockets across helper processes")
check(!dualStack.contains { $0.local == "*:*" && $0.udpBound } && dualStack.filter(\.udpBound).count == 2, "Unbound UDP sockets have no port to show")
check(NetworkSockets.split("[fe80:17::1]:1024") == ("fe80:17::1", "1024") && NetworkSockets.split("*:7000") == ("*", "7000"), "Split IPv6 and wildcard endpoints")
check(NetworkSockets.addressClass("192.168.2.1") == "Local network" && NetworkSockets.addressClass("172.20.0.4") == "Local network" && NetworkSockets.addressClass("172.32.0.4") == "Public address", "Classify private IPv4 ranges")
check(NetworkSockets.addressClass("fe80:17::1") == "Local network" && NetworkSockets.addressClass("::1") == "This Mac" && NetworkSockets.addressClass("2003:c8::1") == "Public address" && NetworkSockets.addressClass("::ffff:10.0.0.1") == "Local network", "Classify IPv6 and mapped addresses")
print("PASS: socket groups merge address families and helper duplicates; endpoints split and classify without lookups")
let loopbackPair = NetworkSockets.grouped(NetworkSockets.parse("p8\ncpostgres\nf1\ntIPv4\nPTCP\nn127.0.0.1:5432\nTST=LISTEN\nf2\ntIPv6\nPTCP\nn[::1]:5432\nTST=LISTEN\n"))
check(loopbackPair[0].entries.count == 1 && loopbackPair[0].entries[0].families == ["IPv4", "IPv6"] && loopbackPair[0].entries[0].duplicates == 1, "IPv4 and IPv6 loopback listeners on one port appear once")
check(dualGroups[1].entries.first { $0.local == "*:5353" }?.duplicates == 2, "Helper duplicates are counted beyond address families")
print("PASS: loopback listeners merge across address families; duplicate counts exclude family pairs")
let liveAdapter: [String: Any] = ["ExternalConnected": true, "IsCharging": true, "PowerTelemetryData": ["SystemPowerIn": 33992],
    "AdapterDetails": ["Name": "35W USB-C Power Adapter ", "Manufacturer": "Apple Inc.", "Watts": 35, "AdapterVoltage": 20000, "Current": 1740, "Model": "0x701B", "FwVersion": "01070076", "IsWireless": false, "SerialString": "redacted"]]
let adapterSnapshot = PowerSnapshot(liveAdapter)
check(adapterSnapshot.adapter?.name == "35W USB-C Power Adapter" && adapterSnapshot.adapter?.watts == 35 && adapterSnapshot.adapter?.volts == 20 && adapterSnapshot.adapter?.amps == 1.74, "Recorded adapter name, rating and contract")
check(adapterSnapshot.charging == true && adapterSnapshot.adapter?.manufacturer == "Apple Inc." && adapterSnapshot.adapter?.firmware == "01070076", "Adapter manufacturer, firmware and charging state")
check(PowerSnapshot(["ExternalConnected": true, "AdapterDetails": ["FamilyCode": 0]]).adapter == nil && PowerSnapshot(["ExternalConnected": false, "AdapterDetails": liveAdapter["AdapterDetails"]!]).adapter == nil, "No adapter without identity or external power")
print("PASS: power adapter identity parses from recorded AdapterDetails; empty or disconnected adapters stay hidden")
check(dualGroups[1].entries.first { $0.local == "*:5353" }?.pids == [6, 7] && dualGroups[0].entries[0].pids == [5], "Merged rows keep every owning process")
print("PASS: merged socket rows list all owning process IDs")
