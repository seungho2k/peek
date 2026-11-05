#if DEBUG
import AppKit

/// Headless editor checks. Run: `.build/debug/Peek --selftest`
@MainActor
enum SelfTest {
    private static var failures = 0

    /// Renders an editor with sample content to a PNG: `--render <path>`
    static func render(to path: String) -> Never {
        _ = NSApplication.shared
        let editor = NoteEditor(loadFromDisk: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 260), styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = Theme.background
        editor.scrollView.frame = window.contentView!.bounds
        window.contentView!.addSubview(editor.scrollView)
        if let mode = LineNumberMode(rawValue: ProcessInfo.processInfo.environment["PEEK_LINE_NUMBERS"] ?? "") {
            Theme.lineNumberMode = mode
        }
        let sample = ProcessInfo.processInfo.environment["PEEK_RENDER_TEXT"]?.replacingOccurrences(of: "\\n", with: "\n")
        editor.textView.load(markdown: sample ?? "한글 제목 line\n**굵은 줄**\n- 리스트\n  - 들여쓰기\n---\n마지막\n")
        editor.scrollView.tile()
        window.orderFrontRegardless()
        window.displayIfNeeded()
        let view = window.contentView!
        view.layoutSubtreeIfNeeded()
        editor.textView.layoutManager!.ensureLayout(for: editor.textView.textContainer!)
        let tv = editor.textView
        let size = NSSize(width: tv.frame.width, height: 260)
        let image = NSImage(size: size)
        image.lockFocusFlipped(true)
        Theme.background.setFill(); NSRect(origin: .zero, size: size).fill()
        let rep = tv.bitmapImageRepForCachingDisplay(in: tv.bounds)!
        tv.cacheDisplay(in: tv.bounds, to: rep)
        rep.draw(in: NSRect(origin: .zero, size: tv.bounds.size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        image.unlockFocus()
        let tiff = image.tiffRepresentation!
        try? NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
        exit(0)
    }

    static func run() -> Never {
        roundTrip()
        noListContinuation()
        ruleFromDashes()
        lineFormats()
        blockLines()
        undo()
        images()
        koreanComposition()
        lineMetrics()
        koreanMidLine()
        clickLines()
        links()
        settingsText()
        autoBold()
        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    private static func makeView(_ markdown: String = "") -> NoteTextView {
        let storage = NSTextStorage()
        let lm = NSLayoutManager()
        storage.addLayoutManager(lm)
        let container = NSTextContainer(size: NSSize(width: 300, height: 10000))
        lm.addTextContainer(container)
        let tv = NoteTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 600), textContainer: container)
        let window = NSWindow(contentRect: tv.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = tv
        window.makeFirstResponder(tv)
        tv.load(markdown: markdown)
        return tv
    }

    private static func type(_ tv: NoteTextView, _ s: String) {
        tv.insertText(s, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private static func caret(_ tv: NoteTextView, _ loc: Int) {
        tv.setSelectedRange(NSRange(location: loc, length: 0))
    }

    private static func check(_ name: String, _ tv: NoteTextView, _ expected: String) {
        let got = tv.markdown()
        if got == expected {
            print("ok   \(name)")
        } else {
            failures += 1
            print("FAIL \(name)\n  expected: \(expected.debugDescription)\n  got:      \(got.debugDescription)")
        }
    }

    private static func expect(_ name: String, _ condition: Bool) {
        if condition {
            print("ok   \(name)")
        } else {
            failures += 1
            print("FAIL \(name)")
        }
    }

    private static func roundTrip() {
        let md = "a\n**b**\n- c\n---\n  - d\n\n- "
        check("round trip", makeView(md), md)
    }

    private static func noListContinuation() {
        let tv = makeView()
        type(tv, "- abc")
        tv.insertNewline(nil)
        check("enter after '- ' line adds nothing", tv, "- abc\n")
    }

    private static func ruleFromDashes() {
        let tv = makeView()
        type(tv, "---")
        tv.insertNewline(nil)
        type(tv, "after")
        check("--- becomes rule", tv, "---\nafter")
    }

    private static func lineFormats() {
        let tv = makeView("- item")
        caret(tv, 3)
        tv.perform(.bold)
        check("bold line includes a leading dash", tv, "**- item**")
        tv.perform(.bold)
        check("bold toggle off", tv, "- item")
        tv.selectAll(nil)
        tv.insertText("item", replacementRange: NSRange(location: NSNotFound, length: 0))
        caret(tv, 2)
        tv.perform(.rule)
        type(tv, "x")
        check("rule below line", tv, "item\n---\nx")

        let empty = makeView("")
        empty.perform(.rule)
        check("rule on empty line", empty, "---\n")
    }

    private static func blockLines() {
        let tv = makeView("a\n---\nb")
        caret(tv, 3)  // after the rule char
        type(tv, "z")
        check("typing on rule line goes below", tv, "a\n---\nz\nb")

        let del = makeView("a\n---\nb")
        caret(del, 4)  // start of "b"
        del.deleteBackward(nil)
        check("backspace deletes rule", del, "a\nb")

        let fwd = makeView("a\n---")
        caret(fwd, 1)
        fwd.deleteForward(nil)
        check("forward delete removes rule", fwd, "a")

        let mixed = makeView("ab")
        caret(mixed, 1)
        mixed.applyEdits([(NSRange(location: 1, length: 0), NoteFormat.attachmentString(RuleAttachment()))])
        check("mixed line is split", mixed, "a\n---\nb")
    }

    private static func images() {
        let a = "![](images/a.png)", b = "![](images/b.png)", c = "![](images/c.png)"

        let empty = makeView("")
        empty.insertImages(["a.png"])
        check("image fills empty line", empty, a)

        let text = makeView("abc")
        caret(text, 1)
        text.insertImages(["b.png", "c.png"])
        check("image on text line goes below", text, "abc\n\(b)\(c)")

        let row = makeView(a)
        caret(row, 1)
        row.insertImages(["b.png"])
        check("image joins row", row, a + b)
        caret(row, 0)
        row.insertImages(["c.png"])
        check("image joins row on the left", row, c + a + b)

        let typing = makeView(a)
        caret(typing, 1)
        type(typing, "hi")
        check("typing on image line goes below", typing, "\(a)\nhi")

        let atStart = makeView(a)
        caret(atStart, 0)
        type(atStart, "hi")
        check("typing at image line start goes above", atStart, "hi\n\(a)")

        let between = makeView(a + b)
        caret(between, 1)
        type(between, "hi")
        check("typing between images splits the row", between, "\(a)\nhi\n\(b)")

        let merge = makeView("\(a)\n\(b)")
        caret(merge, 2)
        merge.deleteBackward(nil)
        check("backspace joins two image lines", merge, a + b)

        let mergeFwd = makeView("\(a)\n\(b)")
        caret(mergeFwd, 1)
        mergeFwd.deleteForward(nil)
        check("forward delete joins two image lines", mergeFwd, a + b)

        let split = makeView(a + b)
        caret(split, 1)
        split.insertNewline(nil)
        check("enter between images splits the row", split, "\(a)\n\(b)")

        let back = makeView("\(a)\ntext")
        caret(back, 2)
        back.deleteBackward(nil)
        check("backspace doesn't merge text into image line", back, "\(a)\ntext")
        expect("backspace moves caret to image line end", back.selectedRange().location == 1)

        let enter = makeView(a)
        caret(enter, 1)
        enter.insertNewline(nil)
        type(enter, "x")
        check("enter on image line opens line below", enter, "\(a)\nx")

        let copy = makeView("x\n\(a)\(b)\n**y**")
        copy.selectAll(nil)
        let pb = NSPasteboard(name: NSPasteboard.Name("peek.selftest"))
        pb.clearContents()
        _ = copy.writeSelection(to: pb, types: copy.writablePasteboardTypes)
        let paste = makeView("")
        _ = paste.readSelection(from: pb, type: .peekNote)
        check("copy/paste round trip", paste, "x\n\(a)\(b)\n**y**")
        expect("rtfd written", pb.data(forType: .rtfd) != nil)
        pb.releaseGlobally()

        // Justified row: equal heights, total width fills the line.
        let names = ["selftest-wide.png", "selftest-square.png"]
        for (name, size) in zip(names, [NSSize(width: 200, height: 100), NSSize(width: 100, height: 100)]) {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            try? rep.representation(using: .png, properties: [:])!.write(to: NoteStore.shared.imageURL(named: name))
        }
        let layout = makeView("![](images/\(names[0]))![](images/\(names[1]))")
        let lm = layout.layoutManager!, tc = layout.textContainer!
        lm.ensureLayout(for: tc)
        let r0 = lm.boundingRect(forGlyphRange: NSRange(location: 0, length: 1), in: tc)
        let r1 = lm.boundingRect(forGlyphRange: NSRange(location: 1, length: 1), in: tc)
        let inset = Theme.blockSideInset
        print("     row: \(r0) \(r1) container=\(tc.size.width)")
        expect("row images share height", abs(r0.height - r1.height) < 1)
        expect("row on one line", abs(r0.minY - r1.minY) < 1)
        expect("row starts at the left inset", abs(r0.minX - inset) < 0.01)
        expect("row ends exactly at the right inset", abs(r1.maxX - (tc.size.width - inset)) < 0.01)
        expect("aspect kept", abs(r0.width / r1.width - 2) < 0.1)
        // Space around an image line equals the space between text lines.
        let spaced = makeView("a\n![](images/\(names[0]))\nb\nc")
        let slm = spaced.layoutManager!, stc = spaced.textContainer!
        slm.ensureLayout(for: stc)
        let lineA = slm.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        // The image sits on its line's baseline (cell origin at the baseline).
        let imageFrag = slm.lineFragmentRect(forGlyphAt: 2, effectiveRange: nil)
        let imageHeight = ImageCell.rowWidths(in: spaced.textStorage!, at: 2, container: stc)[0].height
        let imageBottomY = imageFrag.minY + slm.location(forGlyphAt: 2).y
        let imageRect = NSRect(x: 0, y: imageBottomY - imageHeight, width: 1, height: imageHeight)
        let baselineA = lineA.minY + slm.location(forGlyphAt: 0).y
        let lineB = slm.lineFragmentRect(forGlyphAt: 4, effectiveRange: nil)
        let lineC = slm.lineFragmentRect(forGlyphAt: 6, effectiveRange: nil)
        let baselineB = lineB.minY + slm.location(forGlyphAt: 4).y
        let capTop = { (lineTop: CGFloat, glyph: Int) in lineTop + slm.location(forGlyphAt: glyph).y - Theme.font.capHeight }
        let textGap = capTop(lineC.minY, 6) - baselineB
        let gapAbove = imageRect.minY - baselineA
        let gapBelow = capTop(lineB.minY, 4) - imageRect.maxY
        print("     gaps: text=\(textGap) aboveImage=\(gapAbove) belowImage=\(gapBelow)")
        expect("gap above image matches text line gap", abs(gapAbove - textGap) < 1)
        expect("gap below image matches text line gap", abs(gapBelow - textGap) < 1)

        // Consecutive image lines touch.
        let stacked = makeView("a\n![](images/\(names[0]))\n![](images/\(names[1]))\nb")
        let klm = stacked.layoutManager!, ktc = stacked.textContainer!
        klm.ensureLayout(for: ktc)
        let h1 = ImageCell.rowWidths(in: stacked.textStorage!, at: 2, container: ktc)[0].height
        let firstBottom = klm.lineFragmentRect(forGlyphAt: 2, effectiveRange: nil).minY + klm.location(forGlyphAt: 2).y
        let h2 = ImageCell.rowWidths(in: stacked.textStorage!, at: 4, container: ktc)[0].height
        let secondTop = klm.lineFragmentRect(forGlyphAt: 4, effectiveRange: nil).minY + klm.location(forGlyphAt: 4).y - h2
        _ = h1
        print("     stacked: first bottom \(firstBottom), second top \(secondTop)")
        expect("no space between consecutive image lines", abs(secondTop - firstBottom) < 0.01)
        let origin = layout.textContainerOrigin
        let hit1 = layout.imageAttachment(at: NSPoint(x: r1.midX + origin.x, y: r1.midY + origin.y))
        expect("double-click hit finds the second image", hit1?.name == names[1])
        expect("no image hit in empty space", layout.imageAttachment(at: NSPoint(x: 5, y: r0.maxY + 40)) == nil)
        expect("quick look items in note order", layout.noteImageURLs.map(\.lastPathComponent) == names)
        for name in names { try? FileManager.default.removeItem(at: NoteStore.shared.imageURL(named: name)) }

        let mixed = makeView("ab")
        caret(mixed, 1)
        mixed.insertFragment(NoteFormat.parse("1\n\(a)\n2"))
        check("pasted mix keeps images on own line", mixed, "a1\n\(a)\n2b")
    }

    private static func koreanComposition() {
        let tv = makeView("- ")
        caret(tv, 2)
        let nf = NSRange(location: NSNotFound, length: 0)
        for s in ["ㅇ", "아", "안"] { tv.setMarkedText(s, selectedRange: NSRange(location: 1, length: 0), replacementRange: nf) }
        tv.insertText("안", replacementRange: nf)
        for s in ["ㄴ", "녀", "녕"] { tv.setMarkedText(s, selectedRange: NSRange(location: 1, length: 0), replacementRange: nf) }
        tv.insertText("녕", replacementRange: nf)
        check("korean composition", tv, "- 안녕")
        let hangulFont = tv.textStorage!.attribute(.font, at: 2, effectiveRange: nil) as! NSFont
        expect("hangul gets a font that has its glyphs (\(hangulFont.fontName))",
               hangulFont.coveredCharacterSet.contains(UnicodeScalar("안")))
        tv.perform(.bold)
        let boldHangul = tv.textStorage!.attribute(.font, at: 2, effectiveRange: nil) as! NSFont
        expect("bold hangul has glyphs (\(boldHangul.fontName))",
               boldHangul.coveredCharacterSet.contains(UnicodeScalar("안")))
        let loaded = makeView("한글\n**굵은 한글**")
        let loadedFont = loaded.textStorage!.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
        expect("loaded hangul has glyphs (\(loadedFont.fontName))",
               loadedFont.coveredCharacterSet.contains(UnicodeScalar("한")))

        let rule = makeView("---")
        caret(rule, 1)
        rule.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: nf)
        rule.setMarkedText("하", selectedRange: NSRange(location: 1, length: 0), replacementRange: nf)
        rule.insertText("하", replacementRange: nf)
        check("korean on rule line goes below", rule, "---\n하")
    }

    /// Lines must not change height/baseline depending on which fonts they mix
    /// (Hangul falls back to Apple SD Gothic Neo, which has different metrics than SF).
    private static func lineMetrics() {
        func metrics(_ text: String) -> (height: CGFloat, baseline: CGFloat) {
            let tv = makeView(text)
            let lm = tv.layoutManager!
            lm.ensureLayout(for: tv.textContainer!)
            let rect = lm.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
            return (rect.height, lm.location(forGlyphAt: 0).y)
        }
        let hangul = metrics("한글"), mixed = metrics("한글 a"), latin = metrics("abc"), bold = metrics("**한글**")
        print("     hangul=\(hangul) mixed=\(mixed) latin=\(latin) bold=\(bold)")
        expect("line height stable when typing latin after hangul", hangul.height == mixed.height && hangul.baseline == mixed.baseline)
        expect("hangul and latin lines same height", hangul.height == latin.height && hangul.baseline == latin.baseline)
        expect("bold hangul line same height", bold.height == hangul.height)
    }

    /// Composing Hangul in the middle of a long (wrapped) line must stay in place.
    private static func koreanMidLine() {
        let long = String(repeating: "가나다라마바사아자차카타파하 ", count: 6)
        let tv = makeView(long)
        tv.layoutManager!.ensureLayout(for: tv.textContainer!)
        let mid = 20
        caret(tv, mid)
        let nf = NSRange(location: NSNotFound, length: 0)
        for s in ["ㅎ", "하", "한"] { tv.setMarkedText(s, selectedRange: NSRange(location: 1, length: 0), replacementRange: nf) }
        tv.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: nf)
        tv.insertText("한", replacementRange: nf)
        for s in ["ㄱ", "그", "글"] { tv.setMarkedText(s, selectedRange: NSRange(location: 1, length: 0), replacementRange: nf) }
        tv.insertText("글", replacementRange: nf)
        let expected = (long as NSString).replacingCharacters(in: NSRange(location: mid, length: 0), with: "한글")
        check("hangul typed mid long line stays in place", tv, expected)
    }

    /// Clicking in the middle of line N must put the caret on line N.
    private static func clickLines() {
        for doc in ["aa\nbb\ncc", "aa\nbb\n", "한글\n굵게\n셋째", "aa\n\n", "https://www.playful-dc.com/en/ko\n\n"] {
            let tv = makeView(doc)
            let lm = tv.layoutManager!
            lm.ensureLayout(for: tv.textContainer!)
            let h = Theme.lineMetrics.height
            let ns = doc as NSString
            for line in 0..<3 {
                // Lines can wrap: use the actual fragment of each logical line.
                let starts = [0] + ns.components(separatedBy: "\n").dropLast().reduce(into: [Int]()) { acc, part in
                    acc.append((acc.last ?? 0) + (part as NSString).length + 1) }
                let start = starts[line]
                let frag = start < ns.length ? lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: start), effectiveRange: nil) : lm.extraLineFragmentRect
                _ = h
                let y = tv.textContainerOrigin.y + frag.midY
                let idx = tv.characterIndexForInsertion(at: NSPoint(x: 6, y: y))
                let lineOfIdx = ns.substring(to: min(idx, ns.length)).filter { $0 == "\n" }.count
                expect("click line \(line + 1) of \(doc.debugDescription) → line \(lineOfIdx + 1) (idx \(idx))", lineOfIdx == line)
            }
        }
    }

    private static func links() {
        func link(_ tv: NoteTextView, _ at: Int) -> URL? {
            tv.textStorage!.attribute(.link, at: at, effectiveRange: nil) as? URL
        }
        let tv = makeView()
        type(tv, "https://example.com/a")
        expect("URL not a link before Enter", link(tv, 3) == nil)
        tv.insertNewline(nil)
        expect("URL becomes a link after Enter", link(tv, 3)?.absoluteString == "https://example.com/a")
        type(tv, "next")
        expect("next line is not a link", link(tv, (tv.string as NSString).length - 1) == nil)
        check("link line saves as plain URL", tv, "https://example.com/a\nnext")

        let loaded = makeView("https://a.com\nhttps://b.com")
        expect("loaded URL line with break is a link", link(loaded, 2) != nil)
        expect("last URL line without break is not a link", link(loaded, 16) == nil)

        let edited = makeView("https://a.com\nx")
        caret(edited, 13)
        type(edited, " words")
        expect("editing a link line into text removes the link", link(edited, 2) == nil)

        let text = makeView()
        type(text, "see https://a.com")
        text.insertNewline(nil)
        expect("URL inside text is not a link", link(text, 6) == nil)
    }

    private static func settingsText() {
        let formatted = SettingsText.format(Settings.shared)
        let (changes, invalid) = SettingsText.parse(formatted)
        expect("formatted settings parse cleanly (\(changes.count) items)", invalid.isEmpty && changes.count == 12)

        for (text, code, mods) in [("cmd+-", KeyCode.minus, NSEvent.ModifierFlags.command),
                                   ("opt+space", KeyCode.space, .option),
                                   ("cmd+,", KeyCode.comma, .command),
                                   ("cmd+enter", KeyCode.returnKey, .command),
                                   ("ctrl+shift+k", KeyCode.k, [.control, .shift])] {
            let sc = ShortcutText.parse(text)
            expect("parse \(text)", sc == Shortcut(keyCode: code, modifiers: mods))
            if let sc { expect("format \(text)", ShortcutText.format(sc) == text) }
        }

        let sample = "**preferences**\n\nedge:\nmiddle\n\nmin-width:\nabc\n---\n**animations**\n\nfoo:\nbar\n\nbold\nb\n\nfade-in:\n90\n---\nshortcuts\n\nrule:\ncmd+k\n\nfill:\ncmd+k\n\nfade-out:"
        let bad = SettingsText.parse(sample)
        // lines: 0 title | 2 edge 3 middle | 5 min-width 6 50 || 8 title | 10 foo 11 bar | 13 bold 14 b |
        // 16 fade-in 17 90 || 19 title | 21 rule 22 cmd+k | 24 fill 25 cmd+k | 27 fade-out (no value)
        expect("bad lines flagged (\(bad.invalid.sorted()))", bad.invalid == [3, 10, 14, 22, 25, 27])
        expect("good lines applied; invalid min-width becomes 100", bad.changes == [.minWidth(100), .fadeIn(90)])
        let oneLine = SettingsText.parse("**preferences**\n\nedge: left\nmin-width: 150\nbogus: 1\nfade-in: x\n---\n**keys**\n\ntoggle: opt+space")
        expect("one-line items parse (\(oneLine.invalid.sorted()))", oneLine.invalid == [4, 5]
            && oneLine.changes == [.edge(.left), .minWidth(150), .shortcut(.pin, Shortcut(keyCode: KeyCode.space, modifiers: .option))])
        expect("min-width below 100 becomes 100", SettingsText.parse("t\n---\nt\n\nmin-width:\n60").changes == [.minWidth(100)])
    }

    private static func autoBold() {
        let saved = NoteFormat.autoBoldFirstLine
        NoteFormat.autoBoldFirstLine = true
        let tv = makeView("")
        type(tv, "title")
        check("typing on empty line 00 makes it bold", tv, "**title**")
        tv.insertNewline(nil)
        type(tv, "body")
        check("line 01 stays plain", tv, "**title**\nbody")
        tv.perform(.rule)
        type(tv, "next")
        check("line 00 after a rule is bold", tv, "**title**\nbody\n---\n**next**")
        tv.perform(.bold)
        type(tv, "!")
        check("⌘B on it makes it plain and it stays plain", tv, "**title**\nbody\n---\nnext!")

        let loaded = makeView("title\nbody")
        check("existing notes aren't changed", loaded, "title\nbody")

        let ime = makeView("")
        let nf = NSRange(location: NSNotFound, length: 0)
        ime.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: nf)
        ime.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: nf)
        ime.insertText("한", replacementRange: nf)
        check("korean on empty line 00 is bold too", ime, "**한**")

        NoteFormat.autoBoldFirstLine = false
        let off = makeView("")
        type(off, "title")
        check("option off: plain", off, "title")
        NoteFormat.autoBoldFirstLine = saved
    }

    private static func undo() {
        let tv = makeView("x")
        caret(tv, 1)
        tv.perform(.bold)
        tv.undoManager?.undo()
        check("undo bold", tv, "x")
    }
}
#endif
