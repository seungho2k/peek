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
    private let hotKey = GlobalHotKey()
    /// Global hotkey that fills the focused window of another app (`fill-window`).
    private let fillHotKey = GlobalHotKey()
    /// Moves other windows out of the panel's way while it's shown (`make-room`).
    private let windowRoom = WindowRoom()
    /// The Accessibility prompt is shown at most once per launch.
    private var askedForAccessibility = false

    /// 0 = fully hidden, 1 = fully shown.
    private var progress: CGFloat = 0
    /// Where the current animation is heading.
    private var target: CGFloat = 0
    private var animFrom: CGFloat = 0
    private var animStart: CFTimeInterval = 0
    private var animDuration: CFTimeInterval = 0
    private var animTimer: Timer?

    /// Start of an ⌥-drag resize: mouse location and panel depth at mouse-down.
    private var optionResize: (point: NSPoint, depth: CGFloat)?

    private var monitors: [Any] = []
    private var cancellables: Set<AnyCancellable> = []

    let settingsEditor = SettingsEditor()
    /// The panel is showing the settings instead of the note.
    private(set) var settingsOpen = false

    private static let handleThickness: CGFloat = 5
    /// ⌥-drag resize moves the edge this many times faster than the mouse.
    private static let optionResizeGain: CGFloat = 2

    override init() {
        NoteFormat.autoBoldFirstLine = Settings.shared.autoBoldFirstLine
        Theme.showLineNumbers = Settings.shared.showLineNumbers
        editor = NoteEditor()
        super.init()
        setUpContent()
        installMonitors()
        observeSettings()

        hotKey.onPress = { [weak self] in self?.hotKeyPressed() }
        hotKey.register(settings.shortcut(for: .pin))
        fillHotKey.onPress = { [weak self] in self?.fillFocusedWindow() }
        fillHotKey.register(settings.shortcut(for: .fillWindow))
        settings.canUseGlobalShortcut = { [weak self] action, sc in
            guard let self else { return false }
            return (action == .pin ? self.hotKey : self.fillHotKey).register(sc)
        }
        editor.textView.onOpenSettings = { [weak self] in self?.toggleSettings() }
        settingsEditor.onClose = { [weak self] in self?.hideSettings() }

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
        let content = NSView()
        panel.contentView = content

        editor.scrollView.translatesAutoresizingMaskIntoConstraints = true
        editor.scrollView.autoresizingMask = [.width, .height]
        content.addSubview(editor.scrollView)
        settingsEditor.scrollView.translatesAutoresizingMaskIntoConstraints = true
        content.addSubview(settingsEditor.scrollView)

        resizeHandle.onDrag = { [weak self] point in self?.resize(to: point) }
        resizeHandle.onDragEnded = { [weak self] in self?.commitLiveDepth() }
        content.addSubview(resizeHandle)

        layoutContent()
        panel.initialFirstResponder = editor.textView
        panel.makeFirstResponder(editor.textView)
    }

    private func layoutContent() {
        guard let content = panel.contentView else { return }
        content.frame = NSRect(origin: .zero, size: panel.frame.size)
        let t = Self.handleThickness
        let b = content.bounds

        editor.scrollView.frame = b
        settingsEditor.scrollView.frame = b
        switch settings.edge {
        case .right:
            resizeHandle.frame = NSRect(x: 0, y: 0, width: t, height: b.height)
            resizeHandle.autoresizingMask = [.height, .maxXMargin]
        case .left:
            resizeHandle.frame = NSRect(x: b.width - t, y: 0, width: t, height: b.height)
            resizeHandle.autoresizingMask = [.height, .minXMargin]
        }
        resizeHandle.edge = settings.edge

    }

    private func observeSettings() {
        settings.$shortcuts.dropFirst().sink { [weak self] shortcuts in
            DispatchQueue.main.async {
                self?.hotKey.register(shortcuts[.pin] ?? ShortcutAction.pin.defaultShortcut)
                self?.fillHotKey.register(shortcuts[.fillWindow] ?? ShortcutAction.fillWindow.defaultShortcut)
            }
        }.store(in: &cancellables)
        settings.$showLineNumbers.dropFirst().sink { [weak self] on in
            DispatchQueue.main.async {
                Theme.showLineNumbers = on
                self?.editor.textView.restyleAll()
                self?.settingsEditor.textView.restyleAll()
            }
        }.store(in: &cancellables)
        settings.$autoBoldFirstLine.dropFirst().sink { on in
            DispatchQueue.main.async { NoteFormat.autoBoldFirstLine = on }
        }.store(in: &cancellables)
        settings.$minDepth.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.applyFrame()
            }
        }.store(in: &cancellables)
        settings.$makeRoom.dropFirst().sink { [weak self] on in
            DispatchQueue.main.async {
                guard let self else { return }
                if on {
                    self.makeRoom()
                    if self.target == 1 { self.windowRoom.startWatching { [weak self] in self?.scheduleRefit() } }
                } else {
                    self.refitWork?.cancel()
                    self.windowRoom.stopWatching()
                    self.windowRoom.restore()
                }
            }
        }.store(in: &cancellables)
        settings.$edge.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.edgeChanged() }
        }.store(in: &cancellables)
    }

    /// Only for ⌥-drag resizing inside the panel; the panel is opened/closed with the hotkey.
    private func installMonitors() {
        let mouseEvents: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        if let l = NSEvent.addLocalMonitorForEvents(matching: mouseEvents, handler: { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handleOptionResize(event) ?? false }
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
        }
    }

    private func depth(for screen: NSScreen) -> CGFloat {
        clampDepth(liveDepth ?? settings.sideWidth, on: screen)
    }

    /// Largest depth: the panel fills the screen like Window ▸ Fill (menu bar excluded).
    private func maxDepth(on screen: NSScreen) -> CGFloat {
        let f = screen.frame, vf = screen.visibleFrame
        switch settings.edge {
        case .right: return f.maxX - vf.minX
        case .left: return vf.maxX - f.minX
        }
    }

    private func clampDepth(_ value: CGFloat, on screen: NSScreen) -> CGFloat {
        min(max(value, CGFloat(settings.minDepth)), maxDepth(on: screen)).rounded()
    }

    private func frame(on screen: NSScreen) -> NSRect {
        let f = screen.frame
        let vf = screen.visibleFrame
        let d = depth(for: screen)
        switch settings.edge {
        case .right: return NSRect(x: f.maxX - d, y: vf.minY, width: d, height: vf.height)
        case .left: return NSRect(x: f.minX, y: vf.minY, width: d, height: vf.height)
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
    }

    // MARK: Show / hide

    func show() {
        let wasHidden = target == 0
        if progress == 0 {
            if NoteStore.shared.hasExternalChange() { editor.reload() }
            applyFrame()
            panel.orderFrontRegardless()
        }
        animate(to: 1)
        if wasHidden {
            makeRoom()
            if settings.makeRoom { windowRoom.startWatching { [weak self] in self?.scheduleRefit() } }
        }
    }

    /// A window moved, resized or appeared while peek is shown: fit windows again once things
    /// settle (and the mouse is up, so a window being dragged isn't fought over).
    private var refitWork: DispatchWorkItem?
    private func scheduleRefit() {
        refitWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if NSEvent.pressedMouseButtons != 0 { self.scheduleRefit(); return }
                self.makeRoom()
            }
        }
        refitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Moves other windows out of the panel's area (at its full size), if `make-room` is on.
    private func makeRoom() {
        guard settings.makeRoom, target == 1, let screen = targetScreen else { return }
        guard WindowRoom.isTrusted else {
            if !askedForAccessibility {
                askedForAccessibility = true
                WindowRoom.requestTrust()
            }
            return
        }
        windowRoom.makeRoom(panel: frame(on: screen), screen: screen, edge: settings.edge)
    }

    /// `fill-window`: the focused window of the app in front (or, if that's peek, of the app
    /// before it) fills its screen edge to edge, minus the panel while peek is shown there.
    func fillFocusedWindow() {
        guard WindowRoom.isTrusted else {
            if !askedForAccessibility {
                askedForAccessibility = true
                WindowRoom.requestTrust()
            }
            return
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var app = NSWorkspace.shared.frontmostApplication
        if app?.processIdentifier == ownPID { app = previousApp }
        guard let pid = app?.processIdentifier, pid != ownPID else { return }
        var panelArea: (frame: NSRect, edge: PeekEdge, remember: Bool)?
        if target == 1, let screen = targetScreen {
            panelArea = (frame(on: screen), settings.edge, settings.makeRoom)
        }
        windowRoom.fillFocusedWindow(of: pid, panel: panelArea)
    }

    /// Puts other windows back (quitting peek).
    func restoreWindows() { windowRoom.restoreAndWait() }

    /// ⌘, (or launching peek again): the note panel shows the settings instead of the note
    /// (same width); opens the panel if needed.
    func showSettings() {
        if !settingsOpen { settingsEditor.load() }  // keep text being edited (e.g. on relaunch)
        settingsOpen = true
        swapContent()
        if target == 0 { show() }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(settingsEditor.textView)
    }

    func toggleSettings() {
        if settingsOpen { hideSettings() } else { showSettings() }
    }

    /// Back to the note (⌘, / Esc). Hiding the panel keeps whichever is showing.
    func hideSettings() {
        guard settingsOpen else { return }
        settingsEditor.textView.commitComposition()
        settingsOpen = false
        swapContent()
        panel.makeFirstResponder(editor.textView)
    }

    private func swapContent() {
        editor.scrollView.isHidden = settingsOpen
        settingsEditor.scrollView.isHidden = !settingsOpen
    }

    func hide() {
        guard target != 0 else { return }
        // Don't leave a half-composed syllable behind.
        editor.textView.commitComposition()
        settingsEditor.textView.commitComposition()
        refitWork?.cancel()
        windowRoom.stopWatching()
        windowRoom.restore()
        // Hand focus back, unless the user has since switched to another app themselves.
        if NSApp.isActive, let previous = previousApp, !previous.isTerminated { previous.activate() }
        previousApp = nil
        animate(to: 0)
    }

    /// Global hotkey: show and focus the panel (so ⌘1, ⌘, … work right away), or hide it and
    /// give focus back to the app that had it.
    func hotKeyPressed() {
        if target == 0 {
            show()
            focusPanel()
        } else {
            hide()
        }
    }

    /// The app that was frontmost when the hotkey focused peek; it gets focus back on hide.
    private var previousApp: NSRunningApplication?

    private func focusPanel() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(settingsOpen ? settingsEditor.textView : editor.textView)
    }

    // MARK: Animation

    private func animate(to newTarget: CGFloat) {
        target = newTarget
        animFrom = progress
        animStart = CACurrentMediaTime()
        let ms = newTarget > progress ? Settings.slideInMs : Settings.slideOutMs
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        animDuration = reduceMotion || !settings.animation ? 0 : ms / 1000 * Double(abs(newTarget - progress))

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

    /// Depth while a resize drag is in progress; persisted to settings when the drag ends,
    /// so dragging doesn't write preferences on every mouse event.
    private var liveDepth: CGFloat?

    private func setDepth(_ value: CGFloat, persist: Bool) {
        guard let screen = targetScreen else { return }
        let d = clampDepth(value, on: screen)
        if persist {
            liveDepth = nil
            settings.sideWidth = d
        } else {
            liveDepth = d
        }
        applyFrame()
        if persist { makeRoom() }  // re-fit other windows to the new width
    }

    private func commitLiveDepth() {
        if let d = liveDepth { setDepth(d, persist: true) }
    }

    /// ⌥ + drag anywhere in the panel resizes it (relative to where the drag started).
    private func handleOptionResize(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown:
            guard event.window === panel, event.modifierFlags.contains(.option) else { return false }
            guard let screen = targetScreen else { return false }
            optionResize = (NSEvent.mouseLocation, depth(for: screen))
            NSCursor.resizeLeftRight.push()
            return true
        case .leftMouseDragged:
            guard let start = optionResize else { return false }
            let p = NSEvent.mouseLocation
            let k = Self.optionResizeGain
            switch settings.edge {
            case .right: setDepth(start.depth + (start.point.x - p.x) * k, persist: false)
            case .left: setDepth(start.depth + (p.x - start.point.x) * k, persist: false)
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
        switch settings.edge {
        case .right: setDepth(f.maxX - point.x, persist: false)
        case .left: setDepth(point.x - f.minX, persist: false)
        }
    }

    // MARK: Changes

    private func edgeChanged() {
        liveDepth = nil
        applyFrame()
        layoutContent()
        windowRoom.restore()
        makeRoom()
    }

    @objc private func screensChanged() {
        if progress == 0 { return }
        applyFrame()
    }
}
