import AppKit

/// Text-based settings, shown inside the note panel in place of the note (same width, same
/// text view, so the same line numbers, rules and bolding). Edits apply as you type; lines that
/// can't be applied turn red. ⌘, or Esc goes back to the note.
@MainActor
final class SettingsEditor: NSObject, NSTextViewDelegate {
    let scrollView = NSScrollView()
    let textView: NoteTextView
    private let settings = Settings.shared

    /// Close request (⌘, or Esc).
    var onClose: (() -> Void)?

    override init() {
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
        textView.onOpenSettings = { [weak self] in self?.onClose?() }
        textView.onEscape = { [weak self] in self?.onClose?() }

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.autoresizingMask = [.width, .height]
        scrollView.isHidden = true
    }

    /// Fills the panel with the current settings.
    func load() {
        textView.load(markdown: SettingsText.format(settings))
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        markInvalid([])
    }

    func textDidChange(_ notification: Notification) {
        let (changes, invalid) = SettingsText.parse(textView.markdown())
        SettingsText.apply(changes, to: settings)
        markInvalid(invalid)
    }

    /// Red for lines that couldn't be applied (layout-only attribute, not part of the text).
    private func markInvalid(_ lines: Set<Int>) {
        guard let lm = textView.layoutManager, let storage = textView.textStorage else { return }
        let ns = storage.string as NSString
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: ns.length))
        var index = 0, line = 0
        while index < ns.length {
            let paragraph = ns.paragraphRange(for: NSRange(location: index, length: 0))
            if lines.contains(line) {
                lm.addTemporaryAttribute(.foregroundColor, value: Theme.invalid, forCharacterRange: paragraph)
            }
            index = NSMaxRange(paragraph)
            line += 1
        }
    }

    #if DEBUG
    /// Draws the settings (with one invalid value) for visual checks.
    func debugRender(to path: String, width: CGFloat) {
        load()
        let edgeValue = (textView.string as NSString).range(of: "edge: " + settings.edge.rawValue)
        textView.setSelectedRange(NSRange(location: NSMaxRange(edgeValue), length: 0))
        textView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        let size = NSSize(width: width, height: 420)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        scrollView.isHidden = false
        window.contentView = scrollView
        scrollView.frame = NSRect(origin: .zero, size: size)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let image = NSImage(size: size)
        image.lockFocusFlipped(true)
        Theme.background.setFill(); NSRect(origin: .zero, size: size).fill()
        let rep = textView.bitmapImageRepForCachingDisplay(in: textView.bounds)!
        textView.cacheDisplay(in: textView.bounds, to: rep)
        rep.draw(in: NSRect(origin: .zero, size: textView.bounds.size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        image.unlockFocus()
        try? NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: path))
    }
    #endif
}
