//
//  SystemMediaController.swift
//  Soduto
//
//  Created by Sannidhya Roy on 11/04/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import Cocoa
import MediaRemoteAdapter
import os

/// Controls system-wide media playback.
///
/// **Singleton** — only one `MediaController` (Perl-based mediaremoted bridge) must
/// exist at a time. Browser media sessions (Arc, Orion, etc.) bind to the most
/// recently started mediaremoted listener and only accept commands from it. A second
/// `MediaController` instance created later (e.g. by `MediaPlayerService`) would steal
/// command routing, making this controller's pause/play invisible to browsers.
/// The singleton ensures exactly one instance exists; `MediaPlayerService` borrows
/// the same `mediaController` instead of creating its own.
///
/// Tracks whether this controller initiated a pause so it can safely restore
/// playback without interfering with pauses the user (or another process) made
/// independently — e.g. removing headphones, manually pausing before a call.
///
/// `isMediaPlaying` is updated on every track-info callback; accurate even when
/// an app holds its audio stream open while paused (which CoreAudio would misread).
/// Listening starts at init so `isMediaPlaying` is already current before any call.
///
/// Must be called from the main thread.
final class SystemMediaController {

    // MARK: - Singleton

    static let shared = SystemMediaController()

    // MARK: - State

    /// Whether this controller sent a pause that is still in effect.
    private(set) var pausedByController = false

    /// Current playback state from mediaremoted.
    private var isMediaPlaying = false

    // MARK: - Shared MediaController

    /// The single `MediaController` instance.
    ///
    /// `MediaPlayerService` borrows this to avoid creating a second simultaneous
    /// listener. Set `trackInfoObserver` and `listenerTerminatedObserver` to hook
    /// into callbacks without replacing the primary handlers.
    let mediaController = MediaController()

    // MARK: - Secondary Observers (used by MediaPlayerService)

    /// Called after `isMediaPlaying` is updated on each track-info callback.
    /// `MediaPlayerService` sets this to forward Mac player state to connected devices.
    var trackInfoObserver: ((TrackInfo?) -> Void)?

    /// Called when the `MediaController` listener terminates (e.g. Apple patches the bypass).
    /// `MediaPlayerService` sets this to send an empty playerList for graceful degradation.
    var listenerTerminatedObserver: (() -> Void)?

    // MARK: - Init

    private init() {
        mediaController.onTrackInfoReceived = { [weak self] trackInfo in
            guard let self else { return }
            self.isMediaPlaying = trackInfo?.payload.isPlaying ?? false
            self.trackInfoObserver?(trackInfo)
        }
        mediaController.onListenerTerminated = { [weak self] in
            guard let self else { return }
            Logger.services.notice("SystemMediaController: MediaController listener terminated; isMediaPlaying reset to false")
            self.isMediaPlaying = false
            self.listenerTerminatedObserver?()
        }
        mediaController.startListening()
    }

    // MARK: - Public API

    /// Pauses media playback only if a media player is currently playing.
    ///
    /// `pausedByController` is set only when something was actually playing,
    /// so `resume()` will not spuriously start media that was already
    /// stopped before the call began (e.g. user manually paused during ringing).
    func pause() {
        guard isMediaPlaying else {
            Logger.services.debug("SystemMediaController::pause — skipped (isMediaPlaying=false)")
            return
        }
        Logger.services.debug("SystemMediaController::pause — media playing, sending pause")
        pausedByController = true
        mediaController.pause()
    }

    /// Resumes media playback only if this controller previously paused it.
    ///
    /// Delayed by 500 ms to let the media system settle after the call ends —
    /// Spotify and other players may briefly deregister from mediaremoted when
    /// paused, and a play command sent at exactly the call-end moment goes nowhere.
    func resume() {
        guard pausedByController else {
            Logger.services.debug("SystemMediaController::resume — skipped (not paused by controller)")
            return
        }
        Logger.services.debug("SystemMediaController::resume — scheduling play in 500 ms")
        pausedByController = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            Logger.services.debug("SystemMediaController::resume — sending play")
            self.mediaController.play()
        }
    }
}
