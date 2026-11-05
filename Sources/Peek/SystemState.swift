import AppKit

/// Helpers about system UI state.
@MainActor
enum SystemState {
    /// Mouse button state at the hardware (HID) level. `NSEvent.pressedMouseButtons` can read
    /// 0 while another app runs a drag session (e.g. dragging a file in Finder).
    static var isMouseButtonDown: Bool {
        CGEventSource.buttonState(.hidSystemState, button: .left)
            || CGEventSource.buttonState(.hidSystemState, button: .right)
            || CGEventSource.buttonState(.hidSystemState, button: .center)
    }

    /// Mission Control: the Dock covers a screen with a window — but an auto-hidden Dock that
    /// slides in also uses a screen-sized window, so ignore it while the cursor is at the Dock.
    static func isMissionControlActive() -> Bool {
        isDockOverlayActive() && !isCursorNearDock()
    }

    /// Whether the cursor is within the Dock's reach of the edge the Dock lives on.
    static func isCursorNearDock() -> Bool {
        let dock = UserDefaults(suiteName: "com.apple.dock")
        let orientation = dock?.string(forKey: "orientation") ?? "bottom"
        let tile = CGFloat(dock?.double(forKey: "tilesize") ?? 0)
        let large = (dock?.bool(forKey: "magnification") ?? false) ? CGFloat(dock?.double(forKey: "largesize") ?? 0) : 0
        let reach = max(max(tile, large), 64) + 48
        let p = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }) else { return false }
        let f = screen.frame
        switch orientation {
        case "left": return p.x - f.minX < reach
        case "right": return f.maxX - p.x < reach
        default: return p.y - f.minY < reach
        }
    }

    /// True while Mission Control (or a similar Dock overlay) covers a screen:
    /// the Dock then owns an on-screen, screen-sized window.
    static func isDockOverlayActive() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return false }
        let screenSizes = NSScreen.screens.map(\.frame.size)
        for w in windows where w[kCGWindowOwnerName as String] as? String == "Dock" {
            guard let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict)
            else { continue }
            if screenSizes.contains(where: { bounds.width >= $0.width && bounds.height >= $0.height }) {
                return true
            }
        }
        return false
    }
}
