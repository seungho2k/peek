import AppKit

/// Owns the scroll view + text view and keeps them in sync with note.md.
@MainActor
final class NoteEditor: NSObject, NSTextViewDelegate {
    let scrollView = SnapScrollView()
    let textView: NoteTextView
    private let store = NoteStore.shared
    private var saveWorkItem: DispatchWorkItem?
    private var isDirty = false
    /// The note's own undo history (the settings view lives in the same window).
    private let undo = UndoManager()

    init(loadFromDisk: Bool = true) {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        textView = NoteTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 600), textContainer: container)
        super.init()

        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.delegate = self
        // Any character change — typing, paste, undo/redo — needs saving.
        NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: textView.textStorage, queue: nil
        ) { [weak self] note in  // synchronous: editedMask is only valid during processing
            guard let storage = note.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters) else { return }
            MainActor.assumeIsolated { self?.scheduleSave() }
        }

        scrollView.documentView = textView
        scrollView.snapOffsets = { [weak textView] in textView?.ruleSnapOffsets() ?? [] }
        scrollView.hasVerticalScroller = false  // scrolls with the trackpad/wheel; no visible bar
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder


        if loadFromDisk { reload() }
    }

    /// Replaces the text view content with what's on disk.
    func reload() {
        let markdown = store.load()
        textView.load(markdown: markdown)
        isDirty = false
        refreshLineNumbers()
    }

    func saveNow() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        guard isDirty else { return }
        if store.save(textView.markdown()) { isDirty = false }  // on failure, retry next time
    }

    private func scheduleSave() {
        isDirty = true
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    func undoManager(for view: NSTextView) -> UndoManager? { undo }

    func textDidChange(_ notification: Notification) {
        scheduleSave()
        refreshLineNumbers()
    }

    func refreshLineNumbers() {
        textView.needsDisplay = true
    }
}
