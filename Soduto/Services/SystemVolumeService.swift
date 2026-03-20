//
//  SystemVolumeService.swift
//  Soduto
//
//  Created by Sannidhya Roy on 20/03/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import Cocoa
import CoreAudio
import os

/// Service implementing the kdeconnect.systemvolume plugin.
///
/// **Outgoing direction** (`outgoingEnabled`) — Mac as exposer:
/// - Receives `kdeconnect.systemvolume.request` from the remote (sink-list requests, volume/mute/default changes)
/// - Sends `kdeconnect.systemvolume` with Mac's CoreAudio output-device list and incremental state updates
///
/// **Incoming direction** (`incomingEnabled`) — Mac as controller:
/// - Receives `kdeconnect.systemvolume` from the remote (their sink list and state changes)
/// - Sends `kdeconnect.systemvolume.request` to request their list or adjust their volume/mute/default
///
/// Remote sink volumes are stored in the scale declared by the sender's `maxVolume` field, which
/// is 100 for macOS/Windows and 65536 for Linux (PulseAudio). Always store and use `maxVolume`
/// per sink when building request packets for a remote device.
public class SystemVolumeService: BidirectionalService, ObservableObject {
    
    // MARK: Types
    
    /// Represents a single audio output sink, either a local CoreAudio device or a remote one
    public struct AudioSink {
        /// Opaque name key used in protocol packets (e.g., `"default-73"` for local sinks)
        public let name: String
        /// Human-readable label (e.g., `"Headphones"`, `"Built-in Speakers"`)
        public var description: String
        /// Volume in `[0, maxVolume]`. Not normalised to 0–100 for remote sinks
        public var volume: Int
        /// Upper bound for `volume`: always 100 for local sinks but may be 65536 for Linux remote sinks
        public let maxVolume: Int
        public var muted: Bool
        /// Whether this is the current default output device
        public var enabled: Bool
        /// CoreAudio device ID. `kAudioObjectUnknown` for remote sinks (not addressable locally)
        let audioDeviceID: AudioDeviceID
        /// True when the device has independently addressable left/right channels
        var isStereo: Bool
        
        /// Volume as a fraction in `[0, 1]`, regardless of `maxVolume` scale.
        public var volumePercent: Double { Double(volume) / Double(maxVolume) }
    }
    
    
    // MARK: Properties
    
    var userDefaults: UserDefaults = .standard
    let incomingPreferenceKey = AppDefaultsStore.Preferences.Services.SystemVolume.incomingKey
    let outgoingPreferenceKey = AppDefaultsStore.Preferences.Services.SystemVolume.outgoingKey
    
    private var kSysObj: AudioObjectID { AudioObjectID(kAudioObjectSystemObject) }
    
    /// Remote sinks keyed by `device.id` → sink name → `AudioSink` (incoming / controller side)
    @Published public private(set) var remoteSinks: [Device.Id: [String: AudioSink]] = [:]
    
    /// Local CoreAudio-backed sinks (outgoing / exposer side)
    private var localSinks: [String: AudioSink] = [:]
    
    /// Reverse lookup: CoreAudio device ID → sink name
    private var sinkNameForDeviceID: [AudioDeviceID: String] = [:]
    
    /// Devices we are pushing local sink updates to
    private var outgoingDevices: [Device] = []
    
    /// Whether system-level CoreAudio listeners are currently registered
    private var isMonitoring: Bool = false
    
    /// Set of per-device AudioDeviceIDs for which we have active property listeners
    private var monitoredDeviceIDs: Set<AudioDeviceID> = []
    
    
    // MARK: Setup / Cleanup
    
    deinit {
        stopMonitoringCoreAudio()
    }
    
    
    // MARK: Service
    
    public static let serviceId: Service.Id = "com.soduto.services.systemvolume"
    
    public var incomingCapabilities: Set<Service.Capability> {
        var caps = Set<Service.Capability>()
        if incomingEnabled { caps.insert(DataPacket.systemVolumePacketType) }
        if outgoingEnabled { caps.insert(DataPacket.systemVolumeRequestPacketType) }
        return caps
    }
    
    public var outgoingCapabilities: Set<Service.Capability> {
        var caps = Set<Service.Capability>()
        if incomingEnabled { caps.insert(DataPacket.systemVolumeRequestPacketType) }
        if outgoingEnabled { caps.insert(DataPacket.systemVolumePacketType) }
        return caps
    }
    
    public func handleDataPacket(_ dataPacket: DataPacket, fromDevice device: Device, onConnection connection: Connection) -> Bool {
        do {
            switch dataPacket.type {
            case DataPacket.systemVolumePacketType:
                // Remote device sent us their sink list or a state update (controller role)
                guard incomingEnabled else { return true }
                try handleIncomingSystemVolume(dataPacket, from: device)
            case DataPacket.systemVolumeRequestPacketType:
                // Remote device is controlling our sinks (exposer role)
                guard outgoingEnabled else { return true }
                try handleIncomingSystemVolumeRequest(dataPacket, from: device)
            default:
                return false
            }
        } catch {
            Logger.services.error("SystemVolume: error handling packet: \(error, privacy: .public)")
        }
        return true
    }
    
    public func setup(for device: Device) {
        // Ask the device for its sink list
        if device.incomingCapabilities.contains(DataPacket.systemVolumeRequestPacketType) {
            request(DataPacket.systemVolumeRequestSinksPacket(), from: device)
        }
        
        // Start monitoring Mac sink list if we're willing to share it with remote device
        guard !outgoingDevices.contains(where: { $0.id == device.id }) else { return }
        if outgoingEnabled && device.incomingCapabilities.contains(DataPacket.systemVolumePacketType) {
            outgoingDevices.append(device)
            // startMonitoringCoreAudio is idempotent and calls rebuildLocalSinksFromCoreAudio internally on first call
            // For subsequent devices localSinks is already populated
            if !isMonitoring {
                startMonitoringCoreAudio()
            }
            sendSinkList(to: device)
        }
    }
    
    public func cleanup(for device: Device) {
        remoteSinks.removeValue(forKey: device.id)
        
        if let index = outgoingDevices.firstIndex(where: { $0.id == device.id }) {
            outgoingDevices.remove(at: index)
            if outgoingDevices.isEmpty {
                stopMonitoringCoreAudio()
            }
        }
    }
    
    public func actions(for device: Device) -> [ServiceAction] { [] }
    
    /// Sets the volume of a remote device's audio sink. Called from the dashboard.
    public func setRemoteSinkVolume(_ volume: Int, sinkName: String, onDevice device: Device) {
        request(DataPacket.systemVolumeSetVolumePacket(name: sinkName, volume: volume), from: device)
    }
    
    /// Mutes or unmutes a remote device's audio sink. Called from the dashboard.
    public func setRemoteSinkMuted(_ muted: Bool, sinkName: String, onDevice device: Device) {
        request(DataPacket.systemVolumeSetMutedPacket(name: sinkName, muted: muted), from: device)
    }
    
    public func performAction(_ id: ServiceAction.Id, forDevice device: Device) {}
    
    
    // MARK: Incoming Packet Handlers
    
    private func handleIncomingSystemVolume(_ packet: DataPacket, from device: Device) throws {
        if packet.hasSinkList() {
            // Full sink list replacement
            let rawList = try packet.getSinkList()
            var sinks: [String: AudioSink] = [:]
            for raw in rawList {
                guard let name = raw[DataPacket.SystemVolumeProperty.name] as? String else { continue }
                let description = raw[DataPacket.SystemVolumeProperty.description] as? String ?? ""
                let maxVolume   = (raw[DataPacket.SystemVolumeProperty.maxVolume] as? NSNumber)?.intValue ?? 100
                let volume      = (raw[DataPacket.SystemVolumeProperty.volume]    as? NSNumber)?.intValue ?? 0
                let muted       = (raw[DataPacket.SystemVolumeProperty.muted]     as? NSNumber)?.boolValue ?? false
                let enabled     = (raw[DataPacket.SystemVolumeProperty.enabled]   as? NSNumber)?.boolValue ?? false
                sinks[name] = AudioSink(name: name, description: description, volume: volume, maxVolume: maxVolume, muted: muted, enabled: enabled, audioDeviceID: kAudioObjectUnknown, isStereo: false)
            }
            remoteSinks[device.id] = sinks
            Logger.services.debug("SystemVolume: received \(sinks.count) sinks from \(device.name, privacy: .public)")
        } else {
            // Incremental single-stream update
            let (name, volume, muted, enabled) = try packet.getIncrementalUpdate()
            if remoteSinks[device.id] == nil { remoteSinks[device.id] = [:] }
            guard var existing = remoteSinks[device.id]?[name] else { return }
            if let v = volume  { existing.volume  = v }
            if let m = muted   { existing.muted   = m }
            if let e = enabled { existing.enabled = e }
            remoteSinks[device.id]?[name] = existing
        }
    }
    
    private func handleIncomingSystemVolumeRequest(_ packet: DataPacket, from device: Device) throws {
        if packet.isRequestingSinks() {
            // Remote asked for a fresh sink list
            rebuildLocalSinksFromCoreAudio()
            sendSinkList(to: device)
            return
        }
        guard let name = packet.getStreamControlName() else { return }
        guard let sink = localSinks[name] else {
            Logger.services.notice("SystemVolume: received request for unknown sink '\(name, privacy: .public)'")
            return
        }
        let (volume, muted, enabled) = packet.getStreamControlFields()
        if let v = volume  { setVolume(v, forSink: sink) }
        if let m = muted   { setMute(m, forSink: sink) }
        // enabled: false is intentionally a no-op (only true triggers a default-device change)
        if let e = enabled, e { setDefaultOutput(sinkName: name) }
        // Note: setVolume does NOT auto-unmute (Linux does this but Windows/macOS of official KDE Connect app do not)
    }
    
    
    // MARK: CoreAudio Monitoring
    
    /// Registers system-level CoreAudio listeners and enumerates current output devices (Idempotent: safe to call multiple times)
    private func startMonitoringCoreAudio() {
        guard !isMonitoring else { return }
        isMonitoring = true
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        
        var devicesAddr = propAddr(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListener(kSysObj, &devicesAddr, svOnDeviceListChanged, ctx)
        
        var defaultAddr = propAddr(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListener(kSysObj, &defaultAddr, svOnDeviceListChanged, ctx)
        
        rebuildLocalSinksFromCoreAudio()
    }
    
    /// Deregisters all CoreAudio listeners and clears the local sink map
    private func stopMonitoringCoreAudio() {
        guard isMonitoring else { return }
        isMonitoring = false
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        
        var devicesAddr = propAddr(kAudioHardwarePropertyDevices)
        AudioObjectRemovePropertyListener(kSysObj, &devicesAddr, svOnDeviceListChanged, ctx)
        
        var defaultAddr = propAddr(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListener(kSysObj, &defaultAddr, svOnDeviceListChanged, ctx)
        
        for deviceId in Array(monitoredDeviceIDs) {
            deregisterPerDeviceListeners(for: deviceId)
        }
        localSinks.removeAll()
    }
    
    /// Re-enumerates all CoreAudio output devices and updates `localSinks`
    /// Deregisters stale per-device listeners and registers new ones
    private func rebuildLocalSinksFromCoreAudio() {
        // Deregister per-device listeners for devices that may no longer exist
        for deviceId in Array(monitoredDeviceIDs) {
            deregisterPerDeviceListeners(for: deviceId)
        }
        localSinks.removeAll()
        sinkNameForDeviceID.removeAll()
        
        for deviceId in getAllOutputDeviceIDs() {
            guard hasOutputStreams(deviceId) else { continue }
            let isStereo = CoreAudioOutputVolume.detectStereo(deviceId)
            guard let volume = readVolume(deviceId: deviceId, isStereo: isStereo) else {
                // Skip devices where volume is completely unreadable (e.g., some virtual devices)
                continue
            }
            let sink = AudioSink(
                name: "default-\(deviceId)",
                description: deviceDescription(deviceId),
                volume: volume,
                maxVolume: 100,
                muted: readMute(deviceId),
                enabled: isDefaultOutput(deviceId),
                audioDeviceID: deviceId,
                isStereo: isStereo)
            localSinks[sink.name] = sink
            sinkNameForDeviceID[deviceId] = sink.name
            registerPerDeviceListeners(for: deviceId)
        }
        Logger.services.debug("SystemVolume: rebuilt local sinks — \(self.localSinks.count) output device(s)")
    }
    
    
    // MARK: Sink Update Senders
    
    private func sendSinkList(to device: Device) {
        let packet = DataPacket.systemVolumeSinkListPacket(sinks: Array(localSinks.values))
        send(packet, to: device)
    }
    
    private func sendSinkListToAll() {
        guard !outgoingDevices.isEmpty else { return }
        let packet = DataPacket.systemVolumeSinkListPacket(sinks: Array(localSinks.values))
        for device in outgoingDevices { send(packet, to: device) }
    }
    
    
    // MARK: CoreAudio Callback Handlers (called on main queue via dispatch)
    
    fileprivate func handleVolumeChanged(for deviceId: AudioObjectID) {
        guard let name = sinkNameForDeviceID[deviceId], let sink = localSinks[name] else { return }
        guard let newVolume = readVolume(deviceId: deviceId, isStereo: sink.isStereo) else { return }
        localSinks[name]?.volume = newVolume
        let packet = DataPacket.systemVolumeStreamUpdatePacket(name: name, volume: newVolume, muted: nil, enabled: nil)
        for device in outgoingDevices { send(packet, to: device) }
    }
    
    fileprivate func handleMuteChanged(for deviceId: AudioObjectID) {
        guard let name = sinkNameForDeviceID[deviceId] else { return }
        let newMuted = readMute(deviceId)
        localSinks[name]?.muted = newMuted
        let packet = DataPacket.systemVolumeStreamUpdatePacket(name: name, volume: nil, muted: newMuted, enabled: nil)
        for device in outgoingDevices { send(packet, to: device) }
    }
    
    fileprivate func handleDeviceListChanged() {
        rebuildLocalSinksFromCoreAudio()
        sendSinkListToAll()
    }
    
    
    // MARK: CoreAudio Per-Device Listener Management
    
    private func registerPerDeviceListeners(for deviceId: AudioDeviceID) {
        guard !monitoredDeviceIDs.contains(deviceId) else { return }
        monitoredDeviceIDs.insert(deviceId)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        
        // Volume: master channel and left/right stereo channels
        for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1, 2] {
            var addr = propAddr(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: element)
            AudioObjectAddPropertyListener(deviceId, &addr, svOnVolumeChanged, ctx)
        }
        // Mute
        var muteAddr = propAddr(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        AudioObjectAddPropertyListener(deviceId, &muteAddr, svOnMuteChanged, ctx)
        // Data source (human-readable description can change, e.g. speakers → headphones)
        var srcAddr = propAddr(kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput)
        AudioObjectAddPropertyListener(deviceId, &srcAddr, svOnDeviceListChanged, ctx)
    }
    
    private func deregisterPerDeviceListeners(for deviceId: AudioDeviceID) {
        guard monitoredDeviceIDs.contains(deviceId) else { return }
        monitoredDeviceIDs.remove(deviceId)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        
        for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1, 2] {
            var addr = propAddr(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: element)
            AudioObjectRemovePropertyListener(deviceId, &addr, svOnVolumeChanged, ctx)
        }
        var muteAddr = propAddr(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        AudioObjectRemovePropertyListener(deviceId, &muteAddr, svOnMuteChanged, ctx)
        var srcAddr = propAddr(kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput)
        AudioObjectRemovePropertyListener(deviceId, &srcAddr, svOnDeviceListChanged, ctx)
    }
    
    
    // MARK: CoreAudio Read / Write Helpers
    
    private func getAllOutputDeviceIDs() -> [AudioDeviceID] {
        var addr = propAddr(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(kSysObj, &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: kAudioObjectUnknown, count: count)
        guard AudioObjectGetPropertyData(kSysObj, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { $0 != kAudioObjectUnknown }
    }
    
    private func hasOutputStreams(_ deviceId: AudioDeviceID) -> Bool {
        var addr = propAddr(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(deviceId, &addr, 0, nil, &size) == noErr && size > 0
    }
    
    /// Returns the current volume as an integer in [0, 100], or nil if the property is unavailable
    private func readVolume(deviceId: AudioDeviceID, isStereo: Bool) -> Int? {
        let element: AudioObjectPropertyElement = isStereo ? 1 : kAudioObjectPropertyElementMain
        var addr = propAddr(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: element)
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(deviceId, &addr, 0, nil, &size, &volume) == noErr else { return nil }
        return Int((volume * 100.0).rounded())
    }
    
    /// Returns the current mute state. Returns false if the property is unavailable
    private func readMute(_ deviceId: AudioDeviceID) -> Bool {
        var addr = propAddr(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceId, &addr, 0, nil, &size, &muted) == noErr else { return false }
        return muted != 0
    }
    
    private func isDefaultOutput(_ deviceId: AudioDeviceID) -> Bool {
        var defaultId: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = propAddr(kAudioHardwarePropertyDefaultOutputDevice)
        guard AudioObjectGetPropertyData(kSysObj, &addr, 0, nil, &size, &defaultId) == noErr else { return false }
        return deviceId == defaultId
    }
    
    private func deviceDescription(_ deviceId: AudioDeviceID) -> String {
        if let name = dataSourceName(deviceId), !name.isEmpty { return name }
        return deviceObjectName(deviceId) ?? ""
    }
    
    /// Translates the device's current data source ID to a human-readable name
    /// (e.g., `"Headphones"`, `"Built-in Speakers"`)
    private func dataSourceName(_ deviceId: AudioDeviceID) -> String? {
        var sourceId: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var sourceAddr = propAddr(kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput)
        guard AudioObjectGetPropertyData(deviceId, &sourceAddr, 0, nil, &size, &sourceId) == noErr else { return nil }
        
        var cfName: Unmanaged<CFString>? = nil
        let result: String? = withUnsafeMutablePointer(to: &sourceId) { inputPtr in
            withUnsafeMutablePointer(to: &cfName) { outputPtr in
                var translation = AudioValueTranslation(mInputData: inputPtr, mInputDataSize: UInt32(MemoryLayout<UInt32>.size), mOutputData: outputPtr, mOutputDataSize: UInt32(MemoryLayout<Unmanaged<CFString>?>.size))
                var nameAddr = propAddr(kAudioDevicePropertyDataSourceNameForIDCFString, scope: kAudioDevicePropertyScopeOutput)
                var translationSize = UInt32(MemoryLayout<AudioValueTranslation>.size)
                guard AudioObjectGetPropertyData(deviceId, &nameAddr, 0, nil, &translationSize, &translation) == noErr, let name = outputPtr.pointee else { return nil }
                return name.takeRetainedValue() as String
            }
        }
        return result
    }
    
    /// Returns the CoreAudio device's own name property (e.g.: `"MacBook Pro Speakers"`)
    private func deviceObjectName(_ deviceId: AudioDeviceID) -> String? {
        var cfName: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var addr = propAddr(kAudioObjectPropertyName, scope: kAudioObjectPropertyScopeGlobal)
        guard AudioObjectGetPropertyData(deviceId, &addr, 0, nil, &size, &cfName) == noErr,
              let name = cfName else { return nil }
        return name.takeRetainedValue() as String
    }
    
    private func setVolume(_ volume: Int, forSink sink: AudioSink) {
        guard sink.audioDeviceID != kAudioObjectUnknown else { return }
        var floatVol = Float32(max(0, min(100, volume))) / 100.0
        let size = UInt32(MemoryLayout<Float32>.size)
        if sink.isStereo {
            var addrL = propAddr(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: 1)
            var addrR = propAddr(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: 2)
            let sL = AudioObjectSetPropertyData(sink.audioDeviceID, &addrL, 0, nil, size, &floatVol)
            let sR = AudioObjectSetPropertyData(sink.audioDeviceID, &addrR, 0, nil, size, &floatVol)
            if sL != noErr || sR != noErr {
                Logger.services.error("SystemVolume: failed to set stereo volume for '\(sink.name, privacy: .public)' (L:\(sL) R:\(sR))")
            }
        } else {
            var addr = propAddr(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput)
            let status = AudioObjectSetPropertyData(sink.audioDeviceID, &addr, 0, nil, size, &floatVol)
            if status != noErr {
                Logger.services.error("SystemVolume: failed to set volume for '\(sink.name, privacy: .public)' (\(status))")
            }
        }
    }
    
    private func setMute(_ muted: Bool, forSink sink: AudioSink) {
        guard sink.audioDeviceID != kAudioObjectUnknown else { return }
        var muteValue: UInt32 = muted ? 1 : 0
        var addr = propAddr(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        let status = AudioObjectSetPropertyData(sink.audioDeviceID, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &muteValue)
        if status != noErr {
            Logger.services.error("SystemVolume: failed to set mute for '\(sink.name, privacy: .public)' (\(status))")
        }
    }
    
    private func setDefaultOutput(sinkName: String) {
        guard let sink = localSinks[sinkName],
              sink.audioDeviceID != kAudioObjectUnknown else { return }
        var deviceId = sink.audioDeviceID
        var addr = propAddr(kAudioHardwarePropertyDefaultOutputDevice)
        let status = AudioObjectSetPropertyData(kSysObj, &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &deviceId)
        if status != noErr {
            Logger.services.error("SystemVolume: failed to set default output to '\(sinkName, privacy: .public)' (\(status))")
        }
    }
    
    /// Convenience shim: delegates to `CoreAudioOutputVolume.propAddr`
    private func propAddr(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        CoreAudioOutputVolume.propAddr(selector, scope: scope, element: element)
    }
}


// MARK: - CoreAudio C Callbacks

// File-scope functions are passed as C function pointers to AudioObjectAddPropertyListener
// CoreAudio invokes them on a private audio HAL thread — always dispatch back to main

private func svOnVolumeChanged(_ objectId: AudioObjectID, _ numAddresses: UInt32, _ addresses: UnsafePointer<AudioObjectPropertyAddress>, _ context: UnsafeMutableRawPointer?) -> OSStatus {
    guard let ctx = context else { return noErr }
    let service = Unmanaged<SystemVolumeService>.fromOpaque(ctx).takeUnretainedValue()
    DispatchQueue.main.async { service.handleVolumeChanged(for: objectId) }
    return noErr
}

private func svOnMuteChanged(_ objectId: AudioObjectID, _ numAddresses: UInt32, _ addresses: UnsafePointer<AudioObjectPropertyAddress>, _ context: UnsafeMutableRawPointer?) -> OSStatus {
    guard let ctx = context else { return noErr }
    let service = Unmanaged<SystemVolumeService>.fromOpaque(ctx).takeUnretainedValue()
    DispatchQueue.main.async { service.handleMuteChanged(for: objectId) }
    return noErr
}

private func svOnDeviceListChanged(_ objectId: AudioObjectID, _ numAddresses: UInt32, _ addresses: UnsafePointer<AudioObjectPropertyAddress>, _ context: UnsafeMutableRawPointer?) -> OSStatus {
    guard let ctx = context else { return noErr }
    let service = Unmanaged<SystemVolumeService>.fromOpaque(ctx).takeUnretainedValue()
    DispatchQueue.main.async { service.handleDeviceListChanged() }
    return noErr
}


// MARK: CoreAudio Output Volume Utilities

/// Stateless helpers for reading and writing the **default system output device's** volume
///
/// Used by `SystemVolumeService` (kdeconnect.systemvolume: no auto-unmute per protocol) and
/// `MediaPlayerService` (MPRIS setVolume: auto-unmute so the volume change is audible)
/// Keeping both callers on the same implementation ensures consistent stereo handling
internal enum CoreAudioOutputVolume {
    
    // MARK: Read
    
    /// Returns the current default output device's volume as an integer in [0, 100]
    /// Stereo-aware: reads left channel (element 1) on devices without a master channel
    /// Returns `fallback` if the device or property is unavailable
    static func readPercent(fallback: Int = 50) -> Int {
        guard let deviceID = defaultDeviceID() else { return fallback }
        let isStereo = detectStereo(deviceID)
        let element: AudioObjectPropertyElement = isStereo ? 1 : kAudioObjectPropertyElementMain
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var a = propAddr(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: element)
        guard AudioObjectGetPropertyData(deviceID, &a, 0, nil, &size, &volume) == noErr else { return fallback }
        return Int((volume * 100.0).rounded())
    }
    
    // MARK: Write
    
    /// Sets the default output device's volume to `percent` [0, 100]
    /// Pass `unmutingIfMuted: true` for MPRIS setVolume (user expects to hear audio immediately)
    /// Pass `false` (the default) for kdeconnect.systemvolume.request, which must not auto-unmute per protocol
    static func write(percent: Int, unmutingIfMuted: Bool = false) {
        guard let deviceID = defaultDeviceID() else { return }
        var floatVol = Float32(max(0, min(100, percent))) / 100.0
        let size = UInt32(MemoryLayout<Float32>.size)
        if detectStereo(deviceID) {
            var addrL = propAddr(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: 1)
            var addrR = propAddr(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: 2)
            AudioObjectSetPropertyData(deviceID, &addrL, 0, nil, size, &floatVol)
            AudioObjectSetPropertyData(deviceID, &addrR, 0, nil, size, &floatVol)
        } else {
            var a = propAddr(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput)
            AudioObjectSetPropertyData(deviceID, &a, 0, nil, size, &floatVol)
        }
        if unmutingIfMuted {
            var mute = UInt32(0)
            var muteAddr = propAddr(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
            // Return value intentionally ignored: mute property is absent on some devices (e.g. aggregate)
            AudioObjectSetPropertyData(deviceID, &muteAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &mute)
        }
    }
    
    // MARK: Private Helpers
    
    private static func defaultDeviceID() -> AudioDeviceID? {
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var a = propAddr(kAudioHardwarePropertyDefaultOutputDevice)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }
    
    internal static func detectStereo(_ deviceID: AudioDeviceID) -> Bool {
        var a = propAddr(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: 1)
        var vol: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(deviceID, &a, 0, nil, &size, &vol) == noErr
    }
    
    internal static func propAddr(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }
}


// MARK: - DataPacket (SystemVolume)

/// System volume plugin data packet utilities
fileprivate extension DataPacket {
    
    // MARK: Types
    
    enum SystemVolumeError: Error {
        case wrongType
        case missingSinkList
        case missingSinkName
    }
    
    struct SystemVolumeProperty {
        static let sinkList     = "sinkList"
        static let name         = "name"
        static let description  = "description"
        static let volume       = "volume"
        static let maxVolume    = "maxVolume"
        static let muted        = "muted"
        static let enabled      = "enabled"
        static let requestSinks = "requestSinks"
    }
    
    
    // MARK: Packet type constants
    
    static let systemVolumePacketType        = "kdeconnect.systemvolume"
    static let systemVolumeRequestPacketType = "kdeconnect.systemvolume.request"
    
    var isSystemVolumePacket:        Bool { type == DataPacket.systemVolumePacketType }
    var isSystemVolumeRequestPacket: Bool { type == DataPacket.systemVolumeRequestPacketType }
    
    
    // MARK: Outgoing packet factories
    
    /// Full sink list packet (sent on connect, after device-list/source changes, or in response to `requestSinks`)
    static func systemVolumeSinkListPacket(sinks: [SystemVolumeService.AudioSink]) -> DataPacket {
        let array = sinks.map { sink -> [String: AnyObject] in [
            SystemVolumeProperty.name:        sink.name as AnyObject,
            SystemVolumeProperty.description: sink.description as AnyObject,
            SystemVolumeProperty.volume:      sink.volume as AnyObject,
            SystemVolumeProperty.maxVolume:   sink.maxVolume as AnyObject,
            SystemVolumeProperty.muted:       sink.muted as AnyObject,
            SystemVolumeProperty.enabled:     sink.enabled as AnyObject,
        ]}
        return DataPacket(type: systemVolumePacketType, body: [
            SystemVolumeProperty.sinkList: array as AnyObject
        ])
    }
    
    /// Incremental single-stream update (sent when only one field changes)
    /// Pass `nil` for fields that have not changed
    static func systemVolumeStreamUpdatePacket(name: String, volume: Int?, muted: Bool?, enabled: Bool?) -> DataPacket {
        var body: [String: AnyObject] = [SystemVolumeProperty.name: name as AnyObject]
        if let v = volume  { body[SystemVolumeProperty.volume]  = v as AnyObject }
        if let m = muted   { body[SystemVolumeProperty.muted]   = m as AnyObject }
        if let e = enabled { body[SystemVolumeProperty.enabled] = e as AnyObject }
        return DataPacket(type: systemVolumePacketType, body: body)
    }
    
    /// Request the remote to send us its sink list
    static func systemVolumeRequestSinksPacket() -> DataPacket {
        DataPacket(type: systemVolumeRequestPacketType, body: [
            SystemVolumeProperty.requestSinks: true as AnyObject
        ])
    }
    
    /// Ask the remote to set the volume of a named sink
    /// `volume` must be in the scale of the sink's `maxVolume` (use `volumePercent * maxVolume`)
    static func systemVolumeSetVolumePacket(name: String, volume: Int) -> DataPacket {
        DataPacket(type: systemVolumeRequestPacketType, body: [
            SystemVolumeProperty.name:   name as AnyObject,
            SystemVolumeProperty.volume: volume as AnyObject,
        ])
    }
    
    /// Ask the remote to mute or unmute a named sink
    static func systemVolumeSetMutedPacket(name: String, muted: Bool) -> DataPacket {
        DataPacket(type: systemVolumeRequestPacketType, body: [
            SystemVolumeProperty.name:  name as AnyObject,
            SystemVolumeProperty.muted: muted as AnyObject,
        ])
    }
    
    /// Ask the remote to make a named sink the default output device
    static func systemVolumeSetDefaultPacket(name: String) -> DataPacket {
        DataPacket(type: systemVolumeRequestPacketType, body: [
            SystemVolumeProperty.name:    name as AnyObject,
            SystemVolumeProperty.enabled: true as AnyObject,
        ])
    }
    
    
    // MARK: Incoming packet parsers
    
    func hasSinkList() -> Bool {
        body[SystemVolumeProperty.sinkList] != nil
    }
    
    func getSinkList() throws -> [[String: Any]] {
        guard isSystemVolumePacket else { throw SystemVolumeError.wrongType }
        guard let raw = body[SystemVolumeProperty.sinkList] as? [[String: Any]] else {
            throw SystemVolumeError.missingSinkList
        }
        return raw
    }
    
    func getIncrementalUpdate() throws -> (name: String, volume: Int?, muted: Bool?, enabled: Bool?) {
        guard isSystemVolumePacket else { throw SystemVolumeError.wrongType }
        guard let name = body[SystemVolumeProperty.name] as? String else {
            throw SystemVolumeError.missingSinkName
        }
        let streamControlFields = getStreamControlFields()
        return (name, streamControlFields.volume, streamControlFields.muted, streamControlFields.enabled)
    }
    
    func isRequestingSinks() -> Bool {
        guard isSystemVolumeRequestPacket else { return false }
        return body[SystemVolumeProperty.requestSinks] as? Bool == true
    }
    
    func getStreamControlName() -> String? {
        guard isSystemVolumeRequestPacket else { return nil }
        return body[SystemVolumeProperty.name] as? String
    }
    
    /// Returns `(volume?, muted?, enabled?)` from either a stream-control request or an incremental update
    func getStreamControlFields() -> (volume: Int?, muted: Bool?, enabled: Bool?) {
        let volume  = (body[SystemVolumeProperty.volume]  as? NSNumber)?.intValue
        let muted   = (body[SystemVolumeProperty.muted]   as? NSNumber)?.boolValue
        let enabled = (body[SystemVolumeProperty.enabled] as? NSNumber)?.boolValue
        return (volume, muted, enabled)
    }
}
