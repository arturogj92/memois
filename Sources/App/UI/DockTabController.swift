import AppKit
import Combine
import SwiftUI

// Panel subclass that never steals focus — dragging won't activate the app
private class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class DockTabController {
    private let panel: NSPanel
    private let hostingController: NSHostingController<DockTabView>
    private weak var model: AppModel?
    private let settings: SettingsStore

    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var currentScreenID: CGDirectDisplayID?
    private var cancellables: Set<AnyCancellable> = []
    /// True while we're programmatically repositioning — ignore didMove saves
    private var isRepositioning = false
    /// Track whether the panel should be visible (only during recording)
    private var isVisible = false

    @MainActor init(model: AppModel, settings: SettingsStore) {
        self.model = model
        self.settings = settings
        let tabView = DockTabView(
            model: model,
            onTap: { @MainActor in model.toggleRecording() }
        )
        hostingController = NSHostingController(rootView: tabView)

        panel = NonActivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hostingController
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isOpaque = false
        panel.hidesOnDeactivate = false
        panel.worksWhenModal = true
        panel.ignoresMouseEvents = true
        panel.isMovableByWindowBackground = settings.floatingPanelFreePosition

        setupMouseTracking()
        setupRightClickMonitor()
        setupScreenFollowing()

        // Save position when user drags the panel (not programmatic moves)
        NotificationCenter.default.publisher(for: NSWindow.didMoveNotification, object: panel)
            .sink { [weak self] _ in
                guard let self,
                      !self.isRepositioning,
                      self.settings.floatingPanelFreePosition else { return }
                self.settings.floatingPanelX = self.panel.frame.origin.x
                self.settings.floatingPanelY = self.panel.frame.origin.y
            }
            .store(in: &cancellables)

        // React to toggle changes
        settings.$floatingPanelFreePosition
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                self.panel.isMovableByWindowBackground = enabled
                if !enabled {
                    self.reposition()
                }
            }
            .store(in: &cancellables)
    }

    func show() {
        isVisible = true
        reposition()
        panel.orderFrontRegardless()
    }

    func hide() {
        isVisible = false
        panel.orderOut(nil)
    }

    func reposition() {
        isRepositioning = true
        defer { isRepositioning = false }

        // If free positioning is on and we have saved coordinates, use them
        if settings.floatingPanelFreePosition,
           let savedX = settings.floatingPanelX,
           let savedY = settings.floatingPanelY {
            let width: CGFloat = 300
            let height: CGFloat = 250
            panel.setFrame(NSRect(x: savedX, y: savedY, width: width, height: height), display: true)
            return
        }

        let screen = focusedScreen()
        let width: CGFloat = 300
        let height: CGFloat = 250

        let x = screen.visibleFrame.midX - (width / 2)
        let dockHeight = max(screen.visibleFrame.minY - screen.frame.minY, 70)
        let y = screen.frame.minY + dockHeight + 4
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }

    /// Returns the screen that currently has focus (where the mouse is).
    private func focusedScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            if screen.frame.contains(mouse) {
                return screen
            }
        }
        return NSScreen.main ?? NSScreen.screens.first ?? NSScreen.screens[0]
    }

    // MARK: - Follow screen with focus

    private func setupScreenFollowing() {
        // Re-check screen on mouse movement between screens
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            self?.checkScreenChange()
        }

        // Also follow when a different app activates (might be on another screen)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isVisible, !self.settings.floatingPanelFreePosition else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                guard self.isVisible else { return }
                self.reposition()
            }
        }
    }

    private func checkScreenChange() {
        // Don't reposition if panel is hidden or free positioning is on
        guard isVisible, !settings.floatingPanelFreePosition else { return }

        let screen = focusedScreen()
        let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        if screenID != currentScreenID {
            currentScreenID = screenID
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isVisible else { return }
                self.reposition()
                self.panel.orderFrontRegardless()
            }
        }
    }

    // MARK: - Mouse tracking: only accept events when cursor is over the pill

    private func pillScreenRect() -> NSRect {
        let f = panel.frame
        let pillWidth: CGFloat = 140
        let pillHeight: CGFloat = 44
        return NSRect(
            x: f.midX - pillWidth / 2,
            y: f.minY,
            width: pillWidth,
            height: pillHeight
        )
    }

    private func setupMouseTracking() {
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.updateIgnoring()
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.updateIgnoring()
            return event
        }
    }

    private func updateIgnoring() {
        let mouse = NSEvent.mouseLocation
        let overPill = pillScreenRect().contains(mouse)
        if panel.ignoresMouseEvents == overPill {
            panel.ignoresMouseEvents = !overPill
        }
    }

    // MARK: - Right-click menu

    private func setupRightClickMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self else { return event }
            let mouse = NSEvent.mouseLocation
            if self.pillScreenRect().contains(mouse) {
                self.showContextMenu(at: event)
                return nil
            }
            return event
        }
    }

    @MainActor
    private func showContextMenu(at event: NSEvent) {
        guard let model else { return }

        let menu = NSMenu()

        if model.recordings.isEmpty {
            let item = NSMenuItem(title: "No recordings yet", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for (index, recording) in model.recordings.prefix(10).enumerated() {
                let time = recording.createdAt.formatted(date: .omitted, time: .shortened)
                let duration = recording.formattedDuration
                let status = recording.transcriptionStatus.rawValue
                let item = NSMenuItem(title: "\(time)  \(duration)  [\(status)]", action: #selector(openRecording(_:)), keyEquivalent: "")
                item.tag = index
                item.target = self
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let showAll = NSMenuItem(title: "Show All Recordings...", action: #selector(showAllRecordings), keyEquivalent: "")
        showAll.target = self
        menu.addItem(showAll)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Memois", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        NSMenu.popUpContextMenu(menu, with: event, for: panel.contentView!)
    }

    @objc private func openRecording(_ sender: NSMenuItem) {
        Task { @MainActor [weak self] in
            self?.model?.showMainWindow?()
        }
    }

    @objc private func showAllRecordings() {
        Task { @MainActor [weak self] in
            self?.model?.showMainWindow?()
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
