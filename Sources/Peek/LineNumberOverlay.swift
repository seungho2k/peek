import AppKit

/// Draws a two-digit line number (00, 01, …) with each digit in a fixed-width cell
/// (the font's digits are proportional).
enum LineNumberLabel {
    static var baseline: CGFloat { NSLayoutManager().defaultBaselineOffset(for: Theme.font) }

    /// Width of a label with `digits` digits.
    static func width(digits: Int) -> CGFloat { CGFloat(digits) * Theme.digitCell }

    static func draw(_ number: Int, rightEdge: CGFloat? = nil, leftEdge: CGFloat? = nil, top: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.font, .foregroundColor: Theme.lineNumber]
        let digits = String(format: "%02d", number)
        let cell = Theme.digitCell
        var x = rightEdge.map { $0 - width(digits: digits.count) } ?? leftEdge ?? 0
        for d in digits {
            let glyph = String(d) as NSString
            let w = glyph.size(withAttributes: attrs).width
            glyph.draw(at: NSPoint(x: x + (cell - w) / 2, y: top), withAttributes: attrs)
            x += cell
        }
    }
}

/// "Outside" line numbers: a transparent, click-through window right beside the note that
/// shows only the numbers, lined up with the note's lines. The note itself has no gutter.
@MainActor
final class LineNumberOverlay {
    let window: NSPanel
    private let view: OverlayView

    init(textView: NoteTextView) {
        window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        view = OverlayView(textView: textView)
        window.contentView = view

        // Follow scrolling and edits.
        if let clip = textView.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: textView, queue: .main) { [weak self] _ in
            // Layout settles after the edit; redraw on the next pass.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refresh() } }
        }
    }

    /// Widest label we expect (3 digits) plus a space on each side.
    static var width: CGFloat { ceil(LineNumberLabel.width(digits: 3) + 2 * Theme.spaceWidth) }

    /// Places the overlay against the note's inner side.
    func place(besideNote note: NSRect, edge: PeekEdge) {
        let w = Self.width
        let x = edge == .right ? note.minX - w : note.maxX
        window.setFrame(NSRect(x: x, y: note.minY, width: w, height: note.height), display: false)
        view.alignRight = edge == .right
        refresh()
    }

    func refresh() { view.needsDisplay = true }

    private final class OverlayView: NSView {
        weak var textView: NoteTextView?
        var alignRight = true

        init(textView: NoteTextView) {
            self.textView = textView
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            guard let tv = textView, let tvWindow = tv.window, let myWindow = window else { return }
            let space = Theme.spaceWidth
            tv.enumerateLineNumbers(in: tv.visibleRect) { number, top in
                // text view → screen → this view
                let inWindow = tv.convert(NSPoint(x: 0, y: top), to: nil)
                let onScreen = tvWindow.convertPoint(toScreen: inWindow)
                let here = convert(myWindow.convertPoint(fromScreen: onScreen), from: nil)
                if alignRight {
                    LineNumberLabel.draw(number, rightEdge: bounds.width - space, top: here.y)
                } else {
                    LineNumberLabel.draw(number, leftEdge: space, top: here.y)
                }
            }
        }
    }
}
