#if DEBUG
import AppKit

/// Headless editor checks. Run: `.build/debug/Peek --selftest`
@MainActor
enum SelfTest {
    private static var failures = 0

    static func run() -> Never {
        roundTrip()
        listContinuation()
        ruleFromDashes()
        lineFormats()
        blockLines()
        tabs()
        undo()
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
        let md = "a\n**b**\n- **c**\n---\n  - d\n\n- "
        check("round trip", makeView(md), md)
    }

    private static func listContinuation() {
        let tv = makeView()
        type(tv, "- abc")
        tv.insertNewline(nil)
        check("list continues", tv, "- abc\n- ")
        tv.insertNewline(nil)
        check("empty item ends list", tv, "- abc\n")
        type(tv, "  - x")
        tv.insertNewline(nil)
        check("indent kept", tv, "- abc\n  - x\n  - ")
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
        check("bold list item", tv, "- **item**")
        let isBold = { (i: Int) in
            (tv.textStorage!.attribute(.font, at: i, effectiveRange: nil) as! NSFont)
                .fontDescriptor.symbolicTraits.contains(.bold)
        }
        expect("dash stays regular, content bold", !isBold(0) && !isBold(1) && isBold(2))
        tv.perform(.plain)
        check("plain clears bold and list", tv, "item")
        tv.perform(.list)
        check("list toggle on", tv, "- item")
        tv.perform(.list)
        check("list toggle off", tv, "item")
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

    private static func tabs() {
        let tv = makeView("- a")
        caret(tv, 3)
        tv.insertTab(nil)
        check("tab indents list", tv, "  - a")
        tv.insertBacktab(nil)
        check("backtab outdents", tv, "- a")
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
