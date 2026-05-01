//
//  WebcamPreviewView.swift
//  Soduto
//
//  Created by Sannidhya Roy on 26/04/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import SwiftUI
import AVFoundation

// MARK: - WebcamPreviewModel

/// Observable state for the webcam preview window.
/// All mutations must happen on the main queue — @Published drives SwiftUI updates.
final class WebcamPreviewModel: ObservableObject {
    
    @Published var cameras: [WebcamCamera] = []
    @Published var zoomLevels: [Float] = []
    @Published var zoomMin: Float = 1.0
    @Published var zoomMax: Float = 1.0
    @Published var currentZoom: Float = 1.0
    @Published var flashAvailable: Bool = false
    @Published var flashActive: Bool = false
    @Published var rotation: Int = 0
    @Published var currentCamera: String = "back"
    
    let displayLayer = AVSampleBufferDisplayLayer()
    
    var onCameraSwitch: ((String) -> Void)?
    var onZoomChange: ((Float) -> Void)?
    var onFlashToggle: ((Bool) -> Void)?
    
    init() {
        displayLayer.videoGravity = .resizeAspect
    }
    
    func pushFrame(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        var formatDesc: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &formatDesc)
        guard let fd = formatDesc else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: now, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescription: fd, sampleTiming: &timing, sampleBufferOut: &sampleBuffer)
        if let sb = sampleBuffer { displayLayer.enqueue(sb) }
    }
    
    func flipCamera() {
        guard cameras.count >= 2 else { return }
        let next: String
        if currentCamera != "front", let front = cameras.first(where: { $0.id == "front" }) {
            next = front.id
        } else if let back = cameras.first(where: { $0.id == "back" }) {
            next = back.id
        } else {
            next = cameras[0].id
        }
        currentCamera = next
        onCameraSwitch?(next)
    }
    
    func toggleFlash() {
        flashActive.toggle()
        onFlashToggle?(flashActive)
    }
}


// MARK: - SampleBufferLayerView

/// Hosts AVSampleBufferDisplayLayer inside SwiftUI.
/// The layer's videoGravity (.resizeAspect) handles aspect-fitting automatically.
private struct SampleBufferLayerView: NSViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer
    
    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.black.cgColor
        
        displayLayer.frame = host.bounds
        displayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        host.layer?.addSublayer(displayLayer)
        
        return host
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {}
}


// MARK: - ZoomControl

/// Three-state zoom control inspired by iOS Camera:
///
/// 1. **Expanded** — all level buttons visible; tap any to snap and collapse
/// 2. **Collapsed** — single button showing current zoom; tap to expand, drag for slider
/// 3. **Slider** — continuous bar with log-scale ticks; release to collapse
///
/// Transitions use `matchedGeometryEffect` for the "water bubble merge/unmerge" feel.
private struct ZoomControl: View {
    let levels: [Float]
    @Binding var currentZoom: Float
    let range: ClosedRange<Float>
    var onChange: ((Float) -> Void)?
    @Binding var active: Bool
    
    private enum Mode { case expanded, collapsed }
    
    @State private var mode: Mode = .expanded
    @State private var isDragging = false
    @State private var livePosition: CGFloat? = nil      // pixel pos on track during drag
    @State private var dragBasePosition: CGFloat = 0     // track position at drag start
    @State private var dragStartTranslation: CGFloat = 0 // gesture translation at recognition
    @State private var collapseTask: Task<Void, Never>?
    @Namespace private var ns
    
    private let bubble = Animation.spring(response: 0.4, dampingFraction: 0.7)
    private let trackWidth: CGFloat = 260
    
    /// Zoom value to display — reads from local drag state when active,
    /// falls back to the binding when idle. This isolates the UI from
    /// external binding mutations (e.g. incoming stream_status packets).
    private var displayZoom: Float {
        if let pos = livePosition {
            return clamp(zoomFromPosition(pos, in: trackWidth))
        }
        return currentZoom
    }
    
    var body: some View {
        ZStack {
            if mode == .expanded {
                expandedView
            } else {
                collapsedOrSliderView
            }
        }
        .onAppear {
            active = (mode == .expanded) || isDragging
            scheduleCollapse()
        }
        .onDisappear { collapseTask?.cancel() }
        .onChange(of: mode) { _, new in active = (new == .expanded) || isDragging }
        .onChange(of: isDragging) { _, new in active = (mode == .expanded) || new }
    }
    
    // MARK: Expanded — all level buttons
    
    /// Fixed optical levels plus a temporary entry for the current zoom
    /// when it sits between fixed levels (e.g. 3.8× between 2× and 5×).
    private var expandedLevels: [Float] {
        let zoom = displayZoom
        if levels.contains(where: { isNear($0, zoom) }) { return levels }
        return (levels + [zoom]).sorted()
    }
    
    private var expandedView: some View {
        HStack(spacing: 0) {
            ForEach(expandedLevels, id: \.self) { level in
                let active = isNear(displayZoom, level)
                Text(zoomLabel(level))
                    .font(.system(size: 13, weight: active ? .bold : .medium, design: .rounded))
                    .foregroundStyle(active ? Color.yellow : Color.white)
                    .frame(minWidth: 40, minHeight: 32)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        currentZoom = level
                        onChange?(level)
                        collapseTask?.cancel()
                        withAnimation(bubble) { mode = .collapsed }
                    }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(.black.opacity(0.55))
                .matchedGeometryEffect(id: "zoomPill", in: ns)
        )
    }
    
    // MARK: Collapsed + Slider
    
    /// Both views live in a single ZStack so the drag gesture stays alive
    /// when the slider scales in and the button scales out.
    private var collapsedOrSliderView: some View {
        ZStack {
            if isDragging {
                sliderBar
                    .transition(.scale(scale: 0.1).combined(with: .opacity))
            }
            
            collapsedButton
                .scaleEffect(isDragging ? 0.5 : 1)
                .opacity(isDragging ? 0 : 1)
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !isDragging {
                        guard abs(value.translation.width) > 5 else { return }
                        let pos = logPosition(currentZoom, in: trackWidth)
                        dragBasePosition = pos
                        dragStartTranslation = value.translation.width
                        livePosition = pos
                        withAnimation(bubble) { isDragging = true }
                        return
                    }
                    let delta = value.translation.width - dragStartTranslation
                    let newPos = min(trackWidth, max(0, dragBasePosition + delta))
                    livePosition = newPos
                    let zoom = clamp(zoomFromPosition(newPos, in: trackWidth))
                    currentZoom = zoom
                    onChange?(zoom)
                }
                .onEnded { _ in
                    if isDragging {
                        withAnimation(bubble) { isDragging = false }
                        livePosition = nil
                    } else {
                        withAnimation(bubble) { mode = .expanded }
                        scheduleCollapse()
                    }
                }
        )
    }
    
    private var collapsedButton: some View {
        Text(zoomLabel(displayZoom))
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(Color.yellow)
            .frame(minWidth: 44, minHeight: 32)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(.black.opacity(0.55))
                    .matchedGeometryEffect(id: "zoomPill", in: ns)
            )
    }
    
    // MARK: Slider bar
    
    private var sliderBar: some View {
        ZStack {
            // Track line
            Capsule()
                .fill(.white.opacity(0.15))
                .frame(width: trackWidth, height: 2)
            
            // Tick marks at each level
            ForEach(levels, id: \.self) { level in
                let x = logPosition(level, in: trackWidth) - trackWidth / 2
                let active = isNear(displayZoom, level)
                Circle()
                    .fill(active ? Color.yellow.opacity(0.8) : .white.opacity(0.4))
                    .frame(width: active ? 6 : 4, height: active ? 6 : 4)
                    .offset(x: x)
            }
            
            // Draggable knob + floating label
            let knobX = (livePosition ?? logPosition(currentZoom, in: trackWidth)) - trackWidth / 2
            VStack(spacing: 4) {
                Text(zoomLabel(displayZoom))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.yellow)
                
                Circle()
                    .fill(Color.yellow)
                    .frame(width: 14, height: 14)
                    .shadow(color: .yellow.opacity(0.3), radius: 4)
            }
            .offset(x: knobX, y: -6)
        }
        .frame(width: trackWidth + 30, height: 50)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(.black.opacity(0.55)))
    }
    
    // MARK: Helpers
    
    private func scheduleCollapse() {
        collapseTask?.cancel()
        collapseTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(bubble) { mode = .collapsed }
        }
    }
    
    private func isNear(_ a: Float, _ b: Float) -> Bool { abs(a - b) < 0.05 }
    
    private func clamp(_ zoom: Float) -> Float {
        max(range.lowerBound, min(range.upperBound, zoom))
    }
    
    private func zoomLabel(_ zoom: Float) -> String {
        zoom.truncatingRemainder(dividingBy: 1) == 0
        ? "\(Int(zoom))×"
        : String(format: "%.1f×", zoom)
    }
    
    /// Logarithmic mapping: zoom value → horizontal position in `width`.
    private func logPosition(_ zoom: Float, in width: CGFloat) -> CGFloat {
        let lo = log(max(range.lowerBound, 0.01))
        let hi = log(max(range.upperBound, 0.01))
        guard hi > lo else { return width / 2 }
        let t = (log(max(zoom, 0.01)) - lo) / (hi - lo)
        return CGFloat(t) * width
    }
    
    /// Inverse: horizontal position → zoom value.
    private func zoomFromPosition(_ x: CGFloat, in width: CGFloat) -> Float {
        let lo = log(max(range.lowerBound, 0.01))
        let hi = log(max(range.upperBound, 0.01))
        guard width > 0 else { return range.lowerBound }
        let t = Float(x / width)
        return exp(lo + t * (hi - lo))
    }
}


// MARK: - WebcamPreviewContentView

struct WebcamPreviewContentView: View {
    @ObservedObject var model: WebcamPreviewModel
    @State private var zoomActive = false
    
    var body: some View {
        ZStack(alignment: .bottom) {
            GeometryReader { geo in
                let isPortrait = abs(model.rotation % 180) == 90
                let scale: CGFloat = isPortrait
                ? min(geo.size.width, geo.size.height) / max(geo.size.width, geo.size.height)
                : 1.0
                
                SampleBufferLayerView(displayLayer: model.displayLayer)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .rotationEffect(.degrees(Double(model.rotation)))
                    .scaleEffect(scale)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
            .ignoresSafeArea()
            
            if model.cameras.count > 1 || !model.zoomLevels.isEmpty || model.flashAvailable {
                controlBar
                    .padding(.bottom, 20)
            }
        }
        .background(Color.black)
        .frame(minWidth: 640, minHeight: 360)
    }
    
    @ViewBuilder
    private var controlBar: some View {
        HStack(spacing: 6) {
            if model.cameras.count > 1 {
                Button { model.flipCamera() } label: {
                    Image(systemName: "camera.rotate.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
            }
            
            if !model.zoomLevels.isEmpty {
                ZoomControl(
                    levels: model.zoomLevels,
                    currentZoom: $model.currentZoom,
                    range: model.zoomMin...model.zoomMax,
                    onChange: model.onZoomChange,
                    active: $zoomActive
                )
            }
            
            if model.flashAvailable {
                Button { model.toggleFlash() } label: {
                    Image(systemName: model.flashActive ? "bolt.fill" : "bolt.slash")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(model.flashActive ? Color.yellow : Color.white)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, zoomActive ? 6 : 4)
        .background(Capsule().fill(.ultraThinMaterial))
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: zoomActive)
    }
}


// MARK: - Previews

private func previewModel(
    cameras: [String] = [],
    zoomLevels: [Float] = [],
    zoomMin: Float = 1.0,
    zoomMax: Float = 10.0,
    currentZoom: Float = 1.0,
    flashAvailable: Bool = false,
    flashActive: Bool = false
) -> WebcamPreviewModel {
    let m = WebcamPreviewModel()
    m.cameras = cameras.map { WebcamCamera(id: $0) }
    m.zoomLevels = zoomLevels
    m.zoomMin = zoomMin
    m.zoomMax = zoomMax
    m.currentZoom = currentZoom
    m.flashAvailable = flashAvailable
    m.flashActive = flashActive
    return m
}

#Preview("Full controls") {
    WebcamPreviewContentView(model: previewModel(
        cameras: ["back", "front"],
        zoomLevels: [0.6, 1.0, 2.0, 5.0, 10.0],
        zoomMin: 0.6,
        zoomMax: 10.0,
        flashAvailable: true
    ))
    .frame(width: 1280, height: 720)
}

#Preview("Flash active") {
    WebcamPreviewContentView(model: previewModel(
        cameras: ["back", "front"],
        zoomLevels: [1.0, 2.0, 5.0],
        currentZoom: 2.0,
        flashAvailable: true,
        flashActive: true
    ))
    .frame(width: 1280, height: 720)
}

#Preview("No controls") {
    WebcamPreviewContentView(model: WebcamPreviewModel())
        .frame(width: 1280, height: 720)
}
