import AppKit
import ApplicationServices

/// While peek is shown, other apps' windows that overlap the panel are narrowed (or moved) to
/// stay clear of it; when peek hides, windows still at the frame peek gave them go back to their
/// original frame (one the user resized or moved in the meantime is left alone).
///
/// Uses the Accessibility API, so it needs the Accessibility permission. Only standard windows
/// on the current Space are touched (not minimized or full-screen ones). AX calls run on a
/// background queue with a short timeout, so a busy app can't stall the panel.
final class WindowRoom: @unchecked Sendable {
    /// A window narrower than this after shrinking is moved away from the panel instead.
    static let minimumWidth: CGFloat = 200

    private let queue = DispatchQueue(label: "peek.window-room")
    /// Windows peek changed (queue-confined).
    private var adjusted: [Adjusted] = []

    private struct Adjusted {
        let window: AXUIElement
        let original: CGRect
        var applied: CGRect
        /// The panel area it was fitted to.
        var panel: CGRect
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that sends the user to the Accessibility settings.
    static func requestTrust() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    // MARK: Geometry (AX coordinates: origin at the primary screen's top-left, y down)

    static func axRect(_ r: NSRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// The frame that keeps `window` clear of `panel` on its `edge` side within `usable`, or nil
    /// if it doesn't overlap the panel. Shrinks the window if that leaves it at least
    /// `minimumWidth` wide; otherwise moves it next to the panel (narrowing it only if needed).
    static func clearedFrame(_ window: CGRect, panel: CGRect, usable: CGRect, edge: PeekEdge) -> CGRect? {
        guard window.minY < panel.maxY, window.maxY > panel.minY,
              window.maxX > panel.minX, window.minX < panel.maxX else { return nil }
        var r = window
        switch edge {
        case .right:
            let limit = panel.minX
            if limit - window.minX >= minimumWidth {
                r.size.width = limit - window.minX
            } else {
                r.origin.x = max(usable.minX, limit - window.width)
                r.size.width = limit - r.origin.x
            }
        case .left:
            let limit = panel.maxX
            if window.maxX - limit >= minimumWidth {
                r.origin.x = limit
                r.size.width = window.maxX - limit
            } else {
                r.origin.x = limit
                r.size.width = min(usable.maxX, limit + window.width) - limit
            }
        }
        return r.width > 0 ? r : nil
    }

    // MARK: Make room / restore

    /// Moves windows out of `panel` (screen coordinates). Call again when the panel's size
    /// changes: windows already moved are re-fitted from their original frame.
    func makeRoom(panel: NSRect, screen: NSScreen, edge: PeekEdge) {
        guard Self.isTrusted else { return }
        let panelAX = Self.axRect(panel), usableAX = Self.axRect(screen.visibleFrame)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let pids = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ownPID && !$0.isHidden }
            .map(\.processIdentifier)
        queue.async { [self] in
            let visible = Self.onScreenWindowBounds()
            for pid in pids {
                for window in Self.windows(of: pid) {
                    guard let current = Self.frame(of: window) else { continue }
                    let index = adjusted.firstIndex { CFEqual($0.window, window) }
                    // A window the user moved since we adjusted it starts over from where it is.
                    if let i = index, !Self.close(current, adjusted[i].applied) { adjusted.remove(at: i) }
                    let i = adjusted.firstIndex { CFEqual($0.window, window) }
                    // Already fitted to this panel (maybe not fully: an app's minimum width can
                    // keep it overlapping). Trying again would only loop on our own notifications.
                    if let i, adjusted[i].panel == panelAX { continue }
                    let base = i.map { adjusted[$0].original } ?? current
                    guard i != nil || visible[pid, default: []].contains(where: { Self.close($0, current) }),
                          Self.isAdjustable(window) else { continue }
                    let goal = Self.clearedFrame(base, panel: panelAX, usable: usableAX, edge: edge) ?? base
                    if Self.close(goal, current) { continue }
                    Self.setFrame(goal, of: window)
                    let applied = Self.frame(of: window) ?? goal
                    if let i {
                        adjusted[i].applied = applied
                        adjusted[i].panel = panelAX
                    } else {
                        adjusted.append(Adjusted(window: window, original: current, applied: applied, panel: panelAX))
                    }
                }
            }
            adjusted.removeAll { Self.close($0.original, $0.applied) }
        }
    }

    /// Puts back every window that is still where peek put it.
    func restore() {
        queue.async { [self] in
            for a in adjusted {
                guard let current = Self.frame(of: a.window), Self.close(current, a.applied) else { continue }
                Self.setFrame(a.original, of: a.window)
            }
            adjusted.removeAll()
        }
    }

    // MARK: Fill

    /// The screen rectangle (AX coordinates) that `window` mostly lies on, as its visible frame.
    private struct ScreenArea { let frame: CGRect; let visible: CGRect }

    /// Makes the focused window of `pid` fill the visible frame of the screen it's on, with no
    /// gaps. If the panel is shown on that screen, the window stops at the panel; with
    /// `remember`, it's then treated like a window make-room moved, so it fills the whole
    /// screen again when peek hides.
    func fillFocusedWindow(of pid: pid_t, panel: (frame: NSRect, edge: PeekEdge, remember: Bool)?) {
        let screens = NSScreen.screens.map { ScreenArea(frame: Self.axRect($0.frame), visible: Self.axRect($0.visibleFrame)) }
        let panelAX = panel.map { Self.axRect($0.frame) }
        queue.async { [self] in
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.3)
            guard let focused = Self.attribute(app, kAXFocusedWindowAttribute),
                  CFGetTypeID(focused) == AXUIElementGetTypeID() else { return }
            let window = focused as! AXUIElement
            guard Self.isAdjustable(window), let current = Self.frame(of: window),
                  let screen = screens.max(by: { Self.overlap($0.frame, current) < Self.overlap($1.frame, current) })
            else { return }
            let full = screen.visible
            var goal = full
            if let panel, let panelAX, panelAX.intersects(screen.frame) {
                goal = Self.clearedFrame(full, panel: panelAX, usable: full, edge: panel.edge) ?? full
            }
            Self.setFrame(goal, of: window)
            adjusted.removeAll { CFEqual($0.window, window) }
            if let panel, let panelAX, panel.remember, goal != full {
                let applied = Self.frame(of: window) ?? goal
                adjusted.append(Adjusted(window: window, original: full, applied: applied, panel: panelAX))
            }
        }
    }

    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let r = a.intersection(b)
        return r.isNull ? 0 : r.width * r.height
    }

    // MARK: Watching

    /// AX observers per app, while watching (main thread only).
    private var observers: [pid_t: AXObserver] = [:]
    private var workspaceTokens: [NSObjectProtocol] = []
    /// Called (on the main thread) when a window may have moved into the panel's area.
    private var onChange: (() -> Void)?

    private static let watchedNotifications = [
        kAXWindowCreatedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification,
        kAXWindowDeminiaturizedNotification,
    ]

    /// Watches every app's windows (created, moved, resized, unminimized) plus app launches,
    /// unhides and Space switches, and calls `onChange` for each. Main thread.
    func startWatching(onChange: @escaping () -> Void) {
        stopWatching()
        guard Self.isTrusted else { return }
        self.onChange = onChange
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != ownPID {
            observe(app.processIdentifier)
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didUnhideApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            workspaceTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                       app.activationPolicy == .regular, app.processIdentifier != ownPID {
                        self?.observe(app.processIdentifier)
                    }
                    self?.onChange?()
                }
            })
        }
    }

    func stopWatching() {
        for observer in observers.values {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observers.removeAll()
        for token in workspaceTokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        workspaceTokens.removeAll()
        onChange = nil
    }

    private func observe(_ pid: pid_t) {
        guard observers[pid] == nil else { return }
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<WindowRoom>.fromOpaque(refcon).takeUnretainedValue().onChange?()
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let observer = created else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        // Registered on the app element, these arrive for all of its windows.
        for name in Self.watchedNotifications {
            AXObserverAddNotification(observer, app, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    /// `restore()` and wait for it (when quitting).
    func restoreAndWait() {
        restore()
        queue.sync {}
    }

    // MARK: AX helpers

    private static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
    }

    /// On-screen (current Space), normal-layer window bounds per app, in AX coordinates.
    private static func onScreenWindowBounds() -> [pid_t: [CGRect]] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        var result: [pid_t: [CGRect]] = [:]
        for w in info where (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict as CFDictionary) else { continue }
            result[pid, default: []].append(rect)
        }
        return result
    }

    private static func windows(of pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    /// A standard window that isn't minimized or full screen, and can be moved and resized.
    private static func isAdjustable(_ window: AXUIElement) -> Bool {
        guard attribute(window, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
              attribute(window, kAXMinimizedAttribute) as? Bool != true,
              attribute(window, "AXFullScreen") as? Bool != true else { return false }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }
        return true
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        guard let p = attribute(window, kAXPositionAttribute), let s = attribute(window, kAXSizeAttribute)
        else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &origin), AXValueGetValue(s as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Size, position, size: an app may clamp a size that doesn't fit at the old position.
    private static func setFrame(_ r: CGRect, of window: AXUIElement) {
        var origin = r.origin, size = r.size
        guard let p = AXValueCreate(.cgPoint, &origin), let s = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, s)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, p)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, s)
    }
}
