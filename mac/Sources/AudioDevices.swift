import CoreAudio
import Foundation

/// CoreAudio device helpers. Only public CoreAudio API is used.
enum AudioDevices {
    struct Device {
        let id: AudioDeviceID
        let uid: String
        let name: String
    }

    /// All devices that expose at least one input channel.
    static func inputs() -> [Device] {
        allDeviceIDs().compactMap { dev in
            guard inputChannelCount(dev) > 0, let uid = stringProperty(dev, kAudioDevicePropertyDeviceUID) else {
                return nil
            }
            return Device(id: dev, uid: uid, name: stringProperty(dev, kAudioObjectPropertyName) ?? uid)
        }
    }

    /// Finds a device (input or output) by its persistent UID.
    static func id(forUID uid: String) -> AudioDeviceID? {
        guard !uid.isEmpty else { return nil }
        return allDeviceIDs().first { stringProperty($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    /// Name of the current system default input device.
    static func defaultInputName() -> String? {
        guard let dev = defaultDevice(kAudioHardwarePropertyDefaultInputDevice) else { return nil }
        return stringProperty(dev, kAudioObjectPropertyName)
    }

    /// Current system default output device.
    static func defaultOutput() -> AudioDeviceID? {
        defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
    }

    // MARK: - Helpers

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dev: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr,
              dev != kAudioObjectUnknown else { return nil }
        return dev
    }

    private static func stringProperty(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(obj, &addr) else { return nil }
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &ref) == noErr, let cf = ref else { return nil }
        return cf.takeRetainedValue() as String
    }

    private static func inputChannelCount(_ dev: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

/// Mutes the default output device while dictating and restores it exactly.
/// If the device is already muted, or has no settable mute control, nothing is changed.
/// `restore()` only undoes what `mute()` changed. Both are idempotent.
final class AudioDucker {
    private var saved: (device: AudioDeviceID, elements: [(element: UInt32, value: UInt32)])?

    func mute() {
        guard saved == nil, let dev = AudioDevices.defaultOutput() else { return }
        let elements = Self.settableMuteElements(dev)
        guard !elements.isEmpty else { return }

        // Leave the device alone if the user already has it muted.
        var originals: [(element: UInt32, value: UInt32)] = []
        for el in elements {
            guard let value = Self.readMute(dev, el) else { return }
            if value != 0 { return }
            originals.append((el, value))
        }

        var muted: [(element: UInt32, value: UInt32)] = []
        for original in originals where Self.writeMute(dev, original.element, 1) {
            muted.append(original)
        }
        if !muted.isEmpty {
            saved = (dev, muted)
        }
    }

    func restore() {
        guard let state = saved else { return }
        for original in state.elements {
            _ = Self.writeMute(state.device, original.element, original.value)
        }
        saved = nil
    }

    // MARK: - Mute property access

    /// Prefers the master element; falls back to channels 1 and 2 when the master has no settable mute.
    private static func settableMuteElements(_ dev: AudioDeviceID) -> [UInt32] {
        func settable(_ el: UInt32) -> Bool {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: el)
            guard AudioObjectHasProperty(dev, &addr) else { return false }
            var isSettable: DarwinBoolean = false
            return AudioObjectIsPropertySettable(dev, &addr, &isSettable) == noErr && isSettable.boolValue
        }
        if settable(kAudioObjectPropertyElementMain) { return [kAudioObjectPropertyElementMain] }
        return [1, 2].filter(settable)
    }

    private static func readMute(_ dev: AudioDeviceID, _ el: UInt32) -> UInt32? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: el)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    @discardableResult
    private static func writeMute(_ dev: AudioDeviceID, _ el: UInt32, _ value: UInt32) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: el)
        var v = value
        return AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v) == noErr
    }
}
