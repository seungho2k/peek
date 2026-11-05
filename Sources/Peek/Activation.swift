import AppKit

/// App activation that works from a mouse hover.
///
/// Since macOS 14, `NSApp.activate()` is only a request ("cooperative activation") and is
/// refused for a background app the user hasn't clicked. Input methods (e.g. Korean) only
/// attach to the active app, so peek must really become active. SkyLight's private
/// `_SLPSSetFrontProcessWithOptions` (as used by AltTab/Hammerspoon) does it as if the user
/// had clicked. Falls back to the public API if the symbol is missing.
@MainActor
enum Activation {
    private typealias SetFrontProcess = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> Int32
    private typealias GetProcessForPID = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> Int32

    private static let userGenerated: UInt32 = 0x200

    private static let setFrontProcess: SetFrontProcess? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let sym = dlsym(handle, "_SLPSSetFrontProcessWithOptions")
        else { return nil }
        return unsafeBitCast(sym, to: SetFrontProcess.self)
    }()

    private static let getProcessForPID: GetProcessForPID? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "GetProcessForPID") else { return nil }  // RTLD_DEFAULT
        return unsafeBitCast(sym, to: GetProcessForPID.self)
    }()

    /// Makes peek the active app.
    static func activateSelf() {
        if !forceFront(pid: getpid()) {
            NSApp.activate()
        }
    }

    private static func forceFront(pid: pid_t) -> Bool {
        guard let setFrontProcess, let getProcessForPID else { return false }
        var psn = ProcessSerialNumber()
        guard getProcessForPID(pid, &psn) == noErr else { return false }
        return setFrontProcess(&psn, 0, userGenerated) == 0
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
