import SwiftUI
import CoreText

enum Style {
    private static let registered: Void = {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("Fonts/BricolageGrotesque.ttf")
        let development = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Resources/Fonts/BricolageGrotesque.ttf")
        if let url = [bundled, development].compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()
    static func type(_ size: CGFloat, weight: Double = 400) -> Font {
        _ = registered
        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontNameAttribute: "BricolageGrotesque-Regular",
            kCTFontVariationAttribute: [NSNumber(value: 0x77676874): NSNumber(value: weight),
                                       NSNumber(value: 0x6F70737A): NSNumber(value: Double(size)),
                                       NSNumber(value: 0x77647468): NSNumber(value: 100)]
        ] as CFDictionary)
        return Font(CTFontCreateWithFontDescriptor(descriptor, size, nil))
    }
    static let hero = type(30, weight: 700)
    static let number = type(26, weight: 600)
    static let heading = type(17, weight: 600)
    static let title = type(15, weight: 600)
    static let body = type(13)
    static let caption = type(12)
    static let inset: CGFloat = 16
    static let radius: CGFloat = 18
    static let tileRadius: CGFloat = 22
    static let blurStrength: CGFloat = 1
}

/// Frosted card. Liquid Glass on macOS 26, material before that, opaque when Reduce Transparency is on.
struct Surface: ViewModifier {
    var radius = Style.tileRadius
    @Environment(\.accessibilityReduceTransparency) private var opaque
    func body(content: Content) -> some View {
        if opaque { content.background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: radius, style: .continuous)) }
        else if #available(macOS 26, *) { content.glassEffect(.regular, in: .rect(cornerRadius: radius)) }
        else {
            content.background(.thinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
        }
    }
}

/// Soft colour wash that follows the selected item's verdict. It sits above the blur and below the content.
struct Aurora: View {
    var color: Color
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var moving = false
    /// Drift time from earlier runs, and when the current run began; pausing keeps the circles where they are.
    @State private var elapsed: TimeInterval = 0
    @State private var runStart: Date?
    var body: some View {
        // The drift redraws three large blurs every frame. As a repeat-forever animation it never stopped, even with
        // the window closed, which kept Strand at 10–15% CPU while idle. A paused timeline doesn't tick at all, so
        // the circles move only while the window is on screen and Strand is active, at 20 frames a second.
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !moving)) { context in
            let time = elapsed + (runStart.map { context.date.timeIntervalSince($0) } ?? 0)
            // Eases from rest to the far position over 9 seconds and back over the next 9, like the old animation.
            circles(drift: (1 - cos(time * .pi / 9)) / 2)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.8), value: color)
        .background(WindowActivityReader { active in moving = active && !reduceMotion })
        .onChange(of: moving) { _, on in
            if on { runStart = Date() }
            else if let runStart { elapsed += Date().timeIntervalSince(runStart); self.runStart = nil }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }

    private func circles(drift: Double) -> some View {
        let between = { (rest: Double, far: Double) in rest + (far - rest) * drift }
        return GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack {
                if !opaque {
                    SoftGlow(color: color.opacity(0.14), diameter: w * 0.8, softness: 90)
                        .offset(x: w * between(0.34, 0.22), y: h * between(-0.18, -0.30))
                    SoftGlow(color: Color.indigo.opacity(0.12), diameter: w * 0.6, softness: 100)
                        .offset(x: w * between(-0.18, -0.30), y: h * between(0.22, 0.34))
                    SoftGlow(color: color.opacity(0.12), diameter: w * 0.45, softness: 80)
                        .offset(x: w * between(0.15, 0.05), y: h * 0.40)
                }
            }.frame(width: w, height: h)
        }
    }
}

/// A circle with very soft edges, as a blurred circle looks, drawn as a radial gradient. A real blur this large
/// cost about 14% CPU per moving frame; a gradient is a fraction of that.
private struct SoftGlow: View {
    var color: Color
    var diameter: CGFloat
    var softness: CGFloat
    var body: some View {
        let radius = diameter / 2, reach = radius + softness * 2
        // Full strength inside, half at the original edge, gone two blur radii out, like a Gaussian-blurred disc.
        let inner = max(0, radius - softness) / reach
        Circle()
            .fill(RadialGradient(stops: [
                .init(color: color, location: 0),
                .init(color: color, location: inner),
                .init(color: color.opacity(0.5), location: radius / reach),
                .init(color: color.opacity(0.12), location: (radius + softness) / reach),
                .init(color: color.opacity(0), location: 1)
            ], center: .center, startRadius: 0, endRadius: reach))
            .frame(width: reach * 2, height: reach * 2)
    }
}

/// Reports whether its window is on screen and Strand is the active app, so ambient motion can rest otherwise.
struct WindowActivityReader: NSViewRepresentable {
    var onChange: (Bool) -> Void
    func makeNSView(context: Context) -> ReaderView { ReaderView(onChange: onChange) }
    func updateNSView(_ view: ReaderView, context: Context) { view.onChange = onChange }
    final class ReaderView: NSView {
        var onChange: (Bool) -> Void
        private var observers: [NSObjectProtocol] = []
        private var reported: Bool?
        init(onChange: @escaping (Bool) -> Void) { self.onChange = onChange; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver); observers = []
            var watched: [(Notification.Name, AnyObject?)] = [(NSApplication.didBecomeActiveNotification, nil), (NSApplication.didResignActiveNotification, nil)]
            if let window {
                watched += [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification].map { ($0, window) }
            }
            for (name, object) in watched {
                observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] note in
                    let closing = note.name == NSWindow.willCloseNotification
                    MainActor.assumeIsolated { self?.report(closing: closing) }
                })
            }
            report(closing: false)
        }
        private func report(closing: Bool) {
            let active = !closing && NSApp.isActive && window?.isVisible == true && window?.occlusionState.contains(.visible) == true
            guard active != reported else { return }
            reported = active
            // Not during a SwiftUI update pass.
            DispatchQueue.main.async { [weak self] in self?.onChange(active) }
        }
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}

/// AppKit behind-window blur: the desktop and the apps behind Strand are the real blur source.
struct WindowGlass: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var configuresWindowChrome = true
    final class View: NSVisualEffectView {
        var configuresWindowChrome = true
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            configure(window)
            // SwiftUI may restore its own background after the first layout pass.
            DispatchQueue.main.async { [weak self] in if let w = self?.window { self?.configure(w) } }
        }
        private func configure(_ window: NSWindow) {
            window.isOpaque = false
            window.backgroundColor = .clear
            guard configuresWindowChrome else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.styleMask.insert(.fullSizeContentView)
            window.styleMask.remove(.miniaturizable)
            window.collectionBehavior.insert(.fullScreenNone)
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
        }
    }
    func makeNSView(context: Context) -> View {
        let view = View()
        view.configuresWindowChrome = configuresWindowChrome
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        // Keep fully opaque: lower alpha mixes the sharp desktop back in instead of blurring it. Native materials
        // do not expose a public blur-radius control.
        view.alphaValue = Style.blurStrength
        return view
    }
    func updateNSView(_ view: View, context: Context) {
        view.configuresWindowChrome = configuresWindowChrome
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.alphaValue = Style.blurStrength
    }
}

/// Complete window background: blur, colour wash and a gentle tint so text stays readable.
struct WindowBackground: View {
    var color: Color
    var configuresWindowChrome = true
    @AppStorage(Setting.colorWash) private var colorWash = true
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            if opaque { Color(nsColor: .windowBackgroundColor) }
            else {
                WindowGlass(configuresWindowChrome: configuresWindowChrome)
                if colorWash { Aurora(color: color) }
            }
        }.ignoresSafeArea().accessibilityHidden(true)
    }
}

/// One neutral backdrop spanning the mode switch and content, without a colour wash.
struct MenuPanelBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var opaque
    var body: some View {
        Group {
            if opaque { Color(nsColor: .windowBackgroundColor) }
            else { WindowGlass(configuresWindowChrome: false) }
        }.ignoresSafeArea().accessibilityHidden(true)
    }
}

struct RoundIconButton: View {
    var systemImage: String
    var label: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            RoundIconLabel(systemImage: systemImage, label: label)
        }.buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
}

struct RoundIconLabel: View {
    var systemImage: String
    var label: String
    @State private var hovering = false
    var body: some View {
        Image(systemName: systemImage).font(.system(size: 14, weight: .medium))
            .frame(width: 34, height: 34).foregroundStyle(hovering ? Color.primary : Color.secondary)
            .background(Circle().fill(Color.primary.opacity(hovering ? 0.14 : 0.07)))
            .contentShape(Circle()).onHover { hovering = $0 }.accessibilityLabel(label)
    }
}
