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
        TimelineView(.periodic(from: .now, by: 1.0)) { _ in
            VStack(spacing: 3) {
                Slider(
                    value: Binding(
                        get: {
                            if isDraggingSeek {
                                return seekFraction
                            } else if let pending = pendingSeekPosition {
                                return Double(pending) / Double(player.length)
                            } else {
                                return estimatedFraction
                            }
                        },
                        set: { v in seekFraction = v; isDraggingSeek = true }
                    ),
                    in: 0...1,
                    onEditingChanged: { editing in
                        if !editing {
                            let newPosition = Int(seekFraction * Double(player.length))
                            isDraggingSeek = false
                            sendSeekPosition(newPosition)
                        }
                    }
                )
                .disabled(!player.canSeek)
                
                HStack {
                    Text(formatMs(displaySeekPosition))
                    Spacer()
                    Text(formatMs(player.length))
                }
                .font(.caption2)
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
            }
        }
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
    
    private var estimatedFraction: Double {
        guard player.length > 0 else { return 0 }
        return Double(estimatedPositionMs) / Double(player.length)
    }
    
    private func formatMs(_ ms: Int) -> String {
        let s = ms / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
