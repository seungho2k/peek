import AppKit
import Combine
import ServiceManagement

enum PeekEdge: String, CaseIterable, Identifiable {
    case right, left, bottom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .right: "Right"
        case .left: "Left"
        case .bottom: "Bottom"
        }
    }
    var isSide: Bool { self != .bottom }
}

enum ShortcutAction: String, CaseIterable, Identifiable, Codable {
    case top, bold, rule, fill, pin, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .top: "Go to Top"
        case .bold: "Bold Line"
        case .rule: "Horizontal Rule"
        case .fill: "Toggle Fill Screen"
        case .pin: "Open & Pin (Global)"
        case .settings: "Open Settings"
        }
    }
    var defaultShortcut: Shortcut {
        switch self {
        case .top: Shortcut(keyCode: KeyCode.zero, modifiers: .command)
        case .bold: Shortcut(keyCode: KeyCode.b, modifiers: .command)
        case .rule: Shortcut(keyCode: KeyCode.l, modifiers: .command)
        case .fill: Shortcut(keyCode: KeyCode.returnKey, modifiers: .command)
        case .pin: Shortcut(keyCode: KeyCode.space, modifiers: .option)
        case .settings: Shortcut(keyCode: KeyCode.comma, modifiers: .command)
        }
    }
}

@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    static let defaultSideWidth: CGFloat = 360
    static let defaultBottomHeight: CGFloat = 320

    @Published var edge: PeekEdge {
        didSet { defaults.set(edge.rawValue, forKey: "edge") }
    }
    /// Slide-in duration in milliseconds.
    @Published var slideInMs: Double {
        didSet { defaults.set(slideInMs, forKey: "slideInMs") }
    }
    /// Slide-out duration in milliseconds.
    @Published var slideOutMs: Double {
        didSet { defaults.set(slideOutMs, forKey: "slideOutMs") }
    }
    /// Panel width when peeking from the left or right edge.
    @Published var sideWidth: CGFloat {
        didSet { defaults.set(Double(sideWidth), forKey: "sideWidth") }
    }
    /// Panel height when peeking from the bottom edge.
    @Published var bottomHeight: CGFloat {
        didSet { defaults.set(Double(bottomHeight), forKey: "bottomHeight") }
    }
    /// Smallest panel width (left/right) or height (bottom), in pt.
    @Published var minDepth: Double {
        didSet { defaults.set(minDepth, forKey: "minDepth") }
    }
    @Published var shortcuts: [ShortcutAction: Shortcut] {
        didSet { saveShortcuts() }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            applyLaunchAtLogin()
        }
    }

    private init() {
        edge = PeekEdge(rawValue: defaults.string(forKey: "edge") ?? "") ?? .right
        slideInMs = defaults.object(forKey: "slideInMs") as? Double ?? 150
        slideOutMs = defaults.object(forKey: "slideOutMs") as? Double ?? 120
        defaults.removeObject(forKey: "hideMargin")  // setting removed
        minDepth = defaults.object(forKey: "minDepth") as? Double ?? 200
        sideWidth = CGFloat(defaults.object(forKey: "sideWidth") as? Double ?? Double(Self.defaultSideWidth))
        bottomHeight = CGFloat(defaults.object(forKey: "bottomHeight") as? Double ?? Double(Self.defaultBottomHeight))

        var sc: [ShortcutAction: Shortcut] = [:]
        if let data = defaults.data(forKey: "shortcuts"),
           let stored = try? JSONDecoder().decode([String: Shortcut].self, from: data) {
            for (k, v) in stored { if let a = ShortcutAction(rawValue: k) { sc[a] = v } }
        }
        // v1 defaults were ⌘1/⌘2/⌘3; move untouched ones to the current defaults.
        let version = defaults.integer(forKey: "shortcutsVersion")
        if version < 2 {
            let v1: [ShortcutAction: UInt16] = [.bold: KeyCode.two]
            for (a, key) in v1 where sc[a] == Shortcut(keyCode: key, modifiers: .command) { sc[a] = nil }
        }
        // v2 had an in-panel ⌘P pin toggle; pin is now a global ⌥Space hotkey.
        if version < 3, sc[.pin] == Shortcut(keyCode: KeyCode.p, modifiers: .command) { sc[.pin] = nil }
        // v3 used ⌘↩ for the rule; ⌘↩ now toggles fill and the rule moved to ⌘-.
        if version < 4, sc[.rule] == Shortcut(keyCode: KeyCode.returnKey, modifiers: .command) { sc[.rule] = nil }
        // v4 used ⌘- for the rule; it's ⌘L now (the list shortcut was removed).
        if version < 5, sc[.rule] == Shortcut(keyCode: KeyCode.minus, modifiers: .command) { sc[.rule] = nil }
        defaults.set(5, forKey: "shortcutsVersion")
        for a in ShortcutAction.allCases where sc[a] == nil { sc[a] = a.defaultShortcut }
        shortcuts = sc

        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func shortcut(for action: ShortcutAction) -> Shortcut {
        shortcuts[action] ?? action.defaultShortcut
    }

    /// In-panel shortcut for a key event. The pin shortcut is a global hotkey, handled elsewhere.
    func action(matching event: NSEvent) -> ShortcutAction? {
        ShortcutAction.allCases.first { $0 != .pin && shortcut(for: $0).matches(event) }
    }

    func resetShortcuts() {
        var sc: [ShortcutAction: Shortcut] = [:]
        for a in ShortcutAction.allCases { sc[a] = a.defaultShortcut }
        shortcuts = sc
    }

    private func saveShortcuts() {
        let dict = Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(dict) { defaults.set(data, forKey: "shortcuts") }
    }

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("peek: launch at login change failed: \(error)")
            let actual = SMAppService.mainApp.status == .enabled
            if actual != launchAtLogin {
                DispatchQueue.main.async { self.launchAtLogin = actual }
            }
        }
    }
}
