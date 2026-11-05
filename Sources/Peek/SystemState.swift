import AppKit

/// Helpers about system UI state.
@MainActor
enum SystemState {
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
