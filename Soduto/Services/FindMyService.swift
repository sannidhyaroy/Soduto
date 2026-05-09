//
//  FindMyService.swift
//  Soduto
//
//  Created by Giedrius Stanevičius on 2016-11-20.
//  Copyright © 2016 Soduto. All rights reserved.
//

import Foundation
import AppKit
import AVFoundation
import CoreAudio
import AudioToolbox
import os

/// Find My service: rings the Mac when a paired device sends a request,
/// and sends ring requests to paired devices from the device menu.
public class FindMyService: NSObject, BidirectionalService {

    // MARK: Types

    enum ActionId: ServiceAction.Id {
        case findMy
    }

    // MARK: BidirectionalService

    var userDefaults: UserDefaults = .standard
    let incomingPreferenceKey = AppDefaultsStore.Preferences.Services.FindMy.incomingKey
    let outgoingPreferenceKey = AppDefaultsStore.Preferences.Services.FindMy.outgoingKey

    // MARK: Service properties

    public static let serviceId: Service.Id = "com.soduto.services.findmy"

    public var incomingCapabilities: Set<Service.Capability> {
        incomingEnabled ? [DataPacket.findMyRequestPacketType] : []
    }

    public var outgoingCapabilities: Set<Service.Capability> {
        outgoingEnabled ? [DataPacket.findMyRequestPacketType] : []
    }

    // MARK: Service methods

    public func handleDataPacket(_ dataPacket: DataPacket, fromDevice device: Device, onConnection connection: Connection) -> Bool {
        guard dataPacket.type == DataPacket.findMyRequestPacketType else { return false }
        guard incomingEnabled else { return true }
        if !isRinging {
            startRinging(initiator: device.name)
        }
        return true
    }

    public func setup(for device: Device) {}
    public func cleanup(for device: Device) {}

    public func actions(for device: Device) -> [ServiceAction] {
        guard outgoingEnabled else { return [] }
        guard device.incomingCapabilities.contains(DataPacket.findMyRequestPacketType) else { return [] }
        return [ServiceAction(id: ActionId.findMy.rawValue, title: "Find My Device", description: "Ring the device so you can find it", service: self, device: device)]
    }

    public func performAction(_ id: ServiceAction.Id, forDevice device: Device, userInfo: [String: Any]?) {
        guard let actionId = ActionId(rawValue: id) else { return }
        switch actionId {
        case .findMy:
            send(DataPacket.findMyPacket(), to: device)
        }
    }

    // MARK: Private

    private var isRinging = false
    private var ringTimer: Timer?
    private var audioEngine: AVAudioEngine?
    private var audioPlayer: AVAudioPlayerNode?
    private var windowController: FindMyWindowController?

    // System volume saved before override; -1 means not saved
    private var savedVolume: Float32 = -1
    private var savedMuted: Bool = false

    private func startRinging(initiator: String) {
        isRinging = true
        overrideSystemVolume()
        startAudio()
        showAlert(initiator: initiator)
    }

    func stopRinging() {
        guard isRinging else { return }
        isRinging = false
        stopAudio()
        restoreSystemVolume()
        windowController?.window?.delegate = nil
        windowController?.close()
        windowController = nil
    }

    private func showAlert(initiator: String) {
        windowController = FindMyWindowController.make(initiatorName: initiator) { [weak self] in
            self?.stopRinging()
        }
        windowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Audio

    private func startAudio() {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)

        let sampleRate: Double = 44100
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1.0

        do {
            try engine.start()
        } catch {
            Logger.services.error("FindMyService: audio engine failed to start: \(error, privacy: .public)")
            stopAudio()
            return
        }

        audioEngine = engine
        audioPlayer = player
        scheduleChirp()
        ringTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
            self?.scheduleChirp()
        }
    }

    private func scheduleChirp() {
        guard let player = audioPlayer, let buffer = makeChirpBuffer() else { return }
        player.scheduleBuffer(buffer)
        guard !player.isPlaying else { return }
        player.play()
    }

    /// Generates a 0.35 s ascending chirp (900 Hz → 1800 Hz) with a sine amplitude envelope.
    /// The swept frequency range sits in the 1–2 kHz band where human spatial hearing is sharpest,
    /// making the source easy to locate even through walls.
    private func makeChirpBuffer() -> AVAudioPCMBuffer? {
        let sampleRate: Double = 44100
        let duration: Double = 0.35
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount
        let data = buffer.floatChannelData![0]
        let f0 = 900.0, f1 = 1800.0
        for i in 0..<Int(frameCount) {
            let t = Double(i) / sampleRate
            let p = t / duration
            let phase = 2 * Double.pi * (f0 * t + (f1 - f0) / (2 * duration) * t * t)
            let envelope = Float(sin(p * Double.pi))
            data[i] = envelope * 0.9 * Float(sin(phase))
        }
        return buffer
    }

    private func stopAudio() {
        ringTimer?.invalidate()
        ringTimer = nil
        audioPlayer?.stop()
        audioEngine?.stop()
        audioPlayer = nil
        audioEngine = nil
    }

    // MARK: System Volume

    /// Saves current system output volume and mute state, then sets volume to maximum.
    private func overrideSystemVolume() {
        guard let deviceID = defaultOutputDevice() else { return }

        var volAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<Float32>.size)
        var vol: Float32 = 0
        if AudioObjectGetPropertyData(deviceID, &volAddr, 0, nil, &size, &vol) == noErr {
            savedVolume = vol
        }

        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        var muted: UInt32 = 0
        if AudioObjectGetPropertyData(deviceID, &muteAddr, 0, nil, &muteSize, &muted) == noErr {
            savedMuted = muted != 0
        }

        var fullVol: Float32 = 1.0
        AudioObjectSetPropertyData(deviceID, &volAddr, 0, nil, size, &fullVol)
        if savedMuted {
            var unmuted: UInt32 = 0
            AudioObjectSetPropertyData(deviceID, &muteAddr, 0, nil, muteSize, &unmuted)
        }
    }

    /// Restores the system output volume and mute state saved by `overrideSystemVolume`.
    private func restoreSystemVolume() {
        defer { savedVolume = -1; savedMuted = false }
        guard savedVolume >= 0, let deviceID = defaultOutputDevice() else { return }

        var volAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var vol = savedVolume
        AudioObjectSetPropertyData(deviceID, &volAddr, 0, nil, UInt32(MemoryLayout<Float32>.size), &vol)

        if savedMuted {
            var muteAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain)
            var muted: UInt32 = 1
            AudioObjectSetPropertyData(deviceID, &muteAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &muted)
        }
    }

    private func defaultOutputDevice() -> AudioObjectID? {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }
}

// MARK: - DataPacket (FindMy)

fileprivate extension DataPacket {

    static let findMyRequestPacketType = "kdeconnect.findmyphone.request"

    static func findMyPacket() -> DataPacket {
        return DataPacket(type: findMyRequestPacketType, body: Body())
    }
}
