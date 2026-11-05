import AppKit

/// The settings as editable text, one `key: value` per line:
///
///     edge: right
///     min-size: 200
///     fade-in: 150
///     fade-out: 120
///     launch-at-login: off
///     toggle: opt+space
///     bold: cmd+b
///     rule: cmd+l
///     fill: cmd+enter
///     settings: cmd+,
@MainActor
enum SettingsText {
    private static let shortcutKeys: [(key: String, action: ShortcutAction)] = [
        ("toggle", .pin), ("bold", .bold), ("rule", .rule), ("fill", .fill), ("settings", .settings),
    ]

    static func format(_ s: Settings) -> String {
        var lines = [
            "edge: \(s.edge.rawValue)",
            "min-size: \(Int(s.minDepth))",
            "fade-in: \(Int(s.slideInMs))",
            "fade-out: \(Int(s.slideOutMs))",
            "launch-at-login: \(s.launchAtLogin ? "on" : "off")",
        ]
        for (key, action) in shortcutKeys {
            lines.append("\(key): \(ShortcutText.format(s.shortcut(for: action)))")
        }
        return lines.joined(separator: "\n")
    }

    /// One parsed line: what to change, or nil if the line is blank.
    enum Change: Equatable {
        case edge(PeekEdge)
        case minSize(Double)
        case fadeIn(Double)
        case fadeOut(Double)
        case launchAtLogin(Bool)
        case shortcut(ShortcutAction, Shortcut)
    }

    /// Parses every line; `invalid` holds the indices of lines that couldn't be applied
    /// (unknown key, bad value, or a shortcut used twice).
    static func parse(_ text: String) -> (changes: [Change], invalid: Set<Int>) {
        var changes: [(line: Int, change: Change)] = []
        var invalid: Set<Int> = []
        for (i, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard let change = parseLine(line) else { invalid.insert(i); continue }
            changes.append((i, change))
        }
        // A shortcut that appears on more than one line is ambiguous: apply none of them.
        var byShortcut: [Shortcut: [Int]] = [:]
        for (line, change) in changes {
            if case .shortcut(_, let sc) = change { byShortcut[sc, default: []].append(line) }
        }
        for lines in byShortcut.values where lines.count > 1 { invalid.formUnion(lines) }
        return (changes.filter { !invalid.contains($0.line) }.map(\.change), invalid)
    }

    private static func parseLine(_ line: String) -> Change? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces).lowercased()
        switch key {
        case "edge":
            return PeekEdge(rawValue: value).map(Change.edge)
        case "min-size":
            guard let n = Double(value), (100...3000).contains(n) else { return nil }
            return .minSize(n)
        case "fade-in", "fade-out":
            guard let n = Double(value), (0...5000).contains(n) else { return nil }
            return key == "fade-in" ? .fadeIn(n) : .fadeOut(n)
        case "launch-at-login":
            switch value {
            case "on", "yes", "true": return .launchAtLogin(true)
            case "off", "no", "false": return .launchAtLogin(false)
            default: return nil
            }
        default:
            guard let action = shortcutKeys.first(where: { $0.key == key })?.action,
                  let sc = ShortcutText.parse(value),
                  !sc.modifierFlags.intersection([.command, .control, .option]).isEmpty
            else { return nil }
            return .shortcut(action, sc)
        }
    }

    static func apply(_ changes: [Change], to s: Settings) {
        for change in changes {
            switch change {
            case .edge(let e): if s.edge != e { s.edge = e }
            case .minSize(let n): if s.minDepth != n { s.minDepth = n }
            case .fadeIn(let n): if s.slideInMs != n { s.slideInMs = n }
            case .fadeOut(let n): if s.slideOutMs != n { s.slideOutMs = n }
            case .launchAtLogin(let on): if s.launchAtLogin != on { s.launchAtLogin = on }
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
