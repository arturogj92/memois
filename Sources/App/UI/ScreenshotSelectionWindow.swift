import AppKit
import ScreenCaptureKit

/// Fullscreen transparent overlay for selecting a screen region to capture
final class ScreenshotSelectionWindow: NSPanel {
    var onCapture: ((NSImage) -> Void)?
    private let targetScreen: NSScreen

    init(screen: NSScreen) {
        targetScreen = screen
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let selectionView = ScreenshotSelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
        selectionView.onSelection = { [weak self] rect in
            guard let self else { return }
            self.captureRegion(rect, on: self.targetScreen)
        }
        selectionView.onCancel = { [weak self] in
            self?.close()
        }
        contentView = selectionView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private func captureRegion(_ rect: NSRect, on screen: NSScreen) {
        // Close overlay before capturing so it doesn't appear in screenshot
        orderOut(nil)

        // Small delay to ensure overlay is fully hidden
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }

            Task {
                await self.captureWithScreenCaptureKit(rect: rect, screen: screen)
            }
        }
    }

    @MainActor
    private func captureWithScreenCaptureKit(rect: NSRect, screen: NSScreen) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
                close()
                return
            }

            let scaleFactor = screen.backingScaleFactor
            let screenFrame = screen.frame

            // sourceRect is in POINTS (not pixels), top-left origin
            // Convert from NSView coords (bottom-left origin) to top-left origin
            let sourceX = rect.origin.x
            let sourceY = screenFrame.height - rect.origin.y - rect.height
            let sourceWidth = rect.width
            let sourceHeight = rect.height

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.sourceRect = CGRect(x: sourceX, y: sourceY, width: sourceWidth, height: sourceHeight)
            // Output size in pixels (scaled for Retina)
            config.width = Int(sourceWidth * scaleFactor)
            config.height = Int(sourceHeight * scaleFactor)
            config.showsCursor = false
            config.captureResolution = .best

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )

            let nsImage = NSImage(cgImage: image, size: NSSize(width: rect.width, height: rect.height))
            onCapture?(nsImage)
            close()
        } catch {
            close()
        }
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? 0
    }
}

/// NSView that draws a dark overlay and lets the user drag a selection rectangle
final class ScreenshotSelectionView: NSView {
    var onSelection: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?

    private var startPoint: NSPoint = .zero
    private var currentPoint: NSPoint = .zero
    private var isDrawing = false

    private var selectionRect: NSRect {
        NSRect(
            x: min(startPoint.x, currentPoint.x),
            y: min(startPoint.y, currentPoint.y),
            width: abs(currentPoint.x - startPoint.x),
            height: abs(currentPoint.y - startPoint.y)
        )
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addCursorRect(bounds, cursor: .crosshair)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onCancel?()
        }
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentPoint = startPoint
        isDrawing = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        isDrawing = false

        let rect = selectionRect
        if rect.width >= 10 && rect.height >= 10 {
            onSelection?(rect)
        } else {
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // Dark overlay
        NSColor.black.withAlphaComponent(0.3).setFill()
        bounds.fill()

        guard isDrawing else {
            drawHint()
            return
        }

        let rect = selectionRect

        // Clear selection area
        NSColor.clear.setFill()
        rect.fill(using: .copy)

        // Selection border (purple accent)
        let borderColor = NSColor(red: 0.65, green: 0.55, blue: 0.98, alpha: 1.0)
        borderColor.setStroke()
        let borderPath = NSBezierPath(rect: rect)
        borderPath.lineWidth = 2
        borderPath.stroke()

        // Corner handles
        let handleSize: CGFloat = 6
        borderColor.setFill()
        let corners: [NSPoint] = [
            NSPoint(x: rect.minX, y: rect.minY),
            NSPoint(x: rect.maxX, y: rect.minY),
            NSPoint(x: rect.minX, y: rect.maxY),
            NSPoint(x: rect.maxX, y: rect.maxY),
        ]
        for corner in corners {
            let handleRect = NSRect(
                x: corner.x - handleSize / 2,
                y: corner.y - handleSize / 2,
                width: handleSize,
                height: handleSize
            )
            handleRect.fill()
        }

        // Dimensions label
        if rect.width > 60 && rect.height > 30 {
            let dimText = "\(Int(rect.width)) × \(Int(rect.height))"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
            let textSize = dimText.size(withAttributes: attrs)
            let labelPadding: CGFloat = 6
            let labelRect = NSRect(
                x: rect.midX - (textSize.width + labelPadding * 2) / 2,
                y: rect.minY - textSize.height - labelPadding * 2 - 6,
                width: textSize.width + labelPadding * 2,
                height: textSize.height + labelPadding * 2
            )
            NSColor.black.withAlphaComponent(0.7).setFill()
            NSBezierPath(roundedRect: labelRect, xRadius: 4, yRadius: 4).fill()
            dimText.draw(
                at: NSPoint(x: labelRect.origin.x + labelPadding, y: labelRect.origin.y + labelPadding),
                withAttributes: attrs
            )
        }
    }

    private func drawHint() {
        let text = "Draw to select · Esc to cancel"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.8),
        ]
        let textSize = text.size(withAttributes: attrs)
        let padding: CGFloat = 12
        let bgRect = NSRect(
            x: bounds.midX - (textSize.width + padding * 2) / 2,
            y: bounds.midY - (textSize.height + padding * 2) / 2,
            width: textSize.width + padding * 2,
            height: textSize.height + padding * 2
        )
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: bgRect, xRadius: 8, yRadius: 8).fill()
        text.draw(
            at: NSPoint(x: bgRect.origin.x + padding, y: bgRect.origin.y + padding),
            withAttributes: attrs
        )
    }
}
