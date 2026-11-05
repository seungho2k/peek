import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(settings: .shared))
            let w = NSWindow(contentViewController: hosting)
            w.title = "peek 설정"
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
            Section("패널") {
                Picker("피크 방향", selection: $settings.edge) {
                    ForEach(PeekEdge.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section("애니메이션") {
                durationRow("나올 때", value: $settings.slideInMs)
                durationRow("들어갈 때", value: $settings.slideOutMs)
            }

            Section {
                ForEach(ShortcutAction.allCases) { action in
                    LabeledContent(action.title) {
                        ShortcutRecorderView(action: action, settings: settings)
                    }
                }
            } header: {
                Text("단축키")
            } footer: {
                HStack {
                    Text("Ctrl+H/J/K/L은 방향키로 고정.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("기본값으로") { settings.resetShortcuts() }
                }
            }

            Section {
                Toggle("로그인 시 자동 실행", isOn: $settings.launchAtLogin)
            }

            Section {
                Button("peek 종료") { NSApp.terminate(nil) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func durationRow(_ title: String, value: Binding<Double>) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: 0...1000, step: 10)
                Text("\(Int(value.wrappedValue)) ms")
                    .monospacedDigit()
                    .frame(width: 64, alignment: .trailing)
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
                Text(recorder.isRecording ? "키 입력…" : shortcut.displayString)
                    .frame(minWidth: 72)
            }
            if let conflict {
                Text(conflict).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func conflictMessage(for shortcut: Shortcut) -> String? {
        if let other = ShortcutAction.allCases.first(where: { $0 != action && settings.shortcut(for: $0) == shortcut }) {
            return "‘\(other.title)’와 겹침"
        }
        if Self.reserved.contains(shortcut) {
            return "기본 단축키와 겹침"
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
            MainActor.assumeIsolated {
                guard let self else { return event }
                if event.keyCode == KeyCode.escape {
                    self.stop()
                    return nil
                }
                let mods = event.modifierFlags.intersection([.command, .control, .option])
                guard !mods.isEmpty else {
                    NSSound.beep()
                    return nil
                }
                onRecord(Shortcut(event: event))
                self.stop()
                return nil
            }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }
}
