import AppKit

/// Text-based settings, shown in a full-height panel docked beside the note. It uses the note's
/// own text view, so it has the same line numbers, rules and section bolding. Edits apply as
/// you type; lines that can't be applied turn red. ⌘, or Esc closes it.
@MainActor
final class SettingsPanelController: NSObject, NSTextViewDelegate {
    let panel = PeekPanel()
    private let scrollView = NSScrollView()
    let textView: NoteTextView
    private let settings = Settings.shared

    /// Close request (⌘, or Esc).
    var onClose: (() -> Void)?
    /// The text changed width (e.g. a longer value); the owner re-docks the panel.
    var onWidthChange: (() -> Void)?

    var isVisible: Bool { panel.isVisible }

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
        let content = NSView()
        content.addSubview(scrollView)
        panel.contentView = content
    }

    /// Fills the panel with the current settings.
    func load() {
        textView.load(markdown: SettingsText.format(settings))
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        markInvalid([])
    }

    /// Width that fits the longest line (plus gutter and margin).
    var preferredWidth: CGFloat {
        let widest = textView.string.components(separatedBy: "\n")
            .map { ($0 as NSString).size(withAttributes: [.font: Theme.boldFont]).width }
            .max() ?? 0
        return ceil(Theme.gutterWidth + widest + Theme.textRightMargin + 8)
    }

    func setFrame(_ frame: NSRect) {
        panel.setFrame(frame, display: true)
        scrollView.frame = NSRect(origin: .zero, size: frame.size)
    }

    /// Shows it and gives it keyboard focus.
    func present() {
        panel.alphaValue = 1
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textView)
    }

    func hide() {
        textView.commitComposition()
        panel.orderOut(nil)
    }

    func textDidChange(_ notification: Notification) {
        let oldWidth = panel.frame.width
        let (changes, invalid) = SettingsText.parse(textView.markdown())
        SettingsText.apply(changes, to: settings)
        markInvalid(invalid)
        if preferredWidth != oldWidth { onWidthChange?() }
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
    /// Draws the panel content (with one invalid value) for visual checks.
    func debugRender(to path: String) {
        load()
        // "preferences" + rule + "edge" + "right": make the edge value invalid.
        let valueEnd = ("preferences\n-\nedge\nright" as NSString).length
        textView.setSelectedRange(NSRange(location: valueEnd, length: 0))
        textView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        let size = NSSize(width: preferredWidth, height: 420)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
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
