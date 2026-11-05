import AppKit

/// Draws a two-digit line number (00, 01, …) with each digit in a fixed-width cell
/// (the font's digits are proportional).
enum LineNumberLabel {
    static var baseline: CGFloat { NSLayoutManager().defaultBaselineOffset(for: Theme.font) }

    /// Width of a label with `digits` digits.
    static func width(digits: Int) -> CGFloat { CGFloat(digits) * Theme.digitCell }

    static func draw(_ number: Int, rightEdge: CGFloat, top: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.font, .foregroundColor: Theme.lineNumber]
        let digits = String(format: "%02d", number)
        let cell = Theme.digitCell
        var x = rightEdge - width(digits: digits.count)
        for d in digits {
            let glyph = String(d) as NSString
            let w = glyph.size(withAttributes: attrs).width
            glyph.draw(at: NSPoint(x: x + (cell - w) / 2, y: top), withAttributes: attrs)
            x += cell
        }
    }
}
