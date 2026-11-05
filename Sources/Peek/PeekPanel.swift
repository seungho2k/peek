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

/// Close strip along the screen edge, shown when the panel fills the screen: a faint ×
/// centered in a thin full-length bar. Transparent; slightly darker on hover; fades in/out.
final class CloseStrip: NSView {
    static let thickness: CGFloat = 28
    var onClick: (() -> Void)?
    private(set) var shown = false
    /// Hover tint, faded in/out via its opacity.
    private let hoverTint = FillView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        alphaValue = 0
        isHidden = true
        hoverTint.frame = bounds
        hoverTint.autoresizingMask = [.width, .height]
        hoverTint.alphaValue = 0
        addSubview(hoverTint)
        let glyph = CrossGlyphView(frame: bounds)
        glyph.autoresizingMask = [.width, .height]
        addSubview(glyph)  // above the tint
    }

    private func setHovering(_ on: Bool, animated: Bool = true) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = animated ? 0.15 : 0
            hoverTint.animator().alphaValue = on ? 1 : 0
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setShown(_ show: Bool) {
        guard show != shown else { return }
        shown = show
        if show { isHidden = false }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            animator().alphaValue = show ? 1 : 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.shown else { return }
                self.isHidden = true
                self.setHovering(false, animated: false)
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { setHovering(true) }
    override func mouseExited(with event: NSEvent) { setHovering(false) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

/// Plain layer-backed fill in `Theme.closeHover`, so its opacity can be animated.
final class FillView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        Theme.closeHover.setFill()
        bounds.fill()
    }
}

/// The faint × centered in its bounds.
final class CrossGlyphView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let r: CGFloat = 4
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: c.x - r, y: c.y - r)); path.line(to: NSPoint(x: c.x + r, y: c.y + r))
        path.move(to: NSPoint(x: c.x - r, y: c.y + r)); path.line(to: NSPoint(x: c.x + r, y: c.y - r))
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        Theme.closeGlyph.setStroke()
        path.stroke()
    }
}
