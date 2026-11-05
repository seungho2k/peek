import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(settings: .shared))
            let w = NSWindow(contentViewController: hosting)
            w.title = "peek Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var settings: Settings

    var body: some View {
        Form {
            Section("Panel") {
                Picker("Peek From", selection: $settings.edge) {
                    ForEach(PeekEdge.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                numberRow(settings.edge.isSide ? "Minimum Width" : "Minimum Height", unit: "pt", value: $settings.minDepth, range: 100...3000)
            }

            Section("Note") {
                Picker("Horizontal Rule", selection: $settings.ruleStyle) {
                    ForEach(RuleStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section("Animation") {
                numberRow("Fade In", unit: "ms", value: $settings.slideInMs, range: 0...5000)
                numberRow("Fade Out", unit: "ms", value: $settings.slideOutMs, range: 0...5000)
            }

            Section {
                ForEach(ShortcutAction.allCases) { action in
                    LabeledContent(action.title) {
                        ShortcutRecorderView(action: action, settings: settings)
                    }
                }
            } header: {
                Text("Shortcuts")
            } footer: {
                HStack {
                    Text("Ctrl+H/J/K/L always act as arrow keys.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Defaults") { settings.resetShortcuts() }
                }
            }

            Section {
                Toggle("Launch at Login", isOn: $settings.launchAtLogin)
            }

            Section {
                Button("Quit peek") { NSApp.terminate(nil) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func numberRow(_ title: String, unit: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        let clamped = Binding<Double>(
            get: { value.wrappedValue },
            set: { value.wrappedValue = min(max($0, range.lowerBound), range.upperBound).rounded() }
        )
        return LabeledContent(title) {
            HStack(spacing: 4) {
                TextField("", value: clamped, format: .number.grouping(.never))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                    .labelsHidden()
                Text(unit).foregroundStyle(.secondary)
            }
        }
    }
}

/// Click, then press the new key combination. Esc cancels.
struct ShortcutRecorderView: View {
    let action: ShortcutAction
    @ObservedObject var settings: Settings
    @StateObject private var recorder = ShortcutRecorder()

    var body: some View {
        let shortcut = settings.shortcut(for: action)
        let conflict = conflictMessage(for: shortcut)
        VStack(alignment: .trailing, spacing: 2) {
            Button {
                if recorder.isRecording {
                    recorder.stop()
                } else {
                    recorder.start { settings.shortcuts[action] = $0 }
                }
            } label: {
                Text(recorder.isRecording ? "Type Shortcut…" : shortcut.displayString)
                    .frame(minWidth: 72)
            }
            if let conflict {
                Text(conflict).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func conflictMessage(for shortcut: Shortcut) -> String? {
        if let other = ShortcutAction.allCases.first(where: { $0 != action && settings.shortcut(for: $0) == shortcut }) {
            return "Conflicts with “\(other.title)”"
        }
        if Self.reserved.contains(shortcut) {
            return "Conflicts with a built-in shortcut"
        }
        return nil
    }

    private static let reserved: Set<Shortcut> = {
        var s: Set<Shortcut> = []
        for k in [KeyCode.h, KeyCode.j, KeyCode.k, KeyCode.l] { s.insert(Shortcut(keyCode: k, modifiers: .control)) }
        for k in [KeyCode.z, KeyCode.x, KeyCode.c, KeyCode.v, KeyCode.a, KeyCode.q] {
            s.insert(Shortcut(keyCode: k, modifiers: .command))
        }
        s.insert(Shortcut(keyCode: KeyCode.z, modifiers: [.command, .shift]))
        return s
    }()
}

@MainActor
final class ShortcutRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    private var monitor: Any?

    func start(onRecord: @escaping (Shortcut) -> Void) {
        stop()
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let flags = event.modifierFlags
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                if keyCode == KeyCode.escape {
                    self.stop()
                    return true
                }
                guard !flags.intersection([.command, .control, .option]).isEmpty else {
                    NSSound.beep()
                    return true
                }
                onRecord(Shortcut(keyCode: keyCode, modifiers: flags))
                self.stop()
                return true
            }
            return consumed ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }
}
