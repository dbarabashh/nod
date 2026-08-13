import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let isDefault: Bool
}

extension [AudioInputDevice] {
    var systemDefaultName: String? {
        first(where: \.isDefault)?.name
    }

    func name(forUID uid: String?) -> String? {
        guard let uid else { return nil }
        return first { $0.uid == uid }?.name
    }
}

enum AudioDeviceCatalog {
    static func inputDevices() -> [AudioInputDevice] {
        let allIDs = enumerateDeviceIDs()
        let defaultID = currentDefaultInputDeviceID()
        var result: [AudioInputDevice] = []
        for id in allIDs {
            guard hasInputStreams(id) else { continue }
            let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) ?? ""
            guard !isPrivateAggregate(id, uid: uid) else { continue }
            let name = stringProperty(id, kAudioObjectPropertyName) ?? "<unnamed>"
            result.append(AudioInputDevice(
                id: id, uid: uid, name: name,
                isDefault: id == defaultID
            ))
        }
        return result
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        for id in enumerateDeviceIDs() {
            if stringProperty(id, kAudioDevicePropertyDeviceUID) == uid,
               hasInputStreams(id), !isPrivateAggregate(id, uid: uid) {
                return id
            }
        }
        return nil
    }

    /// Whether a UID can never name a real microphone again, however long we
    /// wait — as opposed to an unplugged headset, which comes back. The pid
    /// baked into a private aggregate's UID died with the process that made it.
    static func isPrivateAggregateUID(_ uid: String) -> Bool {
        uid.hasPrefix(privateAggregateUIDPrefix)
    }

    static func name(forDeviceID id: AudioDeviceID) -> String? {
        stringProperty(id, kAudioObjectPropertyName)
    }

    /// True for an iPhone/iPad microphone reached via Continuity — macOS can
    /// silently leave one of these as the default input long after the user
    /// stopped using it deliberately, starving the Mac's own mic (and the
    /// user's own voice) for the rest of a recording with no visible sign
    /// why. Checks the deprecated `kAudioDeviceTransportTypeContinuityCapture`
    /// rather than its `...Wired`/`...Wireless` replacements: their minimum
    /// OS wasn't confirmed, while the deprecated constant is available at our
    /// macOS 13.0 deployment target.
    static func isContinuityCapture(_ id: AudioDeviceID) -> Bool {
        transportType(of: id) == kAudioDeviceTransportTypeContinuityCapture
    }

    /// The Mac's own microphone, to fall back to when the system default
    /// turns out to be a Continuity device. Walks device ids directly rather
    /// than `inputDevices()` — that builds a name/UID/default-flag struct for
    /// every device just to throw all of it away except one id.
    static func builtInInputDeviceID() -> AudioDeviceID? {
        for id in enumerateDeviceIDs() where hasInputStreams(id) {
            if transportType(of: id) == kAudioDeviceTransportTypeBuiltIn { return id }
        }
        return nil
    }

    private static func transportType(of id: AudioDeviceID) -> UInt32? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    /// `nil` when there is genuinely no default input (the HAL can transiently
    /// report none — "Could not find default device for dIn") rather than the
    /// old sentinel `0`, so callers don't mistake "unknown" for a real device.
    static func currentDefaultInputDeviceID() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        guard status == noErr, id != 0 else { return nil }
        return id
    }

    // MARK: - Internals

    private static func enumerateDeviceIDs() -> [AudioObjectID] {
        objectList(kAudioHardwarePropertyDevices)
    }

    /// The system object's list of audio objects under `selector` — devices,
    /// processes, whatever the selector names. Same size-probe-then-fetch dance
    /// for all of them.
    static func objectList(_ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static let privateAggregateUIDPrefix = "CADefaultDeviceAggregate"

    /// macOS publishes a private aggregate — `CADefaultDeviceAggregate-<pid>-<n>`
    /// — for every process that opens the default input, so our own capture
    /// creates one the moment a meeting starts. Listing it offered the user a
    /// mirror of the recording they were already in: it appears mid-meeting,
    /// disappears when capture stops, and a preference pointing at it resolves
    /// to nothing afterwards ("Selected microphone isn't available").
    ///
    /// The name gates the check and the composition's private flag decides it.
    /// Neither half is enough alone: the transport type is shared with the
    /// aggregates a user builds in Audio MIDI Setup, which are perfectly real
    /// choices, while reading the composition means asking the HAL to serialize
    /// every sub-device and channel map — far too much to spend on each device
    /// of an enumeration that reruns whenever the machine's audio topology
    /// shifts, which our own capture makes it do.
    private static func isPrivateAggregate(_ id: AudioDeviceID, uid: String) -> Bool {
        guard uid.hasPrefix(privateAggregateUIDPrefix),
              transportType(of: id) == kAudioDeviceTransportTypeAggregate,
              let composition = aggregateComposition(id)
        else { return false }
        let key = kAudioAggregateDeviceIsPrivateKey as String
        return (composition[key] as? NSNumber)?.boolValue == true
    }

    /// Taken *retained* for the same reason as `stringProperty` — the HAL hands
    /// the dictionary back at +1 and the caller owns it.
    private static func aggregateComposition(_ id: AudioDeviceID) -> [String: Any]? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyComposition,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        var value: Unmanaged<CFDictionary>?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as? [String: Any]
    }

    private static func hasInputStreams(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    /// A CFString property of any audio object.
    ///
    /// Taken *retained*: the HAL hands these back at +1, and the caller owns
    /// them. Read on a loop over every audio process on the machine, so an
    /// unbalanced retain here is a steady leak rather than a one-off.
    static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

/// Which processes are recording right now, by bundle identifier.
///
/// `kAudioDevicePropertyDeviceIsRunningSomewhere` — the state behind the orange
/// dot — says only that *someone* is holding the microphone. That was not good
/// enough: it made every running conferencing app look like it was in a call,
/// so Slack, which is open all day, was announced as a call whenever anything
/// else touched the mic. The HAL's process list names the process instead.
enum AudioProcessActivity {
    /// Bundle identifiers with at least one active input stream.
    ///
    /// Empty on macOS 13, where the HAL exposes no process list — the caller
    /// then has only window titles to go on, which is the correct degradation:
    /// fewer detections, never a wrong one.
    static func bundleIDsRecording(excluding ownBundleID: String?) -> Set<String> {
        var recording: Set<String> = []
        for process in AudioDeviceCatalog.objectList(kAudioHardwarePropertyProcessObjectList) {
            guard isRunningInput(process),
                  let bundleID = AudioDeviceCatalog.stringProperty(process, kAudioProcessPropertyBundleID),
                  !bundleID.isEmpty
            else { continue }
            guard bundleID != ownBundleID else { continue }
            recording.insert(bundleID)
        }
        return recording
    }

    private static func isRunningInput(_ process: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(process, &addr, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }
}
