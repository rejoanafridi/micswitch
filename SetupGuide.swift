// SetupGuide — a short first-launch guide, also openable from the menu.
//
// Plain NSAlert (it shows the app icon automatically). If the Mac has no
// built-in microphone, it offers a one-click install of the free BlackHole driver.

import Cocoa

enum SetupGuide {
    private static let shownKey = "didShowSetupGuide"

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

            ⚠️ One more step: this Mac has no built-in microphone.
            MicSwitch needs a free "silent mic" driver (BlackHole) so your headset can stay in HD while the mic is off.

            Click "Install Now". macOS asks for your Mac password once. That's it.
            """
        }

        let alert = NSAlert()
        alert.messageText = "Welcome to MicSwitch"
        alert.informativeText = text
        alert.alertStyle = .informational
        if needsBlackHole {
            alert.addButton(withTitle: "Install Now")
            alert.addButton(withTitle: "Later")
        } else {
            alert.addButton(withTitle: "Got it")
        }

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn && needsBlackHole {
            DriverInstaller.install()
        }
    }
}
