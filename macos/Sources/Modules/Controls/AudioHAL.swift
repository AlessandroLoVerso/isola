import AudioToolbox
import CoreAudio
import Foundation

/// Piccole funzioni sopra le API `AudioObject` di CoreAudio. Tutto sincrono e veloce.
enum HAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func has(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var a = address
        return AudioObjectHasProperty(object, &a)
    }

    static func isSettable(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var a = address
        guard AudioObjectHasProperty(object, &a) else { return false }
        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(object, &a, &settable) == noErr && settable.boolValue
    }

    static func get<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, as _: T.Type) -> T? {
        var a = address
        guard AudioObjectHasProperty(object, &a) else { return nil }
        var size = UInt32(MemoryLayout<T>.size)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, raw) == noErr,
              size == UInt32(MemoryLayout<T>.size) else { return nil }
        return raw.load(as: T.self)
    }

    @discardableResult
    static func set<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T) -> Bool {
        var a = address
        var v = value
        let size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &v) {
            AudioObjectSetPropertyData(object, &a, 0, nil, size, $0) == noErr
        }
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var a = address(selector)
        guard AudioObjectHasProperty(object, &a) else { return nil }
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &ref) { AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0) }
        guard status == noErr, let ref else { return nil }
        return ref.takeRetainedValue() as String
    }

    // MARK: Dispositivi

    static func defaultDevice(input: Bool) -> AudioObjectID? {
        let sel = input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
        guard let id = get(system, address(sel), as: AudioObjectID.self), id != kAudioObjectUnknown else { return nil }
        return id
    }

    @discardableResult
    static func setDefaultDevice(_ id: AudioObjectID, input: Bool) -> Bool {
        let sel = input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
        return set(system, address(sel), id)
    }

    static func allDevices() -> [AudioObjectID] {
        var a = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    /// Numero di canali del dispositivo nello scope dato (0 = non ha quel verso).
    static func channelCount(_ id: AudioObjectID, input: Bool) -> Int {
        var a = address(kAudioDevicePropertyStreamConfiguration,
                        input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func isHidden(_ id: AudioObjectID) -> Bool {
        (get(id, address(kAudioDevicePropertyIsHidden), as: UInt32.self) ?? 0) != 0
    }

    static func name(_ id: AudioObjectID) -> String {
        string(id, kAudioObjectPropertyName) ?? "Dispositivo"
    }

    static func uid(_ id: AudioObjectID) -> String? {
        string(id, kAudioDevicePropertyDeviceUID)
    }

    // MARK: Volume e muto

    static func scope(input: Bool) -> AudioObjectPropertyScope {
        input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
    }

    static func mainVolumeAddress(input: Bool) -> AudioObjectPropertyAddress {
        address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope(input: input))
    }

    static func muteAddress(input: Bool) -> AudioObjectPropertyAddress {
        address(kAudioDevicePropertyMute, scope(input: input))
    }

    /// Volume "principale" 0...1 (come il cursore del menu di macOS).
    static func mainVolume(_ id: AudioObjectID, input: Bool) -> Float? {
        if let v = get(id, mainVolumeAddress(input: input), as: Float32.self) { return v }
        return get(id, address(kAudioDevicePropertyVolumeScalar, scope(input: input)), as: Float32.self)
    }

    @discardableResult
    static func setMainVolume(_ id: AudioObjectID, input: Bool, _ value: Float) -> Bool {
        let v = Float32(min(max(value, 0), 1))
        if isSettable(id, mainVolumeAddress(input: input)) { return set(id, mainVolumeAddress(input: input), v) }
        let main = address(kAudioDevicePropertyVolumeScalar, scope(input: input))
        if isSettable(id, main) { return set(id, main, v) }
        return false
    }

    static func isMuted(_ id: AudioObjectID, input: Bool) -> Bool? {
        get(id, muteAddress(input: input), as: UInt32.self).map { $0 != 0 }
    }

    static func canMute(_ id: AudioObjectID, input: Bool) -> Bool {
        isSettable(id, muteAddress(input: input))
    }

    @discardableResult
    static func setMuted(_ id: AudioObjectID, input: Bool, _ muted: Bool) -> Bool {
        set(id, muteAddress(input: input), UInt32(muted ? 1 : 0))
    }

    /// Gli elementi del volume scalare impostabili nello scope (0 = principale, poi i canali).
    static func settableVolumeElements(_ id: AudioObjectID, input: Bool) -> [AudioObjectPropertyElement] {
        let channels = channelCount(id, input: input)
        return (0...UInt32(max(channels, 0))).filter {
            isSettable(id, address(kAudioDevicePropertyVolumeScalar, scope(input: input), $0))
        }
    }

    static func volumeScalar(_ id: AudioObjectID, input: Bool, element: AudioObjectPropertyElement) -> Float? {
        get(id, address(kAudioDevicePropertyVolumeScalar, scope(input: input), element), as: Float32.self)
    }

    @discardableResult
    static func setVolumeScalar(_ id: AudioObjectID, input: Bool, element: AudioObjectPropertyElement, _ value: Float) -> Bool {
        set(id, address(kAudioDevicePropertyVolumeScalar, scope(input: input), element), Float32(value))
    }

    /// `true` se un'app qualsiasi sta usando il dispositivo (per il microfono: una chiamata).
    static func isRunningSomewhere(_ id: AudioObjectID) -> Bool {
        (get(id, address(kAudioDevicePropertyDeviceIsRunningSomewhere), as: UInt32.self) ?? 0) != 0
    }
}

/// Un listener CoreAudio (blocco sulla coda principale). `remove()` lo stacca.
final class HALListener {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock
    private var active = false

    init(object: AudioObjectID, address: AudioObjectPropertyAddress, handler: @escaping () -> Void) {
        self.object = object
        self.address = address
        self.block = { _, _ in handler() }
        var a = address
        guard AudioObjectHasProperty(object, &a) else { return }
        active = AudioObjectAddPropertyListenerBlock(object, &a, DispatchQueue.main, block) == noErr
    }

    var isActive: Bool { active }

    func remove() {
        guard active else { return }
        active = false
        AudioObjectRemovePropertyListenerBlock(object, &address, DispatchQueue.main, block)
    }

    deinit { remove() }
}

/// Un dispositivo audio per i menu di scelta.
struct AudioDeviceItem: Identifiable, Equatable {
    let id: AudioObjectID
    let name: String
}
