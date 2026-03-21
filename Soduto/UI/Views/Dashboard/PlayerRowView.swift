//
//  PlayerRowView.swift
//  Soduto
//
//  Created by Sannidhya Roy on 20/03/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import SwiftUI

struct PlayerRowView: View {
    @ObservedObject var player: PlayerRemote
    @ObservedObject var model: DeviceDashboardModel
    
    @State private var isExpanded: Bool
    @State private var showArtworkPopover = false
    @State private var muteVolume: Int = 0
    
    // Seek pending state
    @State private var seekFraction: Double = 0
    @State private var isDraggingSeek = false
    @State private var pendingSeekPosition: Int? = nil
    @State private var pendingSeekTask: Task<Void, Never>? = nil
    
    // Volume pending state
    @State private var isDraggingVolume = false
    @State private var draggingVolume: Double = 0
    @State private var pendingVolume: Int? = nil
    @State private var pendingVolumeTask: Task<Void, Never>? = nil
    
    // Play/Pause pending state
    @State private var pendingIsPlaying: Bool? = nil
    @State private var pendingIsPlayingTask: Task<Void, Never>? = nil
    
    // Shuffle pending state
    @State private var pendingShuffle: Bool? = nil
    @State private var pendingShuffleTask: Task<Void, Never>? = nil
    
    // Loop pending state
    @State private var pendingLoopStatus: String? = nil
    @State private var pendingLoopTask: Task<Void, Never>? = nil
    
    // Next/Prev in-flight (no value to show — just tracks whether a track change is pending)
    @State private var pendingTrackChange = false
    @State private var pendingTrackTask: Task<Void, Never>? = nil
    
    init(player: PlayerRemote, model: DeviceDashboardModel) {
        self.player = player
        self.model = model
        self._isExpanded = State(initialValue: player.isPlaying)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Collapsed header — always visible, Z-index above controls
            HStack(spacing: 12) {
                // Artwork — clickable for popover
                Button {
                    showArtworkPopover = true
                } label: {
                    albumArtView
                        .frame(width: 48, height: 48)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showArtworkPopover, arrowEdge: .trailing) {
                    artworkPopover
                }
                
                // Title area — clickable to toggle expand/collapse
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                        isExpanded.toggle()
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.displayTitle)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                        let artistAlbum = [player.artist, player.album]
                            .compactMap { s -> String? in s.flatMap { $0.isEmpty ? nil : $0 } }
                            .joined(separator: " • ")
                        if !artistAlbum.isEmpty {
                            Text(artistAlbum)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                
                // Play/pause button (header)
                Button { sendPlayPause() } label: {
                    Image(systemName: effectiveIsPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!player.canPlay && !player.canPause)
                
                // Chevron — also clickable to toggle expand/collapse
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .zIndex(1)
            
            // Expanded controls — slide from under header
            if isExpanded {
                VStack(spacing: 12) {
                    transportControls
                    if player.length > 0 { seekBar }
                    if player.supportsVolume { volumeSlider }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 14)
                .transition(.offset(y: -10).combined(with: .opacity))
            }
        }
        // Confirmation observers — each clears its pending state when the device echoes back the expected value
        .onChange(of: player.isPlaying) { _, newValue in
            if let pending = pendingIsPlaying, newValue == pending {
                pendingIsPlaying = nil
                pendingIsPlayingTask?.cancel()
                pendingIsPlayingTask = nil
            }
            // Auto-expand when playing starts
            if newValue && !isExpanded {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                    isExpanded = true
                }
            }
        }
        .onChange(of: player.volume) { _, newValue in
            if let pending = pendingVolume, newValue == pending {
                pendingVolume = nil
                pendingVolumeTask?.cancel()
                pendingVolumeTask = nil
            }
        }
        .onChange(of: player.shuffle) { _, newValue in
            if let pending = pendingShuffle, newValue == pending {
                pendingShuffle = nil
                pendingShuffleTask?.cancel()
                pendingShuffleTask = nil
            }
        }
        .onChange(of: player.loopStatus) { _, newValue in
            if let pending = pendingLoopStatus, newValue == pending {
                pendingLoopStatus = nil
                pendingLoopTask?.cancel()
                pendingLoopTask = nil
            }
        }
        .onChange(of: player.title) { _, _ in
            // Any track metadata change confirms a pending Next/Prev
            if pendingTrackChange {
                pendingTrackChange = false
                pendingTrackTask?.cancel()
                pendingTrackTask = nil
            }
        }
        .onChange(of: player.position) { _, newValue in
            // Any position update from the device confirms a pending seek
            pendingSeekPosition = nil
            pendingSeekTask?.cancel()
            pendingSeekTask = nil
            // Also confirm Next/Prev when position resets near the start of a new track —
            // handles the edge case where the next track is identical (same title, artist, length)
            if pendingTrackChange && newValue < 2_000 {
                pendingTrackChange = false
                pendingTrackTask?.cancel()
                pendingTrackTask = nil
            }
        }
    }
    
    // MARK: - Subviews
    
    @ViewBuilder
    private var artworkPopover: some View {
        VStack(spacing: 12) {
            albumArtView
                .frame(width: 200, height: 200)
            
            VStack(spacing: 4) {
                Text(player.displayTitle)
                    .font(.headline)
                    .lineLimit(2)
                let artistAlbum = [player.artist, player.album]
                    .compactMap { $0.flatMap { $0.isEmpty ? nil : $0 } }
                    .joined(separator: " • ")
                if !artistAlbum.isEmpty {
                    Text(artistAlbum)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(16)
    }
    
    @ViewBuilder
    private var albumArtView: some View {
        Group {
            if let image = player.albumArtImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .quaternaryLabelColor))
                .opacity(0.3)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
    
    private var transportControls: some View {
        ZStack {
            // Center cluster — always truly centered, unaffected by side buttons
            HStack(spacing: 20) {
                Button { sendPrevious() } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 18))
                }
                .disabled(!player.canGoPrevious)
                
                Button { sendSeek(by: -10) } label: {
                    Image(systemName: "10.arrow.trianglehead.counterclockwise")
                        .font(.system(size: 18))
                }
                .disabled(!player.canSeek)
                
                Button { sendPlayPause() } label: {
                    Image(systemName: effectiveIsPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 38))
                }
                .disabled(!player.canPlay && !player.canPause)
                
                Button { sendSeek(by: 10) } label: {
                    Image(systemName: "10.arrow.trianglehead.clockwise")
                        .font(.system(size: 18))
                }
                .disabled(!player.canSeek)
                
                Button { sendNext() } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 18))
                }
                .disabled(!player.canGoNext)
            }
            
            // Side buttons — float over center layer, never affect its centering
            HStack {
                if player.supportsShuffle {
                    Button { sendShuffle() } label: {
                        Image(systemName: "shuffle")
                            .font(.system(size: 14))
                            .foregroundStyle(effectiveShuffle ? Color.accentColor : Color.secondary)
                    }
                }
                
                Spacer()
                
                Button { sendStop() } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.secondary)
                }
                
                if player.supportsLoopStatus {
                    Button { sendLoop() } label: {
                        Image(systemName: effectiveLoopStatus == "Track" ? "repeat.1" : "repeat")
                            .font(.system(size: 14))
                            .foregroundStyle(effectiveLoopStatus == "None" ? Color.secondary : Color.accentColor)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }
    
    private var seekBar: some View {
        HStack(spacing: 8) {
            TimelineView(.periodic(from: .now, by: 1.0)) { _ in
                Text(formatMs(displaySeekPosition))
                    .contentTransition(.numericText(countsDown: false))
                    .animation(.linear(duration: 0.25), value: displaySeekPosition)
            }
            .frame(width: 36, alignment: .leading)
            .monospacedDigit()
            
            WaveMorphSeekBar(
                positionMs: player.position,
                lengthMs: player.length,
                positionTimestamp: player.timestamp,
                pendingSeekMs: pendingSeekPosition,
                isPlaying: effectiveIsPlaying,
                canSeek: player.canSeek,
                onScrubChanged: { fraction, dragging in
                    seekFraction = fraction
                    isDraggingSeek = dragging
                    if !dragging {
                        sendSeekPosition(Int(fraction * Double(player.length)))
                    }
                }
            )
            .frame(height: 20)
            
            Text(formatMs(player.length))
                .contentTransition(.numericText(countsDown: false))
                .animation(.linear(duration: 0.25), value: player.length)
                .frame(width: 36, alignment: .trailing)
                .monospacedDigit()
        }
        .font(.caption2)
        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
    }
    
    private var volumeSlider: some View {
        let vol = effectiveVolume
        return HStack(spacing: 8) {
            Button {
                if vol == 0 {
                    sendVolume(muteVolume > 0 ? muteVolume : 50)
                } else {
                    muteVolume = vol
                    sendVolume(0)
                }
            } label: {
                Text("Volume")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 44, alignment: .leading)
            
            Button {
                sendVolume(max(0, vol - 5))
            } label: {
                Image(systemName: "speaker.wave.1.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
            
            Slider(
                value: Binding(
                    get: { Double(vol) },
                    set: { v in isDraggingVolume = true; draggingVolume = v }
                ),
                in: 0...100,
                step: 5,
                onEditingChanged: { editing in
                    if !editing {
                        isDraggingVolume = false
                        sendVolume(Int(draggingVolume))
                    }
                }
            )
            
            Button {
                sendVolume(min(100, vol + 5))
            } label: {
                Image(systemName: "speaker.wave.3.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
            
            Text("\(vol)%")
                .font(.caption2)
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                .frame(width: 32, alignment: .trailing)
                .monospacedDigit()
        }
    }
    
    // MARK: - Effective (pending-aware) state
    
    private var displaySeekPosition: Int {
        if let pending = pendingSeekPosition { return pending }
        if isDraggingSeek { return Int(seekFraction * Double(player.length)) }
        return estimatedPositionMs
    }
    
    private var effectiveIsPlaying: Bool { pendingIsPlaying ?? player.isPlaying }
    private var effectiveShuffle: Bool   { pendingShuffle   ?? player.shuffle }
    private var effectiveLoopStatus: String { pendingLoopStatus ?? player.loopStatus }
    private var effectiveVolume: Int {
        isDraggingVolume ? Int(draggingVolume) : (pendingVolume ?? player.volume)
    }
    
    // MARK: - Command Senders
    
    private func sendPlayPause() {
        let newValue = !effectiveIsPlaying
        pendingIsPlaying = newValue
        pendingIsPlayingTask?.cancel()
        pendingIsPlayingTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(3))
                pendingIsPlaying = nil
                pendingIsPlayingTask = nil
                HUDToast.show("Couldn't \(newValue ? "play" : "pause") '\(player.identity)'", style: .error)
            } catch {}
        }
        model.playPause(for: player)
    }
    
    private func sendNext() {
        pendingTrackChange = true
        pendingTrackTask?.cancel()
        pendingTrackTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(3))
                pendingTrackChange = false
                pendingTrackTask = nil
                HUDToast.show("Couldn't skip track on '\(player.identity)'", style: .error)
            } catch {}
        }
        model.next(for: player)
    }
    
    private func sendPrevious() {
        pendingTrackChange = true
        pendingTrackTask?.cancel()
        pendingTrackTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(3))
                pendingTrackChange = false
                pendingTrackTask = nil
                HUDToast.show("Couldn't go back on '\(player.identity)'", style: .error)
            } catch {}
        }
        model.previous(for: player)
    }
    
    private func sendStop() {
        model.stop(for: player)
    }
    
    private func sendSeek(by seconds: Int) {
        let target = max(0, min(player.length, estimatedPositionMs + seconds * 1_000))
        sendSeekPosition(target)
    }
    
    private func sendSeekPosition(_ position: Int) {
        pendingSeekPosition = position
        pendingSeekTask?.cancel()
        pendingSeekTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(3))
                pendingSeekPosition = nil
                pendingSeekTask = nil
                HUDToast.show("Couldn't seek '\(player.identity)' to \(formatMs(position))", style: .error)
            } catch {}
        }
        model.setPosition(position, for: player)
    }
    
    private func sendVolume(_ volume: Int) {
        pendingVolume = volume
        pendingVolumeTask?.cancel()
        pendingVolumeTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(3))
                pendingVolume = nil
                pendingVolumeTask = nil
                HUDToast.show("Couldn't set '\(player.identity)' volume to \(volume)%", style: .error)
            } catch {}
        }
        model.setVolume(volume, for: player)
    }
    
    private func sendShuffle() {
        let newValue = !effectiveShuffle
        pendingShuffle = newValue
        pendingShuffleTask?.cancel()
        pendingShuffleTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(3))
                pendingShuffle = nil
                pendingShuffleTask = nil
                HUDToast.show("Couldn't \(newValue ? "enable" : "disable") shuffle on '\(player.identity)'", style: .error)
            } catch {}
        }
        model.setShuffle(newValue, for: player)
    }
    
    private func sendLoop() {
        let newValue = nextLoopStatus(effectiveLoopStatus)
        pendingLoopStatus = newValue
        pendingLoopTask?.cancel()
        pendingLoopTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(3))
                pendingLoopStatus = nil
                pendingLoopTask = nil
                HUDToast.show("Couldn't set '\(player.identity)' repeat to '\(newValue)'", style: .error)
            } catch {}
        }
        model.setLoopStatus(newValue, for: player)
    }
    
    // MARK: - Helpers
    
    private func nextLoopStatus(_ current: String?) -> String {
        switch current {
        case "None": return "Track"
        case "Track": return "Playlist"
        default: return "None"
        }
    }
    
    private var estimatedPositionMs: Int {
        guard player.isPlaying, player.length > 0 else { return player.position }
        let elapsed = Int(Date().timeIntervalSince(player.timestamp) * 1000)
        return min(player.length, player.position + elapsed)
    }
    
    private func formatMs(_ ms: Int) -> String {
        let s = ms / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Wave Morph Seek Bar

private struct WaveMorphSeekBar: View {
    // Raw playback data — fraction is computed per-frame inside TimelineView for smooth motion
    let positionMs: Int
    let lengthMs: Int
    let positionTimestamp: Date
    let pendingSeekMs: Int?
    let isPlaying: Bool
    let canSeek: Bool
    let onScrubChanged: (_ fraction: Double, _ isDragging: Bool) -> Void
    
    @State private var isHovering = false
    @State private var isDragging = false
    @State private var dragFraction: Double = 0
    // Drag-end: holds last drag position so the bar doesn't flash back to player.position
    // while pendingSeekMs propagates from the parent.  Also suppresses the device echo animation.
    @State private var localPendingFraction: Double? = nil
    // Tap / ±10s button: animates the bar from the pre-tap position to the chosen target.
    // Also suppresses the device echo animation once the animation is done.
    @State private var localSeekTarget: Double? = nil
    
    // Timestamp-based animation state — all visual values are derived from these
    // inside the TimelineView closure, so every frame gets correct interpolated values
    // without relying on withAnimation + @State (which doesn't reliably drive Canvas).
    @State private var interactiveTarget: Bool   = false
    @State private var interactiveFrom: Double   = 0
    @State private var interactiveChangedAt: Date = .distantPast
    @State private var playingTarget: Bool       = false
    @State private var playingFrom: Double       = 0
    @State private var playingChangedAt: Date    = .distantPast
    
    // Seek-snap animation — smoothly blends bar from last visual position to new reported one
    @State private var seekAnimFrom: Double      = 0
    @State private var seekAnimChangedAt: Date   = .distantPast
    // Previous-packet position: used to compute the pre-update visual fraction
    @State private var knownPositionMs: Int      = 0
    @State private var knownTimestamp: Date      = .distantPast
    
    private let restHeight: Double      = 3
    private let playingHeight: Double   = 3.5      // playing but not hovering (between rest and hover)
    private let hoverHeight: Double     = 5
    private let maxAmplitude: Double    = 3.5
    private let waveFreq: Double        = 0.15   // radians per pixel
    private let waveSpeed: Double       = 2.5    // radians per second
    private let taperWidth: Double      = 18     // px to fade wave at each end
    private let thumbRadius: Double     = 5.5
    private let animDuration: Double    = 0.3

    /// True whenever the Canvas needs per-frame updates. When false the TimelineView
    /// is paused so SwiftUI stops scheduling display-link callbacks, dropping energy
    /// use to near zero and halting the stream of CGPath/Metal allocations.
    private var isAnimationActive: Bool {
        // Continuous motion: wave flowing + position advancing
        if isPlaying || isDragging { return true }
        // Hover / playing state transitions still in flight
        let now = Date()
        if interactiveTarget || now.timeIntervalSince(interactiveChangedAt) < animDuration { return true }
        if playingTarget     || now.timeIntervalSince(playingChangedAt)     < animDuration { return true }
        // Seek animations
        if localSeekTarget != nil || localPendingFraction != nil { return true }
        if now.timeIntervalSince(seekAnimChangedAt) < seekAnimDuration { return true }
        return false
    }

    var body: some View {
        GeometryReader { geo in
            let barWidth = geo.size.width

            TimelineView(.animation(paused: !isAnimationActive)) { tl in
                let now              = tl.date
                let phase            = now.timeIntervalSinceReferenceDate * waveSpeed
                let interactiveProg  = eased(from: interactiveFrom, target: interactiveTarget ? 1 : 0,
                                             changedAt: interactiveChangedAt, now: now)
                let playingProg      = eased(from: playingFrom, target: playingTarget ? 1 : 0,
                                             changedAt: playingChangedAt, now: now)
                let fraction         = displayFraction(at: now)
                
                Canvas { ctx, size in
                    renderBar(ctx: ctx, size: size, phase: phase, fraction: fraction,
                              interactiveProg: interactiveProg, playingProg: playingProg)
                }
            }
            .contentShape(Rectangle())
            // Drag gesture: minimumDistance: 3 so genuine taps never enter the drag path.
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { val in
                        guard canSeek else { return }
                        let f = max(0, min(1, val.location.x / barWidth))
                        if !isDragging {
                            isDragging = true
                            setInteraction(true)
                        }
                        dragFraction = f
                        onScrubChanged(f, true)
                    }
                    .onEnded { val in
                        guard canSeek else { return }
                        let f = max(0, min(1, val.location.x / barWidth))
                        dragFraction = f
                        localPendingFraction = f   // hold position until device echoes
                        isDragging = false
                        setInteraction(isHovering)
                        onScrubChanged(f, false)
                    }
            )
            // Tap gesture: fires only when touch ends without significant movement,
            // so isDragging is never set and the animation from resting→target plays cleanly.
            .simultaneousGesture(
                SpatialTapGesture()
                    .onEnded { event in
                        guard canSeek else { return }
                        let f = max(0, min(1, event.location.x / barWidth))
                        let now = Date()
                        let pre: Double
                        if let pending = pendingSeekMs {
                            pre = Double(pending) / Double(max(1, lengthMs))
                        } else if lengthMs > 0 {
                            let elapsedMs = max(0, now.timeIntervalSince(positionTimestamp)) * 1000
                            pre = isPlaying ? min(1, Double(positionMs + Int(elapsedMs)) / Double(lengthMs)) : Double(positionMs) / Double(lengthMs)
                        } else {
                            pre = 0
                        }
                        seekAnimFrom      = pre
                        seekAnimChangedAt = now
                        localSeekTarget   = f
                        onScrubChanged(f, false)
                    }
            )
            .onHover { hovering in
                guard canSeek else { return }
                isHovering = hovering
                setInteraction(hovering || isDragging)
            }
        }
        .onAppear {
            setPlaying(isPlaying, animated: false)
            knownPositionMs = positionMs
            knownTimestamp  = positionTimestamp
        }
        .onChange(of: isPlaying)   { _, playing in setPlaying(playing) }
        .onChange(of: canSeek)     { _, seeking in if !seeking { setInteraction(false) } }
        .onChange(of: pendingSeekMs) { _, newPending in
            guard let newPending else {
                // Device confirmed the seek (pendingSeekMs cleared by parent).
                // Update the reference point to where the bar was showing (tap target or
                // drag endpoint) so that any concurrent positionTimestamp observer starts
                // device animation from the correct visual position, not the old resting one.
                // Handles the rare case where the device replies with a different position.
                if let shown = localSeekTarget ?? localPendingFraction {
                    knownPositionMs = Int(shown * Double(max(1, lengthMs)))
                    knownTimestamp  = Date()
                }
                localSeekTarget      = nil
                localPendingFraction = nil
                seekAnimChangedAt    = .distantPast
                return
            }
            // ±10s seek buttons (or any parent-initiated seek that isn't a drag): animate the thumb.
            // Skip during drag (localPendingFraction is set).
            guard localPendingFraction == nil else { return }
            let targetFraction = Double(newPending) / Double(max(1, lengthMs))
            // Skip if localSeekTarget already points here (e.g. tap already set it)
            if let existing = localSeekTarget, abs(existing - targetFraction) < 0.001 { return }
            let now = Date()
            // Start from wherever the bar currently is (mid-animation or static)
            let current: Double
            if let prior = localSeekTarget {
                let t = min(1.0, max(0.0, now.timeIntervalSince(seekAnimChangedAt)) / seekAnimDuration)
                let curve = 1.0 - pow(1.0 - t, 3.0)
                current = seekAnimFrom + (prior - seekAnimFrom) * curve
            } else if lengthMs > 0 {
                let elapsedMs = max(0, now.timeIntervalSince(positionTimestamp)) * 1000
                current = isPlaying ? min(1, Double(positionMs + Int(elapsedMs)) / Double(lengthMs)) : Double(positionMs) / Double(lengthMs)
            } else {
                current = 0
            }
            seekAnimFrom      = current
            seekAnimChangedAt = now
            localSeekTarget   = targetFraction
        }
        .onChange(of: positionTimestamp) { _, newTimestamp in
            defer {
                knownPositionMs = positionMs
                knownTimestamp  = newTimestamp
            }
            // While a user-initiated seek is in flight, skip device-update animation.
            // localSeekTarget / localPendingFraction are cleared by onChange(of: pendingSeekMs)
            // when pendingSeekMs goes nil — not here — so intermediate packets from the
            // device never interrupt an ongoing tap or drag animation.
            guard localPendingFraction == nil, localSeekTarget == nil else { return }
            // Don't animate while dragging — the bar already tracks the finger
            guard !isDragging, lengthMs > 0 else { return }
            // Visual fraction just before this packet using old reference point
            let elapsed = max(0, newTimestamp.timeIntervalSince(knownTimestamp)) * 1000
            let prevFraction = isPlaying ? min(1, Double(knownPositionMs + Int(elapsed)) / Double(lengthMs)) : Double(knownPositionMs) / Double(max(1, lengthMs))
            let newFraction = Double(positionMs) / Double(max(1, lengthMs))
            // Skip trivially small deltas (position nudge of < 0.2% of track length)
            guard abs(newFraction - prevFraction) > 0.002 else { return }
            seekAnimFrom      = prevFraction
            seekAnimChangedAt = newTimestamp
        }
    }
    
    // MARK: - Per-frame helpers
    
    private let seekAnimDuration: Double = 0.45
    
    private func displayFraction(at now: Date) -> Double {
        if isDragging { return max(0, min(1, dragFraction)) }
        if let local = localPendingFraction { return max(0, min(1, local)) }
        if let target = localSeekTarget {
            // Tap or ±10s: animate from pre-tap position toward chosen target
            let t = min(1.0, max(0.0, now.timeIntervalSince(seekAnimChangedAt)) / seekAnimDuration)
            let curve = 1.0 - pow(1.0 - t, 3.0)
            return seekAnimFrom + (target - seekAnimFrom) * curve
        }
        if let pending = pendingSeekMs {
            return Double(pending) / Double(max(1, lengthMs))
        }
        guard lengthMs > 0 else { return 0 }
        // Live target: where playback actually is right now
        let targetFraction: Double
        if isPlaying {
            let elapsedMs = max(0, now.timeIntervalSince(positionTimestamp)) * 1000
            targetFraction = min(1, Double(positionMs + Int(elapsedMs)) / Double(lengthMs))
        } else {
            targetFraction = Double(positionMs) / Double(lengthMs)
        }
        // Blend from pre-packet visual position toward the live target so position
        // updates animate in rather than snap. targetFraction advances with time
        // during playback, so the blend converges naturally.
        let t = min(1.0, max(0.0, now.timeIntervalSince(seekAnimChangedAt)) / seekAnimDuration)
        guard t < 1.0 else { return targetFraction }
        let curve = 1.0 - pow(1.0 - t, 3.0)
        return seekAnimFrom + (targetFraction - seekAnimFrom) * curve
    }
    
    private func renderBar(ctx: GraphicsContext, size: CGSize, phase: Double, fraction: Double, interactiveProg: Double, playingProg: Double) {
        let w    = size.width
        let h    = size.height
        let midY = h / 2
        
        // Bar height: three levels — rest (paused+no hover), playing (no hover), hover/drag
        // interactive overrides playing entirely; playing contributes only when not interacting
        let combinedProg = max(playingProg, interactiveProg)
        let barH  = restHeight + (playingHeight - restHeight) * playingProg * (1 - interactiveProg) + (hoverHeight   - restHeight) * interactiveProg
        let r     = barH / 2
        let waveAmp = maxAmplitude * playingProg * (1 - interactiveProg)
        let fillX = max(0, min(w, w * fraction))
        
        // 1. Unfilled (right) — flat secondary track, slightly thinner than filled
        let flatH = barH * 0.8
        let flatR = flatH / 2
        if fillX < w {
            let rect = CGRect(x: fillX, y: midY - flatR, width: w - fillX, height: flatH)
            ctx.fill(Path(roundedRect: rect, cornerRadius: flatR), with: .color(Color.secondary.opacity(0.22)))
        }
        
        // 2. Filled (left) — sinusoidal wave when playing, flat accent bar when paused/hovering
        if fillX > 0 {
            if waveAmp > 0.1 {
                // Symmetric taper at both ends ensures the path starts and ends at midY,
                // eliminating the broken joint where the wave meets the thumb.
                var wavePath = Path()
                var x: Double = 0
                while x <= fillX {
                    let amp = waveAmp * min(1, x / taperWidth) * min(1, (fillX - x) / taperWidth)
                    let y   = midY + amp * sin(waveFreq * x + phase)
                    if x == 0 { wavePath.move(to: CGPoint(x: 0, y: y)) }
                    else       { wavePath.addLine(to: CGPoint(x: x, y: y)) }
                    x += 3
                }
                wavePath.addLine(to: CGPoint(x: fillX, y: midY))
                ctx.stroke(wavePath, with: .color(Color.accentColor), style: StrokeStyle(lineWidth: barH, lineCap: .round, lineJoin: .round))
            } else {
                let rect = CGRect(x: 0, y: midY - r, width: fillX, height: barH)
                ctx.fill(Path(roundedRect: rect, cornerRadius: r), with: .color(Color.accentColor))
            }
        }
        
        // 3. Thumb — visible when playing OR hovering/dragging; invisible when paused + no hover
        // combinedProg drives both opacity and radius, so it fades in/out smoothly
        if combinedProg > 0.01 {
            let tr  = thumbRadius * combinedProg
            let tcx = max(tr, min(w - tr, fillX))
            ctx.fill(Path(ellipseIn: CGRect(x: tcx - tr - 1.2, y: midY - tr - 0.4, width: (tr + 1.2) * 2, height: (tr + 0.4) * 2)), with: .color(.black.opacity(0.12 * combinedProg)))
            ctx.fill(Path(ellipseIn: CGRect(x: tcx - tr, y: midY - tr, width: tr * 2, height: tr * 2)), with: .color(.white.opacity(combinedProg)))
        }
    }
    
    // MARK: - Timestamp-based easing
    
    /// Cubic ease-out from `from` toward `target`, starting at `changedAt`.
    private func eased(from: Double, target: Double, changedAt: Date, now: Date) -> Double {
        let t     = min(1, max(0, now.timeIntervalSince(changedAt)) / animDuration)
        let curve = 1 - pow(1 - t, 3)
        return from + (target - from) * curve
    }
    
    private func setInteraction(_ interactive: Bool, animated: Bool = true) {
        guard interactive != interactiveTarget else { return }
        let now = Date()
        interactiveFrom = animated ? eased(from: interactiveFrom, target: interactiveTarget ? 1 : 0, changedAt: interactiveChangedAt, now: now) : (interactive ? 1 : 0)
        interactiveTarget    = interactive
        interactiveChangedAt = animated ? now : .distantPast
    }
    
    private func setPlaying(_ playing: Bool, animated: Bool = true) {
        guard playing != playingTarget else { return }
        let now = Date()
        playingFrom = animated ? eased(from: playingFrom, target: playingTarget ? 1 : 0, changedAt: playingChangedAt, now: now) : (playing ? 1 : 0)
        playingTarget    = playing
        playingChangedAt = animated ? now : .distantPast
    }
}
