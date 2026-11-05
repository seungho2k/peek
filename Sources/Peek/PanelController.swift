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

    let settingsPanel = SettingsPanelController()
    private lazy var lineNumberOverlay = LineNumberOverlay(textView: editor.textView)
    private lazy var settingsLineNumberOverlay = LineNumberOverlay(textView: settingsPanel.textView)
    /// The note was narrowed to make room for the settings panel.
    private var shrunkForSettings = false
    /// The settings are open (they fade out and back in with the note).
    private var settingsOpen = false
    private var isLayingOutSettings = false

    private static let handleThickness: CGFloat = 5
    /// ⌥-drag resize moves the edge this many times faster than the mouse.
    private static let optionResizeGain: CGFloat = 2

    override init() {
        NoteFormat.autoBoldFirstLine = Settings.shared.autoBoldFirstLine
        Theme.lineNumberMode = Settings.shared.lineNumbers
        editor = NoteEditor()
        super.init()
        setUpContent()
        installMonitors()
        observeSettings()

        hotKey.onPress = { [weak self] in self?.hotKeyPressed() }
        hotKey.register(settings.shortcut(for: .pin))
        editor.textView.onOpenSettings = { [weak self] in self?.toggleSettings() }
        settingsPanel.onClose = { [weak self] in self?.hideSettings() }
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
        let content = NSView()
        panel.contentView = content

        editor.scrollView.translatesAutoresizingMaskIntoConstraints = true
        editor.scrollView.autoresizingMask = [.width, .height]
        content.addSubview(editor.scrollView)

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
            DispatchQueue.main.async { self?.hotKey.register(shortcuts[.pin] ?? ShortcutAction.pin.defaultShortcut) }
        }.store(in: &cancellables)
        settings.$lineNumbers.dropFirst().sink { [weak self] mode in
            DispatchQueue.main.async {
                Theme.lineNumberMode = mode
                self?.updateLineNumberOverlay()
                self?.editor.textView.restyleAll()
                self?.settingsPanel.textView.restyleAll()
            }
        }.store(in: &cancellables)
        settings.$autoBoldFirstLine.dropFirst().sink { on in
            DispatchQueue.main.async { NoteFormat.autoBoldFirstLine = on }
        }.store(in: &cancellables)
        settings.$minDepth.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.applyFrame()
                if self?.settingsOpen == true { self?.layoutSettings() }
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
        }
    }

    /// Positions the panel and applies the fade (`progress` is the opacity).
    private func applyFrame() {
        guard let screen = targetScreen else { return }
        let newFrame = frame(on: screen)
        if newFrame != panel.frame {
            panel.setFrame(newFrame, display: true)
            layoutContent()
            if settingsOpen { layoutSettings() }
        }
        panel.alphaValue = progress
        if settingsOpen { settingsPanel.panel.alphaValue = progress }  // fades with the note
        updateLineNumberOverlay()
    }

    // MARK: Outside line numbers

    /// The note's outside numbers sit where the settings panel docks, so while settings are open
    /// the numbers move outside the settings panel instead (for its own lines).
    private func updateLineNumberOverlay() {
        let outside = settings.lineNumbers == .outside && progress > 0
        show(lineNumberOverlay, beside: panel.frame, if: outside && !settingsOpen)
        show(settingsLineNumberOverlay, beside: settingsPanel.panel.frame, if: outside && settingsOpen)
    }

    private func show(_ overlay: LineNumberOverlay, beside frame: NSRect, if visible: Bool) {
        guard visible else {
            if overlay.window.isVisible { overlay.window.orderOut(nil) }
            return
        }
        overlay.place(besideNote: frame, edge: settings.edge)
        overlay.window.alphaValue = progress
        if !overlay.window.isVisible { overlay.window.orderFrontRegardless() }
    }

    // MARK: Show / hide

    func show() {
        if progress == 0 {
            if NoteStore.shared.hasExternalChange() { editor.reload() }
            applyFrame()
            panel.orderFrontRegardless()
            if settingsOpen {
                // Settings that were open when the note was hidden come back with it.
                layoutSettings()
                settingsPanel.panel.alphaValue = progress
                settingsPanel.panel.orderFrontRegardless()
            }
        }
        animate(to: 1)
    }

    /// ⌘, (or launching peek again): text settings beside the note; opens the note if needed.
    func showSettings() {
        settingsPanel.load()
        settingsOpen = true
        updateLineNumberOverlay()
        if target == 0 { show() } else { layoutSettings() }
        settingsPanel.panel.alphaValue = progress
        settingsPanel.present()
    }

    func toggleSettings() {
        if settingsOpen { hideSettings() } else { showSettings() }
    }

    /// Closes the settings for good (⌘, / Esc). Hiding the note only fades them out with it.
    func hideSettings() {
        settingsOpen = false
        settingsPanel.hide()
        updateLineNumberOverlay()
        if shrunkForSettings {
            // Give the note its own width back.
            shrunkForSettings = false
            liveDepth = nil
            applyFrame()
        }
    }

    /// Docks the settings panel full-height against the note's inner side. If there's no room
    /// for it, the note first narrows by the missing width (until the settings close).
    private func layoutSettings() {
        guard !isLayingOutSettings, let screen = targetScreen else { return }
        isLayingOutSettings = true
        defer { isLayingOutSettings = false }
        let vf = screen.visibleFrame
        let width = min(CGFloat(settings.minDepth), vf.width)  // settings are always min-width wide
        var note = panel.frame
        let room = settings.edge == .right ? note.minX - vf.minX : vf.maxX - note.maxX
        if room < width && !shrunkForSettings && liveDepth == nil {
            // Narrow the note just enough for the settings to fit beside it.
            shrunkForSettings = true
            setDepth(note.width - (width - room), persist: false)
            note = panel.frame
        }
        let x = settings.edge == .right ? max(vf.minX, note.minX - width) : min(vf.maxX - width, note.maxX)
        settingsPanel.setFrame(NSRect(x: x, y: vf.minY, width: width, height: vf.height))
        updateLineNumberOverlay()
    }

    func hide() {
        guard target != 0 else { return }
        // Don't leave a half-composed syllable behind.
        editor.textView.commitComposition()
        settingsPanel.textView.commitComposition()
        animate(to: 0)
    }

    /// Global hotkey: show (without taking focus) or hide. The panel stays until toggled off;
    /// clicking it focuses it like any window.
    func hotKeyPressed() {
        if target == 0 { show() } else { hide() }
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
            if settingsOpen { settingsPanel.panel.orderOut(nil) }  // still open; returns with the note
            lineNumberOverlay.window.orderOut(nil)
            settingsLineNumberOverlay.window.orderOut(nil)
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
            settings.sideWidth = d
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
        depthBeforeFill = nil
        switch settings.edge {
        case .right: setDepth(f.maxX - point.x, persist: false)
        case .left: setDepth(point.x - f.minX, persist: false)
        }
    }

    // MARK: Changes

    private func edgeChanged() {
        shrunkForSettings = false
        liveDepth = nil
        depthBeforeFill = nil
        applyFrame()
        layoutContent()
    }

    @objc private func screensChanged() {
        if progress == 0 { return }
        applyFrame()
    }
}
