import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panelController: PanelController!
    private let settingsWindow = SettingsWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        removeUnreferencedImages()
        panelController = PanelController()
        panelController.onOpenSettings = { [weak self] in self?.showSettings() }
        #if DEBUG
        if ProcessInfo.processInfo.environment["PEEK_FOCUS_PROBE"] != nil { runFocusProbe() }
        #endif
    }

    #if DEBUG
    private func runFocusProbe() {
        func report(_ label: String) {
            let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
            print("\(label): visible=\(panelController.panel.isVisible) frame=\(panelController.panel.frame) alpha=\(panelController.panel.alphaValue) screen=\(NSScreen.main!.visibleFrame) front=\(front) active=\(NSApp.isActive) key=\(panelController.panel.isKeyWindow)")
        }
        report("before")
        let delay = Double(ProcessInfo.processInfo.environment["PEEK_FOCUS_PROBE"] ?? "") ?? 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            report("before show")
            self.panelController.show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                report("shown")
                self.panelController.hide()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    report("hidden")
                    exit(0)
                }
            }
        }
    }
    #endif

    /// peek has no Dock or menu bar icon: launching it again opens settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        panelController.editor.saveNow()
    }

    private func removeUnreferencedImages() {
        let store = NoteStore.shared
        let markdown = store.load() as NSString
        let matches = NoteFormat.imageRef.matches(in: markdown as String, range: NSRange(location: 0, length: markdown.length))
        store.removeUnreferencedImages(referenced: Set(matches.map { markdown.substring(with: $0.range(at: 1)) }))
    }

    func showSettings() {
        settingsWindow.show()
    }
}
