import AppKit

extension NSAttributedString.Key {
    /// Marks the characters of a line that is bold as a whole.
    static let peekBold = NSAttributedString.Key("peekBold")
    /// Marks the characters of a line that is struck through as a whole.
    static let peekStrike = NSAttributedString.Key("peekStrike")
}

/// Kind of a line ("paragraph") in the note.
enum LineKind: Equatable {
    case text
    case rule
    case images
}

/// Conversion between the on-disk markdown subset and the text view's attributed string,
/// plus derived styling.
///
/// On disk, one line per paragraph:
///   `---`                      horizontal rule
///   `![](images/a.png)![](…)`  image line (one or more images)
///   `**text**`, `~~text~~`     bold / struck-through line (both: `**~~text~~**`)
///   anything else              plain text
@MainActor
enum NoteFormat {
    static let attachmentChar = Character(UnicodeScalar(NSTextAttachment.character)!)
    static let imageRef = try! NSRegularExpression(pattern: #"!\[\]\(images/([^)\s/]+)\)"#)

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: Theme.font, .foregroundColor: Theme.text, .paragraphStyle: Theme.textParagraph]
    }

    // MARK: Parse

    static func parse(_ markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            if i > 0 { result.append(NSAttributedString(string: "\n", attributes: baseAttributes)) }
            let parsed = NSMutableAttributedString(attributedString: parseLine(line))
            // A URL-only line that was ended with Enter is a link.
            if i < lines.count - 1, let url = linkURL(in: line) {
                parsed.addAttribute(.link, value: url, range: NSRange(location: 0, length: parsed.length))
            }
            result.append(parsed)
        }
        return result
    }

    // MARK: Links

    private static let linkDetector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// The URL if the whole line (ignoring surrounding spaces) is a single web address.
    static func linkURL(in line: String) -> URL? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let ns = trimmed as NSString
        guard ns.length > 0, !trimmed.contains(" "),
              let match = linkDetector.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)),
              match.range.location == 0, match.range.length == ns.length,
              let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        else { return nil }
        return url
    }

    /// Keeps `.link` only on lines that still are a URL and end with a line break; a line only
    /// becomes a link when Enter is pressed on it (see NoteTextView.insertNewline).
    private static func ensureLink(_ storage: NSTextStorage, _ line: NSRange) {
        let ns = storage.string as NSString
        var hasLink = false
        storage.enumerateAttribute(.link, in: line) { value, _, stop in
            if value != nil { hasLink = true; stop.pointee = true }
        }
        if NSMaxRange(line) < ns.length, storage.attribute(.link, at: NSMaxRange(line), effectiveRange: nil) != nil {
            storage.removeAttribute(.link, range: NSRange(location: NSMaxRange(line), length: 1))
        }
        guard hasLink else { return }
        let followedByBreak = NSMaxRange(line) < ns.length
        if followedByBreak, let url = linkURL(in: ns.substring(with: line)) {
            var current: URL?
            var uniform = true
            storage.enumerateAttribute(.link, in: line) { value, _, _ in
                let u = value as? URL
                if current == nil { current = u } else if u != current { uniform = false }
                if u == nil { uniform = false }
            }
            if !uniform || current != url { storage.addAttribute(.link, value: url, range: line) }
        } else {
            storage.removeAttribute(.link, range: line)
        }
    }

    private static func parseLine(_ line: String) -> NSAttributedString {
        if line == "---" {
            return attachmentString(RuleAttachment())
        }
        if let names = imageNames(inImageLine: line) {
            let s = NSMutableAttributedString()
            for name in names { s.append(attachmentString(ImageAttachment(name: name))) }
            return s
        }
        // Whole-line formats: **bold**, ~~strike~~, or both (either nesting order).
        var inner = line
        var attrs = baseAttributes
        while true {
            if attrs[.peekBold] == nil, let stripped = unwrap(inner, "**") {
                inner = stripped
                attrs[.peekBold] = true
            } else if attrs[.peekStrike] == nil, let stripped = unwrap(inner, "~~") {
                inner = stripped
                attrs[.peekStrike] = true
            } else {
                break
            }
        }
        return NSAttributedString(string: inner, attributes: attrs)
    }

    /// `marker…marker` → the text inside, if it isn't blank.
    private static func unwrap(_ s: String, _ marker: String) -> String? {
        guard s.count >= 2 * marker.count + 1, s.hasPrefix(marker), s.hasSuffix(marker) else { return nil }
        let inner = String(s.dropFirst(marker.count).dropLast(marker.count))
        return inner.trimmingCharacters(in: .whitespaces).isEmpty ? nil : inner
    }

    /// If the line consists solely of image references, returns their file names.
    static func imageNames(inImageLine line: String) -> [String]? {
        let ns = line as NSString
        let matches = imageRef.matches(in: line, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }
        var covered = 0
        for m in matches {
            guard m.range.location == covered else { return nil }
            covered = NSMaxRange(m.range)
        }
        guard covered == ns.length else { return nil }
        return matches.map { ns.substring(with: $0.range(at: 1)) }
    }

    static func attachmentString(_ attachment: NSTextAttachment) -> NSAttributedString {
        let s = NSMutableAttributedString(attachment: attachment)
        s.addAttributes(baseAttributes, range: NSRange(location: 0, length: s.length))
        return s
    }

    // MARK: Serialize

    static func serialize(_ text: NSAttributedString) -> String {
        var lines: [String] = []
        let ns = text.string as NSString
        var loc = 0
        repeat {
            let content = lineContentRange(in: ns, at: loc)
            lines.append(serializeLine(text, content))
            loc = NSMaxRange(content) + 1
        } while loc <= ns.length
        return lines.joined(separator: "\n")
    }

    private static func serializeLine(_ text: NSAttributedString, _ range: NSRange) -> String {
        switch kind(of: text, line: range) {
        case .rule:
            return "---"
        case .images:
            var out = ""
            text.enumerateAttribute(.attachment, in: range) { value, r, _ in
                if let img = value as? ImageAttachment {
                    out += String(repeating: "![](images/\(img.name))", count: r.length)
                }
            }
            return out
        case .text:
            let line = (text.string as NSString).substring(with: range)
                .replacingOccurrences(of: String(attachmentChar), with: "")
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
            var out = line
            if isStruck(text, line: range) { out = "~~" + out + "~~" }
            if isBold(text, line: range) { out = "**" + out + "**" }
            return out
        }
    }

    // MARK: Lines

    /// Range of the line containing `location`, excluding its line break.
    static func lineContentRange(in string: NSString, at location: Int) -> NSRange {
        let loc = min(max(0, location), string.length)
        var start = 0, end = 0, contentsEnd = 0
        string.getParagraphStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: loc, length: 0))
        return NSRange(location: start, length: contentsEnd - start)
    }

    /// All line content ranges intersecting `range`.
    static func lineRanges(in string: NSString, covering range: NSRange) -> [NSRange] {
        var result: [NSRange] = []
        var loc = range.location
        let end = NSMaxRange(range)
        repeat {
            let line = lineContentRange(in: string, at: loc)
            result.append(line)
            loc = NSMaxRange(line) + 1
        } while loc <= end && loc <= string.length
        return result
    }

    static func kind(of text: NSAttributedString, line range: NSRange) -> LineKind {
        guard range.length > 0 else { return .text }
        var images = 0, rules = 0, other = false
        text.enumerateAttribute(.attachment, in: range) { value, r, _ in
            if value is ImageAttachment {
                images += r.length
            } else if value is RuleAttachment {
                rules += r.length
            } else {
                other = true
            }
        }
        if other { return .text }
        if rules == 1 && images == 0 && range.length == 1 { return .rule }
        if images == range.length { return .images }
        return .text
    }

    static func isBold(_ text: NSAttributedString, line range: NSRange) -> Bool {
        has(.peekBold, text, range)
    }

    static func isStruck(_ text: NSAttributedString, line range: NSRange) -> Bool {
        has(.peekStrike, text, range)
    }

    private static func has(_ key: NSAttributedString.Key, _ text: NSAttributedString, _ range: NSRange) -> Bool {
        var found = false
        text.enumerateAttribute(key, in: range) { value, _, stop in
            if value != nil { found = true; stop.pointee = true }
        }
        return found
    }

    // MARK: Styling

    /// When you start typing on an empty line 00 (the first text line of the note or after a
    /// rule), it becomes bold as if ⌘B had been pressed — saved as `**…**`, and ⌘B undoes it.
    static var autoBoldFirstLine = false

    /// Whether `line` is numbered 00: no text line between it and the start / the last rule.
    static func isFirstLineOfSection(_ storage: NSAttributedString, _ line: NSRange) -> Bool {
        let ns = storage.string as NSString
        var loc = line.location
        while loc > 0 {
            let previous = lineContentRange(in: ns, at: loc - 1)
            switch kind(of: storage, line: previous) {
            case .images: loc = previous.location
            case .rule: return true
            case .text: return false
            }
        }
        return true
    }

    /// Re-derives fonts/colors for every line touching `range`.
    ///
    /// Only touches attributes that actually differ: this runs inside text storage editing,
    /// and every change widens the storage's edited range — NSTextView places the caret at
    /// the end of that range when an input method commits text, so restyling a whole line
    /// unconditionally would throw the caret to the end of the line mid-composition.
    /// Fonts are compared by size and weight only, so fallback fonts that AppKit substitutes
    /// (e.g. Apple SD Gothic Neo for Hangul) are left alone.
    static func restyle(_ storage: NSTextStorage, range: NSRange) {
        let ns = storage.string as NSString
        guard ns.length > 0 else { return }
        let start = min(range.location, ns.length)
        let full = ns.paragraphRange(for: NSRange(location: start, length: min(range.length, ns.length - start)))
        for line in lineRanges(in: ns, covering: full) {
            let withBreak = NSRange(location: line.location, length: min(line.length + 1, ns.length - line.location))
            let isText = kind(of: storage, line: line) == .text
            let bold = isText && isBold(storage, line: line)  // saved as **…**
            let strike = isText && isStruck(storage, line: line)  // saved as ~~…~~

            // Struck-through lines fade to the line-number color.
            if strike && line.length > 0 {
                ensureColor(storage, line, Theme.lineNumber)
                ensureColor(storage, NSRange(location: NSMaxRange(line), length: withBreak.length - line.length), Theme.text)
            } else {
                ensureColor(storage, withBreak, Theme.text)
            }
            ensureParagraph(storage, withBreak, kind(of: storage, line: line) == .text
                ? Theme.textParagraph : Theme.blockParagraph)
            if bold && line.length > 0 {
                ensureFont(storage, line, bold: true)
                ensureFont(storage, NSRange(location: NSMaxRange(line), length: withBreak.length - line.length), bold: false)
            } else {
                ensureFont(storage, withBreak, bold: false)
            }
            ensureMark(.peekBold, storage, line, on: bold)
            ensureMark(.peekStrike, storage, line, on: strike)
            ensureStrikethrough(storage, line, on: strike)
            if kind(of: storage, line: line) == .text { ensureLink(storage, line) }
            if withBreak.length > line.length {
                let lineBreak = NSRange(location: NSMaxRange(line), length: 1)
                ensureMark(.peekBold, storage, lineBreak, on: false)
                ensureMark(.peekStrike, storage, lineBreak, on: false)
                ensureStrikethrough(storage, lineBreak, on: false)
            }
        }
    }

    private static func ensureFont(_ storage: NSTextStorage, _ range: NSRange, bold: Bool) {
        guard range.length > 0 else { return }
        var fixes: [NSRange] = []
        storage.enumerateAttribute(.font, in: range) { value, r, _ in
            guard let font = value as? NSFont,
                  font.pointSize == Theme.fontSize,
                  font.fontDescriptor.symbolicTraits.contains(.bold) == bold
            else { fixes.append(r); return }
        }
        let target = bold ? Theme.boldFont : Theme.font
        for r in fixes { storage.addAttribute(.font, value: target, range: r) }
    }

    private static func ensureParagraph(_ storage: NSTextStorage, _ range: NSRange, _ style: NSParagraphStyle) {
        guard range.length > 0 else { return }
        var fixes: [NSRange] = []
        storage.enumerateAttribute(.paragraphStyle, in: range) { value, r, _ in
            let p = value as? NSParagraphStyle
            if p?.headIndent != style.headIndent || p?.firstLineHeadIndent != style.firstLineHeadIndent
                || p?.tailIndent != style.tailIndent { fixes.append(r) }
        }
        for r in fixes { storage.addAttribute(.paragraphStyle, value: style, range: r) }
    }

    private static func ensureColor(_ storage: NSTextStorage, _ range: NSRange, _ color: NSColor) {
        guard range.length > 0 else { return }
        var fixes: [NSRange] = []
        storage.enumerateAttribute(.foregroundColor, in: range) { value, r, _ in
            if (value as? NSColor) !== color { fixes.append(r) }
        }
        for r in fixes { storage.addAttribute(.foregroundColor, value: color, range: r) }
    }

    private static func ensureMark(_ key: NSAttributedString.Key, _ storage: NSTextStorage, _ range: NSRange, on: Bool) {
        guard range.length > 0 else { return }
        var fixes: [NSRange] = []
        storage.enumerateAttribute(key, in: range) { value, r, _ in
            if (value != nil) != on { fixes.append(r) }
        }
        for r in fixes {
            if on {
                storage.addAttribute(key, value: true, range: r)
            } else {
                storage.removeAttribute(key, range: r)
            }
        }
    }

    private static func ensureStrikethrough(_ storage: NSTextStorage, _ range: NSRange, on: Bool) {
        guard range.length > 0 else { return }
        var fixes: [NSRange] = []
        storage.enumerateAttribute(.strikethroughStyle, in: range) { value, r, _ in
            if ((value as? Int ?? 0) != 0) != on { fixes.append(r) }
        }
        for r in fixes {
            if on {
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: r)
            } else {
                storage.removeAttribute(.strikethroughStyle, range: r)
            }
        }
    }
}
