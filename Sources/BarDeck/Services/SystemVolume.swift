import CoreAudio
import Foundation

/// Reads and writes the default output device's volume, and mirrors changes
/// made elsewhere (keyboard, Control Centre) back into the Touch Bar.
@MainActor
final class SystemVolume {

    /// 'vmvc' — the virtual main volume, the same scalar the F11/F12 keys drive.
    private static let virtualMainVolume: AudioObjectPropertySelector = 0x766D_7663
    private static let muteSelector: AudioObjectPropertySelector = 0x6D75_7465

    var onChange: ((Float, Bool) -> Void)?

    private var deviceID: AudioDeviceID = kAudioObjectUnknown
    private var listeners: [(id: AudioDeviceID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []

    init() {
        refreshDevice()
        observeDefaultDeviceChanges()
    }

    // MARK: - Public state

    var volume: Float {
        get { scalar(for: Self.virtualMainVolume) ?? 0 }
        set { setScalar(max(0, min(1, newValue)), for: Self.virtualMainVolume) }
    }

    var isMuted: Bool {
        get { (integer(for: Self.muteSelector) ?? 0) != 0 }
        set { setInteger(newValue ? 1 : 0, for: Self.muteSelector) }
    }

    func toggleMute() { isMuted.toggle(); emit() }

    // MARK: - Device plumbing

    private func refreshDevice() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &id) == noErr else { return }
        removeDeviceListeners()
        deviceID = id
        addDeviceListeners()
    }

    private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private func scalar(for selector: AudioObjectPropertySelector) -> Float? {
        guard deviceID != kAudioObjectUnknown else { return nil }
        var addr = address(selector)
        guard AudioObjectHasProperty(deviceID, &addr) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private func setScalar(_ value: Float, for selector: AudioObjectPropertySelector) {
        guard deviceID != kAudioObjectUnknown else { return }
        var addr = address(selector)
        guard AudioObjectHasProperty(deviceID, &addr) else { return }
        var v = Float32(value)
        AudioObjectSetPropertyData(deviceID, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        // Raising the slider off zero should also unmute, like the hardware keys do.
        if value > 0 && isMuted { isMuted = false }
    }

    private func integer(for selector: AudioObjectPropertySelector) -> UInt32? {
        guard deviceID != kAudioObjectUnknown else { return nil }
        var addr = address(selector)
        guard AudioObjectHasProperty(deviceID, &addr) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private func setInteger(_ value: UInt32, for selector: AudioObjectPropertySelector) {
        guard deviceID != kAudioObjectUnknown else { return }
        var addr = address(selector)
        guard AudioObjectHasProperty(deviceID, &addr) else { return }
        var v = value
        AudioObjectSetPropertyData(deviceID, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
    }

    // MARK: - Change notifications

    private func emit() { onChange?(volume, isMuted) }

    /// CoreAudio reports after every write, up to ~100 times a second during a fast slide.
    /// Re-reading on each one flooded the main thread, so changes are coalesced to one per 50 ms.
    private var emitScheduled = false
    private func scheduleEmit() {
        guard !emitScheduled else { return }
        emitScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.emitScheduled = false
            self.emit()
        }
    }

    private func addDeviceListeners() {
        for selector in [Self.virtualMainVolume, Self.muteSelector] {
            var addr = address(selector)
            guard AudioObjectHasProperty(deviceID, &addr) else { continue }
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.scheduleEmit() }
            }
            let status = AudioObjectAddPropertyListenerBlock(deviceID, &addr, DispatchQueue.main, block)
            if status == noErr { listeners.append((deviceID, addr, block)) }
        }
    }

    private func removeDeviceListeners() {
        for entry in listeners {
            var address = entry.address
            AudioObjectRemovePropertyListenerBlock(entry.id, &address, DispatchQueue.main, entry.block)
        }
        listeners.removeAll()
    }

    private func observeDefaultDeviceChanges() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.refreshDevice()
                self?.emit()
            }
        }
    }
}
