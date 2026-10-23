import AppKit

/// Keys and defaults for user settings. Views bind with @AppStorage; models read through these helpers.
enum Setting {
    static let startMode = "strand.startMode"            // "last", "cables" or "network"
    static let appearance = "strand.appearance"          // "system", "light" or "dark"
    static let colorWash = "strand.colorWash"
    static let menuBarPower = "strand.menuBarPower"
    static let plugPopup = "strand.plugPopup"
    static let selectNew = "strand.selectNew"
    static let notifyUnplug = "strand.notifyUnplug"
    static let dockNesting = "strand.dockNesting"
    static let technicalDetails = "strand.technicalDetails"
    static let networkInterval = "strand.networkInterval"
    static let hideLoopback = "strand.hideLoopback"
    static let trafficBits = "strand.trafficBits"

    /// Reads like @AppStorage does, so "YES"/"1" strings from launch arguments count as true.
    static func flag(_ key: String, default value: Bool) -> Bool { UserDefaults.standard.object(forKey: key) == nil ? value : UserDefaults.standard.bool(forKey: key) }
    static let intervals: [Double] = [1, 2, 3, 5]
    static var refreshInterval: TimeInterval {
        let value = UserDefaults.standard.double(forKey: networkInterval)
        return intervals.contains(value) ? value : 3
    }

    /// Applies the theme to every window, including the menu bar panel. Launch arguments for previews take precedence in the scene.
    /// Runs on every settings change, so it only touches NSApp when the theme differs: assigning an appearance,
    /// even the same one, makes every window lay out again.
    @MainActor static func applyAppearance() {
        let target: NSAppearance.Name?
        switch UserDefaults.standard.string(forKey: appearance) {
        case "light": target = .aqua
        case "dark": target = .darkAqua
        default: target = nil
        }
        guard NSApp.appearance?.name != target else { return }
        NSApp.appearance = target.flatMap { NSAppearance(named: $0) }
    }

    /// Network rates in bytes or bits per second, following the setting.
    static func rate(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond else { return "—" }
        return flag(trafficBits, default: false) ? bits(bytesPerSecond) : StorageUsage.formatted(bytesPerSecond)
    }
    static func bits(_ bytesPerSecond: Double) -> String {
        let value = bytesPerSecond * 8
        if value >= 1_000_000_000 { return String(format: "%.1f Gbit/s", value / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1f Mbit/s", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1f kbit/s", value / 1_000) }
        return String(format: "%.0f bit/s", value)
    }
}
