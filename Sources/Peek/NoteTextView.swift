import AppKit

/// The note editor. Content is a sequence of lines; each line is plain text (optionally
/// bold as a whole), a horizontal rule, or a row of images. Rule/image lines ("block
/// lines") never contain text — typing on them moves to a new line.
final class NoteTextView: NSTextView, NSTextStorageDelegate, NSLayoutManagerDelegate {
    var onOpenSettings: (() -> Void)?

    /// Character range edited since the last block normalization pass.
    private var pendingNormalizeRange: NSRange?
    private var isNormalizing = false

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
        insertionPointColor = Theme.text
        typingAttributes = NoteFormat.baseAttributes

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
            var hasAttachment = false
            if chars.length > 0 {
                storage.enumerateAttribute(.attachment, in: chars) { value, _, stop in
                    if value != nil { hasAttachment = true; stop.pointee = true }
                }
            }
            if hasAttachment { return false }
            let m = Theme.lineMetrics
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
        NSAttributedString(string: s, attributes: NoteFormat.baseAttributes)
    }

    private func resetTypingAttributes() {
        typingAttributes = NoteFormat.baseAttributes
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

    override func insertText(_ string: Any, replacementRange: NSRange) {
        DebugLog.log("insertText \(String(describing: (string as? NSAttributedString)?.string ?? string)) rr=\(replacementRange) marked=\(hasMarkedText())")
        if replacementRange.location == NSNotFound { moveOffBlockLineForTyping() }
        super.insertText(string, replacementRange: replacementRange)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        DebugLog.log("setMarkedText \(String(describing: (string as? NSAttributedString)?.string ?? string)) rr=\(replacementRange) marked=\(hasMarkedText())")
        if !hasMarkedText() && replacementRange.location == NSNotFound { moveOffBlockLineForTyping() }
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
            let prefixLen = NoteFormat.listPrefixLength(lineText)
            if prefixLen > 0 && sel.location >= current.location + prefixLen {
                if current.length == prefixLen {
                    // Empty list item ends the list.
                    applyEdits([(current, plain(""))])
                } else {
                    let prefix = String(lineText.utf16.prefix(prefixLen)) ?? "- "
                    applyEdits([(sel, plain("\n" + prefix))],
                               selectAfter: NSRange(location: sel.location + 1 + (prefix as NSString).length, length: 0))
                }
                resetTypingAttributes()
                return
            }
        }
        super.insertNewline(sender)
        resetTypingAttributes()
    }

    private func listLinesInSelection() -> [NSRange] {
        lines(in: selectedRange()).filter {
            kind(of: $0) == .text && NoteFormat.listPrefixLength(text(of: $0)) > 0
        }
    }

    override func insertTab(_ sender: Any?) {
        let listLines = listLinesInSelection()
        guard !listLines.isEmpty, !hasMarkedText() else { return super.insertTab(sender) }
        applyEdits(listLines.map { (NSRange(location: $0.location, length: 0), plain("  ")) })
    }

    override func insertBacktab(_ sender: Any?) {
        let edits: [(NSRange, NSAttributedString)] = listLinesInSelection().compactMap { line in
            let spaces = text(of: line).prefix { $0 == " " }.count
            guard spaces > 0 else { return nil }
            return (NSRange(location: line.location, length: min(2, spaces)), plain(""))
        }
        applyEdits(edits)
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
        case .top: moveToDocumentStart()
        case .bold: toggleBold()
        case .list: toggleList()
        case .rule: insertRule()
        case .pin: break  // global hotkey, handled by PanelController
        case .settings: onOpenSettings?()
        }
    }

    private var selectedLines: [NSRange] { lines(in: selectedRange()) }

    private func moveToDocumentStart() {
        setSelectedRange(NSRange(location: 0, length: 0))
        scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    private func toggleBold() {
        guard let storage = textStorage else { return }
        let textLines = selectedLines.filter { kind(of: $0) == .text }
        let nonEmpty = textLines.filter { $0.length > 0 }

        if nonEmpty.isEmpty {
            // Empty line: toggle bold for what's typed next.
            guard !textLines.isEmpty else { return }
            var attrs = NoteFormat.baseAttributes
            if typingAttributes[.peekBold] == nil {
                attrs[.peekBold] = true
                attrs[.font] = Theme.boldFont
            }
            typingAttributes = attrs
            return
        }

        let makeBold = !nonEmpty.allSatisfy { NoteFormat.isBold(storage, line: $0) }
        changeAttributes(of: nonEmpty) { storage in
            for line in nonEmpty {
                if makeBold {
                    storage.addAttribute(.peekBold, value: true, range: line)
                } else {
                    storage.removeAttribute(.peekBold, range: line)
                }
            }
        }
        var attrs = NoteFormat.baseAttributes
        if makeBold {
            attrs[.peekBold] = true
            attrs[.font] = Theme.boldFont
        }
        typingAttributes = attrs
    }

    private func toggleList() {
        let textLines = selectedLines.filter { kind(of: $0) == .text }
        guard !textLines.isEmpty else { return }
        let prefixes = textLines.map { NoteFormat.listPrefixLength(text(of: $0)) }
        if prefixes.allSatisfy({ $0 > 0 }) {
            applyEdits(zip(textLines, prefixes).map { (NSRange(location: $0.location, length: $1), plain("")) })
        } else {
            applyEdits(zip(textLines, prefixes).compactMap { line, prefix in
                prefix > 0 ? nil : (NSRange(location: line.location, length: 0), plain("- "))
            })
        }
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
            let last = line(at: NSMaxRange(sel))
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
