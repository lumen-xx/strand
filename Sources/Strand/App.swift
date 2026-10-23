import SwiftUI
import StrandCore

@main struct StrandApp: App {
    @StateObject private var model = Model.shared
    @StateObject private var updates = Updates.shared
    @Environment(\.openWindow) private var openWindow
    @NSApplicationDelegateAdaptor(StrandLifecycle.self) private var lifecycle
    init() { SnapshotRenderer.runIfRequested() }
    var body: some Scene {
        Window("Strand", id: "strand") { Group {
            if CommandLine.arguments.contains("--panel-preview") { Panel(model: model, updates: updates) }
            else { Inspector(model: model, updates: updates) }
        }.onAppear { Bridge.openWindow = { openWindow(id: "strand") } }.task {
            if CommandLine.arguments.contains("--check-ui") { PresentationChecks.run() }
            if CommandLine.arguments.contains("--fixture") { NSApp.activate(ignoringOtherApps: true); NSApp.windows.first { $0.title == "Strand" }?.makeKeyAndOrderFront(nil) }
        }.preferredColorScheme(CommandLine.arguments.contains("--dark") ? .dark : CommandLine.arguments.contains("--light") ? .light : nil) }
            .windowStyle(.hiddenTitleBar).windowResizability(.contentSize).defaultSize(width: 920, height: 740)
            .commands {
                CommandGroup(after: .appInfo) { Button("Check for Updates…") { updates.check() } }
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { model.showingSettings = true; openWindow(id: "strand"); NSApp.activate(ignoringOtherApps: true) }.keyboardShortcut(",")
                }
                // The standard Edit items stay so text fields keep Cut, Copy, Paste and Select All. Command-C on the cable list
                // copies the selection's details through onCopyCommand.
                CommandGroup(after: .pasteboard) { Button("Copy Report") { model.copyReport() }.keyboardShortcut("c", modifiers: [.command, .shift]) }
            }
    }
}

struct VerdictChip: View {
    var item: ConnectionItem
    var body: some View {
        HStack(spacing: 6) {
            if item.powering == true { Image(systemName: "bolt.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(item.color).accessibilityHidden(true) }
            else { Circle().fill(item.color).frame(width: 7, height: 7) }
            Text(item.chip).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
        }.font(Style.caption.weight(.medium)).padding(.horizontal, 10).padding(.vertical, 5)
            .background(item.color.opacity(0.16), in: Capsule())
            .overlay(Capsule().strokeBorder(item.color.opacity(0.28), lineWidth: 1))
            .accessibilityLabel(item.accessibility)
    }
}

/// Original transparent product photography shared by both lists.
struct ItemIcon: View {
    var item: ConnectionItem
    var size: CGFloat = 64
    var body: some View {
        ConnectionDrawing(kind: item.kind, color: item.color, speed: item.speed)
            .frame(width: size, height: size)
    }
}

struct ItemRow: View {
    var item: ConnectionItem
    var selected: Bool
    var highlighted: Bool
    var compact = false
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 14) {
            ItemIcon(item: item, size: compact ? 54 : 58)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.name).font(Style.title).lineLimit(1)
                Text(item.port).font(Style.caption).foregroundStyle(.secondary).lineLimit(1)
                VerdictChip(item: item)
            }
            Spacer(minLength: 0)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Style.radius, style: .continuous)
                // The menu panel shows only the hover state; selection and plug-in highlights belong to the window.
                .fill(compact ? (hovering ? Color.primary.opacity(0.05) : .clear) : highlighted ? item.color.opacity(0.28) : selected ? Color.primary.opacity(0.10) : hovering ? Color.primary.opacity(0.05) : .clear))
            .overlay(RoundedRectangle(cornerRadius: Style.radius, style: .continuous).strokeBorder(!compact && selected ? item.color.opacity(0.45) : .clear, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: Style.radius, style: .continuous))
            .onHover { hovering = $0 }
            .accessibilityElement(children: .ignore).accessibilityLabel(item.accessibility).accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// A row for a cable connected through a dock or hub: smaller than a top-level row, same layout and type.
struct NestedRow: View {
    var kind: String
    var color: Color
    var name: String
    var caption: String
    var selected: Bool
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 12) {
            ConnectionDrawing(kind: kind, color: color).frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(Style.title).lineLimit(1)
                Text(caption).font(Style.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Style.radius, style: .continuous).fill(selected ? Color.primary.opacity(0.10) : hovering ? Color.primary.opacity(0.05) : .clear))
            .overlay(RoundedRectangle(cornerRadius: Style.radius, style: .continuous).strokeBorder(selected ? color.opacity(0.45) : .clear, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: Style.radius, style: .continuous))
            .onHover { hovering = $0 }
            .accessibilityElement(children: .ignore).accessibilityLabel("\(name), \(caption)").accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

struct EmptyConnection: View {
    var compact = false
    /// A failed port read is not the same as nothing connected.
    var failed = false
    var body: some View {
        VStack(spacing: compact ? 6 : 14) {
            ConnectionDrawing(color: .secondary.opacity(0.5)).frame(width: compact ? 190 : 340, height: compact ? 130 : 240)
            Text(failed ? "Ports could not be read" : "Plug something in").font(compact ? Style.title : Style.heading).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.vertical, compact ? 16 : 40)
    }
}

struct ErrorNotice: View {
    var text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
            Text(text).font(Style.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: Style.radius, style: .continuous))
    }
}

struct CablePanel: View {
    @ObservedObject var model: Model
    @ObservedObject var updates: Updates
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    var body: some View {
        VStack(spacing: 10) {
            if let error = model.error, !model.items.isEmpty { ErrorNotice(text: error) }
            if model.items.isEmpty { EmptyConnection(compact: true, failed: model.error != nil).frame(height: 180) }
            else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(model.items) { item in
                            Button { model.selected = item.id; model.showingSettings = false; showWindow() } label: { ItemRow(item: item, selected: model.selected == item.id, highlighted: model.highlighted == item.id, compact: true).frame(height: PanelLayout.rowHeight) }
                                .buttonStyle(.plain).contextMenu { Button("Copy details") { model.copyDetails(item) } }
                        }
                    }
                }.scrollIndicators(.never).frame(height: PanelLayout.listHeight(count: model.items.count))
            }
        }.padding(12).frame(width: 360)
            .focusable().focused($focused).focusEffectDisabled().onAppear { focused = true }
            .onCopyCommand { [NSItemProvider(object: model.report as NSString)] }
            .onKeyPress(.downArrow) { model.moveSelection(1); return .handled }
            .onKeyPress(.upArrow) { model.moveSelection(-1); return .handled }
            .onKeyPress(.return) { model.showingSettings = false; showWindow(); return .handled }
            .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85), value: model.items.map(\.id))
    }
    func showWindow() {
        StatusBar.shared.close()
        if let open = Bridge.openWindow { open() } else { openWindow(id: "strand") }
        NSApp.activate(ignoringOtherApps: true)
    }
}
enum PanelLayout {
    static let rowHeight: CGFloat = 96
    static func listHeight(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return min(CGFloat(count) * rowHeight + CGFloat(count - 1) * 4, 320)
    }
}

/// Marks hardware that reports Apple as its maker. It says what is reported, never that the item is verified genuine.
struct AppleBadge: View {
    var label: String
    var explanation: String
    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "apple.logo").font(.system(size: 11, weight: .medium)).accessibilityHidden(true)
                Text(label)
            }.font(Style.caption.weight(.medium)).padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color.primary.opacity(0.08), in: Capsule())
                .accessibilityElement(children: .combine).accessibilityLabel(label + ", reported by the hardware")
            InfoHint(text: explanation)
        }
    }
}

struct StatTile: View {
    var icon: String
    var value: String?
    var label: String
    var color: Color
    var explanation: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(value == nil ? Color.secondary : color)
                    .frame(width: 26, height: 26).background(Circle().fill((value == nil ? Color.secondary : color).opacity(0.16)))
                Text(label).font(Style.caption.weight(.medium)).foregroundStyle(.secondary)
                if let explanation { InfoHint(text: explanation) }
            }
            Text(value ?? "—").font(Style.number.weight(.semibold)).monospacedDigit().minimumScaleFactor(0.5).lineLimit(1)
                .foregroundStyle(value == nil ? Color.secondary.opacity(0.6) : Color.primary)
        }.frame(maxWidth: .infinity, minHeight: 84, alignment: .leading).padding(14).modifier(Surface())
            .accessibilityElement(children: .contain).accessibilityLabel(value.map { "\(label), \($0)" } ?? "\(label), not reported")
    }
}
/// Explanations live on a dedicated, keyboard-accessible info control.
struct InfoHint: View {
    var text: String
    var prominent = false
    @State private var shown = false
    @State private var hovered = false
    @State private var contentHovered = false
    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle")
                .font(prominent ? Style.title : Style.caption)
                .foregroundStyle(.secondary)
                .frame(width: prominent ? 34 : 22, height: prominent ? 34 : 22)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel("Information")
            .accessibilityValue(text)
            .onHover { hovered = $0; if $0 { shown = true } }
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                Text(text).font(Style.body).fixedSize(horizontal: false, vertical: true)
                    .frame(width: 280, alignment: .leading).padding(14)
                    .onHover { contentHovered = $0 }
            }
            .task(id: hovered || contentHovered) {
                guard !hovered && !contentHovered else { return }
                try? await Task.sleep(for: .milliseconds(250))
                if !Task.isCancelled { shown = false }
            }
    }
}
struct DetailField {
    let name: String
    let value: String
    init(_ line: String) {
        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        name = String(parts[0]).trimmingCharacters(in: .whitespaces)
        value = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
    }
}

struct InformationRow: View {
    var name: String
    var value: String
    var explanation: String
    var body: some View {
        HStack(spacing: 8) {
            Text(name).foregroundStyle(.secondary)
            InfoHint(text: explanation)
            Spacer(minLength: 16)
            Text(value).monospacedDigit().textSelection(.enabled)
        }.font(Style.body).padding(.vertical, 8)
    }
}

struct CableInspector: View {
    @ObservedObject private var network = NetworkModel.shared
    @AppStorage(Setting.dockNesting) private var dockNesting = true
    @AppStorage(Setting.technicalDetails) private var technicalDetails = true
    @ObservedObject var model: Model
    @ObservedObject var updates: Updates
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var listFocused: Bool
    var body: some View {
        ZStack(alignment: .topTrailing) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    ScrollView {
                        VStack(spacing: 4) {
                            if let error = model.error { ErrorNotice(text: error).padding(.bottom, 6) }
                            ForEach(model.items.filter { model.parent(of: $0) == nil }) { item in
                                Button { model.selected = item.id; model.showingSettings = false } label: { ItemRow(item: item, selected: model.selected == item.id, highlighted: model.highlighted == item.id) }.buttonStyle(.plain)
                                    .contextMenu { Button("Copy details") { model.copyDetails(item) } }
                                if dockNesting { dockChildren(item) }
                            }
                        }.padding(.horizontal, 12).padding(.top, 60).padding(.bottom, 16)
                    }.scrollIndicators(.never)
                }.frame(width: 320).frame(maxHeight: .infinity)
                    .overlay(alignment: .trailing) { Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1) }
                    .focusable().focused($listFocused).focusEffectDisabled()
                    .onCopyCommand { [NSItemProvider(object: model.report as NSString)] }
                    .onKeyPress(.downArrow) { model.moveSelection(1); return .handled }
                    .onKeyPress(.upArrow) { model.moveSelection(-1); return .handled }
                Group {
                    if model.showingSettings {
                        ScrollView { Preferences(model: model, updates: updates).padding(.top, 42).frame(maxWidth: .infinity) }.scrollIndicators(.never)
                    }
                    else if let item = model.item { detail(item).id(item.id) }
                    else { EmptyConnection(failed: model.error != nil) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 8) {
                InfoHint(text: "Strand shows only what macOS reports. A cable with its other end loose can look like nothing is connected, and an active connection does not prove a cable's top speed. Ratings appear when the cable has a readable e-marker chip. Product photos illustrate connection categories; they do not identify the connected brand or model.", prominent: true)
                RoundIconButton(systemImage: "arrow.clockwise", label: "Refresh") { model.refresh() }
                RoundIconButton(systemImage: "gearshape", label: model.showingSettings ? "Back to connection" : "Settings") { model.showingSettings.toggle() }
            }.padding(.top, 14).padding(.trailing, 16)
            RoundIconButton(systemImage: "xmark", label: "Close") { (NSApp.keyWindow ?? NSApp.mainWindow)?.performClose(nil) }
                .padding(.top, 14).padding(.leading, 16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.ignoresSafeArea(.container, edges: .top).background(WindowBackground(color: model.item?.color ?? .accentColor))
            .frame(minWidth: 800, maxWidth: 1100, minHeight: 600, maxHeight: 900)
            .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85), value: model.items.map(\.id))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: model.selected)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: model.highlighted)
            .onAppear { listFocused = true }
    }

    /// Cables behind a dock or hub, under it with a guide line from the hub's photo. Each opens its own detail.
    @ViewBuilder func dockChildren(_ parent: ConnectionItem) -> some View {
        let children = model.children(of: parent)
        if !children.isEmpty {
            HStack(alignment: .top, spacing: 0) {
                RoundedRectangle(cornerRadius: 1).fill(Color.primary.opacity(0.18)).frame(width: 2).padding(.vertical, 6).padding(.leading, 40)
                VStack(spacing: 2) {
                    ForEach(children) { item in
                        Button { model.selected = item.id; model.showingSettings = false } label: {
                            NestedRow(kind: item.kind, color: item.color, name: item.name, caption: item.chip, selected: model.selected == item.id)
                        }.buttonStyle(.plain).contextMenu { Button("Copy details") { model.copyDetails(item) } }
                    }
                }.padding(.leading, 10)
            }.padding(.bottom, 6)
        }
    }

    func facts(_ item: ConnectionItem) -> [CableFact] {
        var list = item.facts ?? []
        if list.isEmpty, let speed = item.speed { list.append(CableFact(name: "Speed", value: speed)) }
        if let link = item.link { list.append(CableFact(name: "Active transport", value: link)) }
        return list
    }

    /// Facts most people look for: capability, live link and audio/display state. Identity values and ratings detail go under Technical details.
    func isKeyFact(_ name: String) -> Bool {
        ["Cable speed", "Speed", "Cable power rating", "Link speed", "Active transport", "Audio output", "Microphone", "Display link", "USB link", "Connected through"].contains(name)
            || name.hasSuffix(" · USB link") || name == "DisplayPort link"
    }
    func factExplanation(_ name: String) -> String {
        let explanations = [
            "Active transport": "Reported active transport, not the cable’s maximum capability. CC is the configuration channel used to detect a connection and negotiate power.",
            "Cable speed": "USB signaling capability reported by the cable’s e-marker. This does not establish Thunderbolt certification or its alternate-mode capability. Actual speed also depends on the devices and port. A 10–20 Gbps label means macOS does not distinguish the lane configuration.",
            "Speed": "Reported cable signaling capability. This is not a measurement of current transfer speed.",
            "Cable current": "Maximum current reported by the cable’s e-marker, not current flowing through the cable.",
            "Cable power rating": "Power capability derived from the reported current at a 20 V cable rating. A higher voltage tolerance alone is not treated as an EPR wattage rating.",
            "Cable voltage ceiling": "Maximum voltage tolerance reported by the cable’s e-marker. This does not establish its usable charging wattage.",
            "Cable vendor ID": "USB vendor identifier from the cable’s e-marker. It identifies the registered vendor; macOS may not provide a readable brand name.",
            "Cable product ID": "Product identifier supplied by the cable’s e-marker. It is not a serial number or a readable model name.",
            "Cable type": "Passive cables carry signals directly. Active cables contain electronics that help carry signals. This type comes from the e-marker identity.",
            "Link speed": "Speed negotiated between this Mac’s Ethernet adapter and the device at the other end. It is not measured throughput and does not establish the cable’s category or maximum rating.",
            "Charger rating": "Rated output reported by the power adapter. The Mac may draw less, for example when the battery is nearly full.",
            "Mac power input": "Power currently flowing into this Mac from the adapter, measured by macOS for the whole Mac.",
            "Charger manufacturer": "Manufacturer reported by the power adapter.",
            "Charger model": "Model identifier reported by the power adapter. It is not a serial number.",
            "Charger firmware": "Firmware version reported by the power adapter.",
            "Charger type": "Connection type reported by the power adapter.",
            "Audio output": "Whether macOS currently sends system audio to the headphone jack. The jack cannot identify the headphones or cable plugged in.",
            "Sample rate": "Sample rate macOS uses for the headphone output.",
            "Microphone": "macOS reports a microphone on the headphone jack, as with a headset plug.",
            "Display link": "Link rate macOS reports for the display on this port. It describes the current connection, not the cable’s maximum rating.",
            "Display lanes": "Number of active lanes in the display link.",
            "Display manufacturer ID": "Three-letter manufacturer code from the display’s identity data.",
            "USB link": "Current USB signaling rate reported for this device, not its cable's maximum capability or measured throughput.",
            "Manufacturer": "Manufacturer name reported by the device. Some devices report a generic name.",
            "Connected through": "The hub or dock this device is plugged into.",
            "Connection": "The device reports itself as a USB receiver for a wireless mouse, keyboard or headset. macOS does not report whether it uses 2.4 GHz or Bluetooth LE, or the battery level.",
            "Interface": "macOS network interface for this Ethernet adapter. Its traffic and addresses are in Network mode.",
            "Selected power option": "Power option selected for this physical port. Its wattage is an available ceiling, not an instantaneous power measurement."
        ]
        if name.hasSuffix(" · USB link") { return "Current USB signaling rate reported for this device, not the cable’s maximum capability or measured read/write throughput." }
        if name.hasPrefix("DisplayPort") { return "Reported active DisplayPort link for this monitor. Link rate, lane count and tunnelling describe this connection; they do not establish the cable’s Thunderbolt rating." }
        return explanations[name] ?? "Value reported by macOS for this connection. Unavailable fields are hidden."
    }

    func detail(_ item: ConnectionItem) -> some View {
        ScrollViewReader { proxy in
            ScrollView { detailContent(item) }.scrollIndicators(.never)
                .task {
                    if CommandLine.arguments.contains("--show-graphs") {
                        try? await Task.sleep(for: .milliseconds(300))
                        proxy.scrollTo(CommandLine.arguments.contains("--show-details") ? "details" : "monitoring", anchor: .bottom)
                    }
                }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    func detailContent(_ item: ConnectionItem) -> some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                Text(item.name).font(Style.hero)
                HStack(spacing: 10) {
                    Text(item.port).font(Style.body).foregroundStyle(.secondary)
                    VerdictChip(item: item)
                    if item.appleEMarker {
                        AppleBadge(label: "Apple e-marker", explanation: "The cable’s e-marker chip reports Apple’s USB vendor ID (0x05AC). This is what an original Apple cable reports, but Strand cannot verify authenticity: a counterfeit cable can copy the ID.")
                    }
                }
            }.frame(maxWidth: .infinity)
            HStack(spacing: 20) {
                // Devices behind a hub show the cable they use beside the device itself.
                let deviceKind = item.deviceKind ?? (item.parent != nil && ["headphones", "keyboard", "mouse", "receiver"].contains(item.kind) ? item.kind : nil)
                let device = deviceKind != nil
                let companions = (item.dock == nil ? 0 : 1) + (item.charger == nil ? 0 : 1) + (device ? 1 : 0)
                ConnectionDrawing(kind: device ? "cable" : item.kind, color: item.color, speed: item.speed).frame(width: companions == 0 ? 240 : companions == 1 ? 200 : 150, height: 180)
                if device {
                    Image(systemName: "arrow.left.and.right").font(Style.title).foregroundStyle(item.color.opacity(0.8)).accessibilityHidden(true)
                    ConnectionDrawing(kind: deviceKind ?? item.kind, color: item.color).frame(width: 190, height: 160)
                }
                if let dock = item.dock {
                    Image(systemName: "arrow.left.and.right").font(Style.title).foregroundStyle(item.color.opacity(0.8)).accessibilityHidden(true)
                    ConnectionDrawing(kind: dock.kind, color: item.color).frame(width: companions == 1 ? 170 : 130, height: 150)
                }
                if item.charger != nil {
                    Image(systemName: "bolt.fill").font(Style.title).foregroundStyle(item.color.opacity(0.8)).accessibilityHidden(true)
                    ConnectionDrawing(kind: "charger", color: item.color).frame(width: companions == 1 ? 150 : 120, height: 150)
                }
            }.frame(height: 180).accessibilityElement(children: .ignore)
                .accessibilityLabel([item.name, item.dock.map { "through " + $0.title }, item.charger.map { "powered by " + $0.name }].compactMap { $0 }.joined(separator: ", "))
            // Order follows what people check first: any limit, status and power, what it can do, what powers the Mac,
            // what is happening now, then technical identity.
            if let summary = item.summary {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: item.tone == "amber" ? "exclamationmark.triangle.fill" : "checkmark.circle.fill").foregroundStyle(item.color).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.tone == "amber" ? "Power limit" : "Assessment").font(Style.title)
                        Text(summary).font(Style.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(item.color.opacity(0.12), in: RoundedRectangle(cornerRadius: Style.radius, style: .continuous))
                    .accessibilityElement(children: .combine)
            }
            HStack(spacing: 12) {
                StatTile(icon: "checkmark.seal.fill", value: item.verdict ?? "Active", label: "Status", color: item.color, explanation: item.summary ?? "Connection state reported by macOS. An active connection does not establish the cable’s speed or power rating.")
                if let power = item.power { StatTile(icon: "bolt.fill", value: power, label: "Power", color: item.color, explanation: item.powerExplanation ?? "Reported power capability; instantaneous readings appear in the power graph.") }
            }
            let fields = facts(item)
            // CC alone is only the detection channel, so it carries no meaning for most people.
            let key = fields.filter { isKeyFact($0.name) && !($0.name == "Active transport" && $0.value == "CC") }
            let technical = fields.filter { fact in !key.contains { $0.name == fact.name } }
            if !key.isEmpty {
                VStack(spacing: 0) {
                    ForEach(key, id: \.name) { fact in InformationRow(name: fact.name, value: fact.value, explanation: factExplanation(fact.name)) }
                }
            }
            if let charger = item.charger { chargerSection(charger, color: item.color) }
            if let dock = item.dock { dockSection(dock) }
            // Interface counters are read for Network mode anyway, so these graphs do not depend on the monitoring setting.
            if item.kind == "ethernet" {
                let id = String(item.id.dropFirst("ethernet:".count))
                let received = network.downloads[id] ?? UsageHistory(), sent = network.uploads[id] ?? UsageHistory()
                if !received.points.isEmpty || !sent.points.isEmpty {
                    RateChart(received: received, sent: sent, bits: Setting.flag(Setting.trafficBits, default: false), help: "Received and sent traffic on this Ethernet interface, including local-network traffic. These are interface counters, not a measurement of the cable’s maximum speed. Hover to read measured samples.")
                }
            }
            if item.kind != "ethernet", model.monitoring || model.fixtureName == "telemetry" || model.fixtureName == "graph-routing" { monitoring(item).id("monitoring") }
            let profiles = item.profiles ?? []
            if technicalDetails, !technical.isEmpty || !profiles.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    HStack { Text("Technical details").font(Style.title); Spacer() }.padding(.bottom, 4)
                    ForEach(technical, id: \.name) { fact in InformationRow(name: fact.name, value: fact.value, explanation: factExplanation(fact.name)) }
                    if !profiles.isEmpty {
                        HStack { Text("Power Delivery profiles").foregroundStyle(.secondary); InfoHint(text: "Power source options reported under this physical port. The selected option is marked Active. This is not an instantaneous power measurement."); Spacer() }
                            .font(Style.body).padding(.top, 10).padding(.bottom, 2)
                        ForEach(profiles) { profile in
                            HStack {
                                Text(profile.value).monospacedDigit()
                                Spacer()
                                if profile.active { Label("Active", systemImage: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                            }.font(Style.body).padding(.vertical, 5).accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            let raw = item.details.split(separator: "\n").map(String.init).filter { $0.contains(":") && !$0.contains("Not reported") }
            if technicalDetails, !raw.isEmpty {
                Divider().padding(.top, 4)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    ForEach(Array(raw.enumerated()), id: \.offset) { _, line in
                        let field = DetailField(line)
                        GridRow {
                            Text(field.name).foregroundStyle(.secondary).textSelection(.enabled)
                            Text(field.value).monospacedDigit().multilineTextAlignment(.trailing)
                                .frame(maxWidth: .infinity, alignment: .trailing).textSelection(.enabled)
                        }.accessibilityElement(children: .combine)
                    }
                }.font(Style.caption).frame(maxWidth: .infinity, alignment: .leading).id("details")
            }
            if model.fixtureName != nil { Text("Illustrative UI fixture").font(Style.caption).foregroundStyle(.tertiary) }
        }.padding(.horizontal, 28).padding(.top, 18).padding(.bottom, 24).frame(maxWidth: 760).frame(maxWidth: .infinity)
    }
    func chargerSection(_ charger: RelatedCharger, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Charger").font(Style.title)
                InfoHint(text: "The power adapter macOS reports for this Mac, shown on the only connected port with a selected power option. Name, rating and firmware come from the adapter; Mac power input is a system-wide measurement, not a per-cable sensor. The photo illustrates the charger category, not its brand or model.")
                Spacer()
                if let charging = charger.charging {
                    HStack(spacing: 6) { Circle().fill(charging ? Color.green : Color.secondary).frame(width: 7, height: 7); Text(charging ? "Charging" : "Not charging") }
                        .font(Style.caption.weight(.medium)).padding(.horizontal, 10).padding(.vertical, 5)
                        .background((charging ? Color.green : Color.secondary).opacity(0.16), in: Capsule())
                }
            }.padding(.bottom, 4)
            HStack(spacing: 10) {
                Text(charger.name).font(Style.heading).textSelection(.enabled)
                if charger.apple {
                    AppleBadge(label: "Apple", explanation: "The power adapter reports Apple Inc. as its manufacturer. Strand cannot verify authenticity: a counterfeit adapter can report the same name.")
                }
            }.padding(.vertical, 6)
            ForEach(charger.facts, id: \.name) { fact in InformationRow(name: fact.name, value: fact.value, explanation: factExplanation(fact.name)) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    func dockSection(_ dock: DockInfo) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(dock.kind == "dock" ? "Dock" : "Hub").font(Style.title)
                InfoHint(text: "Thunderbolt docks identify themselves with a maker and model, so Strand calls them docks. Every other hub, including USB-C docks with their own power supply, is shown as a hub because macOS reports only its hub chips. Only connected devices are listed; macOS does not report empty ports.")
                Spacer()
            }.padding(.bottom, 4)
            Text(dock.title).font(Style.heading).padding(.vertical, 6).textSelection(.enabled)
            if let link = dock.link {
                InformationRow(name: "Link to Mac", value: link, explanation: "Fastest USB link between this Mac and the \(dock.kind)’s hub. Devices behind it share this connection.")
            }
            if let builtIn = dock.builtIn, !builtIn.isEmpty {
                Text("Built into this \(dock.kind)").font(Style.body).foregroundStyle(.secondary).padding(.top, 10).padding(.bottom, 2)
                ForEach(builtIn, id: \.self) { function in
                    Text(function).font(Style.body).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !dock.devices.isEmpty {
                Text("Connected through this \(dock.kind)").font(Style.body).foregroundStyle(.secondary).padding(.top, 10).padding(.bottom, 2)
                ForEach(Array(dock.devices.enumerated()), id: \.offset) { _, device in
                    HStack(spacing: 8) {
                        Text(device.name).lineLimit(1)
                        Spacer(minLength: 16)
                        Text(device.value).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                    }.font(Style.body).padding(.vertical, 6).accessibilityElement(children: .combine)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    func monitoring(_ item: ConnectionItem) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            if model.powerGraphPortID == item.id, !model.powerHistory.points.isEmpty {
                UsageGraph(title: "Mac power input", history: model.powerHistory, color: .orange,
                           help: "Mac power input, shown on the only connected port with a reported winning power option. This remains a system-wide measurement, not a per-cable sensor. Ambiguous power sources are hidden.")
            }
            ForEach(GraphRouting.storage(model.storageUsage, portID: item.id)) { usage in
                let reads = usage.readRate == nil ? UsageHistory() : model.readHistories[usage.id] ?? UsageHistory()
                let writes = usage.writeRate == nil ? UsageHistory() : model.writeHistories[usage.id] ?? UsageHistory()
                if !reads.points.isEmpty || !writes.points.isEmpty {
                    RateChart(received: reads, sent: writes, title: usage.name, names: ("Read", "Write"),
                              help: "USB storage bytes read and written per second. Device-level activity, not total traffic on this cable. Hover to read measured samples.")
                }
            }
        }
    }
}

struct Preferences: View {
    @ObservedObject var model: Model
    @ObservedObject var updates: Updates
    @AppStorage("menuBarEnabled") private var menuBarEnabled = true
    @AppStorage("hideMenuBarWhenIdle") private var hideWhenIdle = false
    @AppStorage(Setting.startMode) private var startMode = "last"
    @AppStorage(Setting.appearance) private var appearance = "system"
    @AppStorage(Setting.colorWash) private var colorWash = true
    @AppStorage(Setting.menuBarPower) private var menuBarPower = false
    @AppStorage(Setting.plugPopup) private var plugPopup = true
    @AppStorage(Setting.selectNew) private var selectNew = true
    @AppStorage(Setting.notifyUnplug) private var notifyUnplug = false
    @AppStorage(Setting.dockNesting) private var dockNesting = true
    @AppStorage(Setting.technicalDetails) private var technicalDetails = true
    @AppStorage(Setting.networkInterval) private var networkInterval = 3.0
    @AppStorage(Setting.hideLoopback) private var hideLoopback = false
    @AppStorage(Setting.trafficBits) private var trafficBits = false
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Settings").font(Style.heading).padding(.top, 8)
            section("General") {
                setting("Launch at login", icon: "power", value: Binding(get: { model.login }, set: { model.setLogin($0) }), info: "Start Strand in the menu bar when you sign in. Closing the main window leaves Strand running.")
                if let error = model.loginError { Text(error).font(Style.caption).foregroundStyle(.red).textSelection(.enabled) }
                choice("Open Strand in", icon: "rectangle.split.2x1", selection: $startMode, options: [("last", "Last used"), ("cables", "Cables"), ("network", "Network")],
                       info: "Which mode the window shows when it opens. Last used remembers your previous choice.")
            }
            section("Menu bar") {
                setting("Show in menu bar", icon: "menubar.rectangle", value: $menuBarEnabled, info: "Show the Strand connector icon and panel in the menu bar. When off, Strand stays in the Dock while it runs so you can still open it.")
                if menuBarEnabled {
                    setting("Hide when nothing is connected", icon: "eye.slash", value: $hideWhenIdle, info: "Remove the menu bar icon while no connection is detected. It returns when something is plugged in. Strand stays in the Dock meanwhile so you can still open it.")
                    setting("Show charging power", icon: "bolt", value: $menuBarPower, info: "Show the selected wattage of the connection powering your Mac next to the menu bar icon, for example 34.8 W. Hidden while nothing powers the Mac.")
                }
            }
            section("Appearance") {
                choice("Theme", icon: "circle.lefthalf.filled", selection: $appearance, options: [("system", "System"), ("light", "Light"), ("dark", "Dark")],
                       info: "Follow the system appearance or keep Strand light or dark. Product photos switch with it.")
                setting("Colour background", icon: "paintpalette", value: $colorWash, info: "Tint the window background with a soft colour that follows the selected connection. Off keeps the plain blurred background.")
            }
            section("Connections") {
                setting("Notify on plug-in", icon: "bell", value: $model.notify, info: "Show a notification when macOS detects a new connection. Off by default.")
                setting("Notify on unplug", icon: "bell.slash", value: Binding(get: { notifyUnplug }, set: { notifyUnplug = $0; if $0 { Model.requestNotificationAccess() } }),
                        info: "Show a notification when a connection disappears, including docks, Ethernet and headphones. Off by default.")
                setting("Plug-in popup", icon: "bubble.middle.bottom", value: $plugPopup, info: "Briefly show the new connection under the menu bar icon when something is plugged in.")
                setting("Select new connections", icon: "cursorarrow.click", value: $selectNew, info: "Jump to and briefly highlight a connection when it is plugged in. Off keeps your current selection.")
                setting("Devices under docks", icon: "list.bullet.indent", value: $dockNesting, info: "List the devices connected through a dock or hub right under it in the sidebar. Off shows the dock alone; its detail view still lists them.")
                setting("Technical details", icon: "doc.text.magnifyingglass", value: $technicalDetails, info: "Show identity values, ratings, Power Delivery profiles and the raw table at the end of each connection's detail view.")
            }
            section("Network") {
                choice("Refresh every", icon: "arrow.clockwise", selection: $networkInterval, options: Setting.intervals.map { ($0, "\(Int($0)) s") },
                       info: "How often Network mode reads traffic and sockets while the window is open. Shorter intervals react faster and use slightly more energy. With the window closed, Strand reads interfaces every 15 seconds and still notices Ethernet cables and address changes at once.")
                setting("Hide connections within this Mac", icon: "arrow.triangle.2.circlepath", value: $hideLoopback, info: "Leave out connections whose remote end is this Mac (loopback), which apps use to talk to each other locally.")
                setting("Show traffic in bits per second", icon: "speedometer", value: $trafficBits, info: "Show network rates in kbit/s and Mbit/s, the units internet plans use, instead of KB/s and MB/s. Totals stay in bytes.")
            }
            section("Monitoring") {
                setting("Power and read/write usage", icon: "waveform.path", value: $model.monitoring, info: "Sample Mac power input and available USB storage read/write rates every two seconds. Graphs appear only when measurements are available. These are system input and device activity, not per-cable traffic. Turning this off stops storage-counter sampling and clears graph history.")
            }
            section("Updates") {
                setting("Check automatically", icon: "arrow.triangle.2.circlepath", value: $updates.automatic, info: "Check for new Strand releases automatically. Off by default. You can always check manually below.")
                HStack {
                    Spacer()
                    Button("Check for Updates…") { updates.check() }.controlSize(.regular)
                }.padding(.top, 4)
            }
            HStack(alignment: .bottom) {
                Text("© \(String(Calendar.current.component(.year, from: Date()))) opyuii\nAll rights reserved.").font(Style.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Version \(version) (\(build))").foregroundStyle(.secondary).textSelection(.enabled)
                    Link("opyuii.com", destination: URL(string: "https://opyuii.com")!)
                }.font(Style.caption)
            }.padding(.horizontal, 4)
        }.padding(24).frame(maxWidth: 480)
    }
    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0" }
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development" }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(Style.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 4)
            VStack(alignment: .leading, spacing: 16, content: content).padding(16).modifier(Surface(radius: Style.radius))
        }
    }
    private func setting(_ title: String, icon: String, value: Binding<Bool>, info: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(Style.body).foregroundStyle(.secondary).frame(width: 20).accessibilityHidden(true)
            Text(title).font(Style.body)
            InfoHint(text: info)
            Spacer(minLength: 8)
            Toggle(title, isOn: value).labelsHidden().toggleStyle(.switch).controlSize(.small).accessibilityLabel(title)
        }
    }
    private func choice<Value: Hashable>(_ title: String, icon: String, selection: Binding<Value>, options: [(Value, String)], info: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(Style.body).foregroundStyle(.secondary).frame(width: 20).accessibilityHidden(true)
            Text(title).font(Style.body)
            InfoHint(text: info)
            Spacer(minLength: 8)
            Picker(title, selection: selection) { ForEach(options, id: \.0) { Text($0.1).tag($0.0) } }
                .labelsHidden().pickerStyle(.menu).fixedSize().controlSize(.small).accessibilityLabel(title)
        }
    }
}

/// Debug aid: `--fixture <name> --snapshot <png> [--panel] [--dark|--light]` renders a view offscreen and quits.
/// It shows layout only; behind-window blur needs a visible window.
@MainActor enum SnapshotRenderer {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), args.indices.contains(i + 1) else { return }
        let path = args[i + 1]
        DispatchQueue.main.async {
            let model = Model()
            let updates = Updates()
            let panel = args.contains("--panel")
            let root: AnyView = panel ? AnyView(Panel(model: model, updates: updates)) : AnyView(Inspector(model: model, updates: updates))
            let size = panel ? CGSize(width: 360, height: 420) : CGSize(width: 920, height: 640)
            let host = NSHostingView(rootView: root)
            host.frame = CGRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: args.contains("--light") ? .aqua : .darkAqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                exit(0)
            }
        }
    }
}

@MainActor final class StrandLifecycle: NSObject, NSApplicationDelegate {
    private var observers: [NSObjectProtocol] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        StatusBar.shared.configure(model: .shared, updates: .shared)
        Setting.applyAppearance()
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeMainNotification, NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let closing = note.name == NSWindow.willCloseNotification ? note.object as? NSWindow : nil
                MainActor.assumeIsolated { self?.updateDockPresence(ignoring: closing) }
            })
        }
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateDockPresence(ignoring: nil)
                Setting.applyAppearance()
                Model.shared.updateMenuBarPower()
            }
        })
        updateDockPresence(ignoring: nil)
    }
    /// The Dock icon follows the main window. Without a menu bar item the app stays in the Dock so it remains reachable.
    private var updating = false
    private func updateDockPresence(ignoring closing: NSWindow?) {
        guard !updating else { return }
        updating = true; defer { updating = false }
        let menuBar = UserDefaults.standard.object(forKey: "menuBarEnabled") as? Bool ?? true
        let defaults = UserDefaults.standard
        let menuBarShown = menuBar && !(defaults.bool(forKey: "hideMenuBarWhenIdle") && defaults.bool(forKey: "strand.idle"))
        let hiddenOnPurpose = menuBar && !menuBarShown
        let windowOpen = NSApp.windows.contains { $0 !== closing && $0.title == "Strand" && $0.isVisible }
        StatusBar.shared.setVisible(menuBarShown)
        let policy: NSApplication.ActivationPolicy = (windowOpen || (!menuBarShown && !hiddenOnPurpose)) ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Bridge.openWindow?() }
        return true
    }
}
