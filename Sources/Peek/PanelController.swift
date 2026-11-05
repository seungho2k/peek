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
    private let closeStrip = CloseStrip()
    private let hotKey = GlobalHotKey()
    /// While the panel is visible: hides it if Mission Control opens.
    private var overlayWatchTimer: Timer?

    /// 0 = fully hidden, 1 = fully shown.
    private var progress: CGFloat = 0
    /// Where the current animation is heading.
    private var target: CGFloat = 0
    private var animFrom: CGFloat = 0
    private var animStart: CFTimeInterval = 0
    private var animDuration: CFTimeInterval = 0
    private var animTimer: Timer?

    private(set) var isPinned = false
    /// False right after a forced close while the cursor may be on the edge; re-armed once
    /// the cursor leaves the edge.
    private var edgeTriggerArmed = true
    /// Start of an ⌥-drag resize: mouse location and panel depth at mouse-down.
    private var optionResize: (point: NSPoint, depth: CGFloat)?
    /// A mouse button went down inside the panel and is still held.
    private var pressBeganInside = false
    /// Polls the mouse while a button is held: during drag sessions (e.g. dragging a file
    /// from Finder) mouse events don't reach our monitors.
    private var pressPollTimer: Timer?
    /// App that was active before the panel took focus.
    /// Most recently active app other than peek, to hand focus back to.
    private var lastOtherApp: NSRunningApplication?
    /// The panel got keyboard focus from a click and should give it back.
    private var focusedByClick = false

    private var monitors: [Any] = []
    private var cancellables: Set<AnyCancellable> = []

    var onOpenSettings: (() -> Void)?

    private static let handleThickness: CGFloat = 5
    /// ⌥-drag resize moves the edge this many times faster than the mouse.
    private static let optionResizeGain: CGFloat = 2

    override init() {
        editor = NoteEditor()
        super.init()
        setUpContent()
        installMonitors()
        observeSettings()
        observeActivation()

        hotKey.onPress = { [weak self] in self?.hotKeyPressed() }
        hotKey.register(settings.shortcut(for: .pin))
        editor.textView.onOpenSettings = { [weak self] in self?.onOpenSettings?() }
        editor.textView.onToggleFill = { [weak self] in self?.toggleFill() }

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
        resizeHandle.onDragEnded = { [weak self] in self?.commitLiveDepth() }
        content.addSubview(resizeHandle)

        // Shown only when the panel fills the screen, since the mouse can't leave it then.
        closeStrip.onClick = { [weak self] in self?.closeFromButton() }
        content.addSubview(closeStrip)
        layoutContent()
        panel.initialFirstResponder = editor.textView
        panel.makeFirstResponder(editor.textView)
    }

    private func layoutContent() {
        guard let content = panel.contentView else { return }
        content.frame = NSRect(origin: .zero, size: panel.frame.size)
        let t = Self.handleThickness
        let b = content.bounds

        // When full, a close strip runs along the screen edge and the text area gives way.
        let s = isFull ? CloseStrip.thickness : 0
        switch settings.edge {
        case .right:
            editor.scrollView.frame = NSRect(x: 0, y: 0, width: b.width - s, height: b.height)
            closeStrip.frame = NSRect(x: b.width - CloseStrip.thickness, y: 0, width: CloseStrip.thickness, height: b.height)
        case .left:
            editor.scrollView.frame = NSRect(x: s, y: 0, width: b.width - s, height: b.height)
            closeStrip.frame = NSRect(x: 0, y: 0, width: CloseStrip.thickness, height: b.height)
        case .bottom:
            editor.scrollView.frame = NSRect(x: 0, y: s, width: b.width, height: b.height - s)
            closeStrip.frame = NSRect(x: 0, y: 0, width: b.width, height: CloseStrip.thickness)
        }
        closeStrip.setShown(isFull)
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
        settings.$shortcuts.dropFirst().sink { [weak self] shortcuts in
            DispatchQueue.main.async { self?.hotKey.register(shortcuts[.pin] ?? ShortcutAction.pin.defaultShortcut) }
        }.store(in: &cancellables)
        settings.$minDepth.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.applyFrame() }
        }.store(in: &cancellables)
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
        clampDepth(liveDepth ?? (settings.edge.isSide ? settings.sideWidth : settings.bottomHeight), on: screen)
    }

    /// Largest depth: the panel fills the screen like Window ▸ Fill (menu bar excluded).
    private func maxDepth(on screen: NSScreen) -> CGFloat {
        let f = screen.frame, vf = screen.visibleFrame
        switch settings.edge {
        case .right: return f.maxX - vf.minX
        case .left: return vf.maxX - f.minX
        case .bottom: return vf.maxY - f.minY
        }
    }

    private func clampDepth(_ value: CGFloat, on screen: NSScreen) -> CGFloat {
        min(max(value, CGFloat(settings.minDepth)), maxDepth(on: screen)).rounded()
    }

    private var isFull: Bool {
        guard let screen = targetScreen else { return false }
        return depth(for: screen) >= maxDepth(on: screen) - 0.5
    }

    private func frame(on screen: NSScreen) -> NSRect {
        let f = screen.frame
        let vf = screen.visibleFrame
        let d = depth(for: screen)
        switch settings.edge {
        case .right: return NSRect(x: f.maxX - d, y: vf.minY, width: d, height: vf.height)
        case .left: return NSRect(x: f.minX, y: vf.minY, width: d, height: vf.height)
        case .bottom: return NSRect(x: vf.minX, y: f.minY, width: vf.width, height: d)
        }
    }

    /// Positions the panel and applies the fade (`progress` is the opacity).
    private func applyFrame() {
        guard let screen = targetScreen else { return }
        let newFrame = frame(on: screen)
        if newFrame != panel.frame {
            panel.setFrame(newFrame, display: true)
            layoutContent()
        }
        panel.alphaValue = progress
        if closeStrip.shown != isFull { layoutContent() }
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
            if local && event.window === panel {
                pressBeganInside = true
                panelClicked()
            }
            startPressPolling()
            return
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            if !SystemState.isMouseButtonDown { pressBeganInside = false }
        default:
            break
        }
        evaluateMouse(event: event)
    }

    private func evaluateMouse(event: NSEvent?) {
        guard let screen = targetScreen else { return }
        let loc = NSEvent.mouseLocation
        let buttonsDown = SystemState.isMouseButtonDown

        if target == 0 {
            // Hidden or sliding out: only the screen edge brings it back (also mid-drag,
            // so files can be dragged in).
            let atEdge = isAtEdge(loc, of: screen)
            if !edgeTriggerArmed {
                if !atEdge { edgeTriggerArmed = true }
                return
            }
            if atEdge && !SystemState.isDockOverlayActive() { show() }
            return
        }

        if pressBeganInside && buttonsDown { return }  // e.g. selecting text or resizing

        if isInsideKeepArea(loc, of: screen) {
            return
        } else if isPinned {
            if focusedByClick { returnFocus() }
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
                if !SystemState.isMouseButtonDown {
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

    /// The panel only takes keyboard focus when clicked. Clicking activates peek like any
    /// app (input methods such as Korean need the active app); when the panel closes or the
    /// mouse leaves a pinned panel, activation goes back to the app used before.
    private func observeActivation() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let app, app != NSRunningApplication.current { self?.lastOtherApp = app }
            }
        }
    }

    /// Clicking the panel focuses it and pins it, so it stays while you work elsewhere.
    private func panelClicked() {
        focusedByClick = true
        isPinned = true
    }

    /// Give keyboard focus back to the previously active app (the panel may stay on screen).
    private func returnFocus() {
        DebugLog.log("returnFocus focusedByClick=\(focusedByClick) \(DebugLog.state)")
        guard focusedByClick else { return }
        focusedByClick = false
        // Don't leave a half-composed syllable behind; the input method would otherwise
        // commit it later at an odd moment.
        editor.textView.commitComposition()
        guard NSApp.isActive else { return }
        if let other = NSApp.windows.first(where: { $0 !== panel && $0.isVisible && $0.canBecomeKey }) {
            other.makeKeyAndOrderFront(nil)  // e.g. the settings window stays in charge
        } else if let app = lastOtherApp, !app.isTerminated {
            NSApp.yieldActivation(to: app)
            app.activate(from: NSRunningApplication.current, options: [])
        } else {
            NSApp.deactivate()
        }
    }

    // MARK: Show / hide

    func show() {
        if progress == 0 {
            if NoteStore.shared.hasExternalChange() { editor.reload() }
            applyFrame()
            panel.orderFrontRegardless()
        }
        startOverlayWatch()
        animate(to: 1)
    }

    /// Mission Control gives no notification; while visible, check a few times a second.
    private func startOverlayWatch() {
        guard overlayWatchTimer == nil else { return }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, SystemState.isDockOverlayActive() else { return }
                self.isPinned = false
                self.hideImmediately()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        overlayWatchTimer = timer
    }

    private func stopOverlayWatch() {
        overlayWatchTimer?.invalidate()
        overlayWatchTimer = nil
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
        stopOverlayWatch()
        editor.saveNow()
    }

    private func closeFromButton() {
        isPinned = false
        hide()
    }

    /// Global hotkey: open + pin without taking focus. When pinned: unpin and fade out even
    /// if the mouse is over the panel. When open but not pinned: pin.
    func hotKeyPressed() {
        if target == 0 {
            isPinned = true
            show()
        } else if isPinned {
            isPinned = false
            // The mouse may sit on the screen edge; don't reopen until it has left the edge.
            edgeTriggerArmed = false
            hide()
        } else {
            isPinned = true
        }
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
            stopOverlayWatch()
            editor.saveNow()
        }
    }

    // MARK: Resize

    /// Depth while a resize drag is in progress; persisted to settings when the drag ends,
    /// so dragging doesn't write preferences on every mouse event.
    private var liveDepth: CGFloat?
    /// Depth before ⌘↩ filled the screen; ⌘↩ again restores it.
    private var depthBeforeFill: CGFloat?

    private func setDepth(_ value: CGFloat, persist: Bool) {
        guard let screen = targetScreen else { return }
        let d = clampDepth(value, on: screen)
        if persist {
            liveDepth = nil
            if settings.edge.isSide { settings.sideWidth = d } else { settings.bottomHeight = d }
        } else {
            liveDepth = d
        }
        applyFrame()
    }

    private func commitLiveDepth() {
        if let d = liveDepth { setDepth(d, persist: true) }
    }

    /// ⌘↩: fill the screen, or restore the size from before. Does nothing if the panel was
    /// made full by hand (there is no size to go back to).
    func toggleFill() {
        guard let screen = targetScreen else { return }
        if let previous = depthBeforeFill {
            depthBeforeFill = nil
            setDepth(previous, persist: true)
        } else if !isFull {
            depthBeforeFill = depth(for: screen)
            setDepth(maxDepth(on: screen), persist: true)
        }
    }

    /// ⌥ + drag anywhere in the panel resizes it (relative to where the drag started).
    private func handleOptionResize(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown:
            guard event.window === panel, event.modifierFlags.contains(.option) else { return false }
            guard let screen = targetScreen else { return false }
            optionResize = (NSEvent.mouseLocation, depth(for: screen))
            depthBeforeFill = nil
            pressBeganInside = true
            startPressPolling()
            (settings.edge.isSide ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
            return true
        case .leftMouseDragged:
            guard let start = optionResize else { return false }
            let p = NSEvent.mouseLocation
            let k = Self.optionResizeGain
            switch settings.edge {
            case .right: setDepth(start.depth + (start.point.x - p.x) * k, persist: false)
            case .left: setDepth(start.depth + (p.x - start.point.x) * k, persist: false)
            case .bottom: setDepth(start.depth + (p.y - start.point.y) * k, persist: false)
            }
            return true
        case .leftMouseUp:
            guard optionResize != nil else { return false }
            optionResize = nil
            NSCursor.pop()
            commitLiveDepth()
            return true
        default:
            return false
        }
    }

    private func resize(to point: NSPoint) {
        guard let screen = targetScreen else { return }
        let f = screen.frame
        depthBeforeFill = nil
        switch settings.edge {
        case .right: setDepth(f.maxX - point.x, persist: false)
        case .left: setDepth(point.x - f.minX, persist: false)
        case .bottom: setDepth(point.y - f.minY, persist: false)
        }
    }

    // MARK: Changes

    private func edgeChanged() {
        liveDepth = nil
        depthBeforeFill = nil
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
