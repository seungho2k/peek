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
    static var font: NSFont { .systemFont(ofSize: fontSize) }
    static var boldFont: NSFont { .boldSystemFont(ofSize: fontSize) }

    /// Text inset inside the panel (plus the text container's 5pt line fragment padding).
    static let textInset = NSSize(width: 3, height: 6)

    static let imageGap: CGFloat = 4

    /// Close button glyph (faint) and its hover background.
    static let closeGlyph = dynamic(
        light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.35),
        dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.4)
    )
    static let closeHover = dynamic(
        light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.07),
        dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.1)
    )

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
