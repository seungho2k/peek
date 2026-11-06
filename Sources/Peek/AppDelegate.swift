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
                for w in NSApp.windows where w.isVisible { print("window \(type(of: w)) \(w.frame) alpha=\(w.alphaValue) ignoresMouse=\(w.ignoresMouseEvents)") }
                if ProcessInfo.processInfo.environment["PEEK_SETTINGS_TOGGLE_PROBE"] != nil {
                    let pc = self.panelController!
                    @MainActor func state(_ l: String) { print("\(l): panel=\(pc.panel.isVisible)/\(String(format: "%.2f", pc.panel.alphaValue)) settingsOpen=\(pc.settingsOpen)") }
                    pc.showSettings(); state("settings opened")
                    pc.hotKeyPressed()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { state("mid fade-out")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { state("hidden")
                            pc.hotKeyPressed()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) { state("mid fade-in")
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { state("shown again"); exit(0) }
                            }
                        }
                    }
                    return
                }
                if ProcessInfo.processInfo.environment["PEEK_SETTINGS_PROBE"] != nil {
                    self.panelController.showSettings()
                    print("settings: panel=\(self.panelController.panel.frame) settingsOpen=\(self.panelController.settingsOpen)")
                    self.panelController.hideSettings()
                    print("settings closed: settingsOpen=\(self.panelController.settingsOpen)")
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
