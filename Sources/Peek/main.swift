import AppKit

MainActor.assumeIsolated {
    BundledFonts.register()
    #if DEBUG
    if CommandLine.arguments.contains("--selftest") || CommandLine.arguments.contains("--render") {
        DebugLog.enabled = false
    }
    if CommandLine.arguments.contains("--selftest") { SelfTest.run() }
    if let i = CommandLine.arguments.firstIndex(of: "--render-settings"), i + 1 < CommandLine.arguments.count {
        _ = NSApplication.shared
        DebugLog.enabled = false
        NoteFormat.autoBoldFirstLine = Settings.shared.autoBoldFirstLine
        SettingsPanelController().debugRender(to: CommandLine.arguments[i + 1])
        exit(0)
    }
    if let i = CommandLine.arguments.firstIndex(of: "--render"), i + 1 < CommandLine.arguments.count {
        SelfTest.render(to: CommandLine.arguments[i + 1])
    }
    #endif

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
