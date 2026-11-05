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
