//
//  SinkRowView.swift
//  Soduto
//
//  Created by Sannidhya Roy on 21/03/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import SwiftUI

struct SinkRowView: View {
    let sink: SystemVolumeService.AudioSink
    let device: DashboardDevice
    @ObservedObject var model: DeviceDashboardModel
    
    @State private var isDragging = false
    @State private var draggingVolume: Double = 0
    
    @State private var pendingVolume: Int? = nil
    @State private var pendingVolumeTask: Task<Void, Never>? = nil
    @State private var pendingMuted: Bool? = nil
    @State private var pendingMuteTask: Task<Void, Never>? = nil
    
    private var effectiveVolumePercent: Int {
        isDragging ? Int(draggingVolume) : (pendingVolume ?? Int(sink.volumePercent * 100))
    }
    
    private var effectiveMuted: Bool { pendingMuted ?? sink.muted }
    
    var body: some View {
        HStack(spacing: 8) {
            // Title — single-click to mute/unmute
            VStack(alignment: .leading, spacing: 2) {
                Text(sink.description.isEmpty ? sink.name : sink.description)
                    .font(.callout)
                    .lineLimit(1)
                if effectiveMuted {
                    Text("Muted")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 80, alignment: .leading)
            .onTapGesture {
                sendMute(!effectiveMuted)
            }
            
            Button {
                sendVolume(max(0, effectiveVolumePercent - 5))
            } label: {
                Image(systemName: effectiveMuted ? "speaker.slash.fill" : "speaker.wave.1.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
            .disabled(effectiveMuted)
            
            Slider(
                value: Binding(
                    get: { Double(effectiveVolumePercent) },
                    set: { v in isDragging = true; draggingVolume = v }
                ),
                in: 0...100,
                step: 5,
                onEditingChanged: { editing in
                    if !editing {
                        isDragging = false
                        sendVolume(Int(draggingVolume))
                    }
                }
            )
            .disabled(effectiveMuted)
            
            Button {
                sendVolume(min(100, effectiveVolumePercent + 5))
            } label: {
                Image(systemName: "speaker.wave.3.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
            .disabled(effectiveMuted)
            
            Text("\(effectiveVolumePercent)%")
                .font(.caption2)
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                .frame(width: 32, alignment: .trailing)
                .monospacedDigit()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .onChange(of: sink.volume) { _, _ in
            let serverPercent = Int(sink.volumePercent * 100)
            if let pending = pendingVolume, serverPercent == pending {
                pendingVolume = nil
                pendingVolumeTask?.cancel()
                pendingVolumeTask = nil
            }
            if !isDragging { draggingVolume = sink.volumePercent * 100 }
        }
        .onChange(of: sink.muted) { _, newValue in
            if let pending = pendingMuted, newValue == pending {
                pendingMuted = nil
                pendingMuteTask?.cancel()
                pendingMuteTask = nil
            }
        }
        .onAppear {
            draggingVolume = sink.volumePercent * 100
        }
    }
    
    private func sendVolume(_ percent: Int) {
        pendingVolume = percent
        pendingVolumeTask?.cancel()
        pendingVolumeTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(3))
                pendingVolume = nil
                pendingVolumeTask = nil
                HUDToast.show("Couldn't set '\(sink.name)' volume to \(percent)%", style: .error)
            } catch {}
        }
        let deviceVolume = Int((Double(percent) / 100.0) * Double(sink.maxVolume))
        model.setSinkVolume(deviceVolume, sink: sink, device: device.device)
    }
    
    private func sendMute(_ muted: Bool) {
        pendingMuted = muted
        pendingMuteTask?.cancel()
        pendingMuteTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(3))
                pendingMuted = nil
                pendingMuteTask = nil
                HUDToast.show("Couldn't \(muted ? "mute" : "unmute") '\(sink.name)'", style: .error)
            } catch {}
        }
        model.systemVolumeService?.setRemoteSinkMuted(muted, sinkName: sink.name, onDevice: device.device)
    }
}
