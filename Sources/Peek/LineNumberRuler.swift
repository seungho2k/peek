import AppKit

/// Faint two-digit line numbers (01, 02, …) beside each logical line.
final class LineNumberRuler: NSRulerView {
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: Theme.fontSize, weight: .regular)
    private static let width: CGFloat = 26
    private static let rightPadding: CGFloat = 4
    /// Distance from the top of a drawn label to its baseline.
    private static let labelBaseline = NSLayoutManager().defaultBaselineOffset(for: font)

    init(textView: NSTextView, scrollView: NSScrollView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = Self.width
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var requiredThickness: CGFloat { Self.width }

    override func draw(_ dirtyRect: NSRect) {
        // No background or separator line: just the numbers.
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = clientView as? NSTextView,
              let lm = tv.layoutManager, let tc = tv.textContainer
        else { return }
        let ns = tv.string as NSString
        let origin = tv.textContainerOrigin
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: Theme.lineNumber]

        func draw(_ number: Int, lineTop: CGFloat, hasText: Bool) {
            // Align with the text baseline on text lines, with the top on image/rule lines.
            let baseline = hasText ? Theme.lineMetrics.baseline : Self.labelBaseline
            let pointInText = NSPoint(x: 0, y: lineTop + origin.y + baseline)
            let y = convert(pointInText, from: tv).y - Self.labelBaseline
            let label = String(format: "%02d", number) as NSString
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: bounds.width - Self.rightPadding - size.width, y: y), withAttributes: attrs)
        }

        let visibleGlyphs = lm.glyphRange(forBoundingRect: tv.visibleRect, in: tc)
        let visibleChars = lm.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)

        var index = ns.length == 0 ? 0 : ns.paragraphRange(for: NSRange(location: min(visibleChars.location, ns.length - 1), length: 0)).location
        var number = 1
        var i = 0
        while i < index {  // count line breaks before the first visible line
            let r = ns.range(of: "\n", options: [], range: NSRange(location: i, length: index - i))
            if r.location == NSNotFound { break }
            number += 1
            i = NSMaxRange(r)
        }

        while index < ns.length && index <= NSMaxRange(visibleChars) {
            let glyph = lm.glyphIndexForCharacter(at: index)
            let frag = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let isBlock = tv.textStorage?.attribute(.attachment, at: index, effectiveRange: nil) != nil
            draw(number, lineTop: frag.minY, hasText: !isBlock)
            index = NSMaxRange(ns.paragraphRange(for: NSRange(location: index, length: 0)))
            number += 1
        }
        // Empty last line (document empty or ending with a line break).
        if lm.extraLineFragmentTextContainer != nil {
            draw(number, lineTop: lm.extraLineFragmentRect.minY, hasText: true)
        }
    }
}
