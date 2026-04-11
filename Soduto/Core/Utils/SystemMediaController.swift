//
//  SystemMediaController.swift
//  Soduto
//
//  Created by Sannidhya Roy on 11/04/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import Cocoa
import CoreAudio
import MediaRemoteAdapter

/// Controls system-wide media playback in response to call events.
///
/// Tracks whether this controller initiated a pause so it can safely restore
/// playback without interfering with pauses the user (or another process) made
/// independently — e.g. removing headphones, manually pausing before a call.
///
/// Uses `MediaController` from `MediaRemoteAdapter` to send pause/play commands
/// directly to the system media daemon, bypassing NSEvent dispatch.
///
/// Must be called from the main thread.
final class SystemMediaController {
    
    // MARK: - State
    
    /// Whether this controller sent a pause that is still in effect.
    private(set) var pausedByController = false
    
    /// Media controller for sending pause/play commands to mediaremoted.
    /// Created lazily on first use.
    private lazy var mediaController = MediaController()
    
    // MARK: - Public API
    
    /// Pauses media playback if audio output is currently active.
    ///
    /// `pausedByController` is set only when something was actually playing,
    /// so `resume()` will not spuriously start media that was already
    /// stopped before the call began.
    func pause() {
        guard isAudioOutputActive() else { return }
        pausedByController = true
        mediaController.pause()
    }
    
    /// Resumes media playback only if this controller previously paused it.
    func resume() {
        guard pausedByController else { return }
        pausedByController = false
        mediaController.play()
    }
    
    // MARK: - Private
    
    /// Returns `true` if any process is currently producing audio on the
    /// default output device.
    ///
    /// Uses `kAudioDevicePropertyDeviceIsRunningSomewhere` from CoreAudio —
    /// public API, no entitlements required.
    private func isAudioOutputActive() -> Bool {
        var deviceId = AudioDeviceID(kAudioObjectUnknown)
        var hwAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &hwAddress, 0, nil, &size, &deviceId) == noErr, deviceId != kAudioObjectUnknown else { return false }
        
        var isRunning: UInt32 = 0
        var devAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceId, &devAddress, 0, nil, &size, &isRunning) == noErr else { return false }
        
        return isRunning != 0
    }
}
