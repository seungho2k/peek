import AppKit
import Quartz

/// Double-clicking an image opens Quick Look (like Space in Finder) over all images in the
/// note, in order, so the arrow keys move between them.
extension NoteTextView: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    /// The image attachment drawn under `point` (view coordinates), if any.
    func imageAttachment(at point: NSPoint) -> ImageAttachment? {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage, storage.length > 0
        else { return nil }
        let origin = textContainerOrigin
        let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        let glyph = lm.glyphIndex(for: local, in: tc, fractionOfDistanceThroughGlyph: nil)
        let rect = lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc)
        guard rect.contains(local) else { return nil }
        let index = lm.characterIndexForGlyph(at: glyph)
        guard index < storage.length else { return nil }
        return storage.attribute(.attachment, at: index, effectiveRange: nil) as? ImageAttachment
    }

    /// Image files referenced by the note, in document order.
    var noteImageURLs: [URL] {
        guard let storage = textStorage else { return [] }
        var urls: [URL] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, r, _ in
            if let img = value as? ImageAttachment {
                for _ in 0..<r.length { urls.append(NoteStore.shared.imageURL(named: img.name)) }
            }
        }
        return urls
    }

    func showQuickLook(startingAt image: ImageAttachment) {
        guard let storage = textStorage else { return }
        var start = 0, i = 0
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
            if let img = value as? ImageAttachment {
                if img === image { start = i; stop.pointee = true }
                i += 1
            }
        }
        previewStartIndex = start
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.reloadData()
            panel.currentPreviewItemIndex = start
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        previewURLs = noteImageURLs
        panel.dataSource = self
        panel.delegate = self
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)  // above the note panel
        panel.reloadData()
        panel.currentPreviewItemIndex = previewStartIndex
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { previewURLs.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { previewURLs[index] as NSURL }
    }
}
