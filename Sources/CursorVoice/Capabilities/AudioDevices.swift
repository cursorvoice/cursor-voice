import Foundation
import CoreAudio

/// Enumerates Core Audio input devices and resolves a saved device UID back to
/// an AudioDeviceID, so the user can pick which microphone Cursor Voice uses.
struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum AudioDevices {

    /// All devices that have at least one input channel.
    static func inputDevices() -> [AudioInputDevice] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return [] }

        var out: [AudioInputDevice] = []
        for id in ids where hasInput(id) && !isAggregate(id) {
            let uid = stringProp(id, kAudioDevicePropertyDeviceUID) ?? ""
            let name = stringProp(id, kAudioObjectPropertyName) ?? "Unknown"
            // Skip Core Audio's internal aggregate/default plumbing devices,
            // whose names are ugly UIDs like "CADefaultDeviceAggregate-…".
            if uid.isEmpty || name.hasPrefix("CADefaultDeviceAggregate") { continue }
            out.append(AudioInputDevice(id: id, uid: uid, name: name))
        }
        return out
    }

    /// True for aggregate / auto-aggregate devices (system plumbing, not real mics).
    private static func isAggregate(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var t: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &t) == noErr else { return false }
        return t == kAudioDeviceTransportTypeAggregate || t == kAudioDeviceTransportTypeAutoAggregate
    }

    /// Resolve a saved UID to its current AudioDeviceID (nil if unplugged).
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        inputDevices().first { $0.uid == uid }?.id
    }

    // MARK: - Private

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return false }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return false }

        let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        var channels = 0
        for buf in abl { channels += Int(buf.mNumberChannels) }
        return channels > 0
    }

    private static func stringProp(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cf: CFString?
        let status = withUnsafeMutablePointer(to: &cf) { ptr -> OSStatus in
            ptr.withMemoryRebound(to: UInt8.self, capacity: Int(size)) { _ in
                AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr)
            }
        }
        guard status == noErr else { return nil }
        return cf as String?
    }
}
