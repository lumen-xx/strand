import UserNotifications
import AppKit
import Combine
import ServiceManagement
import StrandCore

@MainActor final class Model: ObservableObject {
    static let shared = Model()
    @Published var ports: [StrandCore.Port] = [] { didSet { cachedItems = nil; updateIdle() } }
    @Published var power = PowerSnapshot([:]) { didSet { cachedItems = nil } }
    @Published var error: String?
    @Published var selected: String? = UserDefaults.standard.string(forKey: "strand.selection") { didSet { if fixtureName == nil { UserDefaults.standard.set(selected, forKey: "strand.selection") } } }
    @Published var highlighted: String?
    @Published var showingSettings = CommandLine.arguments.contains("--settings-preview")
    @Published var ethernetItems: [ConnectionItem] = [] { didSet { cachedItems = nil; updateIdle() } }
    /// Headphone jack and built-in HDMI connections.
    @Published var otherItems: [ConnectionItem] = [] { didSet { cachedItems = nil; updateIdle() } }
    private var otherPrimed = false
    /// "strand.idle" drives the menu bar icon's idle hiding. Every write posts a defaults change that the app
    /// reacts to, so it is only written when the value flips, not on every two-second reading.
    private func updateIdle() {
        let idle = items.isEmpty
        if UserDefaults.standard.object(forKey: "strand.idle") as? Bool != idle { UserDefaults.standard.set(idle, forKey: "strand.idle") }
    }
    /// Until the first port reading, a saved selection may refer to a port that simply has not been read yet.
    private var portsLoaded = false
    private var networkSubscription: AnyCancellable?
    /// The first interface reading sets the baseline, so Ethernet already connected at launch is not announced.
    private var ethernetPrimed = false
    @Published var fixtureItems: [ConnectionItem]? { didSet { cachedItems = nil } }
    @Published var deviceDetails: [String: ConnectionMetadata] = [:] { didSet { cachedItems = nil } }
    /// Views ask for `items` many times per render (rows, parents, children), so it is built once per change of
    /// its inputs instead of on every call. Graph samples arrive every two seconds without touching it.
    private var cachedItems: [ConnectionItem]?
    let fixtureName: String?
    var items: [ConnectionItem] {
        if let cachedItems { return cachedItems }
        let built = buildItems()
        cachedItems = built
        return built
    }
    private func buildItems() -> [ConnectionItem] {
        // Fixtures go through the same ordering, so devices behind a dock appear as they do live.
        if let fixtureItems { return Self.ordered(fixtureItems.filter { $0.kind != "ethernet" }, ethernet: fixtureItems.filter { $0.kind == "ethernet" }) }
        let chargerPort = GraphRouting.powerPortID(ports: ports, power: power)
        let connected = ports.filter { $0.connected == true }.map { port in
            var item = ConnectionItem.live(port, metadata: deviceDetails[port.id])
            if port.id == chargerPort { item.charger = RelatedCharger.reported(power) }
            // A selected power option while the Mac reports external power means this port is powering it.
            if power.connected, let active = port.capabilities.active {
                item.powering = true; item.chip = number(active.watts) + " W"
                if item.verdict == nil { item.verdict = power.charging == true ? "Charging" : "Powering Mac" }
                item.spoken = "\(item.name), powering this Mac at \(number(active.watts)) watts, \(item.port)"
            }
            return item
        } + otherItems
        return Self.ordered(connected, ethernet: ethernetItems)
    }
    /// Cables behind a dock or hub follow it, so the list and arrow keys keep them together.
    static func ordered(_ connected: [ConnectionItem], ethernet ethernetItems: [ConnectionItem]) -> [ConnectionItem] {
        var ordered: [ConnectionItem] = []
        for item in connected {
            ordered.append(item)
            guard let dock = item.dock else { continue }
            for device in dock.devices {
                if let adapter = ethernetItems.first(where: { $0.adapter == device.name }) { ordered.append(adapter) }
                else if let child = ConnectionItem.device(device, through: item) { ordered.append(child) }
            }
        }
        return ordered + ethernetItems.filter { adapter in !ordered.contains { $0.id == adapter.id } }
    }
    /// What the sidebar lists under a dock or hub: cables Strand shows on their own, meaning Ethernet adapters,
    /// headphones, keyboards and mice. Storage and other devices stay in the hub's detail.
    func children(of item: ConnectionItem) -> [ConnectionItem] {
        guard Setting.flag(Setting.dockNesting, default: true), item.dock != nil else { return [] }
        return items.filter { parent(of: $0)?.id == item.id }
    }
    /// The dock or hub an item is connected through, when macOS reports it behind one.
    func parent(of item: ConnectionItem) -> ConnectionItem? {
        guard Setting.flag(Setting.dockNesting, default: true) else { return nil }
        if let parent = item.parent { return items.first { $0.id == parent } }
        guard let adapter = item.adapter else { return nil }
        return items.first { $0.dock?.devices.contains { $0.name == adapter } == true }
    }
    var item: ConnectionItem? { items.first { $0.id == selected } }
    @Published var login = SMAppService.mainApp.status == .enabled
    @Published var loginError: String?
    @Published var notify = UserDefaults.standard.bool(forKey: "strand.notify") { didSet { UserDefaults.standard.set(notify, forKey: "strand.notify"); if notify { Self.requestNotificationAccess() } } }
    @Published var monitoring = UserDefaults.standard.bool(forKey: "strand.monitoring") {
        didSet {
            UserDefaults.standard.set(monitoring, forKey: "strand.monitoring")
            storageUsage = []; previousStorage = [:]; previousSampleTime = nil; powerHistory = UsageHistory(); readHistories = [:]; writeHistories = [:]
            storageLog = []; powerLog = UsageHistory(); readLogs = [:]; writeLogs = [:]
            refresh()
        }
    }
    @Published var powerHistory = UsageHistory()
    @Published var readHistories: [UInt64: UsageHistory] = [:]
    @Published var writeHistories: [UInt64: UsageHistory] = [:]
    @Published var storageUsage: [StorageUsage] = []
    /// Readings are collected here all the time but only published while a Strand window or the menu bar panel
    /// is on screen. Power input and graph samples change every reading, and publishing them re-rendered the
    /// hidden window every two seconds. Opening Strand publishes everything collected so far.
    private var storageLog: [StorageUsage] = []
    private var powerLog = UsageHistory()
    private var readLogs: [UInt64: UsageHistory] = [:]
    private var writeLogs: [UInt64: UsageHistory] = [:]
    private var latestPower: PowerSnapshot?
    private var visibilityObserver: NSObjectProtocol?
    static var interfaceShowing: Bool {
        NSApp.windows.contains { $0.isVisible && $0.occlusionState.contains(.visible) && ($0.title == "Strand" || $0.className.contains("Popover")) }
    }
    private func publishLatest() {
        if let latestPower, latestPower != power { power = latestPower }
        guard monitoring else { return }
        powerHistory = powerLog; readHistories = readLogs; writeHistories = writeLogs; storageUsage = storageLog
    }
    var powerGraphPortID: String? {
        if fixtureName == "telemetry" || fixtureName == "graph-routing" { return fixtureItems?.first?.id }
        return GraphRouting.powerPortID(ports: ports, power: power)
    }
    private var previousPowerPortID: String?
    private var previousStorage: [UInt64: StorageCounter] = [:]
    private var previousSampleTime: TimeInterval?
    private var timer: AnyCancellable?
    private let queue = DispatchQueue(label: "com.opyuii.strand.registry", qos: .utility)
    private var reading = false
    init(fixture: String? = nil) {
        let args = CommandLine.arguments
        fixtureName = fixture ?? args.firstIndex(of: "--fixture").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        if let fixtureName {
            let local = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Fixtures/UI/\(fixtureName).json")
            let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/UI/\(fixtureName).json")
            let url = FileManager.default.fileExists(atPath: local.path) ? local : source
            // `--select <id>` previews a specific fixture item.
            do { fixtureItems = try JSONDecoder().decode([ConnectionItem].self, from: Data(contentsOf: url)); selected = args.firstIndex(of: "--select").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? fixtureItems?.first?.id }
            catch { fixtureItems = []; self.error = "Fixture could not load: \(error.localizedDescription)" }
            if fixtureName == "telemetry" || fixtureName == "graph-routing" {
                let start = Date().timeIntervalSince1970 - 118
                power = PowerSnapshot(["ExternalConnected":true, "PowerTelemetryData":["SystemPowerIn":48000]])
                var reads = UsageHistory(), writes = UsageHistory()
                for i in 0..<60 {
                    let t = start + Double(i) * 2
                    powerHistory.append(48 + sin(Double(i)/7) * 5, at: t)
                    reads.append(30_000_000 + sin(Double(i)/5) * 12_000_000, at: t)
                    writes.append(8_000_000 + cos(Double(i)/4) * 3_000_000, at: t)
                }
                storageUsage = [StorageUsage(id: 1, name: "Example USB SSD", readRate: reads.points.last?.value, writeRate: writes.points.last?.value, portID: fixtureName == "graph-routing" ? fixtureItems?.last?.id : fixtureItems?.first?.id)]
                readHistories[1] = reads; writeHistories[1] = writes
            }
            return
        }
        let network = NetworkModel.shared
        // dropFirst skips the empty value published before the first reading.
        networkSubscription = network.$interfaces.dropFirst().sink { [weak self] interfaces in
            guard let self else { return }
            let items = interfaces.filter(\.ethernetCable).map(ConnectionItem.ethernet)
            let added = self.ethernetPrimed ? items.first { item in !self.ethernetItems.contains { $0.id == item.id } } : nil
            self.ethernetPrimed = true
            // Interfaces publish on every traffic reading; only real cable changes reach the views.
            guard items != self.ethernetItems else { return }
            self.ethernetItems = items
            if let added { self.announce(added, body: added.port) }
            if self.portsLoaded, !self.items.contains(where: { $0.id == self.selected }) { self.selected = self.items.first?.id }
            self.noteChanges()
        }
        network.refresh()
        visibilityObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if Self.interfaceShowing { self?.publishLatest() } }
        }
        refresh()
        timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.refresh() }
    }
    static func postPlugNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
    static func requestNotificationAccess() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    func refresh() {
        guard fixtureName == nil, !reading else { return }; reading = true
        let shouldMonitor = monitoring
        queue.async { [weak self] in
            let result = Result { try Registry.snapshot() }
            let counters = shouldMonitor ? UsageMonitor.usbStorage() : []
            let deviceDetails = UsageMonitor.connectionDetails()
            let others = OtherPorts.connections()
            let sampledAt = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async {
                guard let self else { return }; self.reading = false; self.portsLoaded = true
                let newOther = self.otherPrimed ? others.first { item in !self.otherItems.contains { $0.id == item.id } } : nil
                self.otherPrimed = true
                if others != self.otherItems { self.otherItems = others }
                if let newOther { self.announce(newOther, body: newOther.port) }
                switch result {
                case .success(let (ports, power)):
                    let added = ports.first { p in p.connected == true && !self.ports.isEmpty && self.ports.first(where: { $0.id == p.id })?.connected != true }
                    // Publish only what changed, so an idle Mac doesn't re-render every view every two seconds.
                    if ports != self.ports { self.ports = ports }
                    // Power input changes on every reading. Hidden, only what the menu bar shows matters: a charger
                    // connecting or disconnecting, charging, its rating, or the wattage title when that is enabled.
                    let showing = Self.interfaceShowing
                    self.latestPower = power
                    if power != self.power, showing || Setting.flag(Setting.menuBarPower, default: false)
                        || power.connected != self.power.connected || power.charging != self.power.charging || power.adapterWatts != self.power.adapterWatts {
                        self.power = power
                    }
                    if deviceDetails != self.deviceDetails { self.deviceDetails = deviceDetails }
                    if self.error != nil { self.error = nil }
                    if shouldMonitor && self.monitoring {
                        let elapsed = self.previousSampleTime.map { sampledAt - $0 }
                        self.storageLog = counters.map { counter in
                            let previous = self.previousStorage[counter.id].flatMap { $0.portID == counter.portID ? $0 : nil }
                            if previous == nil {
                                self.readLogs[counter.id] = nil; self.writeLogs[counter.id] = nil
                            }
                            return StorageUsage(id: counter.id, name: counter.name,
                                readRate: previous.flatMap { old in elapsed.flatMap { StorageUsage.rate(counter.read, previous: old.read, elapsed: $0) } },
                                writeRate: previous.flatMap { old in elapsed.flatMap { StorageUsage.rate(counter.written, previous: old.written, elapsed: $0) } }, portID: counter.portID)
                        }
                        let timestamp = Date().timeIntervalSince1970
                        let owner = GraphRouting.powerPortID(ports: ports, power: power)
                        if owner != self.previousPowerPortID { self.powerLog = UsageHistory() }
                        self.previousPowerPortID = owner
                        if owner == nil { self.powerLog = UsageHistory() }
                        else { self.powerLog.append(power.inputWatts, at: timestamp) }
                        let activeIDs = Set(counters.map(\.id))
                        self.readLogs = self.readLogs.filter { activeIDs.contains($0.key) }
                        self.writeLogs = self.writeLogs.filter { activeIDs.contains($0.key) }
                        for usage in self.storageLog {
                            var reads = self.readLogs[usage.id] ?? UsageHistory()
                            var writes = self.writeLogs[usage.id] ?? UsageHistory()
                            reads.append(usage.readRate, at: timestamp); writes.append(usage.writeRate, at: timestamp)
                            self.readLogs[usage.id] = reads; self.writeLogs[usage.id] = writes
                        }
                        self.previousStorage = Dictionary(uniqueKeysWithValues: counters.map { ($0.id, $0) })
                        self.previousSampleTime = sampledAt
                        if showing { self.publishLatest() }
                    }
                    if let added { self.announce(.live(added, metadata: deviceDetails[added.id]), title: added.name, body: added.verdict) }
                    if !self.items.contains(where: { $0.id == self.selected }) { self.selected = self.items.first?.id }
                case .failure(let error): self.error = "Could not read port state: \(error.localizedDescription)"; self.ports = []
                }
                self.noteChanges()
            }
        }
    }
    /// A newly detected connection: optional notification, menu bar tip, selection and a brief highlight.
    func announce(_ item: ConnectionItem, title: String? = nil, body: String) {
        if notify { Self.postPlugNotification(title: title ?? item.name, body: body) }
        if Setting.flag(Setting.plugPopup, default: true) { StatusBar.shared.showPlug(item: item) }
        guard Setting.flag(Setting.selectNew, default: true) else { return }
        selected = item.id; highlighted = item.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in if self?.highlighted == item.id { self?.highlighted = nil } }
    }
    /// Names of the connections seen at the last check, for unplug notices.
    private var knownConnections: [String: (name: String, port: String)] = [:]
    /// Posts a notice for connections that disappeared, when enabled, and refreshes the menu bar power title.
    func noteChanges() {
        guard fixtureName == nil, portsLoaded else { return }
        let current = Dictionary(items.map { ($0.id, (name: $0.name, port: $0.port)) }, uniquingKeysWith: { first, _ in first })
        if Setting.flag(Setting.notifyUnplug, default: false), !knownConnections.isEmpty {
            for (id, removed) in knownConnections where current[id] == nil { Self.postPlugNotification(title: removed.name + " disconnected", body: removed.port) }
        }
        knownConnections = current
        updateMenuBarPower()
    }
    func updateMenuBarPower() {
        let powering = items.first { $0.powering == true }
        StatusBar.shared.setPowerTitle(Setting.flag(Setting.menuBarPower, default: false) ? powering?.chip : nil)
    }
    func setLogin(_ value: Bool) {
        do { if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; login = SMAppService.mainApp.status == .enabled; loginError = nil }
        catch { loginError = error.localizedDescription; login = SMAppService.mainApp.status == .enabled }
    }
    func moveSelection(_ delta: Int) {
        guard !items.isEmpty else { return }
        let index = items.firstIndex { $0.id == selected } ?? 0
        selected = items[max(0, min(items.count - 1, index + delta))].id
    }
    func details(_ item: ConnectionItem) -> String {
        let charger = item.charger.map { "\nCharger: \($0.name)\n" + $0.facts.map { $0.name + ": " + $0.value }.joined(separator: "\n") } ?? ""
        let dock = item.dock.map { "\nConnected through \($0.title):\n" + $0.devices.map { $0.name + ": " + $0.value }.joined(separator: "\n") } ?? ""
        return "\(item.name)\n\(item.port)\n\(item.chip)\n\(item.details)" + charger + dock
    }
    /// The selected connection's details, or the full report when nothing is selected.
    var report: String {
        if let item { return details(item) }
        return "Strand \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "development")\n\(Date())\n\n" + ports.map(\.report).joined(separator: "\n") + "\n" + power.report + "\n\nNo active connection can also mean a cable with its other end loose. Cable and PD identity availability varies by Mac and hardware."
    }
    func copyDetails(_ item: ConnectionItem) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(details(item), forType: .string)
    }
    func copyReport() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(report, forType: .string)
    }
}
