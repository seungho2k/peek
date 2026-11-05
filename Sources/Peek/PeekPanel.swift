import AppKit

/// Borderless floating panel. Shown without taking focus; a click activates peek and
/// makes it key (see PanelController's focus handling).
final class PeekPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isMovable = false
        isOpaque = false
        hasShadow = true
        backgroundColor = Theme.background
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The panel slides partly off-screen; never let AppKit push it back on-screen.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Thin strip on the panel's inner edge for resizing its depth.
final class ResizeHandle: NSView {
    var edge: PeekEdge = .right { didSet { window?.invalidateCursorRects(for: self) } }
    var onDrag: ((NSPoint) -> Void)?
    var onDragEnded: (() -> Void)?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: edge.isSide ? .resizeLeftRight : .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        onDrag?(NSEvent.mouseLocation)
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnded?()
    }
}
