import SwiftUI
import StrandCore

struct ConnectionItem: Identifiable, Equatable, Codable {
    var id: String
    var name: String
    var port: String
    var kind: String = "cable"
    var chip: String = "Connected"
    var tone: String = "neutral"
    var speed: String?
    var power: String?
    var powerExplanation: String?
    var verdict: String?
    var link: String?
    var summary: String?
    var facts: [CableFact]?
    var profiles: [ProfileFact]?
    var details: String = ""
    var spoken: String?
    /// The charger powering the Mac through this connection. Shown with the cable in the detail view only.
    var charger: RelatedCharger?
    /// This connection supplies power to the Mac; its tag shows a bolt and the selected wattage.
    var powering: Bool?
    var dock: DockInfo?
    /// macOS name of an Ethernet adapter, used to place it under the dock that contains it.
    var adapter: String?
    /// The dock or hub item a device is connected through.
    var parent: String?
    /// A mouse, keyboard, headset or receiver plugged straight into this port; shown beside the cable.
    var deviceKind: String?
    /// The cable's e-marker reports Apple's USB vendor ID. A reported ID is not proof of authenticity.
    var appleEMarker: Bool { facts?.contains { $0.name == "Cable vendor ID" && $0.value.uppercased() == "0X05AC" } == true }
    var color: Color { tone == "amber" ? .orange : tone == "green" ? .green : .accentColor }
    var accessibility: String { spoken ?? "\(name), \(chip), \(port)" }
    static func live(_ port: StrandCore.Port, metadata: ConnectionMetadata? = nil) -> Self {
        let magSafe = port.name.contains("MagSafe")
        let knownDevice = !port.device.contains("Not reported") && port.device != "Nothing connected"
        // The copyable details keep only what macOS reported; "Not reported" filler and caveat paragraphs stay out of view.
        var reported = port.report.split(separator: "\n").map(String.init)
            .filter { !$0.contains("Not reported") && !$0.hasPrefix("The weakest link") }.joined(separator: "\n")
        if let metadata { reported += "\n" + metadata.facts.map { $0.name + ": " + $0.value }.joined(separator: "\n") }
        if let dock = metadata?.dock {
            reported += "\n" + ([("Connected through", dock.title)] + (dock.link.map { [("Dock link", $0)] } ?? [])).map { $0.0 + ": " + $0.1 }.joined(separator: "\n")
        }
        var item = Self(id: port.id, name: magSafe ? "MagSafe cable" : metadata?.dock?.title ?? metadata?.name ?? (knownDevice ? port.device : "USB-C cable"), port: port.name, kind: magSafe ? "magsafe" : "cable",
                    speed: port.capabilities.speed, power: (port.capabilities.active?.watts ?? port.capabilities.cableWatts).map { number($0) + " W" },
                    powerExplanation: port.capabilities.active != nil ? "Selected USB-PD power option for this port, not instantaneous power draw." : "Cable capability from the e-marker, not instantaneous power draw.",
                    verdict: port.capabilities.summary == nil ? nil : "Limited", link: port.transports.isEmpty ? nil : port.transports.joined(separator: ", "), summary: port.capabilities.summary,
                    facts: port.capabilities.facts.map { CableFact(name: $0.0, value: $0.1) } + (metadata?.facts ?? []),
                    profiles: port.capabilities.profiles.enumerated().map { index, option in
                        let active = port.capabilities.active.map { selected in
                            if let id = selected.identifier, let optionID = option.identifier { return id == optionID }
                            let matching = port.capabilities.profiles.filter { $0.volts == selected.volts && $0.amps >= selected.amps && $0.watts >= selected.watts }
                            return matching.count == 1 && matching[0] == option
                        } ?? false
                        return ProfileFact(id: index, value: option.description, active: active)
                    }, details: reported)
        item.dock = metadata?.dock
        if let shown = metadata?.device?.shown, metadata?.dock == nil {
            item.deviceKind = shown.kind; item.chip = shown.label
            if metadata?.device?.wireless == true { item.facts = (item.facts ?? []) + [CableFact(name: "Connection", value: "Wireless USB receiver")] }
        }
        return item
    }
}

struct CableFact: Codable, Equatable { var name: String; var value: String }
extension ConnectionItem {
    /// Headphones, keyboards and mice behind a dock or hub get their own row and detail. Other devices stay in the hub's list.
    static func device(_ device: DockDevice, through hub: ConnectionItem) -> ConnectionItem? {
        guard let shown = device.shown else { return nil }
        let parts = device.value.components(separatedBy: " · ")
        let link = parts.first { $0.hasSuffix("bps") }, maker = parts.first { !$0.hasSuffix("bps") }
        var facts = [CableFact(name: "Connected through", value: hub.dock?.title ?? hub.name)]
        if device.wireless == true { facts.append(CableFact(name: "Connection", value: "Wireless USB receiver")) }
        if let link { facts.append(CableFact(name: "USB link", value: link)) }
        if let maker { facts.append(CableFact(name: "Manufacturer", value: maker)) }
        return ConnectionItem(id: "device:" + hub.id + ":" + device.name, name: device.name, port: (hub.dock?.title ?? hub.name) + " · " + hub.port, kind: shown.kind,
                              chip: shown.label, verdict: "Connected", link: "USB", facts: facts,
                              details: facts.map { $0.name + ": " + $0.value }.joined(separator: "\n"), parent: hub.id)
    }
}
struct RelatedCharger: Codable, Equatable {
    var name: String
    var apple: Bool { facts.contains { $0.name == "Charger manufacturer" && $0.value.hasPrefix("Apple") } }
    var power: String?
    var charging: Bool?
    var facts: [CableFact] = []
    /// macOS reports one adapter for the whole Mac. Callers attach it only to the single port with a selected power option.
    static func reported(_ power: PowerSnapshot) -> RelatedCharger? {
        guard let adapter = power.adapter else { return nil }
        let rating = adapter.watts.map { number($0) + " W" }
        var facts: [CableFact] = []
        if let rating { facts.append(CableFact(name: "Charger rating", value: rating)) }
        if let input = power.inputWatts { facts.append(CableFact(name: "Mac power input", value: String(format: "%.1f W", input))) }
        if let manufacturer = adapter.manufacturer { facts.append(CableFact(name: "Charger manufacturer", value: manufacturer)) }
        if let model = adapter.model { facts.append(CableFact(name: "Charger model", value: model)) }
        if let firmware = adapter.firmware { facts.append(CableFact(name: "Charger firmware", value: firmware)) }
        if adapter.wireless { facts.append(CableFact(name: "Charger type", value: "Wireless")) }
        return RelatedCharger(name: adapter.name ?? rating.map { $0 + " charger" } ?? "Charger", power: rating, charging: power.charging, facts: facts)
    }
}
struct ConnectionMetadata: Equatable { var name: String? = nil; var facts: [CableFact] = []; var dock: DockInfo? = nil; var device: DockDevice? = nil }
/// A hub or dock behind a USB-C port. Only Thunderbolt docks report a maker and model; USB-C docks report their hub chips.
struct DockInfo: Codable, Equatable {
    /// "dock" for Thunderbolt docks, which identify themselves; every other hub is "hub".
    var kind: String
    var maker: String?
    var model: String?
    /// Fastest link between the Mac and the hub.
    var link: String?
    /// Devices currently connected through it, with their link speed and reported manufacturer.
    var devices: [DockDevice] = []
    /// The hub's own functions, such as a display output or an empty card reader.
    var builtIn: [String]?
    var title: String {
        // "CalDigit, Inc." reads better as "CalDigit" next to a model name.
        let brand = maker?.replacingOccurrences(of: #",?\s+(Inc\.?|Co\.,? Ltd\.?|Ltd\.?|LLC|GmbH|Corp\.?|Corporation)$"#, with: "", options: [.regularExpression, .caseInsensitive])
        let reported = [brand, model].compactMap { $0 }.joined(separator: " ")
        return reported.isEmpty ? (kind == "dock" ? "Thunderbolt dock" : "USB-C hub") : reported
    }
}
struct DockDevice: Codable, Equatable {
    var name: String
    /// Link speed and reported manufacturer.
    var value: String
    /// Category from the device's USB classes and HID usages: audio, keyboard, mouse, receiver, input, storage, camera or network.
    var kind: String?
    /// A USB receiver for a 2.4 GHz or Bluetooth LE device.
    var wireless: Bool?
    /// Item kind and tag for devices shown with their own photo; nil for devices listed only in a hub's detail.
    var shown: (kind: String, label: String)? {
        guard let kind else { return nil }
        let mapped = ["audio": ("headphones", "Headphones"), "keyboard": ("keyboard", "Keyboard"), "mouse": ("mouse", "Mouse"), "receiver": ("receiver", "Receiver")][kind]
        return mapped.map { (kind: $0.0, label: (wireless == true && kind != "receiver" ? "Wireless " + $0.1.lowercased() : $0.1)) }
    }
}
struct ProfileFact: Codable, Equatable, Identifiable { var id: Int; var value: String; var active: Bool }

// MARK: Product photography

/// Representative product renders, white in light appearance and black in dark appearance. Choosing an image never
/// changes reported identity or ratings; sources are listed in ConnectionImages/sources.json.
enum ConnectionPhoto {
    /// nil for connections without a product photo; they use a symbol instead.
    static func name(kind: String, speed: String? = nil, dark: Bool = false) -> String? {
        // One image serves both appearances for Ethernet.
        if kind == "ethernet" { return kind }
        // Docks show the hub image too: one familiar shape is easier to recognise than a particular dock.
        if kind == "dock" { return "hub" + (dark ? "-dark" : "-light") }
        if ["hub", "headphones", "keyboard", "mouse"].contains(kind) { return kind + (dark ? "-dark" : "-light") }
        // Remaining device categories use symbols.
        if ConnectionDrawing.symbols[kind] != nil { return nil }
        let shade = dark ? "-dark" : "-light"
        if kind == "magsafe" { return "magsafe" + shade }
        // The charger's wattage is in its name and facts; one representative photo covers every rating.
        if kind == "charger" { return "charger" + shade }
        if let gbps = quantity(speed, unit: "Gbps") {
            if gbps >= 80 { return "thunderbolt-5" + shade }
            if gbps >= 5 { return "thunderbolt-4" + shade }
        }
        return "usb-c" + shade
    }
    private static func quantity(_ text: String?, unit: String) -> Double? {
        guard let text, let expression = try? NSRegularExpression(pattern: "([0-9]+(?:\\.[0-9]+)?)\\s*" + unit),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Double(text[range])
    }
    static let images: [String: NSImage] = {
        let names = ["ethernet"] + ["usb-c", "magsafe", "thunderbolt-4", "thunderbolt-5", "charger", "hub", "headphones", "keyboard", "mouse"].flatMap { [$0 + "-light", $0 + "-dark"] }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Resources/ConnectionImages")
        return Dictionary(uniqueKeysWithValues: names.compactMap { name in
            let url = Bundle.main.resourceURL?.appendingPathComponent("ConnectionImages/\(name).png")
            guard let image = url.flatMap({ NSImage(contentsOf: $0) }) ?? NSImage(contentsOf: source.appendingPathComponent(name + ".png")) else { return nil }
            return (name, image)
        })
    }()
}

struct ConnectionDrawing: View {
    var kind = "cable"
    var color: Color = .secondary
    var speed: String?
    @Environment(\.colorScheme) private var scheme
    static let symbols = ["hdmi": "tv", "receiver": "dot.radiowaves.left.and.right", "keyboard": "keyboard", "mouse": "computermouse", "input": "gamecontroller", "storage": "externaldrive",
                          "camera": "web.camera", "network": "network", "usb": "cable.connector"]
    var body: some View {
        Group {
            if let name = ConnectionPhoto.name(kind: kind, speed: speed, dark: scheme == .dark), let image = ConnectionPhoto.images[name] {
                // No shadow: in dark mode it read as a glow around the photo, and the renders carry their own shading.
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: Self.symbols[kind] ?? "cable.connector").resizable().scaledToFit()
                    .foregroundStyle(kind == "cable" ? Color.secondary : color).scaleEffect(0.6)
            }
        }.accessibilityHidden(true)
    }
}
