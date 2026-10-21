// Auto mode: follows Discord's own mute button.
//
// Discord keeps recording from the mic even while muted, so audio alone can't tell
// muted from unmuted. Instead we read the state of Discord's Mute switch through the
// Accessibility API (needs permission once) and combine it with "is Discord in a call"
// (= Discord is recording at all).

import Cocoa
import ApplicationServices
import CoreAudio

private let discordBundlePrefix = "com.hnc.Discord"

/// True when any Discord process (main app or helper) is recording from a mic.
func isDiscordRecording() -> Bool {
    guard #available(macOS 14.0, *) else { return false }
    var list = addr(kAudioHardwarePropertyProcessObjectList)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(systemObject, &list, 0, nil, &size) == noErr else { return false }
    var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(systemObject, &list, 0, nil, &size, &processes) == noErr else { return false }

    for process in processes {
        var running = addr(kAudioProcessPropertyIsRunningInput)
        var value: UInt32 = 0
        var vsize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(process, &running, 0, nil, &vsize, &value) == noErr, value != 0 else { continue }
        if (stringProperty(process, kAudioProcessPropertyBundleID) ?? "").hasPrefix(discordBundlePrefix) { return true }
    }
    return false
}

final class DiscordMuteWatcher {
    /// Called with true when you should be heard (in a call and unmuted), false otherwise.
    var onChange: ((Bool) -> Void)?

    private var timer: Timer?
    private var muteSwitch: AXUIElement?
    private var discordPID: pid_t = 0
    private var lastSearch = Date.distantPast
    private var reported: Bool?
    private var pending: Bool?

    static var hasPermission: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that sends the user to Privacy & Security → Accessibility.
    static func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        reported = nil
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        muteSwitch = nil
        reported = nil
        pending = nil
    }

    /// Discord muted state if we can see its Mute switch, nil if not (yet).
    var discordMuted: Bool? { muteSwitch.flatMap(Self.mutedState) }

    private func poll() {
        guard Self.hasPermission,
              let discord = NSWorkspace.shared.runningApplications.first(where: {
                  $0.bundleIdentifier == discordBundlePrefix
              }) else {
            settle(false)
            return
        }

        if discord.processIdentifier != discordPID {
            discordPID = discord.processIdentifier
            muteSwitch = nil
            // Electron apps only build their accessibility tree when asked.
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(discordPID),
                                         "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }

        if discordMuted == nil, Date().timeIntervalSince(lastSearch) > 3 {
            lastSearch = Date()
            muteSwitch = Self.findMuteSwitch(in: AXUIElementCreateApplication(discordPID))
            Log.write(muteSwitch == nil ? "Discord Mute switch not found yet"
                                        : "Found Discord Mute switch (muted: \(discordMuted.map(String.init) ?? "?"))")
        }

        guard isDiscordRecording() else { settle(false); return }   // not in a call
        guard let muted = discordMuted else { return }               // can't see the switch: leave it to the user
        settle(!muted)
    }

    /// Reports a change only after it holds for two polls, so input switches don't cause flapping.
    private func settle(_ talking: Bool) {
        guard talking != reported else { pending = nil; return }
        if pending == talking {
            reported = talking
            pending = nil
            Log.write("Auto: \(talking ? "Discord unmuted → Mic ON" : "Discord muted / not in call → Mic OFF")")
            onChange?(talking)
        } else {
            pending = talking
        }
    }

    // MARK: Accessibility tree

    private static func attribute(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
    }

    private static func label(_ el: AXUIElement) -> String {
        for name in [kAXDescriptionAttribute, kAXTitleAttribute] {
            if let s = attribute(el, name) as? String, !s.isEmpty { return s }
        }
        return ""
    }

    /// Discord's switch is `aria-label="Mute"` with aria-checked = muted; some versions
    /// relabel it "Unmute" while muted instead.
    static func mutedState(_ el: AXUIElement) -> Bool? {
        switch label(el).lowercased() {
        case "unmute": return true
        case "mute":
            if let n = attribute(el, kAXValueAttribute) as? NSNumber { return n.intValue != 0 }
            return false
        default: return nil   // element gone or relabelled: search again
        }
    }

    private static func findMuteSwitch(in app: AXUIElement) -> AXUIElement? {
        var queue: [AXUIElement] = [app]
        var visited = 0
        while !queue.isEmpty, visited < 25_000 {
            let el = queue.removeFirst()
            visited += 1
            let role = attribute(el, kAXRoleAttribute) as? String ?? ""
            if role == kAXCheckBoxRole || role == kAXButtonRole,
               ["mute", "unmute"].contains(label(el).lowercased()) {
                return el
            }
            if let children = attribute(el, kAXChildrenAttribute) as? [AXUIElement] {
                queue.append(contentsOf: children)
            }
        }
        return nil
    }
}

/// Tiny log at ~/Library/Logs/MicSwitch.log for troubleshooting Auto mode.
enum Log {
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/MicSwitch.log")

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
