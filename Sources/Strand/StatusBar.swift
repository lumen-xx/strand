import SwiftUI
import AppKit

/// Lets the AppKit-hosted panel open the SwiftUI window scene.
@MainActor enum Bridge { static var openWindow: (() -> Void)? }

/// Menu bar item whose popover is centred under the icon and shows an arrow pointing at it.
@MainActor final class StatusBar: NSObject {
    static let shared = StatusBar()
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var model: Model?
    private var updates: Updates?

    func configure(model: Model, updates: Updates) {
        guard item == nil else { return }
        self.model = model; self.updates = updates
        let hosting = NSHostingController(rootView: Panel(model: model, updates: updates))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = true
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = status.button {
            button.image = NSImage(systemSymbolName: "cable.connector", accessibilityDescription: "Strand")
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Strand")
        }
        item = status
        if CommandLine.arguments.contains("--tip-test") { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if let first = model.items.first { self.showPlug(item: first) } } }
    }

    /// Shows the powering connection's wattage beside the icon, or the icon alone.
    func setPowerTitle(_ text: String?) {
        guard let item, let button = item.button else { return }
        let title = text.map { " " + $0 } ?? ""
        guard button.title != title else { return }
        button.title = title
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeft
        item.length = title.isEmpty ? NSStatusItem.squareLength : NSStatusItem.variableLength
        button.setAccessibilityLabel(text.map { "Strand, charging at \($0)" } ?? "Strand")
    }

    func setVisible(_ visible: Bool) {
        if !visible { close() }
        // Changing visibility writes defaults, which re-enters callers observing defaults; apply only real changes.
        guard let item, item.isVisible != visible else { return }
        item.isVisible = visible
    }

    func close() { popover.performClose(nil) }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu() } else { toggle() }
    }

    private func showMenu() {
        guard let button = item?.button else { return }
        close()
        let menu = NSMenu()
        func add(_ title: String, _ action: @escaping () -> Void) {
            let entry = NSMenuItem(title: title, action: #selector(MenuTarget.run), keyEquivalent: "")
            let target = MenuTarget(action); entry.target = target; entry.representedObject = target
            menu.addItem(entry)
        }
        add("Open Strand") { Self.shared.openMain() }
        menu.addItem(.separator())
        add("Settings…") { Self.shared.model?.showingSettings = true; Self.shared.openMain() }
        add("Check for Updates…") { Self.shared.updates?.check() }
        menu.addItem(.separator())
        add("Quit Strand") { NSApp.terminate(nil) }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    private func openMain() {
        if let open = Bridge.openWindow { open() }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func toggle() {
        guard let button = item?.button else { return }
        if popover.isShown { close(); return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private var tip: NSPanel?
    private var tipTimer: Timer?

    /// Small card under the menu bar icon, styled like the menu bar panel, naming what just connected for two seconds.
    func showPlug(item: ConnectionItem) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.presentTip(item) }
    }

    private func presentTip(_ connection: ConnectionItem) {
        guard let item, item.isVisible, !popover.isShown, let button = item.button, let window = button.window else { return }
        let arrow: CGFloat = 8
        let size = NSSize(width: 190, height: 56 + arrow)
        let bubble = BubbleShape(arrowHeight: arrow, arrowWidth: 18, radius: 14)
        let card = HStack(spacing: 9) {
            ItemIcon(item: connection, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.name).font(Style.type(13, weight: 600)).lineLimit(1)
                HStack(spacing: 4) {
                    Circle().fill(connection.color).frame(width: 5, height: 5)
                    Text("Connected").font(Style.type(10.5, weight: 500)).foregroundStyle(connection.color)
                }
            }
            Spacer(minLength: 0)
        }
            .padding(.horizontal, 12).padding(.top, arrow).frame(width: size.width, height: size.height)
            .clipShape(bubble)
            .overlay(bubble.stroke(.white.opacity(0.14), lineWidth: 0.5))
        let hosting = NSHostingView(rootView: card)
        hosting.frame = NSRect(origin: .zero, size: size)
        tip?.orderOut(nil)
        let panel = NSPanel(contentRect: hosting.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .statusBar; panel.ignoresMouseEvents = true; panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        // Keep the native blur outside SwiftUI's clip: clipping an embedded visual-effect
        // view can flatten its backdrop in this small, nonactivating window.
        let backdrop = NSVisualEffectView(frame: hosting.frame)
        backdrop.material = .sidebar
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        let mask = NSImage(size: size)
        mask.lockFocus()
        if let context = NSGraphicsContext.current?.cgContext {
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            context.addPath(bubble.path(in: CGRect(origin: .zero, size: size)).cgPath)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
        }
        mask.unlockFocus()
        backdrop.maskImage = mask
        backdrop.addSubview(hosting)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = backdrop
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        panel.setFrameOrigin(NSPoint(x: anchor.midX - size.width / 2, y: anchor.minY - size.height - 1))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; panel.animator().alphaValue = 1 }
        tip = panel
        tipTimer?.invalidate()
        tipTimer = Timer.scheduledTimer(withTimeInterval: CommandLine.arguments.contains("--tip-test") ? 15 : 2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let panel = self?.tip else { return }
                NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 }, completionHandler: { panel.orderOut(nil) })
            }
        }
    }
}

@MainActor final class MenuTarget: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}

/// Rounded card with a small arrow centred on the top edge.
struct BubbleShape: Shape {
    var arrowHeight: CGFloat
    var arrowWidth: CGFloat
    var radius: CGFloat
    func path(in rect: CGRect) -> Path {
        let body = CGRect(x: rect.minX, y: rect.minY + arrowHeight, width: rect.width, height: rect.height - arrowHeight)
        var path = Path(roundedRect: body, cornerRadius: radius, style: .continuous)
        path.move(to: CGPoint(x: rect.midX - arrowWidth / 2, y: body.minY))
        path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.minY), control: CGPoint(x: rect.midX - arrowWidth / 5, y: rect.minY + 1))
        path.addQuadCurve(to: CGPoint(x: rect.midX + arrowWidth / 2, y: body.minY), control: CGPoint(x: rect.midX + arrowWidth / 5, y: rect.minY + 1))
        path.closeSubpath()
        return path
    }
}
