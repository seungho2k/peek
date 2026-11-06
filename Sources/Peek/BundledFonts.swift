import AppKit
import CoreText

/// Registers the fonts shipped in the app bundle (Contents/Resources/Fonts) for this process.
enum BundledFonts {
    static func register() {
        for dir in candidateDirectories() {
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            else { continue }
            let fonts = files.filter { ["otf", "ttf"].contains($0.pathExtension.lowercased()) }
            guard !fonts.isEmpty else { continue }
            for url in fonts {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
            return
        }
    }

    private static func candidateDirectories() -> [URL] {
        var dirs: [URL] = []
        if let resources = Bundle.main.resourceURL {
            dirs.append(resources.appendingPathComponent("Fonts"))
        }
        #if DEBUG
        // Running the bare binary from .build (self tests): use the repo's copy.
        dirs.append(URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Support/Fonts"))
        #endif
        return dirs
    }
}
