import AppKit

/// Owns the scroll view + text view and keeps them in sync with note.md.
@MainActor
final class NoteEditor: NSObject, NSTextViewDelegate {
    let scrollView = NSScrollView()
    let textView: NoteTextView
    private let store = NoteStore.shared
    private var saveWorkItem: DispatchWorkItem?
    private var isDirty = false

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

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        scrollView.verticalRulerView = LineNumberRuler(textView: textView, scrollView: scrollView)
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLineNumbers() }
        }

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
        store.save(textView.markdown())
        isDirty = false
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

    func textDidChange(_ notification: Notification) {
        scheduleSave()
        refreshLineNumbers()
    }

    func refreshLineNumbers() {
        scrollView.verticalRulerView?.needsDisplay = true
    }
}
