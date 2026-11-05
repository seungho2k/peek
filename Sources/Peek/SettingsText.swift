import AppKit

/// The settings as editable text. Rule-separated blocks, each starting with a bold title;
/// inside a block, items are separated by blank lines — a `key:` line, then its value:
///
///     **preferences**
///
///     edge:
///     right
///
///     min-width:
///     200
///     ---
///     **animations**
///     …
@MainActor
enum SettingsText {
    private static let shortcutKeys: [(key: String, action: ShortcutAction)] = [
        ("toggle", .pin), ("bold", .bold), ("rule", .rule), ("fill", .fill), ("settings", .settings),
    ]

    static func format(_ s: Settings) -> String {
        let blocks: [(title: String, items: [(String, String)])] = [
            ("preferences", [
                ("edge", s.edge.rawValue),
                ("min-width", "\(Int(s.minDepth))"),
                ("launch-at-login", s.launchAtLogin ? "on" : "off"),
                ("bold-first-line", s.autoBoldFirstLine ? "on" : "off"),
            ]),
            ("animations", [
                ("fade-in", "\(Int(s.slideInMs))"),
                ("fade-out", "\(Int(s.slideOutMs))"),
            ]),
            ("keyboard shortcuts", shortcutKeys.map { ($0.key, ShortcutText.format(s.shortcut(for: $0.action))) }),
        ]
        return blocks.map { block in
            (["**\(block.title)**"] + block.items.map { "\($0.0):\n\($0.1)" }).joined(separator: "\n\n")
        }.joined(separator: "\n---\n")
    }

    enum Change: Equatable {
        case edge(PeekEdge)
        case minWidth(Double)
        case fadeIn(Double)
        case fadeOut(Double)
        case launchAtLogin(Bool)
        case autoBoldFirstLine(Bool)
        case shortcut(ShortcutAction, Shortcut)
    }

    /// Parses the sections; `invalid` holds indices of lines that couldn't be applied
    /// (unknown key, missing/bad value, or a shortcut used twice).
    static func parse(_ text: String) -> (changes: [Change], invalid: Set<Int>) {
        // Items: runs of non-empty lines, split by blank lines and rules. The first item of
        // each block is its title and isn't parsed.
        let lines = text.components(separatedBy: "\n")
        var sections: [[(index: Int, text: String)]] = []
        var current: [(index: Int, text: String)] = []
        var expectingTitle = true
        func flush() {
            if !current.isEmpty {
                if expectingTitle { expectingTitle = false } else { sections.append(current) }
            }
            current = []
        }
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "---" { flush(); expectingTitle = true; continue }
            if line.isEmpty { flush(); continue }
            // A bold line is saved as **…**; read the text inside.
            let plain = line.count >= 4 && line.hasPrefix("**") && line.hasSuffix("**") ? String(line.dropFirst(2).dropLast(2)) : line
            current.append((i, plain))
        }
        flush()
        sections.insert([], at: 0)  // keeps the loop below skipping index 0

        var changes: [(line: Int, change: Change)] = []
        var invalid: Set<Int> = []
        for section in sections.dropFirst() where !section.isEmpty {  // the first section is the title
            let key = section[0]
            guard section.count >= 2 else { invalid.insert(key.index); continue }
            let value = section[1]
            let name = key.text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            switch parseValue(key: name, value: value.text.lowercased()) {
            case .unknownKey: invalid.insert(key.index)
            case .badValue: invalid.insert(value.index)
            case .ok(let change): changes.append((value.index, change))
            }
            for extra in section.dropFirst(2) { invalid.insert(extra.index) }
        }
        // A shortcut that appears in more than one section is ambiguous: apply none of them.
        var byShortcut: [Shortcut: [Int]] = [:]
        for (line, change) in changes {
            if case .shortcut(_, let sc) = change { byShortcut[sc, default: []].append(line) }
        }
        for dupes in byShortcut.values where dupes.count > 1 { invalid.formUnion(dupes) }
        return (changes.filter { !invalid.contains($0.line) }.map(\.change), invalid)
    }

    private enum Parsed { case ok(Change), unknownKey, badValue }

    private static func parseValue(key: String, value: String) -> Parsed {
        func onOff(_ v: String) -> Bool? {
            switch v {
            case "on", "yes", "true": true
            case "off", "no", "false": false
            default: nil
            }
        }
        switch key {
        case "edge":
            return PeekEdge(rawValue: value).map { .ok(.edge($0)) } ?? .badValue
        case "min-width":
            guard let n = Double(value), n >= 0, n <= 3000 else { return .badValue }
            return .ok(.minWidth(max(n, Settings.minimumWidthFloor)))  // below 80 becomes 80
        case "fade-in", "fade-out":
            guard let n = Double(value), (0...5000).contains(n) else { return .badValue }
            return .ok(key == "fade-in" ? .fadeIn(n) : .fadeOut(n))
        case "launch-at-login":
            return onOff(value).map { .ok(.launchAtLogin($0)) } ?? .badValue
        case "bold-first-line":
            return onOff(value).map { .ok(.autoBoldFirstLine($0)) } ?? .badValue
        default:
            guard let action = shortcutKeys.first(where: { $0.key == key })?.action else { return .unknownKey }
            guard let sc = ShortcutText.parse(value),
                  !sc.modifierFlags.intersection([.command, .control, .option]).isEmpty
            else { return .badValue }
            return .ok(.shortcut(action, sc))
        }
    }

    static func apply(_ changes: [Change], to s: Settings) {
        for change in changes {
            switch change {
            case .edge(let e): if s.edge != e { s.edge = e }
            case .minWidth(let n): if s.minDepth != n { s.minDepth = n }
            case .fadeIn(let n): if s.slideInMs != n { s.slideInMs = n }
            case .fadeOut(let n): if s.slideOutMs != n { s.slideOutMs = n }
            case .launchAtLogin(let on): if s.launchAtLogin != on { s.launchAtLogin = on }
            case .autoBoldFirstLine(let on): if s.autoBoldFirstLine != on { s.autoBoldFirstLine = on }
            case .shortcut(let action, let sc): if s.shortcut(for: action) != sc { s.shortcuts[action] = sc }
            }
        }
    }
}

/// Shortcuts as text: modifiers `cmd`, `opt`, `ctrl`, `shift` joined with `+`, then a key
/// (`a`–`z`, `0`–`9`, punctuation, `space`, `enter`, `tab`, `esc`, `delete`, arrows, `f1`–`f12`).
enum ShortcutText {
    private static let names: [UInt16: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
        11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
        27: "-", 28: "8", 29: "0", 30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p",
        36: "enter", 37: "l", 38: "j", 39: "'", 40: "k", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "n", 46: "m", 47: ".", 48: "tab", 49: "space", 50: "`", 51: "delete", 53: "esc",
        123: "left", 124: "right", 125: "down", 126: "up",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6",
        98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",
    ]
    private static let codes: [String: UInt16] = {
        var m = Dictionary(uniqueKeysWithValues: names.map { ($0.value, $0.key) })
        m["return"] = 36
        return m
    }()

    static func format(_ sc: Shortcut) -> String {
        let f = sc.modifierFlags
        var parts: [String] = []
        if f.contains(.control) { parts.append("ctrl") }
        if f.contains(.option) { parts.append("opt") }
        if f.contains(.shift) { parts.append("shift") }
        if f.contains(.command) { parts.append("cmd") }
        parts.append(names[sc.keyCode] ?? "#\(sc.keyCode)")
        return parts.joined(separator: "+")
    }

    static func parse(_ text: String) -> Shortcut? {
        // The key itself may be "+" or "-", so split carefully: modifiers end with "+".
        var rest = text.replacingOccurrences(of: " ", with: "").lowercased()
        var mods: NSEvent.ModifierFlags = []
        let modNames: [(String, NSEvent.ModifierFlags)] = [
            ("cmd", .command), ("command", .command), ("opt", .option), ("option", .option), ("alt", .option),
            ("ctrl", .control), ("control", .control), ("shift", .shift),
        ]
        var matched = true
        while matched {
            matched = false
            for (name, flag) in modNames where rest.hasPrefix(name + "+") {
                mods.insert(flag)
                rest.removeFirst(name.count + 1)
                matched = true
                break
            }
        }
        guard let code = codes[rest] else { return nil }
        return Shortcut(keyCode: code, modifiers: mods)
    }
}
