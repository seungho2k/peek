import AppKit

extension NSPasteboard.PasteboardType {
    /// peek's own clipboard format: the markdown subset, with image references.
    static let peekNote = NSPasteboard.PasteboardType("com.seungho.peek.note")
}

/// Copy/paste and drag & drop. Images behave like characters; paste and drop share one path
/// (`readSelection(from:type:)`), which NSTextView calls with the selection already moved
/// to the drop point.
extension NoteTextView {
    private static let readableTypes: [NSPasteboard.PasteboardType] = [.peekNote, .fileURL, .string, .png, .tiff]

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { Self.readableTypes }
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { Self.readableTypes }
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.peekNote, .string, .rtfd] }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        let store = NoteStore.shared
        switch type {
        case .peekNote, .string:
            guard let s = pboard.string(forType: type) else { return false }
            insertFragment(NoteFormat.parse(s))
            return true

        case .fileURL:
            let urls = pboard.readObjects(forClasses: [NSURL.self],
                                          options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            let names = urls.filter(NoteStore.isImageFile).compactMap(store.importImage(from:))
            if names.isEmpty {
                // Not images: fall back to whatever text came along (e.g. the file name).
                guard let s = pboard.string(forType: .string) else { return false }
                insertFragment(NoteFormat.parse(s))
                return true
            }
            insertImages(names)
            return true

        case .png, .tiff:
            guard let data = pboard.data(forType: type) else { return false }
            let png = type == .png ? data
                : NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
            guard let png, let name = store.importImage(data: png, fileExtension: "png") else { return false }
            insertImages([name])
            return true

        default:
            return super.readSelection(from: pboard, type: type)
        }
    }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard let storage = textStorage else { return false }
        let range = selectedRange()
        guard range.length > 0 else { return false }
        let selection = storage.attributedSubstring(from: range)

        switch type {
        case .peekNote, .string:
            return pboard.setString(NoteFormat.serialize(selection), forType: type)
        case .rtfd:
            let rich = Self.richTextForExport(selection)
            guard let data = rich.rtfd(from: NSRange(location: 0, length: rich.length), documentAttributes: [:])
            else { return false }
            return pboard.setData(data, forType: .rtfd)
        default:
            return super.writeSelection(to: pboard, type: type)
        }
    }

    /// For other apps: images as real file attachments, rules as `---`.
    private static func richTextForExport(_ s: NSAttributedString) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: s)
        out.removeAttribute(.peekBold, range: NSRange(location: 0, length: out.length))
        var replacements: [(NSRange, NSAttributedString)] = []
        out.enumerateAttribute(.attachment, in: NSRange(location: 0, length: out.length)) { value, range, _ in
            switch value {
            case let img as ImageAttachment:
                let url = NoteStore.shared.imageURL(named: img.name)
                guard let wrapper = try? FileWrapper(url: url) else { return }
                let r = NSMutableAttributedString()
                for _ in 0..<range.length {
                    r.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
                }
                replacements.append((range, r))
            case is RuleAttachment:
                replacements.append((range, NSAttributedString(string: "---", attributes: NoteFormat.baseAttributes)))
            default:
                break
            }
        }
        for (range, r) in replacements.reversed() { out.replaceCharacters(in: range, with: r) }
        return out
    }

    /// Inserts images as one row at the selection.
    func insertImages(_ names: [String]) {
        let row = NSMutableAttributedString()
        for name in names { row.append(NoteFormat.attachmentString(ImageAttachment(name: name))) }
        insertFragment(row)
    }

    /// Inserts parsed note content at the selection, keeping image rows off text lines.
    func insertFragment(_ fragment: NSAttributedString) {
        guard let storage = textStorage, fragment.length > 0 else { return }
        let sel = selectedRange()
        let ns = storage.string as NSString
        let current = NoteFormat.lineContentRange(in: ns, at: sel.location)
        let isImageRow = !fragment.string.contains("\n")
            && NoteFormat.kind(of: fragment, line: NSRange(location: 0, length: fragment.length)) == .images

        if isImageRow && sel.length == 0 {
            let currentKind = NoteFormat.kind(of: storage, line: current)
            if currentKind == .images || current.length == 0 {
                // Join the row (at the drop/caret position) or fill the empty line.
                applyEdits([(sel, fragment)], selectAfter: NSRange(location: sel.location + fragment.length, length: 0))
            } else {
                // Text or rule line: new image line below it.
                let end = NSMaxRange(current)
                let s = NSMutableAttributedString(string: "\n", attributes: NoteFormat.baseAttributes)
                s.append(fragment)
                applyEdits([(NSRange(location: end, length: 0), s)],
                           selectAfter: NSRange(location: end + s.length, length: 0))
            }
            return
        }
        applyEdits([(sel, fragment)], selectAfter: NSRange(location: sel.location + fragment.length, length: 0))
    }
}
