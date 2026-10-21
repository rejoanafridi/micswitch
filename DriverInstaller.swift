// One-click install of the BlackHole "silent mic" driver for Macs without a built-in mic.
//
// Downloads the official package, refuses it unless it is signed by Existential Audio
// and notarized by Apple, then installs it with the standard macOS password prompt and
// restarts Core Audio so the device shows up right away.

import Cocoa

enum DriverInstaller {
    private static let packageURL = URL(string: "https://existential.audio/downloads/BlackHole2ch-0.7.1.pkg")!
    private static let infoURL = URL(string: "https://existential.audio/blackhole/")!
    /// Developer ID Installer: Existential Audio Inc. (Q5C99V536K)
    private static let expectedSigner = "Existential Audio Inc. (Q5C99V536K)"

    private static var installing = false

    static func install() {
        guard !installing else { return }
        installing = true
        HUD.shared.show(micOn: false, title: "Downloading…", subtitle: "Silent mic driver")
        Log.write("Driver: downloading \(packageURL)")

        URLSession.shared.downloadTask(with: packageURL) { tempURL, response, error in
            let pkg = FileManager.default.temporaryDirectory.appendingPathComponent("BlackHole2ch.pkg")
            var failure: String?
            if let error {
                failure = "Download failed: \(error.localizedDescription)"
            } else if (response as? HTTPURLResponse)?.statusCode != 200 || tempURL == nil {
                failure = "Download failed (server returned \((response as? HTTPURLResponse)?.statusCode ?? 0))."
            } else {
                try? FileManager.default.removeItem(at: pkg)
                do { try FileManager.default.moveItem(at: tempURL!, to: pkg) } catch {
                    failure = "Couldn't save the download: \(error.localizedDescription)"
                }
            }
            if failure == nil, !isTrusted(pkg) {
                failure = "The downloaded package isn't signed by Existential Audio, so it was not installed."
            }
            DispatchQueue.main.async {
                if let failure { finish(failure); return }
                HUD.shared.show(micOn: false, title: "Installing…", subtitle: "Enter your Mac password")
                // Let the HUD draw before the password prompt blocks the main thread.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { runInstaller(pkg) }
            }
        }.resume()
    }

    /// `pkgutil --check-signature` must show the Existential Audio installer certificate
    /// and Apple notarization.
    private static func isTrusted(_ pkg: URL) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/pkgutil")
        p.arguments = ["--check-signature", pkg.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let ok = p.terminationStatus == 0
            && out.contains("Developer ID Installer: \(expectedSigner)")
            && out.contains("Notarization: trusted")
        Log.write("Driver: signature check \(ok ? "passed" : "FAILED")")
        return ok
    }

    private static func runInstaller(_ pkg: URL) {
        let quoted = "'" + pkg.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let source = """
        do shell script "/usr/sbin/installer -pkg \(quoted) -target / && /usr/bin/killall coreaudiod" \
        with prompt "MicSwitch wants to install the free BlackHole silent-mic driver." \
        with administrator privileges
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        try? FileManager.default.removeItem(at: pkg)

        if let error {
            // -128 = the user pressed Cancel on the password prompt.
            let cancelled = (error[NSAppleScript.errorNumber] as? Int) == -128
            finish(cancelled ? nil : "Install failed: \(error[NSAppleScript.errorMessage] as? String ?? "unknown error")",
                   cancelled: cancelled)
            return
        }
        waitForDevice(attempts: 30)
    }

    /// Core Audio takes a few seconds to come back after the restart.
    private static func waitForDevice(attempts: Int) {
        if blackHole() != nil {
            Log.write("Driver: installed, device is up")
            finish(nil)
            return
        }
        guard attempts > 0 else {
            finish("The driver was installed but the device didn't appear yet. Restart your Mac, then reopen MicSwitch.")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { waitForDevice(attempts: attempts - 1) }
    }

    private static func finish(_ failure: String?, cancelled: Bool = false) {
        installing = false
        if cancelled { Log.write("Driver: cancelled by user"); return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        if let failure {
            Log.write("Driver: \(failure)")
            alert.messageText = "Couldn't install the driver"
            alert.informativeText = failure + "\n\nYou can also install BlackHole 2ch from its website."
            alert.addButton(withTitle: "Open Website")
            alert.addButton(withTitle: "Close")
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(infoURL) }
        } else {
            HUD.shared.show(micOn: false, title: "Ready", subtitle: "HD sound")
            alert.messageText = "All set 🎧"
            alert.informativeText = "The silent mic driver is installed. Your headset now stays in HD while your mic is off."
            alert.runModal()
        }
    }
}
