import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panelController: PanelController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        removeUnreferencedImages()
        panelController = PanelController()
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
            if ProcessInfo.processInfo.environment["PEEK_PIN"] != nil {
                self.panelController.hotKeyPressed()
            } else {
                self.panelController.show()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                report("shown")
                if ProcessInfo.processInfo.environment["PEEK_SETTINGS_PROBE"] != nil {
                    self.panelController.showSettings()
                    let sp = self.panelController.settingsPanel.panel
                    print("settings: note=\(self.panelController.panel.frame) settings=\(sp.frame) visible=\(sp.isVisible) key=\(sp.isKeyWindow)")
                    self.panelController.hideSettings()
                    print("settings closed: note=\(self.panelController.panel.frame)")
                }
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
        panelController.showSettings()
    }
}
