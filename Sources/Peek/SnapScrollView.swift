import AppKit

/// A scroll view whose wheel/trackpad scrolling stops only at fixed positions: the top, and
/// the start of each section after a rule (the rule itself just past the top edge). One swipe
/// (or wheel notch) moves one stop. Without rules it scrolls normally. Caret-driven scrolling
/// (typing) is not snapped.
final class SnapScrollView: NSScrollView {
    /// Scroll offsets (document y at the top of the view) that start each rule's section.
    var snapOffsets: (() -> [CGFloat])?

    /// A trackpad swipe must travel this far before it moves one stop.
    static let swipeThreshold: CGFloat = 12
    static let animationDuration: TimeInterval = 0.18

    private var accumulated: CGFloat = 0
    private var steppedThisGesture = false
    private var lastWheelStep: TimeInterval = 0

    override func scrollWheel(with event: NSEvent) {
        let rules = snapOffsets?() ?? []
        guard !rules.isEmpty else { return super.scrollWheel(with: event) }
        if !event.momentumPhase.isEmpty { return }  // the swipe already moved its one stop

        let dy = event.scrollingDeltaY
        if event.phase.isEmpty {
            // Mouse wheel: each notch is one stop (events closer than the animation are one notch).
            guard dy != 0, event.timestamp - lastWheelStep > Self.animationDuration else { return }
            lastWheelStep = event.timestamp
            step(up: dy > 0, rules: rules)
            return
        }
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            accumulated = 0
            steppedThisGesture = false
        }
        accumulated += dy
        if !steppedThisGesture, abs(accumulated) >= Self.swipeThreshold {
            steppedThisGesture = true
            step(up: accumulated > 0, rules: rules)
        }
    }

    /// All stops, ascending: the top, then each rule, clamped to the scrollable range.
    func stops(rules: [CGFloat]) -> [CGFloat] {
        let maxY = max(0, (documentView?.frame.height ?? 0) - contentView.bounds.height)
        return Array(Set(([0] + rules).map { min(max(0, $0), maxY) })).sorted()
    }

    /// Scrolls to the next stop above (`up`) or below the current position.
    func step(up: Bool, rules: [CGFloat], animated: Bool = true) {
        let current = contentView.bounds.origin.y
        let all = stops(rules: rules)
        guard let target = up ? all.last(where: { $0 < current - 0.5 }) : all.first(where: { $0 > current + 0.5 })
        else { return }
        scroll(toY: target, animated: animated)
    }

    /// Section 0 starts at the top; section i at the stop for rule i. Returns false if there's
    /// no such section.
    @discardableResult
    func scroll(toSection index: Int, rules: [CGFloat], animated: Bool = true) -> Bool {
        guard index >= 0, index <= rules.count else { return false }
        let maxY = max(0, (documentView?.frame.height ?? 0) - contentView.bounds.height)
        scroll(toY: min(index == 0 ? 0 : rules[index - 1], maxY), animated: animated)
        return true
    }

    private func scroll(toY target: CGFloat, animated: Bool) {
        let origin = NSPoint(x: contentView.bounds.origin.x, y: target)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Self.animationDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                contentView.animator().setBoundsOrigin(origin)
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.reflectScrolledClipView(self.contentView)
                }
            }
        } else {
            contentView.setBoundsOrigin(origin)
            reflectScrolledClipView(contentView)
        }
    }
}
