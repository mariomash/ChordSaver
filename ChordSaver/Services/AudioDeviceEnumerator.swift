import AudioToolbox
import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Hashable {
    /// `0` means system default (no explicit HAL device set on the unit).
    static let defaultDeviceID: AudioDeviceID = 0

    var id: AudioDeviceID { deviceID }
    let deviceID: AudioDeviceID
    let name: String
    let nominalSampleRate: Double
    let inputChannelCount: Int

    var isDefaultPlaceholder: Bool { deviceID == Self.defaultDeviceID }

    static func defaultEntry() -> AudioInputDevice {
        AudioInputDevice(deviceID: defaultDeviceID, name: "System Default", nominalSampleRate: 0, inputChannelCount: 0)
    }
}

enum AudioDeviceEnumerator {
    private static let objectPropertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    static func refreshInputDevices() -> [AudioInputDevice] {
        var addr = objectPropertyAddress
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return [.defaultEntry()] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )
        guard status == noErr else { return [.defaultEntry()] }

        var inputs: [AudioInputDevice] = [.defaultEntry()]
        for id in deviceIDs where id != kAudioDeviceUnknown {
            guard let name = deviceName(id), hasInputStream(id) else { continue }
            let rate = nominalSampleRate(id)
            let ch = inputChannelCount(id)
            guard ch > 0 else { continue }
            inputs.append(AudioInputDevice(deviceID: id, name: name, nominalSampleRate: rate, inputChannelCount: ch))
        }
        return inputs
    }

    private static func deviceName(_ deviceID: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        var cfName: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &cfName) { ptr -> OSStatus in
            AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &dataSize, ptr)
        }
        guard status == noErr, let ref = cfName?.takeRetainedValue() else { return nil }
        return ref as String
    }

    private static func hasInputStream(_ deviceID: AudioDeviceID) -> Bool {
        inputChannelCount(deviceID) > 0
    }

    private static func inputChannelCount(_ deviceID: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &dataSize) == noErr, dataSize > 0 else {
            return 0
        }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &dataSize, raw) == noErr else { return 0 }
        let abl = raw.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func nominalSampleRate(_ deviceID: AudioDeviceID) -> Double {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &rate)
        return status == noErr ? rate : 0
    }
}
