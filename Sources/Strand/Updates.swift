import AppKit
import Combine
import Sparkle
@MainActor final class Updates: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = Updates()
    @Published var automatic = UserDefaults.standard.bool(forKey: "strand.autoUpdates") {
        didSet { UserDefaults.standard.set(automatic, forKey: "strand.autoUpdates"); controller.updater.automaticallyChecksForUpdates = automatic }
    }
    private lazy var controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
    private var observer: NSObjectProtocol?
    override init() {
        super.init()
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow else { return }
            let owner = window.windowController.map { String(describing: type(of: $0)) } ?? ""
            if owner.contains("SU") || String(describing: type(of: window)).hasPrefix("SU") {
                MainActor.assumeIsolated { window.level = .modalPanel; window.orderFrontRegardless() }
            }
        }
        if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil { controller.startUpdater(); controller.updater.automaticallyChecksForUpdates = automatic }
    }
    func check() { NSApp.activate(ignoringOtherApps: true); controller.checkForUpdates(nil) }
    func allowedChannels(for updater: SPUUpdater) -> Set<String> { ["preview"] }
}
