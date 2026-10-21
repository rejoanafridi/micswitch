// MicSwitch — menu bar toggle for Bluetooth headsets on macOS.
//
// Mic OFF (🎧): system input = a non-Bluetooth device (built-in mic or BlackHole),
//               so the headset stays in A2DP (HD stereo).
// Mic ON  (🎙️): system input = the headset mic, so it switches to HFP (mono, with mic).
//
// Apps (Discord, Meet, Zoom...) must use the "Default" / "System default" input.
// Hotkey: Control + Option + M

import Cocoa
import CoreAudio
import Carbon.HIToolbox

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

func deviceName(_ id: AudioDeviceID) -> String {
    var a = addr(kAudioObjectPropertyName)
    var name: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    let status = withUnsafeMutablePointer(to: &name) {
        AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0)
    }
    return status == noErr ? name as String : "?"
}

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
    var a = addr(sel)
    var dev = id
    return AudioObjectSetPropertyData(systemObject, &a, 0, nil,
                                      UInt32(MemoryLayout<AudioDeviceID>.size), &dev) == noErr
}

/// Mutes/unmutes a device's input so the "Mic OFF" device sends pure silence.
func setInputMuted(_ id: AudioDeviceID, _ muted: Bool) {
    var a = addr(kAudioDevicePropertyMute, kAudioDevicePropertyScopeInput)
    var settable: DarwinBoolean = false
    if AudioObjectHasProperty(id, &a),
       AudioObjectIsPropertySettable(id, &a, &settable) == noErr, settable.boolValue {
        var v: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
    }
}

// MARK: - Device selection

let preferredHeadsetName = "Bullets"   // falls back to any Bluetooth headset

func pickBluetooth(_ scope: AudioObjectPropertyScope) -> AudioDeviceID? {
    let bt = allDevices().filter { isBluetooth($0) && channelCount($0, scope) > 0 }
    return bt.first { deviceName($0).localizedCaseInsensitiveContains(preferredHeadsetName) } ?? bt.first
}

/// A non-Bluetooth input: built-in mic first, then BlackHole, then anything else.
func pickSilentInput() -> AudioDeviceID? {
    let inputs = allDevices().filter { !isBluetooth($0) && channelCount($0, kAudioDevicePropertyScopeInput) > 0 }
    return inputs.first { transportType($0) == kAudioDeviceTransportTypeBuiltIn }
        ?? inputs.first { deviceName($0).localizedCaseInsensitiveContains("BlackHole") }
        ?? inputs.first
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let stateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "", action: #selector(toggle), keyEquivalent: "m")
    private var hotKeyRef: EventHotKeyRef?
    private var micLive = false
    private var mutedSilentDevice: AudioDeviceID?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        toggleItem.keyEquivalentModifierMask = [.control, .option]
        toggleItem.target = self
        stateItem.isEnabled = false
        let menu = NSMenu()
        menu.addItem(stateItem)
        menu.addItem(.separator())
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "About MicSwitch", action: #selector(showAbout), keyEquivalent: ""))
        menu.items.last?.target = self
        menu.addItem(NSMenuItem(title: "GitHub…", action: #selector(openGitHub), keyEquivalent: ""))
        menu.items.last?.target = self
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit MicSwitch", action: #selector(quit), keyEquivalent: "q"))
        menu.items.last?.target = self
        statusItem.menu = menu

        registerHotKey()
        watchDefaultInput()
        setMic(live: false, sound: false)
    }

    @objc func toggle() { setMic(live: !micLive, sound: true) }

    private func setMic(live: Bool, sound: Bool) {
        let btOut = pickBluetooth(kAudioDevicePropertyScopeOutput)

        if live {
            guard let btIn = pickBluetooth(kAudioDevicePropertyScopeInput) else {
                alert("Bluetooth headset mic not found. Is the neckband connected?")
                return
            }
            micLive = true
            setDefault(kAudioHardwarePropertyDefaultInputDevice, btIn)
        } else {
            guard let silent = pickSilentInput() else {
                alert("No non-Bluetooth input device found.\n\nThis Mac has no built-in mic. Install the free BlackHole driver, then reopen MicSwitch:\n\nbrew install blackhole-2ch")
                micLive = false
                updateUI()
                return
            }
            micLive = false
            setInputMuted(silent, true)
            mutedSilentDevice = silent
            setDefault(kAudioHardwarePropertyDefaultInputDevice, silent)
        }
        if let btOut { setDefault(kAudioHardwarePropertyDefaultOutputDevice, btOut) }

        updateUI()
        if sound { NSSound(named: live ? "Pop" : "Bottle")?.play() }
    }

    private func updateUI() {
        statusItem.button?.title = micLive ? "🎙️" : "🎧"
        stateItem.title = micLive ? "Mic ON — HFP (call mode)" : "Mic OFF — A2DP (HD sound)"
        toggleItem.title = micLive ? "Turn Mic OFF (HD sound)" : "Turn Mic ON"
    }

    /// macOS often grabs the headset mic on reconnect. While Mic OFF, push it back.
    private func watchDefaultInput() {
        var a = addr(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectAddPropertyListenerBlock(systemObject, &a, .main) { [weak self] _, _ in
            guard let self, !self.micLive else { return }
            if isBluetooth(getDefault(kAudioHardwarePropertyDefaultInputDevice)) {
                self.setMic(live: false, sound: false)
            }
        }
        var d = addr(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(systemObject, &d, .main) { [weak self] _, _ in
            guard let self, !self.micLive else { return }
            // Neckband (re)connected: re-apply Mic OFF after macOS finishes its own routing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if !self.micLive { self.setMic(live: false, sound: false) }
            }
        }
    }

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

    private func alert(_ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "MicSwitch"
        a.informativeText = text
        a.runModal()
    }

    @objc private func showAbout() {
        let credits = NSAttributedString(
            string: "Keeps your Bluetooth headset in HD (A2DP) while the mic is off.\nHotkey: Control + Option + M\n\nby rejoanafridi · rejoanafridi93@gmail.com\nMIT License",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc private func openGitHub() {
        NSWorkspace.shared.open(URL(string: "https://github.com/rejoanafridi/micswitch")!)
    }

    @objc private func quit() {
        if let dev = mutedSilentDevice { setInputMuted(dev, false) }
        NSApp.terminate(nil)
    }
}

// MARK: - Entry point

if CommandLine.arguments.contains("--list") {
    for id in allDevices() {
        let ins = channelCount(id, kAudioDevicePropertyScopeInput)
        let outs = channelCount(id, kAudioDevicePropertyScopeOutput)
        print("\(deviceName(id)) — in:\(ins) out:\(outs) bluetooth:\(isBluetooth(id))")
    }
    print("Headset in : \(pickBluetooth(kAudioDevicePropertyScopeInput).map(deviceName) ?? "none")")
    print("Headset out: \(pickBluetooth(kAudioDevicePropertyScopeOutput).map(deviceName) ?? "none")")
    print("Mic-OFF input: \(pickSilentInput().map(deviceName) ?? "none — install BlackHole")")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
