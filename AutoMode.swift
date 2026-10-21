// Auto mode: follows the mute button of whatever call app you're in.
//
// Works with Discord, Zoom, Slack huddles, Microsoft Teams, Google Meet (Chrome, Safari,
// Arc, Edge...), FaceTime, Webex and other meeting apps:
//
// 1. The "call app" is the app recording from the mic (with Mic OFF it records silence
//    from BlackHole, so this works before you ever speak).
// 2. Its mute state comes from its Mute/Unmute control, read through the Accessibility
//    API. Many apps keep recording while muted, so audio alone can't tell.
// 3. Apps whose mute control can't be found fall back to "recording = unmuted", which
//    is right for apps that release the mic when you mute (e.g. Google Meet).

import Cocoa
import ApplicationServices
import CoreAudio

/// Regular apps (with a Dock icon) recording from a mic right now. Helper processes are
/// mapped to their app: "com.hnc.Discord.helper.Renderer" → Discord.
func appsRecordingFromAnyMic() -> [NSRunningApplication] {
    guard #available(macOS 14.0, *) else { return [] }
    var list = addr(kAudioHardwarePropertyProcessObjectList)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(systemObject, &list, 0, nil, &size) == noErr else { return [] }
    var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(systemObject, &list, 0, nil, &size, &processes) == noErr else { return [] }

    let apps = NSWorkspace.shared.runningApplications.filter {
        $0.activationPolicy == .regular && $0 != NSRunningApplication.current
    }
    var result: [NSRunningApplication] = []
    for process in processes {
        var running = addr(kAudioProcessPropertyIsRunningInput)
        var value: UInt32 = 0
        var vsize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(process, &running, 0, nil, &vsize, &value) == noErr, value != 0 else { continue }

        var pidAddr = addr(kAudioProcessPropertyPID)
        var pid: pid_t = 0
        var psize = UInt32(MemoryLayout<pid_t>.size)
        AudioObjectGetPropertyData(process, &pidAddr, 0, nil, &psize, &pid)
        let bundleID = stringProperty(process, kAudioProcessPropertyBundleID) ?? ""

        let owner = apps.first { $0.processIdentifier == pid }
            ?? (bundleID.hasPrefix("com.apple.WebKit") ? apps.first { $0.bundleIdentifier == "com.apple.Safari" } : nil)
            ?? apps.filter { bundleID.hasPrefix(($0.bundleIdentifier ?? "\u{0}") + ".") }
                   .max { ($0.bundleIdentifier?.count ?? 0) < ($1.bundleIdentifier?.count ?? 0) }
        if let owner, !result.contains(owner) { result.append(owner) }
    }
    return result
}

final class CallMuteWatcher {
    /// Called with true when you should be heard (in a call and unmuted), false otherwise.
    var onChange: ((Bool) -> Void)?

    private struct Tracked {
        var control: AXUIElement?
        var everFound = false
        var searches = 0
        var lastSearch = Date.distantPast
    }

    private var timer: Timer?
    private var tracked: [pid_t: Tracked] = [:]
    private var reported: Bool?
    private var pending: Bool?
    private var notRecordingSince: Date?
    private let callEndGrace: TimeInterval = 3

    static var hasPermission: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that sends the user to Privacy & Security → Accessibility.
    static func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func start() {
        guard timer == nil else { return }
        reported = nil
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        tracked = [:]
        reported = nil
        pending = nil
        notRecordingSince = nil
    }

    private func poll() {
        let callApps = appsRecordingFromAnyMic()

        // Apps briefly stop recording whenever the input device changes (which we cause
        // ourselves), so only treat it as "left the call" after a few quiet seconds.
        guard !callApps.isEmpty else {
            let since = notRecordingSince ?? Date()
            notRecordingSince = since
            if Date().timeIntervalSince(since) >= callEndGrace {
                tracked = [:]
                settle(false, because: "no app is recording")
            }
            return
        }
        notRecordingSince = nil

        var anyUnmuted = false
        var reasons: [String] = []
        for app in callApps {
            switch muteState(of: app) {
            case .some(let muted):
                if !muted { anyUnmuted = true }
                reasons.append("\(app.localizedName ?? "?") \(muted ? "muted" : "unmuted")")
            case .none:
                // Mute control seen before but not right now (UI re-render): keep the
                // current state rather than guessing.
                if tracked[app.processIdentifier]?.everFound == true { return }
                // Never found one: recording means unmuted.
                if (tracked[app.processIdentifier]?.searches ?? 0) >= 2 || !Self.hasPermission {
                    anyUnmuted = true
                    reasons.append("\(app.localizedName ?? "?") recording (no mute button found)")
                } else {
                    return   // still looking
                }
            }
        }
        settle(anyUnmuted, because: reasons.joined(separator: ", "))
    }

    /// true = muted, false = unmuted, nil = no mute control visible.
    private func muteState(of app: NSRunningApplication) -> Bool? {
        guard Self.hasPermission else { return nil }
        let pid = app.processIdentifier
        var t = tracked[pid] ?? {
            // Electron/Chromium apps only build their accessibility tree when asked.
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid),
                                         "AXManualAccessibility" as CFString, kCFBooleanTrue)
            return Tracked()
        }()

        if let control = t.control, let state = Self.mutedState(control) {
            tracked[pid] = t
            return state
        }
        t.control = nil
        if Date().timeIntervalSince(t.lastSearch) > 3 {
            t.lastSearch = Date()
            t.searches += 1
            t.control = Self.findMuteControl(in: AXUIElementCreateApplication(pid))
            if let control = t.control {
                if !t.everFound {
                    Log.write("Found mute control in \(app.localizedName ?? "?"): “\(Self.label(control))”")
                }
                t.everFound = true
            } else if t.searches == 2 {
                Log.write("No mute control found in \(app.localizedName ?? "?"); using recording state")
            }
        }
        tracked[pid] = t
        return t.control.flatMap(Self.mutedState)
    }

    /// Reports a change only after it holds for two polls, so input switches don't cause flapping.
    private func settle(_ talking: Bool, because reason: String) {
        guard talking != reported else { pending = nil; return }
        if pending == talking {
            reported = talking
            pending = nil
            Log.write("Auto: \(talking ? "Mic ON" : "Mic OFF") (\(reason))")
            onChange?(talking)
        } else {
            pending = talking
        }
    }

    // MARK: Accessibility tree

    /// Label that means "you are unmuted" (the button would mute you).
    static let unmutedLabels: Set<String> = [
        "mute", "mute mic", "mute microphone", "mute audio", "mute my audio", "mute myself",
        "mute yourself", "mute my microphone", "turn off microphone", "turn off mic",
    ]
    /// Label that means "you are muted" (the button would unmute you).
    static let mutedLabels: Set<String> = [
        "unmute", "unmute mic", "unmute microphone", "unmute audio", "unmute my audio", "unmute myself",
        "unmute yourself", "unmute my microphone", "turn on microphone", "turn on mic",
    ]
    private static let controlRoles: Set<String> = [kAXButtonRole, kAXCheckBoxRole, kAXMenuItemRole]

    private static func attribute(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
    }

    static func label(_ el: AXUIElement) -> String {
        for name in [kAXDescriptionAttribute, kAXTitleAttribute] {
            if let s = attribute(el, name) as? String, !s.isEmpty { return s }
        }
        return ""
    }

    /// "Turn off microphone (⌘ + d)" → "turn off microphone"; "Mute ⇧⌘A" → "mute".
    static func normalized(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "\\(.*?\\)", with: "", options: .regularExpression)
        if let cut = s.firstIndex(where: { "⌘⇧⌥⌃".contains($0) }) { s = String(s[..<cut]) }
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased()
    }

    /// true = muted, false = unmuted, nil = not a mute control (or gone).
    static func mutedState(_ el: AXUIElement) -> Bool? {
        let text = normalized(label(el))
        if mutedLabels.contains(text) { return true }
        guard unmutedLabels.contains(text) else { return nil }
        // Discord-style switch: always labelled "Mute", checked while muted.
        if text == "mute", attribute(el, kAXRoleAttribute) as? String == kAXCheckBoxRole,
           let n = attribute(el, kAXValueAttribute) as? NSNumber {
            return n.intValue != 0
        }
        return false
    }

    private static func findMuteControl(in app: AXUIElement) -> AXUIElement? {
        var queue: [AXUIElement] = [app]
        var head = 0
        while head < queue.count, head < 30_000 {
            let el = queue[head]
            head += 1
            if let role = attribute(el, kAXRoleAttribute) as? String, controlRoles.contains(role),
               mutedState(el) != nil {
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
