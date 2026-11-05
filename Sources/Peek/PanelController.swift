import AppKit
import Combine

/// Shows/hides the note panel based on the mouse position, animates the slide,
/// and manages pin + keyboard focus.
@MainActor
final class PanelController: NSObject {
    let panel = PeekPanel()
    let editor: NoteEditor
    private let settings = Settings.shared
    private let resizeHandle = ResizeHandle()

    /// 0 = fully hidden, 1 = fully shown.
    private var progress: CGFloat = 0
    /// Where the current animation is heading.
    private var target: CGFloat = 0
    private var animFrom: CGFloat = 0
    private var animStart: CFTimeInterval = 0
    private var animDuration: CFTimeInterval = 0
    private var animTimer: Timer?

    private(set) var isPinned = false
    /// Start of an ⌥-drag resize: mouse location and panel depth at mouse-down.
    private var optionResize: (point: NSPoint, depth: CGFloat)?
    /// A mouse button went down inside the panel and is still held.
    private var pressBeganInside = false
    /// Polls the mouse while a button is held: during drag sessions (e.g. dragging a file
    /// from Finder) mouse events don't reach our monitors.
    private var pressPollTimer: Timer?
    /// App that was active before the panel took focus.
    private var previousApp: NSRunningApplication?
    /// peek was activated by the panel (not, say, by the settings window).
    private var activatedForPanel = false

    private var monitors: [Any] = []
    private var cancellables: Set<AnyCancellable> = []

    var onOpenSettings: (() -> Void)?

    private static let handleThickness: CGFloat = 5

    override init() {
        editor = NoteEditor()
        super.init()
        setUpContent()
        installMonitors()
        observeSettings()

        editor.textView.onPinToggle = { [weak self] in self?.togglePin() }
        editor.textView.onOpenSettings = { [weak self] in self?.onOpenSettings?() }

        #if DEBUG
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { n in
                DebugLog.log("\(n.name.rawValue) \((n.object as? NSWindow).map { String(describing: type(of: $0)) } ?? "")")
            }
        }
        #endif
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    // MARK: Setup

    private func setUpContent() {
        let content = TrackingView()
        content.onMouseExited = { [weak self] in self?.evaluateMouse(event: nil) }
        panel.contentView = content

        editor.scrollView.translatesAutoresizingMaskIntoConstraints = true
        editor.scrollView.autoresizingMask = [.width, .height]
        content.addSubview(editor.scrollView)

        resizeHandle.onDrag = { [weak self] point in self?.resize(to: point) }
        content.addSubview(resizeHandle)
        layoutContent()
        panel.initialFirstResponder = editor.textView
        panel.makeFirstResponder(editor.textView)
    }

    private func layoutContent() {
        guard let content = panel.contentView else { return }
        content.frame = NSRect(origin: .zero, size: panel.frame.size)
        editor.scrollView.frame = content.bounds
        let t = Self.handleThickness
        let b = content.bounds
        switch settings.edge {
        case .right:
            resizeHandle.frame = NSRect(x: 0, y: 0, width: t, height: b.height)
            resizeHandle.autoresizingMask = [.height, .maxXMargin]
        case .left:
            resizeHandle.frame = NSRect(x: b.width - t, y: 0, width: t, height: b.height)
            resizeHandle.autoresizingMask = [.height, .minXMargin]
        case .bottom:
            resizeHandle.frame = NSRect(x: 0, y: b.height - t, width: b.width, height: t)
            resizeHandle.autoresizingMask = [.width, .minYMargin]
        }
        resizeHandle.edge = settings.edge
    }

    private func observeSettings() {
        settings.$edge.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.edgeChanged() }
        }.store(in: &cancellables)
    }

    private func installMonitors() {
        let mouseEvents: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseUp, .rightMouseUp, .otherMouseUp,
        ]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handleMouse(event, local: false) }
        }) {
            monitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mouseEvents, handler: { [weak self] event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                if self.handleOptionResize(event) { return true }
                self.handleMouse(event, local: true)
                return false
            }
            return consumed ? nil : event
        }) {
            monitors.append(l)
        }
    }

    // MARK: Geometry

    /// The screen whose edge peek lives on.
    private var targetScreen: NSScreen? {
        let screens = NSScreen.screens
        switch settings.edge {
        case .right: return screens.max { $0.frame.maxX < $1.frame.maxX }
        case .left: return screens.min { $0.frame.minX < $1.frame.minX }
        case .bottom: return screens.first  // the screen with the menu bar
        }
    }

    private func depth(for screen: NSScreen) -> CGFloat {
        let raw = settings.edge.isSide ? settings.sideWidth : settings.bottomHeight
        let span = settings.edge.isSide ? screen.frame.width : screen.frame.height
        return clampDepth(raw, span: span)
    }

    private func clampDepth(_ value: CGFloat, span: CGFloat) -> CGFloat {
        min(max(value, Settings.minPanelLength), span * Settings.maxPanelFraction).rounded()
    }

    private func frame(progress p: CGFloat, on screen: NSScreen) -> NSRect {
        let f = screen.frame
        let vf = screen.visibleFrame
        let d = depth(for: screen)
        let shown = (d * p).rounded()
        switch settings.edge {
        case .right:
            return NSRect(x: f.maxX - shown, y: vf.minY, width: d, height: vf.height)
        case .left:
            return NSRect(x: f.minX - d + shown, y: vf.minY, width: d, height: vf.height)
        case .bottom:
            return NSRect(x: vf.minX, y: f.minY - d + shown, width: vf.width, height: d)
        }
    }

    private func applyFrame() {
        guard let screen = targetScreen else { return }
        let newFrame = frame(progress: progress, on: screen)
        if newFrame.size != panel.frame.size {
            panel.setFrame(newFrame, display: true)
            layoutContent()
        } else {
            panel.setFrameOrigin(newFrame.origin)
        }
    }

    private func isAtEdge(_ p: NSPoint, of screen: NSScreen) -> Bool {
        let f = screen.frame
        switch settings.edge {
        case .right: return p.x >= f.maxX - 1 && p.y >= f.minY && p.y <= f.maxY
        case .left: return p.x < f.minX + 1 && p.y >= f.minY && p.y <= f.maxY
        case .bottom: return p.y < f.minY + 1 && p.x >= f.minX && p.x <= f.maxX
        }
    }

    // MARK: Mouse

    private func handleMouse(_ event: NSEvent, local: Bool) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if local && event.window === panel { pressBeganInside = true }
            startPressPolling()
            return
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            if NSEvent.pressedMouseButtons == 0 { pressBeganInside = false }
        default:
            break
        }
        evaluateMouse(event: event)
    }

    private func evaluateMouse(event: NSEvent?) {
        guard let screen = targetScreen else { return }
        let loc = NSEvent.mouseLocation
        let buttonsDown = NSEvent.pressedMouseButtons != 0

        if target == 0 {
            // Hidden or sliding out: only the screen edge brings it back (also mid-drag,
            // so files can be dragged in).
            if isAtEdge(loc, of: screen) && !Activation.isDockOverlayActive() { show() }
            return
        }

        if pressBeganInside && buttonsDown { return }  // e.g. selecting text or resizing

        if isInsideKeepArea(loc, of: screen) {
            if !hasFocus && !buttonsDown { takeFocus() }
        } else if isPinned {
            if activatedForPanel { returnFocus() }
        } else {
            hide()
        }
    }

    /// The panel plus a safety margin toward the screen's interior; along the edge the
    /// whole length counts, so sliding the mouse up/down never closes it.
    private func isInsideKeepArea(_ p: NSPoint, of screen: NSScreen) -> Bool {
        if isAtEdge(p, of: screen) { return true }
        let f = panel.frame
        let margin = CGFloat(settings.hideMargin)
        switch settings.edge {
        case .right: return p.x >= f.minX - margin
        case .left: return p.x <= f.maxX + margin
        case .bottom: return p.y <= f.maxY + margin
        }
    }

    private func startPressPolling() {
        guard pressPollTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if NSEvent.pressedMouseButtons == 0 {
                    self.pressPollTimer?.invalidate()
                    self.pressPollTimer = nil
                    self.pressBeganInside = false
                }
                self.evaluateMouse(event: nil)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pressPollTimer = timer
    }

    // MARK: Focus

    /// Input methods (e.g. Korean) only work in the active app, so peek activates itself
    /// while the panel has focus and hands activation back afterwards (see `Activation`).
    private var hasFocus: Bool { NSApp.isActive && panel.isKeyWindow }

    private func takeFocus() {
        DebugLog.log("takeFocus \(DebugLog.state)")
        if !NSApp.isActive {
            let front = NSWorkspace.shared.frontmostApplication
            previousApp = front == NSRunningApplication.current ? nil : front
            activatedForPanel = true
            Activation.activateSelf()
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(editor.textView)
    }

    /// Give keyboard focus back to the previously active app (the panel may stay on screen).
    /// If peek was already active for another reason (settings window), leave it alone.
    private func returnFocus() {
        DebugLog.log("returnFocus activatedForPanel=\(activatedForPanel) \(DebugLog.state)")
        // Don't leave a half-composed syllable behind; the input method would otherwise
        // commit it later at an odd moment.
        editor.textView.commitComposition()
        guard activatedForPanel else { return }
        activatedForPanel = false
        guard NSApp.isActive else { return }
        if let app = previousApp, !app.isTerminated {
            // Cooperative activation: hand activation over explicitly.
            NSApp.yieldActivation(to: app)
            app.activate(from: NSRunningApplication.current, options: [])
        } else {
            NSApp.deactivate()
        }
        previousApp = nil
    }

    // MARK: Show / hide

    func show() {
        if progress == 0 {
            if NoteStore.shared.hasExternalChange() { editor.reload() }
            applyFrame()
            panel.orderFrontRegardless()
        }
        takeFocus()
        animate(to: 1)
    }

    func hide() {
        guard target != 0 else { return }
        returnFocus()
        animate(to: 0)
    }

    private func hideImmediately() {
        animTimer?.invalidate()
        animTimer = nil
        target = 0
        progress = 0
        returnFocus()
        panel.orderOut(nil)
        editor.saveNow()
    }

    func togglePin() {
        isPinned.toggle()
        if !isPinned {
            evaluateMouse(event: nil)
        }
    }

    // MARK: Animation

    private func animate(to newTarget: CGFloat) {
        target = newTarget
        animFrom = progress
        animStart = CACurrentMediaTime()
        let ms = newTarget > progress ? settings.slideInMs : settings.slideOutMs
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        animDuration = reduceMotion ? 0 : ms / 1000 * Double(abs(newTarget - progress))

        if animDuration <= 0 {
            progress = newTarget
            applyFrame()
            finishAnimation()
            return
        }
        if animTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            animTimer = timer
        }
    }

    private func tick() {
        let t = min(1, (CACurrentMediaTime() - animStart) / animDuration)
        let eased = target == 1 ? 1 - pow(1 - t, 3) : pow(t, 3)  // ease-out in, ease-in out
        progress = animFrom + (target - animFrom) * CGFloat(eased)
        applyFrame()
        if t >= 1 {
            animTimer?.invalidate()
            animTimer = nil
            finishAnimation()
        }
    }

    private func finishAnimation() {
        if target == 0 {
            panel.orderOut(nil)
            editor.saveNow()
        }
    }

    // MARK: Resize

    /// ⌥ + drag anywhere in the panel resizes it (relative to where the drag started).
    private func handleOptionResize(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown:
            guard event.window === panel, event.modifierFlags.contains(.option) else { return false }
            optionResize = (NSEvent.mouseLocation, settings.edge.isSide ? settings.sideWidth : settings.bottomHeight)
            pressBeganInside = true
            startPressPolling()
            (settings.edge.isSide ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
            return true
        case .leftMouseDragged:
            guard let start = optionResize, let screen = targetScreen else { return false }
            let p = NSEvent.mouseLocation
            let f = screen.frame
            switch settings.edge {
            case .right: settings.sideWidth = clampDepth(start.depth + start.point.x - p.x, span: f.width)
            case .left: settings.sideWidth = clampDepth(start.depth + p.x - start.point.x, span: f.width)
            case .bottom: settings.bottomHeight = clampDepth(start.depth + p.y - start.point.y, span: f.height)
            }
            applyFrame()
            return true
        case .leftMouseUp:
            guard optionResize != nil else { return false }
            optionResize = nil
            NSCursor.pop()
            return true
        default:
            return false
        }
    }

    private func resize(to point: NSPoint) {
        guard let screen = targetScreen else { return }
        let f = screen.frame
        switch settings.edge {
        case .right: settings.sideWidth = clampDepth(f.maxX - point.x, span: f.width)
        case .left: settings.sideWidth = clampDepth(point.x - f.minX, span: f.width)
        case .bottom: settings.bottomHeight = clampDepth(point.y - f.minY, span: f.height)
        }
        applyFrame()
    }

    // MARK: Changes

    private func edgeChanged() {
        hideImmediately()
        isPinned = false
        applyFrame()
        layoutContent()
    }

    @objc private func screensChanged() {
        if progress == 0 { return }
        applyFrame()
    }
}

/// Content view that reports when the mouse leaves the panel.
final class TrackingView: NSView {
    var onMouseExited: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self))
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExited?()
    }
}
