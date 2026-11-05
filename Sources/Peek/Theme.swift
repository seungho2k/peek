import AppKit

/// Colors follow Apple Notes (light/dark); metrics follow Stickies.
/// Color values are estimates — fine-tune by sampling Notes with Digital Color Meter.
enum Theme {
    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { isDark($0) ? dark : light }
    }

    /// Note background.
    static let background = dynamic(
        light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        dark: NSColor(srgbRed: 30 / 255, green: 30 / 255, blue: 30 / 255, alpha: 1)
    )

    /// Body text.
    static let text = dynamic(
        light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.85),
        dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.85)
    )

    /// Horizontal rules and other secondary marks.
    static let rule = dynamic(
        light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.15),
        dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.18)
    )

    /// Placeholder for an image whose file is missing.
    static let missingImage = dynamic(
        light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.08),
        dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10)
    )

    /// Stickies' default note text is 12pt.
    static let fontSize: CGFloat = 12
    /// Pretendard (bundled) for all text; Apple SD Gothic Neo, then the system font, as fallbacks.
    static var font: NSFont {
        NSFont(name: "Pretendard-Regular", size: fontSize)
            ?? NSFont(name: "AppleSDGothicNeo-Regular", size: fontSize)
            ?? .systemFont(ofSize: fontSize)
    }
    static var boldFont: NSFont {
        NSFont(name: "Pretendard-Bold", size: fontSize)
            ?? NSFont(name: "AppleSDGothicNeo-Bold", size: fontSize)
            ?? .boldSystemFont(ofSize: fontSize)
    }

    /// Text inset: top/bottom only. Horizontally the container spans the whole panel: text/rule
    /// lines start after the line-number gutter and keep `textRightMargin` on the right
    /// (paragraph indents); image lines use the full width, edge to edge.
    static let textInset = NSSize(width: 0, height: 6)
    static let textRightMargin: CGFloat = 8

    /// Width of one space in the body font: the gap between a line number and its text,
    /// so "01 text" reads as one continuous line.
    static var spaceWidth: CGFloat { (" " as NSString).size(withAttributes: [.font: font]).width }

    /// Space between images on the same line (none: they sit flush).
    static let imageGap: CGFloat = 0

    /// Line numbers: barely visible.
    static let lineNumber = dynamic(
        light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.16),
        dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.16)
    )

    /// Line-number gutter: a space, two digit cells, a space. Digits are drawn one per
    /// fixed-width cell because the font's digits are proportional.
    static var digitCell: CGFloat {
        (0...9).map { (String($0) as NSString).size(withAttributes: [.font: font]).width }.max() ?? 7
    }
    static var gutterWidth: CGFloat { ceil(2 * spaceWidth + 2 * digitCell) }

    /// Paragraph styles: text lines start after the gutter; image and rule lines ("blocks")
    /// use the full width.
    static var textParagraph: NSParagraphStyle { paragraph(indent: gutterWidth) }
    static let blockParagraph = paragraph(indent: blockSideInset)
    /// Image rows and rules keep this much from both panel edges (so they don't cover the border).
    static let blockSideInset: CGFloat = 1
    /// Horizontal rules leave this much on both sides (same as the text's right margin).
    static let ruleSideMargin: CGFloat = textRightMargin

    private static func paragraph(indent: CGFloat) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.firstLineHeadIndent = indent
        p.headIndent = indent
        p.tailIndent = indent == blockSideInset ? 0 : -textRightMargin
        return p
    }

    /// One fixed line height/baseline for every text line, large enough for both the system
    /// font and the Hangul fallback (Apple SD Gothic Neo), so lines don't jump when scripts mix.
    static let lineMetrics: (height: CGFloat, baseline: CGFloat) = {
        let lm = NSLayoutManager()
        var fonts = [font, boldFont]
        for name in ["AppleSDGothicNeo-Regular", "AppleSDGothicNeo-Bold"] {
            if let f = NSFont(name: name, size: fontSize) { fonts.append(f) }
        }
        let baseline = fonts.map { lm.defaultBaselineOffset(for: $0) }.max() ?? 12
        let below = fonts.map { lm.defaultLineHeight(for: $0) - lm.defaultBaselineOffset(for: $0) }.max() ?? 3
        return (ceil(baseline + below), baseline)
    }()
}
