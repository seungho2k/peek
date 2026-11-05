import AppKit

/// Full line width of the container (it spans the whole panel; indents are applied per line).
func containerLineWidth(_ container: NSTextContainer) -> CGFloat {
    max(1, container.size.width - 2 * container.lineFragmentPadding)
}

// MARK: Horizontal rule

final class RuleAttachment: NSTextAttachment {
    init() {
        super.init(data: nil, ofType: nil)
        let cell = RuleCell()
        cell.attachment = self
        attachmentCell = cell
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

final class RuleCell: NSTextAttachmentCell {
    override func cellFrame(
        for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
        glyphPosition position: NSPoint, characterIndex charIndex: Int
    ) -> NSRect {
        let font = Theme.font
        let height = ceil(font.ascender - font.descender + font.leading)
        // Edge to edge like image rows.
        let width = containerLineWidth(textContainer) - 2 * Theme.blockSideInset
        return NSRect(x: 0, y: floor(font.descender), width: max(1, width), height: height)
    }

    override func cellSize() -> NSSize { NSSize(width: 100, height: 15) }
    override func cellBaselineOffset() -> NSPoint { .zero }
    override func wantsToTrackMouse() -> Bool { false }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        drawRule(in: cellFrame, controlView: controlView, characterIndex: nil)
    }

    override func draw(
        withFrame cellFrame: NSRect, in controlView: NSView?,
        characterIndex charIndex: Int, layoutManager: NSLayoutManager
    ) {
        drawRule(in: cellFrame, controlView: controlView, characterIndex: charIndex)
    }

    private func drawRule(in frame: NSRect, controlView: NSView?, characterIndex: Int?) {
        if let idx = characterIndex, isSelected(idx, in: controlView) {
            NSColor.selectedTextBackgroundColor.setFill()
            frame.fill()
        }
        Theme.rule.setFill()
        let scale = controlView?.window?.backingScaleFactor ?? 2
        let thickness = 1 / scale * max(1, scale / 2)
        NSRect(x: frame.minX, y: floor(frame.midY), width: frame.width, height: thickness).fill()
    }
}

func isSelected(_ charIndex: Int, in view: NSView?) -> Bool {
    guard let tv = view as? NSTextView else { return false }
    return tv.selectedRanges.contains { NSLocationInRange(charIndex, $0.rangeValue) }
}

// MARK: Images

@MainActor
enum ImageCache {
    private static var cache: [String: NSImage] = [:]

    static func image(named name: String) -> NSImage? {
        if let img = cache[name] { return img }
        guard let img = NSImage(contentsOf: NoteStore.shared.imageURL(named: name)) else { return nil }
        cache[name] = img
        return img
    }
}

final class ImageAttachment: NSTextAttachment {
    let name: String
    let picture: NSImage?

    @MainActor
    init(name: String) {
        self.name = name
        self.picture = ImageCache.image(named: name)
        super.init(data: nil, ofType: nil)
        let cell = ImageCell()
        cell.attachment = self
        attachmentCell = cell
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Width / height. Missing images use 4:3.
    var aspect: CGFloat {
        guard let size = picture?.size, size.width > 0, size.height > 0 else { return 4.0 / 3.0 }
        return size.width / size.height
    }
}

/// Lays out all images on a line at one common height so the row exactly fills the width.
final class ImageCell: NSTextAttachmentCell {
    override func cellFrame(
        for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
        glyphPosition position: NSPoint, characterIndex charIndex: Int
    ) -> NSRect {
        guard let storage = textContainer.layoutManager?.textStorage
        else { return NSRect(origin: .zero, size: cellSize()) }

        let widths = Self.rowWidths(in: storage, at: charIndex, container: textContainer)
        guard let mine = widths.first(where: { $0.index == charIndex }) else {
            return NSRect(origin: .zero, size: cellSize())
        }
        return NSRect(x: 0, y: 0, width: mine.width + mine.gap, height: mine.height)
    }

    /// Lays out the row: one common height, widths by aspect ratio, and the last image takes
    /// whatever is left so the row ends exactly at the right inset (no rounding gap).
    /// Each image except the last carries the gap to its right inside its own cell.
    static func rowWidths(in storage: NSTextStorage, at charIndex: Int, container: NSTextContainer)
        -> [(index: Int, width: CGFloat, gap: CGFloat, height: CGFloat)] {
        let line = (storage.string as NSString).paragraphRange(for: NSRange(location: charIndex, length: 0))
        var items: [(index: Int, aspect: CGFloat)] = []
        storage.enumerateAttribute(.attachment, in: line) { value, r, _ in
            if let img = value as? ImageAttachment {
                for k in 0..<r.length { items.append((r.location + k, img.aspect)) }
            }
        }
        guard !items.isEmpty else { return [] }
        let gaps = Theme.imageGap * CGFloat(items.count - 1)
        let rowWidth = containerLineWidth(container) - 2 * Theme.blockSideInset - gaps
        let height = max(1, floor(rowWidth / max(items.reduce(0) { $0 + $1.aspect }, 0.01)))
        var used: CGFloat = 0
        return items.enumerated().map { i, item in
            let isLast = i == items.count - 1
            let width = isLast ? max(1, rowWidth - used) : floor(height * item.aspect)
            used += width
            return (item.index, width, isLast ? 0 : Theme.imageGap, height)
        }
    }

    private static func isLastInRow(_ storage: NSTextStorage, _ charIndex: Int) -> Bool {
        let line = (storage.string as NSString).paragraphRange(for: NSRange(location: charIndex, length: 0))
        var last = charIndex
        storage.enumerateAttribute(.attachment, in: line) { value, r, _ in
            if value is ImageAttachment { last = NSMaxRange(r) - 1 }
        }
        return last == charIndex
    }

    override func cellSize() -> NSSize { NSSize(width: 100, height: 75) }
    override func cellBaselineOffset() -> NSPoint { .zero }
    override func wantsToTrackMouse() -> Bool { false }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        drawImage(in: cellFrame, controlView: controlView, characterIndex: nil)
    }

    override func draw(
        withFrame cellFrame: NSRect, in controlView: NSView?,
        characterIndex charIndex: Int, layoutManager: NSLayoutManager
    ) {
        var frame = cellFrame
        if let storage = layoutManager.textStorage, !Self.isLastInRow(storage, charIndex) {
            frame.size.width -= Theme.imageGap
        }
        drawImage(in: frame, controlView: controlView, characterIndex: charIndex)
    }

    private func drawImage(in frame: NSRect, controlView: NSView?, characterIndex: Int?) {
        if let image = (attachment as? ImageAttachment)?.picture {
            image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: true, hints: [NSImageRep.HintKey.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)])
        } else {
            Theme.missingImage.setFill()
            frame.fill()
        }
        if let idx = characterIndex, isSelected(idx, in: controlView) {
            NSColor.selectedTextBackgroundColor.withAlphaComponent(0.5).setFill()
            frame.fill(using: .sourceOver)
        }
    }
}
