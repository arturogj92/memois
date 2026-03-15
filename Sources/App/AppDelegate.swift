import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel

    private var dockTabController: DockTabController!
    private var shortcutMonitor: GlobalShortcutMonitor!
    private var statusItem: NSStatusItem!
    private var cancellables: Set<AnyCancellable> = []

    override init() {
        let settings = SettingsStore()
        self.model = AppModel(
            settings: settings,
            permissions: PermissionManager(),
            recordingStore: RecordingStore(),
            audioRecorder: AudioRecorder(),
            assemblyAI: AssemblyAIClient()
        )
        super.init()

        dockTabController = DockTabController(model: model, settings: settings)
        model.showMainWindow = { [weak self] in self?.presentMainWindow() }
        model.showFloatingPanel = { [weak self] in
            self?.dockTabController.show()
        }
        model.hideFloatingPanel = { [weak self] in
            self?.dockTabController.hide()
        }

        rebuildShortcutMonitor()

        settings.$shortcutKeyCode
            .combineLatest(settings.$shortcutModifierFlagsRawValue)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.rebuildShortcutMonitor() }
            .store(in: &cancellables)

        model.$sessionState
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                if state != .recording {
                    self.dockTabController.hide()
                }
            }
            .store(in: &cancellables)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyActivationPolicy()
        shortcutMonitor.start()
        configureStatusItem()
        model.refreshPermissions()
        presentMainWindow()

        model.settings.$hideDockIcon
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyActivationPolicy() }
            .store(in: &cancellables)
    }

    private func applyActivationPolicy() {
        NSApp.setActivationPolicy(model.settings.hideDockIcon ? .accessory : .regular)
    }

    func applicationWillTerminate(_ notification: Notification) {
        shortcutMonitor.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Memois")
        statusItem.button?.imagePosition = .imageOnly

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show Recordings", action: #selector(showMainWindowFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Refresh Permissions", action: #selector(refreshPermissionsFromMenu), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Memois", action: #selector(quitApplication), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    private func rebuildShortcutMonitor() {
        shortcutMonitor?.stop()
        shortcutMonitor = GlobalShortcutMonitor(
            keyCode: model.settings.shortcutKeyCode,
            requiredFlags: model.settings.shortcutModifierFlags
        )
        shortcutMonitor.onPress = { [weak self] in
            Task { @MainActor [weak self] in
                self?.model.handleShortcutPressed()
            }
        }
        // No release handler — toggle mode
        if NSApp != nil { shortcutMonitor.start() }
    }

    private func presentMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { !($0 is NSPanel) }) {
            window.collectionBehavior.insert(.moveToActiveSpace)
            if let screen = NSScreen.main ?? NSScreen.screens.first,
               !screen.visibleFrame.intersects(window.frame) {
                window.center()
            }
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func showMainWindowFromMenu() { presentMainWindow() }
    @objc private func refreshPermissionsFromMenu() {
        model.refreshPermissions()
        presentMainWindow()
    }
    @objc private func quitApplication() { NSApp.terminate(nil) }
}
