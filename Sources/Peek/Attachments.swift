import AppKit

/// Width available to a line inside the given text container.
func usableLineWidth(_ container: NSTextContainer) -> CGFloat {
    max(1, container.size.width - 2 * container.lineFragmentPadding - 1)
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
        return NSRect(x: 0, y: floor(font.descender), width: usableLineWidth(textContainer), height: height)
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
        guard let me = attachment as? ImageAttachment,
              let storage = textContainer.layoutManager?.textStorage
        else { return NSRect(origin: .zero, size: cellSize()) }

        let row = Self.row(in: storage, at: charIndex)
        let available = usableLineWidth(textContainer) - Theme.imageGap * CGFloat(max(row.count - 1, 0))
        let height = max(1, floor(available / max(row.aspects, 0.01)))
        // Every image but the last carries the gap to its right inside its own cell.
        let gap = charIndex == row.lastIndex ? 0 : Theme.imageGap
        return NSRect(x: 0, y: 0, width: floor(height * me.aspect) + gap, height: height)
    }

    private static func row(in storage: NSTextStorage, at charIndex: Int) -> (count: Int, aspects: CGFloat, lastIndex: Int) {
        let line = (storage.string as NSString).paragraphRange(for: NSRange(location: charIndex, length: 0))
        var aspects: CGFloat = 0, count = 0, last = charIndex
        storage.enumerateAttribute(.attachment, in: line) { value, r, _ in
            if let img = value as? ImageAttachment {
                aspects += img.aspect * CGFloat(r.length)
                count += r.length
                last = NSMaxRange(r) - 1
            }
        }
        return (count, aspects, last)
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
        if let storage = layoutManager.textStorage, charIndex != Self.row(in: storage, at: charIndex).lastIndex {
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
