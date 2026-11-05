import AppKit
import UniformTypeIdentifiers

/// Owns the single note file and the images folder:
///   ~/Library/Application Support/peek/note.md
///   ~/Library/Application Support/peek/images/
@MainActor
final class NoteStore {
    static let shared = NoteStore()

    let directory: URL
    let noteURL: URL
    let imagesDirectory: URL

    /// Modification date of note.md as of our last read/write.
    private var knownModificationDate: Date?

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = support.appendingPathComponent("peek", isDirectory: true)
        noteURL = directory.appendingPathComponent("note.md")
        imagesDirectory = directory.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
    }

    // MARK: Note

    func load() -> String {
        knownModificationDate = modificationDate()
        guard let data = try? Data(contentsOf: noteURL) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    func save(_ markdown: String) {
        do {
            try Data(markdown.utf8).write(to: noteURL, options: .atomic)
            knownModificationDate = modificationDate()
        } catch {
            NSLog("peek: failed to save note: \(error)")
        }
    }

    /// True if note.md was changed by someone else since we last read or wrote it.
    func hasExternalChange() -> Bool {
        modificationDate() != knownModificationDate
    }

    private func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: noteURL.path))?[.modificationDate] as? Date
    }

    // MARK: Images

    func imageURL(named name: String) -> URL {
        imagesDirectory.appendingPathComponent(name)
    }

    static func isImageFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    /// Copies an image file into the images folder. Returns the stored file name.
    func importImage(from url: URL) -> String? {
        guard Self.isImageFile(url) else { return nil }
        let ext = url.pathExtension.lowercased()
        let name = UUID().uuidString + "." + ext
        do {
            try FileManager.default.copyItem(at: url, to: imageURL(named: name))
            return name
        } catch {
            NSLog("peek: failed to import image: \(error)")
            return nil
        }
    }

    /// Stores raw image data (e.g. from the clipboard). Returns the stored file name.
    func importImage(data: Data, fileExtension ext: String) -> String? {
        let name = UUID().uuidString + "." + ext
        do {
            try data.write(to: imageURL(named: name), options: .atomic)
            return name
        } catch {
            NSLog("peek: failed to store image: \(error)")
            return nil
        }
    }

    /// Deletes image files that the note no longer references.
    func removeUnreferencedImages(referenced: Set<String>) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: imagesDirectory.path)) ?? []
        for file in files where !referenced.contains(file) {
            try? FileManager.default.removeItem(at: imageURL(named: file))
        }
    }
}
