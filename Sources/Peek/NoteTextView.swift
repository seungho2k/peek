import AppKit
import Quartz

/// The note editor. Content is a sequence of lines; each line is plain text (optionally
/// bold as a whole), a horizontal rule, or a row of images. Rule/image lines ("block
/// lines") never contain text — typing on them moves to a new line.
final class NoteTextView: NSTextView, NSTextStorageDelegate, NSLayoutManagerDelegate {
    var onOpenSettings: (() -> Void)?

    var baseAttributes: [NSAttributedString.Key: Any] { NoteFormat.baseAttributes }

    /// Quick Look state (see NoteTextView+QuickLook).
    var previewURLs: [URL] = []
    var previewStartIndex = 0

    /// Character range edited since the last block normalization pass.
    private var pendingNormalizeRange: NSRange?
    private var isNormalizing = false
    /// Last range edited in the text storage (for neighbour-dependent relayout).
    private var lastEditedRange: NSRange?

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configure()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func configure() {
        isRichText = true
        importsGraphics = false
        allowsUndo = true
        usesFontPanel = false
        usesFindBar = false
        drawsBackground = false
        textContainerInset = Theme.textInset
        textContainer?.lineFragmentPadding = 0
        linkTextAttributes = [
            .foregroundColor: Theme.lineNumber,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        // Lay out only what's visible: keeps resizing smooth with long notes.
        layoutManager?.allowsNonContiguousLayout = true
        insertionPointColor = Theme.text
        typingAttributes = baseAttributes

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

        textStorage?.delegate = self
        layoutManager?.delegate = self
        updateDragTypeRegistration()
    }

    /// Text starts flush with the line-number ruler; the horizontal inset is all on the right.
    override var textContainerOrigin: NSPoint {
        NSPoint(x: 0, y: textContainerInset.height)
    }

    /// Re-applies line styles to the whole note (e.g. after a display setting changes).
    func restyleAll() {
        guard let storage = textStorage, let lm = layoutManager else { return }
        let all = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.edited(.editedAttributes, range: all, changeInLength: 0)  // restyled in willProcessEditing
        storage.endEditing()
        lm.invalidateLayout(forCharacterRange: all, actualCharacterRange: nil)
        needsDisplay = true
    }

    /// Esc: used by the settings panel to close itself.
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) {
        if let onEscape { onEscape() } else { super.cancelOperation(sender) }
    }

    // MARK: Line numbers

    /// Faint two-digit numbers (00, 01, …) in the left gutter of every text line.
    /// Image and rule lines are not counted; numbering restarts at 00 after every rule.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard Theme.showLineNumbers else { return }
        let right = textContainerOrigin.x + Theme.gutterWidth - Theme.spaceWidth
        enumerateLineNumbers(in: rect) { number, labelTop in
            LineNumberLabel.draw(number, rightEdge: right, top: labelTop)
        }
    }

    /// Calls `body` for each numbered line intersecting `rect` (view coordinates) with its number
    /// and the top y of its label, baseline-aligned with the line's text. Only text lines are
    /// numbered; numbering starts at 00 at the top and again after every rule.
    func enumerateLineNumbers(in rect: NSRect, _ body: (Int, CGFloat) -> Void) {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage else { return }
        let ns = storage.string as NSString
        let originY = textContainerOrigin.y
        let labelOffset = Theme.lineMetrics.baseline - LineNumberLabel.baseline

        func emit(_ number: Int, _ lineTop: CGFloat) {
            let y = lineTop + originY + labelOffset
            if y + Theme.lineMetrics.height >= rect.minY && y <= rect.maxY { body(number, y) }
        }

        var number = 0
        var index = 0
        while index < ns.length {
            let paragraph = ns.paragraphRange(for: NSRange(location: index, length: 0))
            let attachment = storage.attribute(.attachment, at: index, effectiveRange: nil)
            if attachment is RuleAttachment {
                number = 0  // each rule starts a new section
            } else if attachment == nil {
                let frag = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: index), effectiveRange: nil)
                if frag.minY + originY > rect.maxY { return }
                emit(number, frag.minY)
                number += 1
            }
            index = NSMaxRange(paragraph)
        }
        if lm.extraLineFragmentTextContainer === tc {
            emit(number, lm.extraLineFragmentRect.minY)
        }
    }

    /// The first click on the (unfocused) panel both focuses it and places the caret.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Load / save

    func load(markdown: String) {
        guard let storage = textStorage else { return }
        let oldSelection = selectedRange()
        storage.setAttributedString(NoteFormat.parse(markdown))  // restyled via willProcessEditing
        pendingNormalizeRange = nil
        undoManager?.removeAllActions()
        let loc = min(oldSelection.location, storage.length)
        setSelectedRange(NSRange(location: loc, length: 0))
        resetTypingAttributes()
    }

    func markdown() -> String {
        guard let storage = textStorage else { return "" }
        return NoteFormat.serialize(storage)
    }

    // MARK: Styling hook

    // Runs before NSTextStorage fixes attributes, so font fallback (e.g. Apple SD Gothic Neo
    // for Hangul, which SF lacks) is applied on top of our fonts rather than overwritten.

    nonisolated func textStorage(
        _ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange, changeInLength delta: Int
    ) {
        MainActor.assumeIsolated {
            NoteFormat.restyle(textStorage, range: editedRange)
            lastEditedRange = editedRange
            if editedMask.contains(.editedCharacters) {
                pendingNormalizeRange = pendingNormalizeRange.map {
                    NSUnionRange(shifted($0, after: editedRange, delta: delta), editedRange)
                } ?? editedRange
            }
        }
    }

    /// Fixed metrics for text lines (see `Theme.lineMetrics`); image/rule lines keep their own.
    nonisolated func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
        lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
        baselineOffset: UnsafeMutablePointer<CGFloat>,
        in textContainer: NSTextContainer,
        forGlyphRange glyphRange: NSRange
    ) -> Bool {
        MainActor.assumeIsolated {
            guard let storage = layoutManager.textStorage else { return false }
            let chars = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            var attachment: NSTextAttachment?
            if chars.length > 0 {
                storage.enumerateAttribute(.attachment, in: chars) { value, _, stop in
                    if let a = value as? NSTextAttachment { attachment = a; stop.pointee = true }
                }
            }
            let m = Theme.lineMetrics
            if attachment is ImageAttachment {
                // Treat the image like one big glyph spanning cap height → baseline, so the space
                // above and below it matches the space between two text lines.
                guard let height = ImageCell.rowWidths(in: storage, at: chars.location, container: textContainer).first?.height
                else { return false }
                // Between two image lines there is no space at all.
                let ns = storage.string as NSString
                let para = ns.paragraphRange(for: NSRange(location: chars.location, length: 0))
                let prevIsImage = para.location > 0
                    && storage.attribute(.attachment, at: NoteFormat.lineContentRange(in: ns, at: para.location - 1).location,
                                         effectiveRange: nil) is ImageAttachment
                let nextIsImage = NSMaxRange(para) < ns.length
                    && storage.attribute(.attachment, at: NSMaxRange(para), effectiveRange: nil) is ImageAttachment
                let capHeight = Theme.font.capHeight
                let top = prevIsImage ? 0 : m.baseline - capHeight
                let bottom = nextIsImage ? 0 : m.height - m.baseline
                let lineHeight = top + height + bottom  // not rounded: stacked images must touch exactly
                lineFragmentRect.pointee.size.height = lineHeight
                lineFragmentUsedRect.pointee.size.height = lineHeight
                baselineOffset.pointee = top + height
                return true
            }
            if attachment != nil { return false }
            lineFragmentRect.pointee.size.height = m.height
            lineFragmentUsedRect.pointee.size.height = m.height
            baselineOffset.pointee = m.baseline
            return true
        }
    }

    private func shifted(_ r: NSRange, after edit: NSRange, delta: Int) -> NSRange {
        let loc = r.location > edit.location ? max(edit.location, r.location + delta) : r.location
        return NSRange(location: loc, length: max(0, r.length))
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true  // line numbers below the edit may shift
        // An image line's spacing depends on its neighbours: relayout the line before the edit too.
        if let lm = layoutManager, let edit = lastEditedRange {
            let ns = nsString
            let start = edit.location > 0 ? ns.paragraphRange(for: NSRange(location: min(edit.location - 1, max(ns.length - 1, 0)), length: 0)).location : 0
            let end = min(NSMaxRange(edit) + 1, ns.length)
            if end > start { lm.invalidateLayout(forCharacterRange: NSRange(location: start, length: end - start), actualCharacterRange: nil) }
        }
        guard !isNormalizing, !hasMarkedText(), let range = pendingNormalizeRange else { return }
        pendingNormalizeRange = nil
        isNormalizing = true
        normalizeBlockLines(in: range)
        isNormalizing = false
    }

    // MARK: Line helpers

    private var nsString: NSString { (textStorage?.string ?? "") as NSString }

    private func line(at location: Int) -> NSRange {
        NoteFormat.lineContentRange(in: nsString, at: location)
    }

    private func lines(in range: NSRange) -> [NSRange] {
        NoteFormat.lineRanges(in: nsString, covering: range)
    }

    private func kind(of line: NSRange) -> LineKind {
        guard let storage = textStorage else { return .text }
        return NoteFormat.kind(of: storage, line: line)
    }

    private func text(of line: NSRange) -> String {
        nsString.substring(with: line)
    }

    private func plain(_ s: String) -> NSAttributedString {
        NSAttributedString(string: s, attributes: baseAttributes)
    }

    private func resetTypingAttributes() {
        typingAttributes = baseAttributes
    }

    // MARK: Editing primitives (undoable)

    /// Applies several replacements as one undoable change, keeping the selection in place.
    @discardableResult
    func applyEdits(_ edits: [(NSRange, NSAttributedString)], selectAfter: NSRange? = nil) -> Bool {
        guard let storage = textStorage, !edits.isEmpty else { return false }
        let ascending = edits.sorted { $0.0.location < $1.0.location }
        breakUndoCoalescing()
        guard shouldChangeText(
            inRanges: ascending.map { NSValue(range: $0.0) },
            replacementStrings: ascending.map { $0.1.string }
        ) else { return false }

        var sel = selectedRange()
        storage.beginEditing()
        for (range, replacement) in ascending.reversed() {
            storage.replaceCharacters(in: range, with: replacement)
            sel = map(sel, through: range, newLength: replacement.length)
        }
        storage.endEditing()
        setSelectedRange(selectAfter ?? sel)
        didChangeText()
        return true
    }

    private func map(_ sel: NSRange, through edit: NSRange, newLength: Int) -> NSRange {
        func mapLoc(_ loc: Int) -> Int {
            if loc >= NSMaxRange(edit) { return loc + newLength - edit.length }
            if loc > edit.location { return edit.location + newLength }
            return loc
        }
        let start = mapLoc(sel.location)
        let end = mapLoc(NSMaxRange(sel))
        return NSRange(location: start, length: max(0, end - start))
    }

    /// Attribute-only change on the given lines, as one undoable change.
    private func changeAttributes(of lines: [NSRange], _ body: (NSTextStorage) -> Void) {
        guard let storage = textStorage, !lines.isEmpty else { return }
        breakUndoCoalescing()
        guard shouldChangeText(inRanges: lines.map { NSValue(range: $0) }, replacementStrings: nil) else { return }
        storage.beginEditing()
        body(storage)
        storage.endEditing()
        didChangeText()
    }

    // MARK: Block line invariant

    private enum CharClass { case text, image, rule }

    private func charClass(at index: Int) -> CharClass {
        switch textStorage?.attribute(.attachment, at: index, effectiveRange: nil) {
        case is ImageAttachment: .image
        case is RuleAttachment: .rule
        default: .text
        }
    }

    /// Splits any line that mixes text, images and rules so each kind gets its own line.
    private func normalizeBlockLines(in range: NSRange) {
        let length = nsString.length
        guard length > 0 else { return }
        let start = min(range.location, length)
        let clamped = NSRange(location: start, length: min(range.length, length - start))
        var breaks: [Int] = []
        for line in lines(in: clamped) where line.length > 1 {
            var prev = charClass(at: line.location)
            for i in (line.location + 1)..<NSMaxRange(line) {
                let c = charClass(at: i)
                if c != prev || c == .rule { breaks.append(i) }
                prev = c
            }
        }
        guard !breaks.isEmpty else { return }
        applyEdits(breaks.map { (NSRange(location: $0, length: 0), plain("\n")) })
    }

    /// When the caret sits on a rule/image line, open a new text line for typing:
    /// above it at the start of the line, below it at the end, and between the two
    /// halves of an image row when the caret is between images.
    private func moveOffBlockLineForTyping() {
        guard !hasMarkedText() else { return }
        let sel = selectedRange()
        guard sel.length == 0 else { return }
        let current = line(at: sel.location)
        guard kind(of: current) != .text else { return }
        if sel.location == current.location {
            applyEdits([(NSRange(location: sel.location, length: 0), plain("\n"))],
                       selectAfter: NSRange(location: sel.location, length: 0))
        } else if sel.location < NSMaxRange(current) {
            // Between two images: split the row and type on a new line in between.
            applyEdits([(NSRange(location: sel.location, length: 0), plain("\n\n"))],
                       selectAfter: NSRange(location: sel.location + 1, length: 0))
        } else {
            let end = NSMaxRange(current)
            applyEdits([(NSRange(location: end, length: 0), plain("\n"))],
                       selectAfter: NSRange(location: end + 1, length: 0))
        }
        resetTypingAttributes()
    }

    /// Starting to type on an empty line 00 makes it bold (see NoteFormat.autoBoldFirstLine).
    private func boldIfStartingFirstLine() {
        guard NoteFormat.autoBoldFirstLine, !hasMarkedText(), let storage = textStorage else { return }
        let sel = selectedRange()
        guard sel.length == 0 else { return }
        let current = line(at: sel.location)
        guard current.length == 0, NoteFormat.isFirstLineOfSection(storage, current) else { return }
        var attrs = baseAttributes
        attrs[.peekBold] = true
        attrs[.font] = Theme.boldFont
        typingAttributes = attrs
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        DebugLog.log("insertText \(String(describing: (string as? NSAttributedString)?.string ?? string)) rr=\(replacementRange) marked=\(hasMarkedText())")
        if replacementRange.location == NSNotFound {
            moveOffBlockLineForTyping()
            boldIfStartingFirstLine()
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        DebugLog.log("setMarkedText \(String(describing: (string as? NSAttributedString)?.string ?? string)) rr=\(replacementRange) marked=\(hasMarkedText())")
        if !hasMarkedText() && replacementRange.location == NSNotFound {
            moveOffBlockLineForTyping()
            boldIfStartingFirstLine()
        }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    // MARK: Newline / tab / delete

    override func insertNewline(_ sender: Any?) {
        let sel = selectedRange()
        guard !hasMarkedText(), sel.length == 0 else {
            super.insertNewline(sender)
            resetTypingAttributes()
            return
        }
        let current = line(at: sel.location)
        let lineText = text(of: current)

        switch kind(of: current) {
        case .rule, .images:
            if sel.location == current.location { break }  // plain newline: opens a line above
            if sel.location < NSMaxRange(current) {
                // Between two images: split the row into two image lines.
                applyEdits([(sel, plain("\n"))], selectAfter: NSRange(location: sel.location + 1, length: 0))
                resetTypingAttributes()
                return
            }
            let end = NSMaxRange(current)
            applyEdits([(NSRange(location: end, length: 0), plain("\n"))],
                       selectAfter: NSRange(location: end + 1, length: 0))
            resetTypingAttributes()
            return

        case .text:
            if lineText == "---" && sel.location == NSMaxRange(current) {
                let rule = NSMutableAttributedString(attributedString: NoteFormat.attachmentString(RuleAttachment()))
                rule.append(plain("\n"))
                applyEdits([(current, rule)], selectAfter: NSRange(location: current.location + 2, length: 0))
                resetTypingAttributes()
                return
            }
        }
        let url = sel.length == 0 && sel.location == NSMaxRange(current) && kind(of: current) == .text
            ? NoteFormat.linkURL(in: lineText) : nil
        super.insertNewline(sender)
        resetTypingAttributes()
        if let url, current.length > 0 {
            // Enter after a URL-only line turns it into a link.
            changeAttributes(of: [current]) { $0.addAttribute(.link, value: url, range: current) }
        }
    }

    override func deleteBackward(_ sender: Any?) {
        let sel = selectedRange()
        guard !hasMarkedText(), sel.length == 0, sel.location > 0 else { return super.deleteBackward(sender) }
        let current = line(at: sel.location)
        if sel.location == current.location {
            let previous = line(at: sel.location - 1)
            let prevKind = kind(of: previous)
            let curKind = kind(of: current)
            if prevKind == .rule {
                // Delete the rule together with its line break.
                applyEdits([(NSRange(location: previous.location, length: sel.location - previous.location), plain(""))])
                return
            }
            let mergesImageRows = prevKind == .images && curKind == .images
            if current.length > 0 && previous.length > 0 && !mergesImageRows
                && (prevKind != .text || curKind != .text) {
                // Would merge a block line with something else: just step back.
                setSelectedRange(NSRange(location: sel.location - 1, length: 0))
                return
            }
        }
        super.deleteBackward(sender)
    }

    override func deleteForward(_ sender: Any?) {
        let sel = selectedRange()
        let length = nsString.length
        guard !hasMarkedText(), sel.length == 0, sel.location < length else { return super.deleteForward(sender) }
        let current = line(at: sel.location)
        if sel.location == NSMaxRange(current) {
            let next = line(at: sel.location + 1)
            let nextKind = kind(of: next)
            let curKind = kind(of: current)
            if nextKind == .rule && curKind == .text {
                applyEdits([(NSRange(location: sel.location, length: NSMaxRange(next) - sel.location), plain(""))])
                return
            }
            let mergesImageRows = nextKind == .images && curKind == .images
            if current.length > 0 && next.length > 0 && !mergesImageRows
                && (nextKind != .text || curKind != .text) {
                setSelectedRange(NSRange(location: sel.location + 1, length: 0))
                return
            }
        }
        super.deleteForward(sender)
    }

    // MARK: Keys

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, handleKey(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        DebugLog.log("keyDown code=\(event.keyCode) chars=\(event.characters ?? "")")
        if handleKey(event) { return }
        super.keyDown(with: event)
    }

    /// Handles peek's own keys. Matched by physical key so they also work with Korean input.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        if handleQuickLookKey(event) { return true }
        let mods = event.modifierFlags.intersection(Shortcut.relevantModifiers)

        // Ctrl + h/j/k/l → arrow keys (fixed).
        if mods == .control {
            let move: ((Any?) -> Void)? = switch event.keyCode {
            case KeyCode.h: moveLeft
            case KeyCode.j: moveDown
            case KeyCode.k: moveUp
            case KeyCode.l: moveRight
            default: nil
            }
            if let move {
                commitComposition()
                move(nil)
                return true
            }
        }

        if let action = Settings.shared.action(matching: event) {
            commitComposition()
            perform(action)
            return true
        }

        // Standard edit commands, by key position.
        if mods == .command {
            switch event.keyCode {
            case KeyCode.z: undoManager?.undo(); return true
            case KeyCode.x: cut(nil); return true
            case KeyCode.c: copy(nil); return true
            case KeyCode.v: paste(nil); return true
            case KeyCode.a: selectAll(nil); return true
            case KeyCode.q: NSApp.terminate(nil); return true
            default: break
            }
        } else if mods == [.command, .shift] && event.keyCode == KeyCode.z {
            undoManager?.redo()
            return true
        }
        return false
    }

    /// Finishes an in-progress IME composition (e.g. a Korean syllable) as typed.
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        DebugLog.log("mouseDown at \(p) → index \(characterIndexForInsertion(at: p)) sel=\(selectedRange()) key=\(window?.isKeyWindow ?? false) active=\(NSApp.isActive)")
        if event.clickCount == 2, let image = imageAttachment(at: p) {
            showQuickLook(startingAt: image)
            return
        }
        super.mouseDown(with: event)
        DebugLog.log("mouseDown done sel=\(selectedRange())")
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        #if DEBUG
        if !stillSelecting {
            let callers = Thread.callStackSymbols.dropFirst(1).prefix(6).map { $0.split(separator: " ").dropFirst(3).prefix(1).joined() }
            DebugLog.log("selection → \(selectedRange()) via \(callers.joined(separator: " < "))")
        }
        #endif
    }

    override func unmarkText() {
        DebugLog.log("unmarkText")
        super.unmarkText()
    }

    override func doCommand(by selector: Selector) {
        DebugLog.log("doCommand \(selector)")
        super.doCommand(by: selector)
    }

    override func resignFirstResponder() -> Bool {
        DebugLog.log("resignFirstResponder")
        return super.resignFirstResponder()
    }

    override func becomeFirstResponder() -> Bool {
        DebugLog.log("becomeFirstResponder")
        return super.becomeFirstResponder()
    }

    func commitComposition() {
        guard hasMarkedText() else { return }
        unmarkText()
        inputContext?.discardMarkedText()
    }

    // MARK: Line formats

    func perform(_ action: ShortcutAction) {
        switch action {
        case .bold: toggleBold()
        case .strike: toggleStrike()
        case .rule: insertRule()
        case .pin: break  // global hotkey, handled by PanelController
        case .settings: onOpenSettings?()
        }
    }

    private var selectedLines: [NSRange] { lines(in: selectedRange()) }

    private func toggleBold() { toggleLineFormat(.peekBold) }
    private func toggleStrike() { toggleLineFormat(.peekStrike) }

    /// Toggles a whole-line format (bold / strikethrough) on the selected text lines; on an
    /// empty line it applies to what's typed next.
    private func toggleLineFormat(_ key: NSAttributedString.Key) {
        guard let storage = textStorage else { return }
        let textLines = selectedLines.filter { kind(of: $0) == .text }
        let nonEmpty = textLines.filter { $0.length > 0 }

        if nonEmpty.isEmpty {
            guard !textLines.isEmpty else { return }
            var attrs = typingAttributes
            if attrs[key] == nil { attrs[key] = true } else { attrs[key] = nil }
            typingAttributes = Self.styled(attrs, base: baseAttributes)
            return
        }

        var on = false
        for line in nonEmpty {
            var found = false
            storage.enumerateAttribute(key, in: line) { v, _, stop in if v != nil { found = true; stop.pointee = true } }
            if !found { on = true; break }
        }
        changeAttributes(of: nonEmpty) { storage in
            for line in nonEmpty {
                if on { storage.addAttribute(key, value: true, range: line) } else { storage.removeAttribute(key, range: line) }
            }
        }
        // Keep typing in the caret's line format.
        let caretLine = line(at: selectedRange().location)
        var attrs = baseAttributes
        if caretLine.length > 0 {
            if NoteFormat.isBold(storage, line: caretLine) { attrs[.peekBold] = true }
            if NoteFormat.isStruck(storage, line: caretLine) { attrs[.peekStrike] = true }
        }
        typingAttributes = Self.styled(attrs, base: baseAttributes)
    }

    /// Base attributes plus the font/strikethrough that the format marks in `attrs` imply.
    private static func styled(_ attrs: [NSAttributedString.Key: Any], base: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        var out = base
        if attrs[.peekBold] != nil { out[.peekBold] = true; out[.font] = Theme.boldFont }
        if attrs[.peekStrike] != nil { out[.peekStrike] = true; out[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        return out
    }

    private func insertRule() {
        let sel = selectedRange()
        let first = line(at: sel.location)
        let rule = NoteFormat.attachmentString(RuleAttachment())

        if sel.length == 0 && first.length == 0 {
            // Empty line becomes the rule; caret continues on a fresh line below.
            let s = NSMutableAttributedString(attributedString: rule)
            s.append(plain("\n"))
            applyEdits([(NSRange(location: first.location, length: 0), s)],
                       selectAfter: NSRange(location: first.location + 2, length: 0))
        } else {
            let last = lines(in: sel).last ?? line(at: NSMaxRange(sel))
            let end = NSMaxRange(last)
            let s = NSMutableAttributedString(attributedString: plain("\n"))
            s.append(rule)
            s.append(plain("\n"))
            applyEdits([(NSRange(location: end, length: 0), s)],
                       selectAfter: NSRange(location: end + 3, length: 0))
        }
        resetTypingAttributes()
    }
}
