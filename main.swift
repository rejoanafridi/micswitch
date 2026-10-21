// MicSwitch — menu bar toggle for Bluetooth headsets on macOS.
//
// Works with any Bluetooth headset: TWS earbuds, neckbands, AirPods, over-ears.
//
// Mic OFF (🎧): system input = a silent device (BlackHole, or a muted Mac mic),
//               so the headset stays in A2DP (HD stereo).
// Mic ON  (🎙️): system input = the chosen mic. The headset mic switches the headset
//               to HFP (call mode); a Mac/USB mic keeps HD sound.
//
// Apps (Discord, Meet, Zoom...) must use the "Default" / "System default" input.
// Click the menu bar icon or press Control + Option + M to toggle.

import Cocoa
import CoreAudio
import Carbon.HIToolbox
import ServiceManagement

// MARK: - CoreAudio helpers

let systemObject = AudioObjectID(kAudioObjectSystemObject)

func addr(_ sel: AudioObjectPropertySelector,
          _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
          _ el: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: el)
}

func allDevices() -> [AudioDeviceID] {
    var a = addr(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(systemObject, &a, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(systemObject, &a, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func stringProperty(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
    var a = addr(sel)
    var value: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    let status = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0)
    }
    return status == noErr ? value as String : nil
}

func deviceName(_ id: AudioDeviceID) -> String { stringProperty(id, kAudioObjectPropertyName) ?? "Unknown" }
func deviceUID(_ id: AudioDeviceID) -> String { stringProperty(id, kAudioDevicePropertyDeviceUID) ?? "" }

func transportType(_ id: AudioDeviceID) -> UInt32 {
    var a = addr(kAudioDevicePropertyTransportType)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value)
    return value
}

func isBluetooth(_ id: AudioDeviceID) -> Bool {
    let t = transportType(id)
    return t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
}

/// Virtual / aggregate devices (BlackHole, Zoom's, Teams', ...): never a real microphone.
func isVirtual(_ id: AudioDeviceID) -> Bool {
    let t = transportType(id)
    return t == kAudioDeviceTransportTypeVirtual || t == kAudioDeviceTransportTypeAggregate
        || t == kAudioDeviceTransportTypeAutoAggregate
}

func channelCount(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Int {
    var a = addr(kAudioDevicePropertyStreamConfiguration, scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                               alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func getDefault(_ sel: AudioObjectPropertySelector) -> AudioDeviceID {
    var a = addr(sel)
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(systemObject, &a, 0, nil, &size, &id)
    return id
}

@discardableResult
func setDefault(_ sel: AudioObjectPropertySelector, _ id: AudioDeviceID) -> Bool {
    if getDefault(sel) == id { return true }
    var a = addr(sel)
    var dev = id
    return AudioObjectSetPropertyData(systemObject, &a, 0, nil,
                                      UInt32(MemoryLayout<AudioDeviceID>.size), &dev) == noErr
}

private func isSettable(_ id: AudioDeviceID, _ a: inout AudioObjectPropertyAddress) -> Bool {
    var settable: DarwinBoolean = false
    return AudioObjectHasProperty(id, &a)
        && AudioObjectIsPropertySettable(id, &a, &settable) == noErr && settable.boolValue
}

/// Mutes/unmutes a device's input. Falls back to input volume 0 when there is no mute switch.
final class InputMuter {
    private var savedVolume: [AudioDeviceID: Float32] = [:]

    func set(_ id: AudioDeviceID, muted: Bool) {
        var m = addr(kAudioDevicePropertyMute, kAudioDevicePropertyScopeInput)
        if isSettable(id, &m) {
            var v: UInt32 = muted ? 1 : 0
            AudioObjectSetPropertyData(id, &m, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
            return
        }
        for element in [kAudioObjectPropertyElementMain, 1, 2] {
            var a = addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeInput, element)
            guard isSettable(id, &a) else { continue }
            var size = UInt32(MemoryLayout<Float32>.size)
            if muted {
                var current: Float32 = 0
                AudioObjectGetPropertyData(id, &a, 0, nil, &size, &current)
                if current > 0 { savedVolume[id] = current }
                var zero: Float32 = 0
                AudioObjectSetPropertyData(id, &a, 0, nil, size, &zero)
            } else if let restore = savedVolume[id] {
                var v = restore
                AudioObjectSetPropertyData(id, &a, 0, nil, size, &v)
            }
        }
        if !muted { savedVolume[id] = nil }
    }

    func unmuteAll() { savedVolume.keys.forEach { set($0, muted: false) } }
}

// MARK: - Devices

/// One physical Bluetooth headset. macOS often lists its mic and speaker as two devices
/// that share the Bluetooth address in their UID ("74-05-1D-21-B6-9B:input" / ":output").
struct Headset {
    let key: String
    let name: String
    let output: AudioDeviceID
    let input: AudioDeviceID?
}

func headsetKey(_ id: AudioDeviceID) -> String {
    let uid = deviceUID(id)
    if let colon = uid.lastIndex(of: ":"), colon != uid.startIndex { return String(uid[..<colon]) }
    return uid.isEmpty ? deviceName(id) : uid
}

func connectedHeadsets() -> [Headset] {
    let bt = allDevices().filter(isBluetooth)
    let inputs = bt.filter { channelCount($0, kAudioDevicePropertyScopeInput) > 0 }
    return bt.filter { channelCount($0, kAudioDevicePropertyScopeOutput) > 0 }.map { out in
        let key = headsetKey(out)
        let input = inputs.first { $0 == out } ?? inputs.first { headsetKey($0) == key }
            ?? inputs.first { deviceName($0) == deviceName(out) }
        return Headset(key: key, name: deviceName(out), output: out, input: input)
    }
}

/// Real, non-Bluetooth microphones: built-in, USB, audio interfaces.
func macMicrophones() -> [AudioDeviceID] {
    allDevices().filter {
        !isBluetooth($0) && !isVirtual($0) && channelCount($0, kAudioDevicePropertyScopeInput) > 0
    }
}

func blackHole() -> AudioDeviceID? {
    allDevices().first {
        deviceName($0).localizedCaseInsensitiveContains("BlackHole")
            && channelCount($0, kAudioDevicePropertyScopeInput) > 0
    }
}

func isRunningSomewhere(_ id: AudioDeviceID) -> Bool {
    var a = addr(kAudioDevicePropertyDeviceIsRunningSomewhere)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr && value != 0
}

/// Names of apps recording from `device` right now ("Discord", "zoom.us"...). macOS 14+.
func appsRecording(from device: AudioDeviceID) -> [String] {
    guard #available(macOS 14.0, *) else { return [] }
    var list = addr(kAudioHardwarePropertyProcessObjectList)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(systemObject, &list, 0, nil, &size) == noErr else { return [] }
    var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(systemObject, &list, 0, nil, &size, &processes) == noErr else { return [] }

    var names: [String] = []
    for process in processes {
        var devicesAddr = addr(kAudioProcessPropertyDevices, kAudioObjectPropertyScopeInput)
        var dsize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(process, &devicesAddr, 0, nil, &dsize) == noErr, dsize > 0 else { continue }
        var devices = [AudioObjectID](repeating: 0, count: Int(dsize) / MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(process, &devicesAddr, 0, nil, &dsize, &devices)
        guard devices.contains(device) else { continue }

        var pidAddr = addr(kAudioProcessPropertyPID)
        var pid: pid_t = 0
        var psize = UInt32(MemoryLayout<pid_t>.size)
        AudioObjectGetPropertyData(process, &pidAddr, 0, nil, &psize, &pid)
        // Helpers ("Discord Helper (Renderer)") are reported under the main app's name.
        let raw = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "An app"
        let name = raw.components(separatedBy: " Helper").first ?? raw
        if !names.contains(name) { names.append(name) }
    }
    return names
}

// MARK: - Settings

enum Settings {
    private static let d = UserDefaults.standard
    /// Bluetooth address of the headset the user picked; nil = whatever is playing sound.
    static var headsetKey: String? {
        get { d.string(forKey: "headsetKey") }
        set { d.set(newValue, forKey: "headsetKey") }
    }
    /// UID of the Mac/USB mic to talk with; nil = the headset's own mic.
    /// Follow Discord's own mute button instead of clicking MicSwitch.
    static var autoMode: Bool {
        get { d.bool(forKey: "autoMode") }
        set { d.set(newValue, forKey: "autoMode") }
    }
    static var talkMicUID: String? {
        get { d.string(forKey: "talkMicUID") }
        set { d.set(newValue, forKey: "talkMicUID") }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static var shared: AppDelegate?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let muter = InputMuter()
    private var hotKeyRef: EventHotKeyRef?
    private var micLive = false
    /// Apps that open the headset mic directly (input not set to "Default"), keeping it in call mode.
    private var micGrabbers: [String] = []
    private var warnedGrabbers: Set<String> = []
    private let autoWatcher = DiscordMuteWatcher()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        menu.delegate = self

        registerHotKey()
        watchAudioDevices()
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.checkMicGrabbers() }
        autoWatcher.onChange = { [weak self] talking in
            guard let self, talking != self.micLive else { return }
            if self.apply(live: talking) { self.showHUD() }
        }
        if Settings.autoMode { autoWatcher.start() }
        apply(live: false)
        SetupGuide.showIfFirstLaunch(needsBlackHole: needsBlackHole)
    }

    func applicationWillTerminate(_ notification: Notification) { muter.unmuteAll() }

    // MARK: Picking devices

    private var activeHeadset: Headset? {
        let all = connectedHeadsets()
        if let key = Settings.headsetKey, let picked = all.first(where: { $0.key == key }) { return picked }
        let output = getDefault(kAudioHardwarePropertyDefaultOutputDevice)
        return all.first { $0.output == output } ?? all.first
    }

    /// The mic used for Mic ON, if the user chose a Mac/USB mic and it is plugged in.
    private var talkMic: AudioDeviceID? {
        guard let uid = Settings.talkMicUID else { return nil }
        return macMicrophones().first { deviceUID($0) == uid }
    }

    /// Input used for Mic OFF: BlackHole is truly silent; otherwise a Mac mic (muted).
    private var silentInput: AudioDeviceID? { blackHole() ?? macMicrophones().first }

    private var needsBlackHole: Bool { silentInput == nil }

    // MARK: Switching

    @objc func toggle() {
        if apply(live: !micLive) { showHUD() }
    }

    /// Routes the default input for the requested state. Returns false if it could not.
    @discardableResult
    private func apply(live: Bool, interactive: Bool = true) -> Bool {
        let headset = activeHeadset

        if live {
            if let mic = talkMic {
                muter.set(mic, muted: false)
                setDefault(kAudioHardwarePropertyDefaultInputDevice, mic)
            } else if let input = headset?.input {
                setDefault(kAudioHardwarePropertyDefaultInputDevice, input)
            } else {
                if interactive {
                    alert(headset == nil
                          ? "No Bluetooth headset is connected.\n\nConnect your earbuds or neckband, then try again."
                          : "“\(headset!.name)” has no microphone.\n\nRight-click the menu bar icon → Talk Using, and pick your Mac's microphone.")
                }
                return false
            }
            micLive = true
        } else {
            guard let silent = silentInput else {
                micLive = false
                updateStatusIcon()
                if interactive { SetupGuide.show(needsBlackHole: true) }
                return false
            }
            muter.set(silent, muted: true)
            setDefault(kAudioHardwarePropertyDefaultInputDevice, silent)
            micLive = false
        }

        if interactive, let headset { setDefault(kAudioHardwarePropertyDefaultOutputDevice, headset.output) }
        updateStatusIcon()
        return true
    }

    private var keepsHDWhileTalking: Bool { talkMic != nil }

    private var stateTitle: String { micLive ? "Mic ON" : "Mic OFF" }
    private var stateSubtitle: String {
        let base = !micLive ? "HD sound" : keepsHDWhileTalking ? "HD sound · Mac mic" : "Call mode"
        return Settings.autoMode ? base + " · Auto" : base
    }

    private func showHUD() {
        HUD.shared.show(micOn: micLive, title: stateTitle, subtitle: stateSubtitle)
        NSSound(named: micLive ? "Pop" : "Bottle")?.play()
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        if micLive {
            button.image = micOnBadge()
        } else {
            let image = NSImage(systemSymbolName: "headphones", accessibilityDescription: stateTitle)
            image?.isTemplate = true
            button.image = image
        }
        button.contentTintColor = nil
        button.toolTip = "\(stateTitle) — \(stateSubtitle)\nClick or ⌃⌥M to switch · Right-click for settings"
    }

    /// Green pill with a white mic, like macOS's own orange mic indicator: readable on
    /// light and dark menu bars (a tinted template icon gets dimmed on dark ones).
    private func micOnBadge() -> NSImage {
        let size = NSSize(width: 30, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.systemGreen.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8).fill()
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            if let mic = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                let r = NSRect(x: (rect.width - mic.size.width) / 2, y: (rect.height - mic.size.height) / 2,
                               width: mic.size.width, height: mic.size.height)
                mic.draw(in: r)
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Mic ON"
        return image
    }

    // MARK: Menu bar

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            toggle()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let state = NSMenuItem(title: "\(micLive ? "🎙️" : "🎧")  \(stateTitle) — \(stateSubtitle)",
                               action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        let toggleItem = item(micLive ? "Turn Mic OFF" : "Turn Mic ON", #selector(toggle))
        toggleItem.keyEquivalent = "m"
        toggleItem.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(toggleItem)
        if needsBlackHole {
            menu.addItem(item("⚠️ Install silent mic driver (1 click)…", #selector(installDriver)))
        }
        if !micGrabbers.isEmpty {
            let warning = item("⚠️ \(micGrabbers.joined(separator: ", ")) is keeping your headset in call mode…",
                               #selector(showGrabberHelp))
            menu.addItem(warning)
        }

        menu.addItem(.separator())
        let auto = item("Auto: follow Discord's mute button", #selector(toggleAutoMode))
        auto.state = Settings.autoMode ? .on : .off
        menu.addItem(auto)
        if Settings.autoMode && !DiscordMuteWatcher.hasPermission {
            menu.addItem(item("   ⚠️ Allow Accessibility to finish setup…", #selector(askAccessibility)))
        }

        menu.addItem(.separator())
        menu.addItem(header("Headset"))
        let headsets = connectedHeadsets()
        let active = activeHeadset
        if headsets.isEmpty {
            menu.addItem(header("   No Bluetooth headset connected"))
        }
        for h in headsets {
            let i = item(h.name + (h.input == nil ? "  (no mic)" : ""), #selector(pickHeadset(_:)))
            i.representedObject = h.key
            i.state = h.key == active?.key ? .on : .off
            menu.addItem(i)
        }

        menu.addItem(.separator())
        menu.addItem(header("Talk Using"))
        let headsetMic = item("Headset mic  (call quality)", #selector(pickTalkMic(_:)))
        headsetMic.state = talkMic == nil ? .on : .off
        menu.addItem(headsetMic)
        for mic in macMicrophones() {
            let i = item("\(deviceName(mic))  (keeps HD sound)", #selector(pickTalkMic(_:)))
            i.representedObject = deviceUID(mic)
            i.state = Settings.talkMicUID == deviceUID(mic) ? .on : .off
            menu.addItem(i)
        }

        menu.addItem(.separator())
        if #available(macOS 13.0, *) {
            let login = item("Open at Login", #selector(toggleOpenAtLogin))
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(login)
        }
        menu.addItem(item("Setup Guide…", #selector(showGuide)))
        menu.addItem(item("About MicSwitch", #selector(showAbout)))
        menu.addItem(item("GitHub…", #selector(openGitHub)))
        menu.addItem(.separator())
        let quit = item("Quit MicSwitch", #selector(quit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    private func header(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    @objc private func pickHeadset(_ sender: NSMenuItem) {
        Settings.headsetKey = sender.representedObject as? String
        apply(live: micLive)
    }

    @objc private func pickTalkMic(_ sender: NSMenuItem) {
        if let old = talkMic { muter.set(old, muted: false) }
        Settings.talkMicUID = sender.representedObject as? String
        apply(live: micLive)
    }

    @available(macOS 13.0, *)
    @objc private func toggleOpenAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            alert("Couldn't change Open at Login.\n\nAdd MicSwitch yourself in System Settings → General → Login Items.")
        }
    }

    // MARK: Keeping the routing right

    /// macOS grabs a headset's mic when it connects, and apps sometimes change the default.
    /// Re-apply the current state whenever that happens.
    private func watchAudioDevices() {
        var input = addr(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectAddPropertyListenerBlock(systemObject, &input, .main) { [weak self] _, _ in
            guard let self else { return }
            let current = getDefault(kAudioHardwarePropertyDefaultInputDevice)
            let headsetMicExpected = self.micLive && self.talkMic == nil
            if isBluetooth(current) && !headsetMicExpected {
                self.apply(live: self.micLive, interactive: false)
            }
        }
        var devices = addr(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(systemObject, &devices, .main) { [weak self] _, _ in
            guard let self else { return }
            let wasLive = self.micLive
            // Let macOS finish its own routing for the new/removed device first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard self.micLive == wasLive else { return }
                if !self.apply(live: wasLive, interactive: false), wasLive {
                    self.apply(live: false, interactive: false)   // headset gone: fall back to Mic OFF
                }
            }
        }
    }

    /// MicSwitch only controls the *system default* mic. An app whose input is set straight to
    /// the headset bypasses that, so find it and tell the user how to fix it (once per app).
    private func checkMicGrabbers() {
        let headsetMicExpected = micLive && talkMic == nil
        guard !headsetMicExpected, let input = activeHeadset?.input, isRunningSomewhere(input) else {
            micGrabbers = []
            warnedGrabbers = []
            return
        }
        micGrabbers = appsRecording(from: input)
        if micGrabbers.isEmpty { micGrabbers = ["Another app"] }
        if !Set(micGrabbers).isSubset(of: warnedGrabbers) {
            warnedGrabbers.formUnion(micGrabbers)
            showGrabberHelp()
        }
    }

    // MARK: Auto mode

    @objc private func toggleAutoMode() {
        Settings.autoMode.toggle()
        if Settings.autoMode {
            autoWatcher.start()
            if !DiscordMuteWatcher.hasPermission { askAccessibility() }
        } else {
            autoWatcher.stop()
        }
        updateStatusIcon()
    }

    @objc private func askAccessibility() {
        alert("""
        Auto mode reads Discord's mute button, so MicSwitch needs Accessibility permission (one time).

        Next: System Settings opens → Privacy & Security → Accessibility → turn on “MicSwitch”.

        Auto mode starts by itself as soon as it's allowed. Then just mute/unmute in Discord as usual.
        """)
        DiscordMuteWatcher.requestPermission()
    }

    @objc private func showGrabberHelp() {
        guard let app = micGrabbers.first else { return }
        let headsetName = activeHeadset?.name ?? "your headset"
        alert("""
        \(app) is using “\(headsetName)” as its microphone directly, so the headset is stuck in call mode (low quality) no matter what MicSwitch does.

        Fix it once in \(app):
        Settings → Voice & Video (or Audio) → Input Device → “Default”

        After that, MicSwitch controls the mic and you get HD sound while it's off.
        """)
    }

    // MARK: Hotkey

    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { AppDelegate.shared?.toggle() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x4D535754), id: 1) // 'MSWT'
        RegisterEventHotKey(UInt32(kVK_ANSI_M), UInt32(controlKey | optionKey), id,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    // MARK: Misc

    private func alert(_ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "MicSwitch"
        a.informativeText = text
        a.runModal()
    }

    @objc private func installDriver() { DriverInstaller.install() }

    @objc private func showGuide() { SetupGuide.show(needsBlackHole: needsBlackHole) }

    @objc private func showAbout() {
        let credits = NSAttributedString(
            string: "Keeps any Bluetooth headset in HD (A2DP) while your mic is off.\nClick the menu bar icon or press ⌃⌥M.\n\nby rejoanafridi · rejoanafridi93@gmail.com\nMIT License",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc private func openGitHub() {
        NSWorkspace.shared.open(URL(string: "https://github.com/rejoanafridi/micswitch")!)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

// MARK: - Entry point

if CommandLine.arguments.contains("--list") {
    for id in allDevices() {
        let ins = channelCount(id, kAudioDevicePropertyScopeInput)
        let outs = channelCount(id, kAudioDevicePropertyScopeOutput)
        print("\(deviceName(id)) — in:\(ins) out:\(outs) bluetooth:\(isBluetooth(id)) uid:\(deviceUID(id))")
    }
    for h in connectedHeadsets() {
        print("Headset: \(h.name) [\(h.key)] mic:\(h.input.map { _ in "yes" } ?? "no")")
        if let input = h.input, isRunningSomewhere(input) {
            print("  ⚠️ headset mic in use by: \(appsRecording(from: input).joined(separator: ", "))")
        }
    }
    print("Mac mics: \(macMicrophones().map(deviceName))")
    print("Mic-OFF input: \((blackHole() ?? macMicrophones().first).map(deviceName) ?? "none — install BlackHole")")
    exit(0)
}

// Only one copy at a time (e.g. Login Items + manual launch).
if let bundleID = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
       .contains(where: { $0 != NSRunningApplication.current }) {
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
