import AppKit
import Carbon

/// DEBUG-only trace for input/focus issues: ~/Library/Logs/peek-debug.log
enum DebugLog {
    #if DEBUG
    private static let handle: FileHandle? = {
        let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/peek-debug.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try? FileHandle(forWritingTo: url)
    }()
    private static let start = CACurrentMediaTime()
    #endif

    static func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        let line = String(format: "%8.3f ", CACurrentMediaTime() - start) + message() + "\n"
        handle?.write(Data(line.utf8))
        #endif
    }

    @MainActor
    static var state: String {
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        var sourceID = "?"
        if let source, let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
            sourceID = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
        }
        let key = NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "nil"
        return "active=\(NSApp.isActive) front=\(front) keyWin=\(key) src=\(sourceID)"
    }
}
