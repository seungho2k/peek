import AppKit

/// Text-based settings: a small panel docked beside the note (on its inner side). Edits apply
/// as you type; lines that can't be applied turn red. ⌘, or Esc closes it.
@MainActor
final class SettingsPanelController: NSObject, NSTextViewDelegate {
    let panel = PeekPanel()
    private let textView: SettingsTextView = {
        let storage = NSTextStorage()
        let lm = NSLayoutManager()
        storage.addLayoutManager(lm)
        let container = NSTextContainer(size: NSSize(width: 10_000, height: 10_000))
        lm.addTextContainer(container)
        return SettingsTextView(frame: .zero, textContainer: container)
    }()
    private let settings = Settings.shared
    private static let padding = NSSize(width: 10, height: 8)

    var isVisible: Bool { panel.isVisible }

    override init() {
        super.init()
        textView.delegate = self
        textView.onClose = { [weak self] in self?.hide() }
        textView.textContainerInset = Self.padding
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: 10_000, height: 10_000)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        let content = NSView()
        content.addSubview(textView)
        panel.contentView = content
    }

    /// Shows the panel beside `noteFrame` and gives it keyboard focus.
    func show(besideNote noteFrame: NSRect, edge: PeekEdge) {
        let text = SettingsText.format(settings)
        textView.string = text
        textView.typingAttributes = Self.attributes
        textView.textStorage?.setAttributes(Self.attributes, range: NSRange(location: 0, length: (text as NSString).length))
        reposition(besideNote: noteFrame, edge: edge)
        panel.alphaValue = 1
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
    }

    func hide() {
        panel.orderOut(nil)
    }

    #if DEBUG
    /// Draws the panel content with some lines made invalid, for visual checks.
    func debugRender(to path: String) {
        textView.string = SettingsText.format(settings) + "\nedge: middle"
        textView.textStorage?.setAttributes(Self.attributes, range: NSRange(location: 0, length: (textView.string as NSString).length))
        markInvalid(SettingsText.parse(textView.string).invalid)
        let size = fittingSize()
        textView.frame = NSRect(origin: .zero, size: size)
        let image = NSImage(size: size)
        image.lockFocusFlipped(true)
        Theme.background.setFill(); NSRect(origin: .zero, size: size).fill()
        let rep = textView.bitmapImageRepForCachingDisplay(in: textView.bounds)!
        textView.cacheDisplay(in: textView.bounds, to: rep)
        rep.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        image.unlockFocus()
        try? NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: path))
    }
    #endif

    /// Sizes the panel to its text (minimal) and docks it against the note's inner side,
    /// top-aligned (left/right edge) or left-aligned (bottom edge).
    func reposition(besideNote noteFrame: NSRect, edge: PeekEdge) {
        let size = fittingSize()
        let origin: NSPoint = switch edge {
        case .right: NSPoint(x: noteFrame.minX - size.width, y: noteFrame.maxY - size.height)
        case .left: NSPoint(x: noteFrame.maxX, y: noteFrame.maxY - size.height)
        case .bottom: NSPoint(x: noteFrame.minX, y: noteFrame.maxY)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        textView.frame = NSRect(origin: .zero, size: size)
    }

    private static var attributes: [NSAttributedString.Key: Any] {
        [.font: Theme.font, .foregroundColor: Theme.text]
    }

    private func fittingSize() -> NSSize {
        let lines = textView.string.components(separatedBy: "\n")
        let widest = lines.map { ($0 as NSString).size(withAttributes: Self.attributes).width }.max() ?? 0
        let lineHeight = NSLayoutManager().defaultLineHeight(for: Theme.font)
        return NSSize(width: ceil(widest + 2 * Self.padding.width + 12),
                      height: ceil(CGFloat(max(lines.count, 1)) * lineHeight + 2 * Self.padding.height))
    }

    func textDidChange(_ notification: Notification) {
        let (changes, invalid) = SettingsText.parse(textView.string)
        SettingsText.apply(changes, to: settings)
        markInvalid(invalid)
        // Grow/shrink with the text, keeping the docked corner in place.
        let old = panel.frame
        let size = fittingSize()
        let edge = settings.edge
        let origin = NSPoint(x: edge == .right ? old.maxX - size.width : old.minX,
                             y: edge == .bottom ? old.minY : old.maxY - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        textView.frame = NSRect(origin: .zero, size: size)
    }

    private func markInvalid(_ lines: Set<Int>) {
        guard let storage = textView.textStorage else { return }
        let ns = storage.string as NSString
        storage.beginEditing()
        var index = 0, line = 0
        while index <= ns.length {
            let range = ns.lineRange(for: NSRange(location: min(index, ns.length), length: 0))
            let color = lines.contains(line) ? Theme.invalid : Theme.text
            if range.length > 0 { storage.addAttribute(.foregroundColor, value: color, range: range) }
            if NSMaxRange(range) >= ns.length { break }
            index = NSMaxRange(range)
            line += 1
        }
        storage.endEditing()
    }
}

final class SettingsTextView: NSTextView {
    var onClose: (() -> Void)?

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        isRichText = false
        allowsUndo = true
        drawsBackground = false
        insertionPointColor = Theme.text
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        smartInsertDeleteEnabled = false
        inlinePredictionType = .no
        writingToolsBehavior = .none
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func cancelOperation(_ sender: Any?) { onClose?() }  // Esc

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if Settings.shared.shortcut(for: .settings).matches(event) {
            onClose?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
