import SwiftUI
import Charts
import Combine
import Darwin
import SystemConfiguration
import StrandCore

struct NetworkInterface: Identifiable {
    let id: String
    var addresses: [String] = []
    /// Prefix length per address, from the interface netmask.
    var prefixes: [String: Int] = [:]
    var received: UInt64 = 0
    var sent: UInt64 = 0
    var up = false
    var displayName: String?
    var hardwareType: String?
    var linkActive = false
    var hardwareAddress: String?
    /// Bits per second reported by the driver. Only meaningful for wired links; Wi-Fi reports an unrelated base rate.
    var linkSpeed: UInt64 = 0
    var mtu = 0
    var router: String?
    var dns: [String] = []
    var ethernetCable: Bool { wired && linkActive && !(displayName ?? "").localizedCaseInsensitiveContains("Thunderbolt") && !(displayName ?? "").localizedCaseInsensitiveContains("iPhone") }
    var wired: Bool { hardwareType == "Ethernet" && !id.hasPrefix("bridge") }
    var countsInTotal: Bool { wired || hardwareType == "IEEE80211" }
    var kind: String {
        if id == "lo0" { return "Loopback" }
        if id == "awdl0" { return "Peer-to-peer Wi-Fi" }
        if id == "llw0" { return "Low-latency Wi-Fi" }
        if id.hasPrefix("utun") || id.hasPrefix("ipsec") { return "Tunnel" }
        if id.hasPrefix("bridge") { return "Bridge" }
        if hardwareType == "IEEE80211" { return "Wi-Fi" }
        if hardwareType == "Ethernet" { return "Ethernet" }
        return hardwareType ?? "Network interface"
    }
    var status: String { wired ? (linkActive ? "Link active" : "No link") : linkActive ? "Active" : up ? "Up" : "Down" }
    var context: String {
        if id == "awdl0" { return "Apple peer-to-peer Wi-Fi" }
        if id == "llw0" { return "Low-latency Wi-Fi interface" }
        if id == "lo0" { return "Within this Mac" }
        if id.hasPrefix("utun") { return "Virtual network tunnel" }
        return displayName == nil ? "Network interface" : "\(displayName!) · \(id)"
    }
    var explanation: String {
        if id == "awdl0" { return "Apple Wireless Direct Link is a peer-to-peer interface used by features such as AirDrop. Being active does not mean a transfer is happening." }
        if id == "lo0" { return "Loopback carries communication between apps on this Mac; traffic stays on the Mac." }
        if id.hasPrefix("utun") { return "A virtual tunnel managed by macOS or networking software. This interface alone does not identify its owning app or prove a VPN is connected." }
        if id == "llw0" { return "A system-managed low-latency wireless interface. Active is an interface flag, not proof of an ongoing transfer." }
        return "The name is reported by macOS. Primary means the interface macOS reports as its main IPv4 route; other routes may use different interfaces."
    }
    var name: String { displayName ?? (id == "lo0" ? "Loopback" : id.hasPrefix("utun") ? "Tunnel " + id.dropFirst(4) : id == "awdl0" ? "AWDL" : id == "llw0" ? "Low-latency WLAN" : id) }
    /// The address most useful for recognising the interface: IPv4 first, then a routable IPv6 address.
    var mainAddress: String? { addresses.first { !$0.contains(":") } ?? addresses.first { !NetworkInterface.linkLocal($0) } }
    static func linkLocal(_ address: String) -> Bool { address.lowercased().hasPrefix("fe80") || address.hasPrefix("169.254.") }
    static func addressLabel(_ address: String) -> String {
        if !address.contains(":") { return linkLocal(address) ? "IPv4 · Link-local" : "IPv4" }
        if linkLocal(address) { return "IPv6 · Link-local" }
        if address.lowercased().hasPrefix("fc") || address.lowercased().hasPrefix("fd") { return "IPv6 · Unique local" }
        return "IPv6"
    }
    static func speed(_ bits: UInt64) -> String {
        bits >= 1_000_000_000 ? number(Double(bits) / 1_000_000_000) + " Gbps" : number(Double(bits) / 1_000_000) + " Mbps"
    }
}

extension ConnectionItem {
    /// An Ethernet adapter with an active link. The speed is what the link negotiated, not a cable category or rating.
    static func ethernet(_ interface: NetworkInterface) -> ConnectionItem {
        let speed = interface.linkSpeed > 0 ? NetworkInterface.speed(interface.linkSpeed) : nil
        let facts = [speed.map { CableFact(name: "Link speed", value: $0) }, CableFact(name: "Interface", value: interface.id)].compactMap { $0 }
        return ConnectionItem(id: "ethernet:" + interface.id, name: "Ethernet cable", port: interface.name + " · " + interface.id, kind: "ethernet",
                              chip: speed.map { $0 + " link" } ?? "Link active", verdict: "Connected", link: "Ethernet", facts: facts,
                              details: (facts.map { $0.name + ": " + $0.value } + ["Link: Active"]).joined(separator: "\n"), adapter: interface.displayName)
    }
}

@MainActor final class NetworkModel: ObservableObject {
    static let shared = NetworkModel()
    @Published var interfaces: [NetworkInterface] = []
    @Published var sockets: [NetworkSocket] = []
    @Published var selected: String?
    @Published var primary: String?
    @Published var downloads: [String: UsageHistory] = [:]
    @Published var uploads: [String: UsageHistory] = [:]
    @Published var error: String?
    @Published var totalReceived = UsageHistory()
    @Published var totalSent = UsageHistory()
    /// Time of the last socket listing, nil until one has been read.
    @Published var updated: Date?
    /// Listing sockets spawns lsof, so it runs only while a network view is on screen. Interfaces are always read for Ethernet cables.
    var socketDemand = 0
    private var pending = false
    private var previous: [String: NetworkInterface] = [:]
    private var previousTime: TimeInterval?
    private var reading = false
    private let queue = DispatchQueue(label: "com.opyuii.strand.network", qos: .utility)
    private var timer: AnyCancellable?
    private var interval: TimeInterval = 0
    private var defaultsObserver: NSObjectProtocol?
    private var windowObserver: NSObjectProtocol?
    private var linkWatcher: SCDynamicStore?
    private var lastRead = Date.distantPast
    /// With no Strand window on screen nothing shows traffic, so interfaces are read this often instead of every
    /// few seconds. Cables and addresses still update at once through the link watcher.
    private static let idleInterval: TimeInterval = 15
    init() {
        schedule()
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule() }
        }
        // Catch up as soon as the window comes back instead of waiting for the next tick.
        windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Self.windowShowing, Date().timeIntervalSince(self.lastRead) >= self.interval else { return }
                self.refresh()
            }
        }
        watchLinks()
    }
    private static var windowShowing: Bool {
        NSApp.windows.contains { $0.title == "Strand" && $0.isVisible && $0.occlusionState.contains(.visible) }
    }
    private func tick() {
        guard Self.windowShowing || Date().timeIntervalSince(lastRead) >= Self.idleInterval else { return }
        refresh()
    }
    /// configd reports link, address and interface-list changes, so plugging in an Ethernet cable shows up without polling.
    private func watchLinks() {
        var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            let model = Unmanaged<NetworkModel>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { model.refresh() }
        }
        guard let store = SCDynamicStoreCreate(nil, "Strand links" as CFString, callback, &context) else { return }
        let patterns = ["State:/Network/Interface/[^/]+/Link", "State:/Network/Interface/[^/]+/IPv4", "State:/Network/Interface/[^/]+/IPv6"]
        SCDynamicStoreSetNotificationKeys(store, ["State:/Network/Interface"] as CFArray, patterns as CFArray)
        SCDynamicStoreSetDispatchQueue(store, .main)
        linkWatcher = store
    }
    /// Restarts the refresh timer when the interval setting changes.
    private func schedule() {
        let value = Setting.refreshInterval
        guard value != interval else { return }
        interval = value
        timer = Timer.publish(every: value, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.tick() }
    }
    func refresh() {
        guard !reading else { pending = true; return }; reading = true
        lastRead = Date()
        let wantsSockets = socketDemand > 0
        queue.async { [weak self] in
            let interfaces = Self.readInterfaces()
            let store = SCDynamicStoreCreate(nil, "Strand" as CFString, nil, nil)
            let global = store.flatMap { SCDynamicStoreCopyValue($0, "State:/Network/Global/IPv4" as CFString) as? [String: Any] }
            let primary = global?["PrimaryInterface"] as? String
            let result: Result<[NetworkSocket], Error>? = !wantsSockets ? nil : Result {
                let process = Process(), output = Pipe(), errors = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
                process.arguments = ["-nP", "-iTCP", "-iUDP", "-FpcnPTt"]
                process.standardOutput = output; process.standardError = errors
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 || process.terminationStatus == 1 else { throw NSError(domain: "Network", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "macOS could not read socket information."]) }
                return NetworkSockets.parse(String(decoding: data, as: UTF8.self))
            }
            DispatchQueue.main.async {
                guard let self else { return }; self.reading = false
                let now = Date().timeIntervalSince1970
                if let time = self.previousTime, now > time, now - time < 10 {
                    var received = 0.0, sent = 0.0, samples = 0
                    for interface in interfaces {
                        guard let old = self.previous[interface.id], interface.received >= old.received, interface.sent >= old.sent else {
                            self.downloads[interface.id] = nil; self.uploads[interface.id] = nil; continue
                        }
                        self.downloads[interface.id, default: UsageHistory()].append(Double(interface.received - old.received) / (now - time), at: now)
                        self.uploads[interface.id, default: UsageHistory()].append(Double(interface.sent - old.sent) / (now - time), at: now)
                        if interface.countsInTotal && interface.up {
                            received += Double(interface.received - old.received) / (now - time)
                            sent += Double(interface.sent - old.sent) / (now - time)
                            samples += 1
                        }
                    }
                    if samples > 0 { self.totalReceived.append(received, at: now); self.totalSent.append(sent, at: now) }
                    else { self.totalReceived = UsageHistory(); self.totalSent = UsageHistory() }
                }
                if self.previousTime.map({ now - $0 >= 10 }) == true { self.downloads = [:]; self.uploads = [:]; self.totalReceived = UsageHistory(); self.totalSent = UsageHistory() }
                let ids = Set(interfaces.map(\.id))
                self.downloads = self.downloads.filter { ids.contains($0.key) }
                self.uploads = self.uploads.filter { ids.contains($0.key) }
                self.previous = Dictionary(uniqueKeysWithValues: interfaces.map { ($0.id, $0) })
                self.previousTime = now; self.interfaces = interfaces; self.primary = primary
                if !interfaces.contains(where: { $0.id == self.selected }) { self.selected = primary ?? interfaces.first?.id }
                switch result {
                case .success(let sockets): self.sockets = sockets; self.error = nil; self.updated = Date()
                case .failure(let error): self.sockets = []; self.error = error.localizedDescription; self.updated = Date()
                case nil: break
                }
                if self.pending { self.pending = false; self.refresh() }
            }
        }
    }
    nonisolated static func readInterfaces() -> [NetworkInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        let allInterfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        var known = allInterfaces.reduce(into: [String: String]()) { names, interface in
            if let id = SCNetworkInterfaceGetBSDName(interface) as String?, let name = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? { names[id] = name }
        }
        if let preferences = SCPreferencesCreate(nil, "Strand" as CFString, nil), let services = SCNetworkServiceCopyAll(preferences) as? [SCNetworkService] {
            for service in services {
                if let interface = SCNetworkServiceGetInterface(service), let id = SCNetworkInterfaceGetBSDName(interface) as String?, let name = SCNetworkServiceGetName(service) as String? { known[id] = name }
            }
        }
        let kinds = allInterfaces.reduce(into: [String: String]()) { types, interface in
            if let id = SCNetworkInterfaceGetBSDName(interface) as String?, let type = SCNetworkInterfaceGetInterfaceType(interface) as String? { types[id] = type }
        }
        let store = SCDynamicStoreCreate(nil, "Strand" as CFString, nil, nil)
        // Router and DNS servers belong to network services; map them to interfaces through each service's IPv4 state.
        var routers: [String: String] = [:], resolvers: [String: [String]] = [:]
        if let store, let state = SCDynamicStoreCopyMultiple(store, nil, ["State:/Network/Service/.*/IPv4", "State:/Network/Service/.*/DNS"] as CFArray) as? [String: Any] {
            var serviceInterface: [String: String] = [:]
            for (key, value) in state where key.hasSuffix("/IPv4") {
                guard let value = value as? [String: Any], let name = value["InterfaceName"] as? String else { continue }
                serviceInterface[String(key.dropLast(5))] = name
                routers[name] = value["Router"] as? String
            }
            for (key, value) in state where key.hasSuffix("/DNS") {
                if let name = serviceInterface[String(key.dropLast(4))], let servers = (value as? [String: Any])?["ServerAddresses"] as? [String] { resolvers[name] = servers }
            }
        }
        var interfaces: [String: NetworkInterface] = [:]
        var cursor = head
        while let pointer = cursor {
            let value = pointer.pointee; cursor = value.ifa_next
            guard let address = value.ifa_addr else { continue }
            let name = String(cString: value.ifa_name)
            var interface = interfaces[name] ?? NetworkInterface(id: name)
            interface.displayName = known[name]
            interface.hardwareType = kinds[name]
            interface.router = routers[name]
            interface.dns = resolvers[name] ?? []
            if let store, let link = SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(name)/Link" as CFString) as? [String: Any] { interface.linkActive = link["Active"] as? Bool == true }
            interface.up = value.ifa_flags & UInt32(IFF_UP) != 0
            let family = Int32(address.pointee.sa_family)
            if family == AF_INET || family == AF_INET6 {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                    // The %interface scope suffix repeats the interface name.
                    let text = String(String(cString: buffer).split(separator: "%", maxSplits: 1)[0])
                    interface.addresses.append(text)
                    if let mask = value.ifa_netmask { interface.prefixes[text] = prefixLength(mask, family: family) }
                }
            } else if family == AF_LINK, let data = value.ifa_data {
                // 32-bit fallback; replaced below by 64-bit counters when available.
                let counters = data.assumingMemoryBound(to: if_data.self).pointee
                interface.received = UInt64(counters.ifi_ibytes); interface.sent = UInt64(counters.ifi_obytes)
                interface.hardwareAddress = hardwareAddress(address)
            }
            interfaces[name] = interface
        }
        return interfaces.values.filter { ($0.up && !$0.addresses.isEmpty) || $0.wired }.map { interface in
            var interface = interface
            if let counters = counters(interface.id) {
                interface.received = counters.ifi_ibytes; interface.sent = counters.ifi_obytes
                interface.linkSpeed = counters.ifi_baudrate; interface.mtu = Int(counters.ifi_mtu)
            }
            return interface
        }.sorted { $0.id < $1.id }
    }
    /// getifaddrs only exposes 32-bit byte counters, which wrap every 4 GB. The interface MIB has 64-bit ones.
    nonisolated static func counters(_ name: String) -> if_data64? {
        let index = if_nametoindex(name)
        guard index != 0 else { return nil }
        var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, Int32(index), IFDATA_GENERAL]
        var data = ifmibdata(), length = MemoryLayout<ifmibdata>.size
        guard sysctl(&mib, u_int(mib.count), &data, &length, nil, 0) == 0 else { return nil }
        return data.ifmd_data
    }
    /// Netmask sockaddrs can be shorter than their full struct, so only the reported length is read.
    nonisolated static func prefixLength(_ mask: UnsafeMutablePointer<sockaddr>, family: Int32) -> Int {
        let raw = UnsafeRawPointer(mask), length = Int(mask.pointee.sa_len)
        let bytes = family == AF_INET ? 4..<8 : 8..<24
        guard length > bytes.lowerBound else { return 0 }
        return (bytes.lowerBound..<min(bytes.upperBound, length)).reduce(0) { $0 + raw.load(fromByteOffset: $1, as: UInt8.self).nonzeroBitCount }
    }
    nonisolated static func hardwareAddress(_ address: UnsafeMutablePointer<sockaddr>) -> String? {
        address.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { link in
            guard link.pointee.sdl_alen == 6 else { return nil }
            let offset = (MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data) ?? 8) + Int(link.pointee.sdl_nlen)
            let bytes = (0..<6).map { UnsafeRawPointer(link).load(fromByteOffset: offset + $0, as: UInt8.self) }
            // macOS returns 02:00:00:00:00:00 instead of the Wi-Fi address to apps without location access.
            return bytes.dropFirst().allSatisfy({ $0 == 0 }) ? nil : bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
        }
    }
}

struct ModeSwitch: View {
    @AppStorage("strand.mode") private var mode = "cables"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered: String?
    @Namespace private var selection
    var body: some View {
        HStack(spacing: 2) {
            ForEach(["cables", "network"], id: \.self) { value in
                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.85)) { mode = value }
                } label: {
                    Text(value == "cables" ? "Cables" : "Network").font(Style.caption)
                        .padding(.horizontal, 13).frame(height: 28)
                        .foregroundStyle(mode == value || hovered == value ? Color.primary : Color.secondary)
                        .background {
                            if mode == value { Capsule().fill(Color.primary.opacity(0.14)).matchedGeometryEffect(id: "mode", in: selection) }
                            else if hovered == value { Capsule().fill(Color.primary.opacity(0.07)) }
                        }
                        .contentShape(Capsule())
                        .onHover { hovered = $0 ? value : nil }
                }.buttonStyle(.plain).accessibilityLabel(value == "cables" ? "Cables" : "Network").accessibilityAddTraits(mode == value ? .isSelected : [])
            }
        }.padding(3).background(Capsule().fill(Color.primary.opacity(0.07)))
    }
}

struct Inspector: View {
    @ObservedObject var model: Model
    @ObservedObject var updates: Updates
    @AppStorage("strand.mode") private var mode = "cables"
    @AppStorage(Setting.startMode) private var startMode = "last"
    var body: some View {
        ZStack(alignment: .topLeading) {
            if mode == "network" { NetworkInspector(model: model, updates: updates) }
            else { CableInspector(model: model, updates: updates) }
            ModeSwitch().frame(width: 320).padding(.top, 14)
        }.ignoresSafeArea(.container, edges: .top)
            .onAppear { if startMode != "last" { mode = startMode } }
    }
}

struct Panel: View {
    @ObservedObject var model: Model
    @ObservedObject var updates: Updates
    @AppStorage("strand.mode") private var mode = "cables"
    @ObservedObject private var network = NetworkModel.shared
    var body: some View {
        VStack(spacing: 8) {
            ModeSwitch().padding(.top, 10)
            if mode == "cables" { CablePanel(model: model, updates: updates) }
            else {
                NetworkMiniMap(network: network).padding(14).frame(width: 360)
                    .onAppear { network.socketDemand += 1; network.refresh() }
                    .onDisappear { network.socketDemand -= 1 }
            }
        }.background(MenuPanelBackground())
    }
}

struct NetworkInspector: View {
    @ObservedObject var model: Model
    @ObservedObject var updates: Updates
    @ObservedObject private var network = NetworkModel.shared
    /// `--network-section <id>` opens a section directly for previews and snapshots.
    @State private var section = CommandLine.arguments.firstIndex(of: "--network-section").flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil } ?? "dashboard"
    @State private var search = ""
    @State private var physicalExpanded = false
    @State private var virtualExpanded = false
    @State private var expandedGroups: Set<String> = []
    @AppStorage(Setting.trafficBits) private var trafficBits = false
    @AppStorage(Setting.hideLoopback) private var hideLoopback = false
    private let groupPreview = 5
    var body: some View {
        ZStack(alignment: .topTrailing) {
            HStack(spacing: 0) {
                ScrollView { navigation.padding(12).padding(.top, 48) }.scrollIndicators(.never).frame(width: 320)
                ScrollView {
                    if model.showingSettings { Preferences(model: model, updates: updates).padding(.top, 42) }
                    else { content.padding(28).padding(.top, 35) }
                }.scrollIndicators(.never).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 8) {
                InfoHint(text: "Information about this Mac. No network scanning or packet capture. Strand changes nothing unless you choose Quit or Force Quit in a port or connection’s context menu, which ends the owning process after you confirm. Process visibility depends on macOS permissions. Listening means a local socket is waiting; it does not prove the port is reachable through your firewall. Interface traffic includes local and tunnel traffic and is not attributed to individual apps.", prominent: true)
                RoundIconButton(systemImage: "arrow.clockwise", label: "Refresh") { network.refresh() }
                RoundIconButton(systemImage: "gearshape", label: "Settings") { model.showingSettings.toggle() }
            }.padding(.top, 14).padding(.trailing, 16)
            RoundIconButton(systemImage: "xmark", label: "Close") { (NSApp.keyWindow ?? NSApp.mainWindow)?.performClose(nil) }.padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.ignoresSafeArea(.container, edges: .top).background(WindowBackground(color: .accentColor)).frame(minWidth: 800, maxWidth: 1100, minHeight: 600, maxHeight: 900)
            .onAppear { network.socketDemand += 1; network.refresh() }
            .onDisappear { network.socketDemand -= 1 }
            .onChange(of: search) { _, value in
                if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    physicalExpanded = true; virtualExpanded = true; model.showingSettings = false
                    showSearchResult()
                }
            }
    }

    // MARK: Data

    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    func matches(_ text: String) -> Bool { query.isEmpty || text.localizedCaseInsensitiveContains(query) }
    func interfaceSearch(_ interface: NetworkInterface) -> String {
        let category = interface.countsInTotal ? "physical hardware " + (interface.wired ? "ethernet wired usb hotspot" : "wireless wifi") : "virtual"
        let fields: [String] = [interface.name, interface.id, interface.context, interface.kind, interface.hardwareAddress ?? "", interface.router ?? "", category]
        return (fields + interface.addresses).joined(separator: " ")
    }
    func socketSearch(_ socket: NetworkSocket) -> String {
        [socket.process, socket.local, socket.remote ?? "", socket.context, socket.destination ?? "", socket.transport, socket.state, socket.family].joined(separator: " ")
    }
    /// A section title match shows the whole list; otherwise only matching sockets remain.
    func visible(_ sockets: [NetworkSocket], title: String) -> [NetworkSocket] {
        matches(title) ? sockets : sockets.filter { matches(socketSearch($0)) }
    }
    private var listeners: [NetworkSocket] { network.sockets.filter(\.listening) }
    private var udpSockets: [NetworkSocket] { network.sockets.filter(\.udpBound) }
    private var connections: [NetworkSocket] { network.sockets.filter { $0.remote != nil && !(hideLoopback && $0.destination == "This Mac") } }
    private func entryCount(_ sockets: [NetworkSocket]) -> Int { NetworkSockets.grouped(sockets).reduce(0) { $0 + $1.entries.count } }
    private var activeHardware: [NetworkInterface] { network.interfaces.filter { $0.countsInTotal && $0.up && !$0.addresses.isEmpty } }

    func showSearchResult() {
        if let current = network.interfaces.first(where: { $0.id == network.selected }), section == "interfaces", matches(interfaceSearch(current)) { return }
        if let interface = network.interfaces.first(where: { matches(interfaceSearch($0)) }) { network.selected = interface.id; section = "interfaces"; return }
        if let socket = network.sockets.first(where: { ($0.listening || $0.udpBound || $0.remote != nil) && matches(socketSearch($0)) }) { section = socket.remote == nil ? "ports" : "connections"; return }
        if matches("Listening ports UDP sockets") { section = "ports" }
        else if matches("Connections") { section = "connections" }
        else if matches("Dashboard total network traffic received sent") { section = "dashboard" }
        else { section = "search" }
    }
    func highlighted(_ value: String) -> Text {
        let result = NSMutableAttributedString(string: value)
        if !query.isEmpty, let expression = try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: query), options: .caseInsensitive) {
            for match in expression.matches(in: value, range: NSRange(value.startIndex..., in: value)) {
                result.addAttributes([.backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.28), .foregroundColor: NSColor.labelColor], range: match.range)
            }
        }
        return Text(AttributedString(result))
    }

    // MARK: Sidebar

    var navigation: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search apps, ports, addresses", text: $search).textFieldStyle(.plain).font(Style.body)
                if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).accessibilityLabel("Clear search") }
            }.padding(10).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12)).padding(.bottom, 4)
            if matches("Dashboard total network traffic received sent") { sidebar("Dashboard", icon: "chart.xyaxis.line", id: "dashboard", count: nil) }
            let ports = visible(listeners, title: "Listening ports"), udp = visible(udpSockets, title: "Listening ports UDP sockets")
            if !ports.isEmpty || !udp.isEmpty || matches("Listening ports") { sidebar("Listening ports", icon: "dot.radiowaves.left.and.right", id: "ports", count: entryCount(ports)) }
            let remote = visible(connections, title: "Connections")
            if !remote.isEmpty || matches("Connections") { sidebar("Connections", icon: "point.3.connected.trianglepath.dotted", id: "connections", count: entryCount(remote)) }
            let hardware = network.interfaces.filter { $0.countsInTotal && matches(interfaceSearch($0)) }
            let virtual = network.interfaces.filter { !$0.countsInTotal && matches(interfaceSearch($0)) }
            DisclosureGroup(isExpanded: $physicalExpanded) {
                if hardware.isEmpty { Text(search.isEmpty ? "No hardware interfaces reported" : "No matching hardware interfaces").font(Style.caption).foregroundStyle(.secondary).padding(12) }
                ForEach(hardware) { interface in interfaceRow(interface) }
            } label: { groupLabel("Physical", icon: "cable.connector", count: hardware.count) }.disclosureGroupStyle(PhysicalDisclosureStyle()).padding(.top, 6)
            DisclosureGroup(isExpanded: $virtualExpanded) {
                if virtual.isEmpty { Text("No matching virtual interfaces").font(Style.caption).foregroundStyle(.secondary).padding(12) }
                ForEach(virtual) { interface in interfaceRow(interface) }
            } label: { groupLabel("Virtual", icon: "square.stack.3d.up", count: virtual.count) }.disclosureGroupStyle(PhysicalDisclosureStyle())
        }
    }
    func groupLabel(_ title: String, icon: String, count: Int) -> some View {
        HStack(spacing: 8) { Label(title, systemImage: icon).font(Style.title); Spacer(); Text(String(count)).font(Style.caption).monospacedDigit().foregroundStyle(.secondary) }
    }
    func interfaceRow(_ interface: NetworkInterface) -> some View {
        Button { network.selected = interface.id; section = "interfaces"; model.showingSettings = false } label: {
            HStack(spacing: 12) {
                Image(systemName: icon(interface)).foregroundStyle(Color.accentColor).frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(interface.name).font(Style.title).lineLimit(1)
                    Text(interfaceCaption(interface)).font(Style.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 9).contentShape(Rectangle())
                .background(section == "interfaces" && network.selected == interface.id ? Color.primary.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: Style.radius))
        }.buttonStyle(.plain).accessibilityLabel("\(interface.name), \(interfaceCaption(interface))")
    }
    func icon(_ interface: NetworkInterface) -> String {
        interface.wired ? "cable.connector" : interface.hardwareType == "IEEE80211" ? "wifi" : interface.id == "lo0" ? "arrow.triangle.2.circlepath" : interface.id.hasPrefix("utun") ? "lock.shield" : "network"
    }
    /// Interface ID plus what tells similar interfaces apart: link state for wired ports, otherwise the main address.
    func interfaceCaption(_ interface: NetworkInterface) -> String {
        let detail = interface.wired && !interface.linkActive ? "No link" : interface.mainAddress ?? (interface.addresses.isEmpty ? nil : "Link-local only")
        return [interface.id == network.primary ? "Primary" : nil, interface.id, detail].compactMap { $0 }.joined(separator: " · ")
    }
    func sidebar(_ name: String, icon: String, id: String, count: Int?) -> some View {
        Button { section = id; model.showingSettings = false } label: {
            HStack(spacing: 8) {
                Label(name, systemImage: icon).font(Style.title)
                Spacer()
                if let count, network.updated != nil { Text(String(count)).font(Style.caption).monospacedDigit().foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12).contentShape(Rectangle()).background(section == id ? Color.primary.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: Style.radius))
        }.buttonStyle(.plain)
    }

    // MARK: Pages

    @ViewBuilder var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let error = network.error { Text(error).font(Style.body) }
            switch section {
            case "search": Text("No matching network items").font(Style.heading).foregroundStyle(.secondary)
            case "dashboard": dashboard
            case "interfaces":
                if let interface = network.interfaces.first(where: { $0.id == network.selected }) { interfaceDetail(interface) }
                else { Text("Select an interface").font(Style.heading).foregroundStyle(.secondary) }
            case "ports": portsPage
            default: connectionsPage
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    func pageHeader(_ title: String, summary: String, info: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Style.hero)
            HStack(spacing: 6) { Text(summary).font(Style.caption).foregroundStyle(.secondary); InfoHint(text: info) }
        }
    }
    func summary(_ count: Int, _ noun: String, groups: Int) -> String {
        network.updated == nil ? "Reading network…" : "\(count) \(noun)\(count == 1 ? "" : "s") · \(groups) app\(groups == 1 ? "" : "s") · This Mac"
    }

    var portsPage: some View {
        let tcp = NetworkSockets.grouped(visible(listeners, title: "Listening ports"))
        let udp = NetworkSockets.grouped(visible(udpSockets, title: "Listening ports UDP sockets"))
        return VStack(alignment: .leading, spacing: 14) {
            pageHeader("Listening ports", summary: summary(tcp.reduce(0) { $0 + $1.entries.count }, "TCP port", groups: tcp.count),
                       info: "TCP sockets in the LISTEN state, grouped by process name. IPv4 and IPv6 bindings of the same port appear once. All interfaces means the socket accepts connections on every address of this Mac; firewall rules and routing still decide whether anything can reach it. Strand does not identify a service from its port number.")
            if tcp.isEmpty { Text(network.updated == nil ? "Reading network…" : "No listening TCP ports").font(Style.body).foregroundStyle(.secondary) }
            ForEach(tcp) { group in groupCard(group, connections: false) }
            if !udp.isEmpty {
                HStack(spacing: 6) {
                    Text("UDP sockets").font(Style.heading)
                    InfoHint(text: "UDP has no listening state. These sockets are bound to a local port without a fixed peer and can receive datagrams; that does not prove they are reachable. Sockets without a bound port are hidden.")
                    Spacer()
                    Text("\(udp.reduce(0) { $0 + $1.entries.count }) ports").font(Style.caption).foregroundStyle(.secondary)
                }.padding(.top, 10)
                ForEach(udp) { group in groupCard(group, connections: false) }
            }
        }
    }
    var connectionsPage: some View {
        let groups = NetworkSockets.grouped(visible(connections, title: "Connections"), byCount: true)
        return VStack(alignment: .leading, spacing: 14) {
            pageHeader("Connections", summary: summary(groups.reduce(0) { $0 + $1.entries.count }, "connection", groups: groups.count),
                       info: "Sockets with a remote endpoint, grouped by process name and sorted by count. Local network covers private and link-local address ranges; Public address is any other remote address, which may still be a VPN or proxy. Addresses are not resolved to host names and traffic is not inspected.")
            if groups.isEmpty { Text(network.updated == nil ? "Reading network…" : "No visible connections").font(Style.body).foregroundStyle(.secondary) }
            ForEach(groups) { group in groupCard(group, connections: true) }
        }
    }

    func groupCard(_ group: SocketGroup, connections: Bool) -> some View {
        let expanded = expandedGroups.contains(group.id) || !query.isEmpty
        let shown = expanded ? group.entries : Array(group.entries.prefix(groupPreview))
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                highlighted(group.process).font(Style.title).lineLimit(1)
                if let role = group.role { Text(role).font(Style.caption).foregroundStyle(.secondary).lineLimit(1) }
                Spacer(minLength: 8)
                Text(group.pids.count == 1 ? "PID " + String(group.pids[0]) : String(group.pids.count) + " processes").font(Style.caption).monospacedDigit().foregroundStyle(.tertiary)
                    .help(group.pids.map(String.init).joined(separator: ", "))
            }.padding(.bottom, 6)
            ForEach(shown) { entry in
                Divider().opacity(0.6)
                (connections ? AnyView(connectionRow(entry)) : AnyView(portRow(entry)))
                    .contextMenu {
                        Button("Copy local endpoint") { copy(entry.local) }
                        if let remote = entry.remote { Button("Copy remote endpoint") { copy(remote) } }
                        Button("Copy process name") { copy(group.process) }
                        Divider()
                        Button("Quit \(group.process)…") { quit(group.process, pids: entry.pids, force: false) }
                        Button("Force Quit \(group.process)…", role: .destructive) { quit(group.process, pids: entry.pids, force: true) }
                    }
            }
            if group.entries.count > groupPreview && query.isEmpty {
                Divider().opacity(0.6)
                Button {
                    if expanded { expandedGroups.remove(group.id) } else { expandedGroups.insert(group.id) }
                } label: {
                    Text(expanded ? "Show fewer" : "Show \(group.entries.count - groupPreview) more").font(Style.caption).foregroundStyle(Color.accentColor).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }.padding(.horizontal, 16).padding(.vertical, 12).modifier(Surface(radius: Style.radius))
    }
    func portRow(_ entry: SocketEntry) -> some View {
        let socket = entry.sample
        return HStack(spacing: 12) {
            highlighted(socket.localPort).font(Style.title).monospacedDigit().frame(minWidth: 62, alignment: .leading)
            highlighted(socket.scope == "Specific interface" ? socket.localHost : socket.scope).font(Style.body).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if entry.duplicates > 1 { Text("×" + String(entry.duplicates)).font(Style.caption).monospacedDigit().foregroundStyle(.tertiary) }
            if !entry.families.isEmpty { tag(entry.families.joined(separator: " + ")) }
            tag(entry.transport)
        }.padding(.vertical, 8).accessibilityElement(children: .ignore)
            .accessibilityLabel("\(entry.transport) port \(socket.localPort), \(socket.scope == "Specific interface" ? socket.localHost : socket.scope), \(entry.families.joined(separator: " and "))")
    }
    func connectionRow(_ entry: SocketEntry) -> some View {
        let socket = entry.sample
        let established = entry.state == "ESTABLISHED"
        return HStack(spacing: 12) {
            Circle().fill(established ? Color.green : Color.secondary.opacity(0.5)).frame(width: 7, height: 7).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                highlighted(entry.remote ?? "").font(Style.body).monospacedDigit().lineLimit(1).truncationMode(.middle)
                highlighted([socket.destination, "local port " + socket.localPort].compactMap { $0 }.joined(separator: " · ")).font(Style.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if entry.duplicates > 1 { Text("×" + String(entry.duplicates)).font(Style.caption).monospacedDigit().foregroundStyle(.tertiary) }
            if entry.transport == "TCP" { Text(stateName(entry.state)).font(Style.caption).foregroundStyle(established ? .primary : .secondary) }
            tag(entry.transport)
        }.padding(.vertical, 7).accessibilityElement(children: .ignore)
            .accessibilityLabel("\(entry.transport) connection to \(entry.remote ?? ""), \(socket.destination ?? ""), \(entry.transport == "TCP" ? stateName(entry.state) : "")")
    }
    /// lsof reports TCP states as constants such as CLOSE_WAIT.
    func stateName(_ state: String) -> String { state.replacingOccurrences(of: "_", with: " ").lowercased().capitalizedFirst }
    func tag(_ text: String) -> some View {
        Text(text).font(Style.caption).foregroundStyle(.secondary).padding(.horizontal, 7).padding(.vertical, 2).background(Color.primary.opacity(0.07), in: Capsule())
    }
    func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    /// macOS offers no way to close one socket of another process, so closing a port or connection means ending its owner.
    /// Always confirmed; processes owned by the system or another user refuse the signal and are reported.
    func quit(_ process: String, pids: [Int], force: Bool) {
        let targets = pids.filter { $0 > 1 && $0 != Int(getpid()) }
        guard !targets.isEmpty else { return }
        let ids = targets.map(String.init).joined(separator: ", ")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = (force ? "Force quit " : "Quit ") + process + "?"
        alert.informativeText = "macOS can’t close a single port or connection of another app. Quitting \(process) (PID \(ids)) closes this one and all its other connections. Unsaved work in it may be lost."
            + (force ? " Force quit ends it immediately, without letting it save or clean up." : "")
        alert.addButton(withTitle: force ? "Force Quit" : "Quit").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let refused = targets.filter { Darwin.kill(pid_t($0), force ? SIGKILL : SIGTERM) != 0 }
        if !refused.isEmpty {
            let failure = NSAlert()
            failure.messageText = "\(process) could not be quit"
            failure.informativeText = "macOS did not allow Strand to quit PID \(refused.map(String.init).joined(separator: ", ")). It may belong to the system or another user, or it has already ended."
            failure.runModal()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { network.refresh() }
    }

    func trafficTile(_ title: String, icon: String, history: UsageHistory, color: Color, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Image(systemName: icon).foregroundStyle(color); Text(title).foregroundStyle(.secondary); Spacer() }.font(Style.caption)
            Text(Setting.rate(history.points.last?.value)).font(Style.number).monospacedDigit()
            Text(caption).font(Style.caption).foregroundStyle(.secondary)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).modifier(Surface())
    }
    func total(_ bytes: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .decimal) + " since startup" }
    func dashboardCount(_ title: String, count: Int?, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) { Image(systemName: icon); Text(title) }.font(Style.caption).foregroundStyle(.secondary)
                Text(count.map(String.init) ?? "—").font(Style.number).monospacedDigit()
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("\(title), \(count.map(String.init) ?? "reading")")
    }

    var dashboard: some View {
        let hardware = activeHardware
        return VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                Text("Dashboard").font(Style.hero)
                Spacer()
                Text("This Mac").font(Style.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                trafficTile("Received", icon: "arrow.down", history: network.totalReceived, color: .cyan, caption: total(hardware.reduce(0) { $0 + $1.received }))
                trafficTile("Sent", icon: "arrow.up", history: network.totalSent, color: .purple, caption: total(hardware.reduce(0) { $0 + $1.sent }))
            }
            HStack(spacing: 0) {
                dashboardCount("Active interfaces", count: hardware.count, icon: "network") { network.selected = network.primary ?? hardware.first?.id ?? network.selected; section = "interfaces" }
                dashboardCount("Listening ports", count: network.updated == nil ? nil : entryCount(listeners), icon: "dot.radiowaves.left.and.right") { section = "ports" }
                dashboardCount("Connections", count: network.updated == nil ? nil : entryCount(connections), icon: "point.3.connected.trianglepath.dotted") { section = "connections" }
            }.padding(.vertical, 4)
            RateChart(received: network.totalReceived, sent: network.totalSent, bits: trafficBits)
            VStack(alignment: .leading, spacing: 4) {
                HStack { Text("Active hardware").font(Style.title); InfoHint(text: "Wi-Fi and Ethernet-class interfaces with a reported address. The total includes their traffic and excludes virtual tunnels, bridges, loopback and peer-to-peer interfaces."); Spacer() }
                if hardware.isEmpty { Text("No active Wi-Fi or Ethernet interface").font(Style.body).foregroundStyle(.secondary).padding(.vertical, 8) }
                ForEach(hardware) { interface in
                    Button { network.selected = interface.id; section = "interfaces" } label: {
                        HStack(spacing: 12) {
                            Image(systemName: icon(interface)).foregroundStyle(Color.accentColor).frame(width: 20)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(interface.name).font(Style.title)
                                Text([interface.id == network.primary ? "Primary" : nil, interface.id, interface.mainAddress, interface.router.map { "Router " + $0 }].compactMap { $0 }.joined(separator: " · ")).font(Style.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 3) {
                                if let rate = network.downloads[interface.id]?.points.last?.value { Text("↓ " + Setting.rate(rate)).font(Style.caption).monospacedDigit() }
                                if let rate = network.uploads[interface.id]?.points.last?.value { Text("↑ " + Setting.rate(rate)).font(Style.caption).monospacedDigit().foregroundStyle(.secondary) }
                            }
                        }.padding(.vertical, 8).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    func interfaceDetail(_ interface: NetworkInterface) -> some View {
        let addresses = interface.addresses.sorted { (rank($0), $0) < (rank($1), $1) }
        return VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                highlighted(interface.name).font(Style.hero)
                HStack(spacing: 8) {
                    highlighted(interface.kind == interface.name ? interface.id : interface.kind + " · " + interface.id).font(Style.caption).foregroundStyle(.secondary)
                    statusTag(interface.status, active: interface.linkActive || (!interface.wired && interface.up))
                    if interface.id == network.primary { statusTag("Primary", active: true) }
                    InfoHint(text: interface.explanation)
                }
            }
            HStack(spacing: 12) {
                trafficTile("Received", icon: "arrow.down", history: network.downloads[interface.id] ?? UsageHistory(), color: .cyan, caption: total(interface.received))
                trafficTile("Sent", icon: "arrow.up", history: network.uploads[interface.id] ?? UsageHistory(), color: .purple, caption: total(interface.sent))
            }
            RateChart(received: network.downloads[interface.id] ?? UsageHistory(), sent: network.uploads[interface.id] ?? UsageHistory(), bits: trafficBits,
                                help: "Traffic on this interface only, from macOS interface counters. Tunnel and underlying interfaces can count the same traffic separately. Hover to read measured samples.")
            VStack(alignment: .leading, spacing: 0) {
                HStack { Text("Details").font(Style.title); InfoHint(text: "Values reported by macOS for this interface. Router and DNS servers come from the network service using it. Link speed is the negotiated rate of a wired link, not measured throughput; it is hidden for Wi-Fi, where macOS does not report a comparable rate. Unavailable fields are hidden."); Spacer() }.padding(.bottom, 4)
                detailRow("Type", interface.kind)
                detailRow("Status", interface.status)
                if let address = interface.hardwareAddress { detailRow("Hardware address", address) }
                if interface.wired, interface.linkActive, interface.linkSpeed > 0 { detailRow("Link speed", NetworkInterface.speed(interface.linkSpeed)) }
                if interface.mtu > 0 { detailRow("MTU", String(interface.mtu) + " bytes") }
                if let router = interface.router { detailRow("Router", router) }
                if !interface.dns.isEmpty { detailRow(interface.dns.count == 1 ? "DNS server" : "DNS servers", interface.dns.joined(separator: "\n")) }
            }
            if !addresses.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    HStack { Text("Addresses").font(Style.title); InfoHint(text: "Local addresses on this interface with their prefix length. They are not your public internet address. Link-local addresses work only on the directly attached network."); Spacer() }.padding(.bottom, 4)
                    ForEach(addresses, id: \.self) { address in
                        detailRow(NetworkInterface.addressLabel(address), interface.prefixes[address].map { address + "/" + String($0) } ?? address)
                    }
                }
            }
        }
    }
    /// IPv4, then routable IPv6, then link-local.
    func rank(_ address: String) -> Int { NetworkInterface.linkLocal(address) ? 2 : address.contains(":") ? 1 : 0 }
    func detailRow(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(name).foregroundStyle(.secondary)
            Spacer(minLength: 16)
            highlighted(value).monospacedDigit().multilineTextAlignment(.trailing).textSelection(.enabled)
        }.font(Style.body).padding(.vertical, 7).accessibilityElement(children: .combine)
    }
    func statusTag(_ text: String, active: Bool) -> some View {
        HStack(spacing: 5) {
            Circle().fill(active ? Color.green : Color.secondary).frame(width: 6, height: 6)
            Text(text)
        }.font(Style.caption).padding(.horizontal, 8).padding(.vertical, 3).background((active ? Color.green : Color.secondary).opacity(0.14), in: Capsule())
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}


struct PhysicalDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        PhysicalDisclosure(configuration: configuration)
    }
}

private struct PhysicalDisclosure: View {
    let configuration: DisclosureGroupStyleConfiguration
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { configuration.isExpanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    configuration.label
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(Style.caption.weight(.semibold))
                        .foregroundStyle(.secondary).rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    .background(Color.primary.opacity(hovering ? 0.10 : 0.05), in: RoundedRectangle(cornerRadius: Style.radius))
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).onHover { hovering = $0 }
                .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
                .accessibilityHint("Expand or collapse this interface group")
            if configuration.isExpanded { configuration.content }
        }
    }
}




private struct NetworkMiniMap: View {
    @ObservedObject var network: NetworkModel
    @AppStorage(Setting.trafficBits) private var trafficBits = false
    private var apps: [(name: String, count: Int)] {
        let active = network.sockets.filter { $0.state == "ESTABLISHED" && $0.remote != nil && !$0.remote!.hasPrefix("127.") && !$0.remote!.hasPrefix("[::1]:") }
        return Dictionary(grouping: active, by: \.process).map { (name: $0.key, count: $0.value.count) }
            .sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count }
    }
    private var service: NetworkInterface? { network.interfaces.first { $0.id == network.primary } }
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "globe").foregroundStyle(.secondary)
                Text("Internet").font(Style.caption)
                InfoHint(text: "The graph shows traffic on macOS's default IPv4 service, not an internet connectivity test. Apps have reported established remote TCP connections; individual sockets may use a different route or VPN. This diagram does not measure per-app traffic.")
            }
            connector
            if let id = service?.id {
                RateChart(received: network.downloads[id] ?? UsageHistory(), sent: network.uploads[id] ?? UsageHistory(), compact: true, bits: trafficBits)
            }
            connector
            if apps.isEmpty { Text("No active remote connections").font(Style.caption).foregroundStyle(.secondary).padding(8) }
            else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                    ForEach(Array(apps.prefix(6)), id: \.name) { app in
                        Button(action: open) {
                            HStack(spacing: 6) {
                                Image(systemName: "app.connected.to.app.below.fill").foregroundStyle(.secondary)
                                Text(app.name).font(Style.caption).lineLimit(1)
                                Spacer(minLength: 0)
                                Text(String(app.count)).font(Style.caption).monospacedDigit().foregroundStyle(.secondary)
                            }.padding(8).frame(maxWidth: .infinity).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("\(app.name), \(app.count) established connections")
                    }
                }
                if apps.count > 6 { Button("+\(apps.count - 6) more apps", action: open).buttonStyle(.plain).font(Style.caption).foregroundStyle(.secondary) }
            }
        }
    }
    private var connector: some View { Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 1, height: 10).accessibilityHidden(true) }
    private func open() { StatusBar.shared.close(); Bridge.openWindow?(); NSApp.activate(ignoringOtherApps: true) }
}
