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
}
