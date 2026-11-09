import Foundation
import CoreAudio

/// Wyciszenie wyjścia systemu na czas dyktowania (jak `pauseMediaOnDictation`
/// w whistlerze): muzyka i film nie wchodzą do mikrofonu ani nie zagłuszają.
///
/// Przez CoreAudio, bo `osascript` to ~100 ms na start procesu, a wyciszenie
/// ma być z pierwszą sylabą. `osascript` zostaje jako zapas dla urządzeń bez
/// sprzętowego wyciszenia. Odciszamy tylko to, co sami wyciszyliśmy — dźwięk
/// wyciszony wcześniej przez użytkownika zostaje wyciszony.
@MainActor
final class OutputMute {
    private enum Muted { case device(AudioDeviceID), script }
    private var muted: Muted?

    func mute() {
        guard muted == nil else { return }
        if let device = Self.defaultOutput(), let already = Self.isMuted(device) {
            guard !already else { return }
            if Self.setMuted(device, true) { muted = .device(device) }
            return
        }
        if Self.script("output muted of (get volume settings)") == "false",
           Self.script("set volume with output muted") != nil {
            muted = .script
        }
    }

    func restore() {
        switch muted {
        case .device(let device): _ = Self.setMuted(device, false)
        case .script: _ = Self.script("set volume without output muted")
        case nil: return
        }
        muted = nil
    }

    private static func defaultOutput() -> AudioDeviceID? {
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    private static func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                   mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// `nil` = urządzenie nie ma wyciszenia, które dałoby się ustawić.
    private static func isMuted(_ device: AudioDeviceID) -> Bool? {
        var address = muteAddress()
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &address),
              AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    private static func setMuted(_ device: AudioDeviceID, _ on: Bool) -> Bool {
        var address = muteAddress()
        var value: UInt32 = on ? 1 : 0
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    /// Wynik skryptu albo `nil` przy błędzie.
    private static func script(_ source: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
