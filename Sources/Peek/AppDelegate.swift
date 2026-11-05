import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panelController: PanelController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        removeUnreferencedImages()
        panelController = PanelController()
        panelController.onOpenSettings = { [weak self] in self?.showSettings() }
    }

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
        // Implemented with the settings window.
    }
}
