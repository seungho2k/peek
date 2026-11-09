import AppKit

/// The settings as editable text. Rule-separated blocks, each starting with a bold title and
/// a blank line, then one `key: value` per line:
///
///     **preferences**
///
///     edge: right
///     min-width: 200
///     ---
///     **keyboard shortcuts**
///     …
///
/// The parser also accepts the value on the line after `key:`.
@MainActor
enum SettingsText {
    private static let shortcutKeys: [(key: String, action: ShortcutAction)] = [
        ("toggle", .pin), ("bold", .bold), ("strike", .strike), ("rule", .rule), ("settings", .settings),
    ]

    static func format(_ s: Settings) -> String {
        let blocks: [(title: String, items: [(String, String)])] = [
            ("preferences", [
                ("edge", s.edge.rawValue),
                ("min-width", "\(Int(s.minDepth))"),
                ("launch-at-login", "\(s.launchAtLogin)"),
                ("bold-first-line", "\(s.autoBoldFirstLine)"),
                ("line-numbers", "\(s.showLineNumbers)"),
            ]),
            ("keyboard shortcuts", shortcutKeys.map { ($0.key, ShortcutText.format(s.shortcut(for: $0.action))) }),
        ]
        return blocks.map { block in
            "**\(block.title)**\n\n" + block.items.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
        }.joined(separator: "\n---\n")
    }

    enum Change: Equatable {
        case edge(PeekEdge)
        case minWidth(Double)
        case launchAtLogin(Bool)
        case autoBoldFirstLine(Bool)
        case lineNumbers(Bool)
        case shortcut(ShortcutAction, Shortcut)
    }

    /// Parses the sections; `invalid` holds indices of lines that couldn't be applied
    /// (unknown key, missing/bad value, or a shortcut used twice).
    static func parse(_ text: String) -> (changes: [Change], invalid: Set<Int>) {
        let detailed = parseWithLines(text)
        return (detailed.changes.map(\.change), detailed.invalid)
    }

    /// Like `parse`, keeping the line each change came from.
    static func parseWithLines(_ text: String) -> (changes: [(line: Int, change: Change)], invalid: Set<Int>) {
        var changes: [(line: Int, change: Change)] = []
        var invalid: Set<Int> = []

        func take(key: String, keyLine: Int, value: String, valueLine: Int) {
            let name = key.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            switch parseValue(key: name, value: value.lowercased()) {
            case .unknownKey: invalid.insert(keyLine)
            case .badValue: invalid.insert(valueLine)
            case .ok(let change): changes.append((valueLine, change))
            }
        }

        // Each block's first line is its title. Items are `key: value` on one line, or `key:`
        // with the value on the next line.
        var expectingTitle = true
        var pendingKey: (text: String, line: Int)?
        for (i, raw) in text.components(separatedBy: "\n").enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed.isEmpty {
                if let key = pendingKey { invalid.insert(key.line) }  // key without a value
                pendingKey = nil
                if trimmed == "---" { expectingTitle = true }
                continue
            }
            // A bold line is saved as **…**; read the text inside.
            let line = trimmed.count >= 4 && trimmed.hasPrefix("**") && trimmed.hasSuffix("**")
                ? String(trimmed.dropFirst(2).dropLast(2)) : trimmed
            if expectingTitle { expectingTitle = false; continue }
            if let key = pendingKey {
                take(key: key.text, keyLine: key.line, value: line, valueLine: i)
                pendingKey = nil
            } else if let colon = line.firstIndex(of: ":"),
                      case let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces),
                      !value.isEmpty {
                take(key: String(line[..<colon]), keyLine: i, value: value, valueLine: i)
            } else {
                pendingKey = (line, i)
            }
        }
        if let key = pendingKey { invalid.insert(key.line) }

        // A shortcut that appears in more than one section is ambiguous: apply none of them.
        var byShortcut: [Shortcut: [Int]] = [:]
        for (line, change) in changes {
            if case .shortcut(_, let sc) = change { byShortcut[sc, default: []].append(line) }
        }
        for dupes in byShortcut.values where dupes.count > 1 { invalid.formUnion(dupes) }
        return (changes.filter { !invalid.contains($0.line) }, invalid)
    }

    private enum Parsed { case ok(Change), unknownKey, badValue }

    private static func parseValue(key: String, value: String) -> Parsed {
        func bool(_ v: String) -> Bool? {
            switch v {
            case "true": true
            case "false": false
            default: nil
            }
        }
        switch key {
        case "edge":
            return PeekEdge(rawValue: value).map { .ok(.edge($0)) } ?? .badValue
        case "min-width":
            // Anything below 100 — or not a number — means 100.
            let n = min(Double(value) ?? Settings.minimumWidthFloor, 3000)
            return .ok(.minWidth(max(n, Settings.minimumWidthFloor)))
        case "launch-at-login":
            return bool(value).map { .ok(.launchAtLogin($0)) } ?? .badValue
        case "bold-first-line":
            return bool(value).map { .ok(.autoBoldFirstLine($0)) } ?? .badValue
        case "line-numbers":
            return bool(value).map { .ok(.lineNumbers($0)) } ?? .badValue
        default:
            guard let action = shortcutKeys.first(where: { $0.key == key })?.action else { return .unknownKey }
            guard let sc = ShortcutText.parse(value),
                  !sc.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  !sc.isReservedArrow  // cmd+h/j/k/l move the caret
            else { return .badValue }
            return .ok(.shortcut(action, sc))
        }
    }

    /// Applies the changes; returns the indices (into `changes`) that were refused — a global
    /// shortcut that macOS wouldn't register (e.g. taken by another app).
    @discardableResult
    static func apply(_ changes: [Change], to s: Settings) -> Set<Int> {
        var refused: Set<Int> = []
        for (i, change) in changes.enumerated() {
            if case .shortcut(.pin, let sc) = change, s.shortcut(for: .pin) != sc,
               let canUse = s.canUseGlobalShortcut, !canUse(sc) {
                refused.insert(i)
                continue
            }
            switch change {
            case .edge(let e): if s.edge != e { s.edge = e }
            case .minWidth(let n): if s.minDepth != n { s.minDepth = n }
            case .launchAtLogin(let on): if s.launchAtLogin != on { s.launchAtLogin = on }
            case .autoBoldFirstLine(let on): if s.autoBoldFirstLine != on { s.autoBoldFirstLine = on }
            case .lineNumbers(let on): if s.showLineNumbers != on { s.showLineNumbers = on }
            case .shortcut(let action, let sc): if s.shortcut(for: action) != sc { s.shortcuts[action] = sc }
            }
        }
        return refused
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
