// SetupGuide — a short first-launch guide, also openable from the menu.
//
// Plain NSAlert (it shows the app icon automatically). If the Mac has no
// built-in microphone, it also explains how to get the free BlackHole driver.

import Cocoa

enum SetupGuide {
    private static let shownKey = "didShowSetupGuide"
    private static let blackHoleURL = URL(string: "https://existential.audio/blackhole/")!
    private static let installCommand = "brew install --cask blackhole-2ch"

    /// Shows the guide once ever (UserDefaults key "didShowSetupGuide").
    static func showIfFirstLaunch(needsBlackHole: Bool) {
        guard !UserDefaults.standard.bool(forKey: shownKey) else { return }
        show(needsBlackHole: needsBlackHole)
    }

    /// Always shows the guide.
    static func show(needsBlackHole: Bool) {
        UserDefaults.standard.set(true, forKey: shownKey)

        var text = """
        1. In Discord, Zoom, Meet etc. set Input Device (microphone) to "Default".

        2. Keep the call app itself unmuted.

        3. Click the 🎧 icon in the menu bar (or press ⌃⌥M) to turn your mic on/off. Right-click the icon for settings.

        🎧 Mic OFF = HD sound  ·  🎙️ Mic ON = you can talk
        """

        if needsBlackHole {
            text += """


            ────────────────────

            ⚠️ This Mac has no built-in microphone.
            Install the free BlackHole driver to keep HD sound while the mic is off.
            """
        }

        let alert = NSAlert()
        alert.messageText = "Welcome to MicSwitch"
        alert.informativeText = text
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Got it")
        if needsBlackHole {
            alert.addButton(withTitle: "Get BlackHole")
            alert.addButton(withTitle: "Copy Install Command")
        }

        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(blackHoleURL)
        case .alertThirdButtonReturn:
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(installCommand, forType: .string)
        default:
            break
        }
    }
}
