//
//  WaveSeekBar.swift
//  Soduto
//
//  Created by Sannidhya Roy on 22/03/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import SwiftUI
import AppKit

// MARK: - WaveSeekBar

/// NSViewRepresentable wrapper for WaveBarNSView
/// All rendering and animation live in the NSView layer to avoid SwiftUI TimelineView's attribute-graph leak
struct WaveSeekBar: NSViewRepresentable {
    let positionMs: Int
    let lengthMs: Int
    let positionTimestamp: Date
    let pendingSeekMs: Int?
    let isPlaying: Bool
    let canSeek: Bool
    let onSeekCommitted: (_ positionMs: Int) -> Void
    let onPositionLabelChanged: (_ label: String) -> Void
    
    func makeNSView(context: Context) -> WaveBarNSView { WaveBarNSView() }
    
    func updateNSView(_ view: WaveBarNSView, context: Context) {
        view.onSeekCommitted = onSeekCommitted
        view.onPositionLabelChanged = onPositionLabelChanged
        view.externalUpdate(positionMs: positionMs, lengthMs: lengthMs,
                            positionTimestamp: positionTimestamp,
                            pendingSeekMs: pendingSeekMs,
                            isPlaying: isPlaying, canSeek: canSeek)
    }
}

// MARK: - WaveBarNSView

/// Core Graphics wave seek bar driven by a 30 fps Timer
/// Fires an `onPositionLabelChanged` callback once per second so the SwiftUI layer can animate the time label without hosting a TimelineView
final class WaveBarNSView: NSView {
    
    // MARK: Constants
    
    private let restHeight: CGFloat      = 3
    private let playingHeight: CGFloat   = 3.5
    private let hoverHeight: CGFloat     = 5
    private let maxAmplitude: CGFloat    = 3.5
    private let waveSpeed: Double        = 2.5
    private let waveFreq: Float          = 0.15
    private let taperWidth: CGFloat      = 18
    private let thumbRadius: CGFloat     = 5.5
    private let animDuration: Double     = 0.3
    private let seekAnimDuration: Double = 0.45
    
    // MARK: Cached colors
    
    private var cachedAccentColor: CGColor    = NSColor.controlAccentColor.cgColor
    private var cachedSecondaryColor: CGColor = NSColor.secondaryLabelColor.cgColor
    
    // MARK: Playback state
    
    private var positionMs: Int         = 0
    private var lengthMs: Int           = 0
    private var positionTimestamp: Date = .distantPast
    private var pendingSeekMs: Int?     = nil
    private var _isPlaying: Bool        = false
    private var canSeek: Bool           = false
    
    // MARK: Animation state
    
    private var interactiveTarget: Bool    = false
    private var interactiveFrom: Double    = 0
    private var interactiveChangedAt: Date = .distantPast
    private var playingTarget: Bool        = false
    private var playingFrom: Double        = 0
    private var playingChangedAt: Date     = .distantPast
    
    private var seekAnimFrom: Double          = 0
    private var seekAnimChangedAt: Date       = .distantPast
    private var localPendingFraction: Double? = nil
    private var localSeekTarget: Double?      = nil
    private var knownPositionMs: Int          = 0
    private var knownTimestamp: Date          = .distantPast
    
    // MARK: Interaction state
    
    private var isHovering: Bool     = false
    private var isDragging: Bool     = false
    private var dragFraction: Double = 0
    private var mouseDownX: CGFloat  = 0
    
    // MARK: Timer + callbacks
    
    private var animationTimer: Timer?
    private var initialized = false
    private var lastPositionLabel: String = ""
    var onSeekCommitted: ((_ positionMs: Int) -> Void)?
    var onPositionLabelChanged: ((_ label: String) -> Void)?
    
    // MARK: Init / lifecycle
    
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopAnimation() }
    }
    
    override func removeFromSuperview() {
        stopAnimation()
        super.removeFromSuperview()
    }
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for ta in trackingAreas { removeTrackingArea(ta) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self))
    }
    
    override func viewDidChangeEffectiveAppearance() {
        cachedAccentColor = NSColor.controlAccentColor.cgColor
        cachedSecondaryColor = NSColor.secondaryLabelColor.cgColor
        needsDisplay = true
    }
    
    // MARK: External update (from SwiftUI)
    
    func externalUpdate(positionMs: Int, lengthMs: Int, positionTimestamp: Date,
                        pendingSeekMs: Int?, isPlaying: Bool, canSeek: Bool) {
        let isFirst       = !initialized
        initialized       = true
        let oldTimestamp   = self.positionTimestamp
        let oldPending    = self.pendingSeekMs
        let oldCanSeek    = self.canSeek
        
        self.positionMs        = positionMs
        self.lengthMs          = lengthMs
        self.positionTimestamp  = positionTimestamp
        self.canSeek           = canSeek
        
        if isPlaying != _isPlaying {
            _isPlaying = isPlaying
            setPlaying(isPlaying, animated: !isFirst)
        }
        if !canSeek && oldCanSeek { setInteraction(false) }
        
        if pendingSeekMs != oldPending {
            handlePendingSeekChange(old: oldPending, new: pendingSeekMs)
        }
        self.pendingSeekMs = pendingSeekMs
        
        if isFirst {
            knownPositionMs = positionMs
            knownTimestamp  = positionTimestamp
        } else if positionTimestamp != oldTimestamp {
            handleTimestampChange()
        }
        
        refreshAnimation()
    }
    
    // MARK: Drawing
    
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let w = bounds.width, h = bounds.height
        guard w > 0, h > 0 else { return }
        let now = Date()
        
        let interactiveProg = eased(from: interactiveFrom, target: interactiveTarget ? 1 : 0, changedAt: interactiveChangedAt, now: now)
        let playingProg = eased(from: playingFrom, target: playingTarget ? 1 : 0, changedAt: playingChangedAt, now: now)
        let fraction     = displayFraction(at: now)
        let combinedProg = max(playingProg, interactiveProg)
        let barH = restHeight + (playingHeight - restHeight) * playingProg * (1 - interactiveProg) + (hoverHeight - restHeight) * interactiveProg
        let waveAmp = maxAmplitude * playingProg * (1 - interactiveProg)
        let fillX   = max(0, min(w, w * fraction))
        let flatH   = barH * 0.8
        let midY    = h / 2
        let phase   = Float(fmod(now.timeIntervalSinceReferenceDate * waveSpeed, 2 * .pi))
        
        ctx.clear(bounds)
        
        // Unfilled track
        if w - fillX > 0.5 {
            let r = flatH / 2
            ctx.saveGState()
            ctx.setAlpha(0.22)
            ctx.setFillColor(cachedSecondaryColor)
            ctx.addPath(CGPath(roundedRect: CGRect(x: fillX, y: midY - r, width: w - fillX, height: flatH), cornerWidth: r, cornerHeight: r, transform: nil))
            ctx.fillPath()
            ctx.restoreGState()
        }
        
        // Filled wave bar
        if fillX > 0.5 {
            let halfH  = barH / 2
            let startX = halfH
            let endX   = max(startX, fillX - halfH)
            
            ctx.setStrokeColor(cachedAccentColor)
            ctx.setLineWidth(barH)
            ctx.setLineCap(.round)
            ctx.beginPath()
            
            let step: CGFloat = 2
            var x = startX
            var first = true
            while x <= endX {
                let tp = min(1, x / max(taperWidth, 0.001)) * min(1, (fillX - x) / max(taperWidth, 0.001))
                let y  = midY + CGFloat(sinf(Float(x) * waveFreq + phase)) * waveAmp * tp
                if first { ctx.move(to: CGPoint(x: x, y: y)); first = false }
                else     { ctx.addLine(to: CGPoint(x: x, y: y)) }
                x += step
            }
            if !first {
                let tp = min(1, endX / max(taperWidth, 0.001)) * min(1, (fillX - endX) / max(taperWidth, 0.001))
                let y  = midY + CGFloat(sinf(Float(endX) * waveFreq + phase)) * waveAmp * tp
                ctx.addLine(to: CGPoint(x: endX, y: y))
            } else {
                ctx.move(to: CGPoint(x: fillX / 2, y: midY))
                ctx.addLine(to: CGPoint(x: fillX / 2, y: midY))
            }
            ctx.strokePath()
        }
        
        // Thumb
        if combinedProg > 0.01 {
            let tr  = thumbRadius * combinedProg
            let tcx = max(tr, min(w - tr, fillX))
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.12 * combinedProg))
            ctx.fillEllipse(in: CGRect(x: tcx - (tr + 1.2), y: midY - (tr + 0.4), width: (tr + 1.2) * 2, height: (tr + 0.4) * 2))
            ctx.setFillColor(CGColor(gray: 1, alpha: combinedProg))
            ctx.fillEllipse(in: CGRect(x: tcx - tr, y: midY - tr, width: tr * 2, height: tr * 2))
        }
        
        // Position label callback (~1/sec)
        let currentMs = Int(fraction * Double(max(1, lengthMs)))
        let label = formatMs(currentMs)
        if label != lastPositionLabel {
            lastPositionLabel = label
            onPositionLabelChanged?(label)
        }
    }
    
    // MARK: Mouse events
    
    override func mouseEntered(with event: NSEvent) {
        guard canSeek else { return }
        isHovering = true
        setInteraction(true)
    }
    
    override func mouseExited(with event: NSEvent) {
        isHovering = false
        if !isDragging { setInteraction(false) }
    }
    
    override func mouseDown(with event: NSEvent) {
        guard canSeek else { return }
        mouseDownX = convert(event.locationInWindow, from: nil).x
    }
    
    override func mouseDragged(with event: NSEvent) {
        guard canSeek else { return }
        let x = convert(event.locationInWindow, from: nil).x
        if !isDragging {
            guard abs(x - mouseDownX) >= 3 else { return }
            isDragging = true
            setInteraction(true)
        }
        dragFraction = max(0, min(1, x / max(1, bounds.width)))
        refreshAnimation()
    }
    
    override func mouseUp(with event: NSEvent) {
        guard canSeek else { return }
        let x = convert(event.locationInWindow, from: nil).x
        let f = max(0, min(1, x / max(1, bounds.width)))
        
        if isDragging {
            dragFraction = f
            localPendingFraction = f
            isDragging = false
            setInteraction(isHovering)
            onSeekCommitted?(Int(f * Double(max(1, lengthMs))))
        } else {
            // Tap — animate from current visual position to tap target
            let now = Date()
            let pre: Double
            if let pending = pendingSeekMs {
                pre = Double(pending) / Double(max(1, lengthMs))
            } else if lengthMs > 0 {
                let elapsed = max(0, now.timeIntervalSince(positionTimestamp)) * 1000
                pre = _isPlaying ? min(1, Double(positionMs + Int(elapsed)) / Double(lengthMs)) : Double(positionMs) / Double(lengthMs)
            } else { pre = 0 }
            seekAnimFrom      = pre
            seekAnimChangedAt = now
            localSeekTarget   = f
            onSeekCommitted?(Int(f * Double(max(1, lengthMs))))
        }
        refreshAnimation()
    }
    
    // MARK: Animation control
    
    private var needsAnimation: Bool {
        if isDragging || _isPlaying { return true }
        if interactiveTarget { return true }
        let now = Date()
        if now.timeIntervalSince(interactiveChangedAt) < animDuration { return true }
        if now.timeIntervalSince(playingChangedAt) < animDuration { return true }
        if localSeekTarget != nil || localPendingFraction != nil { return true }
        if now.timeIntervalSince(seekAnimChangedAt) < seekAnimDuration { return true }
        return false
    }
    
    private func refreshAnimation() {
        if needsAnimation { startAnimation() }
        needsDisplay = true
    }
    
    private func startAnimation() {
        guard animationTimer == nil else { return }
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.needsDisplay = true
            if !self.needsAnimation { self.stopAnimation() }
        }
        RunLoop.main.add(animationTimer!, forMode: .common)
    }
    
    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
    }
    
    // MARK: Easing helpers
    
    private func eased(from: Double, target: Double, changedAt: Date, now: Date) -> Double {
        let t = min(1, max(0, now.timeIntervalSince(changedAt)) / animDuration)
        return from + (target - from) * (1 - pow(1 - t, 3))
    }
    
    private func setInteraction(_ interactive: Bool) {
        guard interactive != interactiveTarget else { return }
        let now = Date()
        interactiveFrom = eased(from: interactiveFrom, target: interactiveTarget ? 1 : 0, changedAt: interactiveChangedAt, now: now)
        interactiveTarget    = interactive
        interactiveChangedAt = now
        refreshAnimation()
    }
    
    private func setPlaying(_ playing: Bool, animated: Bool = true) {
        guard playing != playingTarget else { return }
        let now = Date()
        if animated {
            playingFrom = eased(from: playingFrom, target: playingTarget ? 1 : 0, changedAt: playingChangedAt, now: now)
            playingChangedAt = now
        } else {
            playingFrom      = playing ? 1 : 0
            playingChangedAt = .distantPast
        }
        playingTarget = playing
        refreshAnimation()
    }
    
    private func displayFraction(at now: Date) -> Double {
        if isDragging { return max(0, min(1, dragFraction)) }
        if let local = localPendingFraction { return max(0, min(1, local)) }
        if let target = localSeekTarget {
            let t = min(1, max(0, now.timeIntervalSince(seekAnimChangedAt)) / seekAnimDuration)
            return seekAnimFrom + (target - seekAnimFrom) * (1 - pow(1 - t, 3))
        }
        if let pending = pendingSeekMs {
            return Double(pending) / Double(max(1, lengthMs))
        }
        guard lengthMs > 0 else { return 0 }
        let targetFraction: Double
        if _isPlaying {
            let elapsedMs = max(0, now.timeIntervalSince(positionTimestamp)) * 1000
            targetFraction = min(1, Double(positionMs + Int(elapsedMs)) / Double(lengthMs))
        } else {
            targetFraction = Double(positionMs) / Double(lengthMs)
        }
        let t = min(1, max(0, now.timeIntervalSince(seekAnimChangedAt)) / seekAnimDuration)
        guard t < 1.0 else { return targetFraction }
        return seekAnimFrom + (targetFraction - seekAnimFrom) * (1 - pow(1 - t, 3))
    }
    
    // MARK: Seek state handlers
    
    private func handlePendingSeekChange(old: Int?, new: Int?) {
        guard let newVal = new else {
            if let shown = localSeekTarget ?? localPendingFraction {
                knownPositionMs = Int(shown * Double(max(1, lengthMs)))
                knownTimestamp  = Date()
            }
            localSeekTarget      = nil
            localPendingFraction = nil
            seekAnimChangedAt    = .distantPast
            return
        }
        guard localPendingFraction == nil else { return }
        let targetFrac = Double(newVal) / Double(max(1, lengthMs))
        if let existing = localSeekTarget, abs(existing - targetFrac) < 0.001 { return }
        let now = Date()
        let current: Double
        if let prior = localSeekTarget {
            let t = min(1, max(0, now.timeIntervalSince(seekAnimChangedAt)) / seekAnimDuration)
            current = seekAnimFrom + (prior - seekAnimFrom) * (1 - pow(1 - t, 3))
        } else if lengthMs > 0 {
            let elapsed = max(0, now.timeIntervalSince(positionTimestamp)) * 1000
            current = _isPlaying ? min(1, Double(positionMs + Int(elapsed)) / Double(lengthMs)) : Double(positionMs) / Double(lengthMs)
        } else { current = 0 }
        seekAnimFrom      = current
        seekAnimChangedAt = now
        localSeekTarget   = targetFrac
    }
    
    private func handleTimestampChange() {
        let prevMs = knownPositionMs
        let prevTs = knownTimestamp
        knownPositionMs = positionMs
        knownTimestamp  = positionTimestamp
        guard localPendingFraction == nil, localSeekTarget == nil else { return }
        guard !isDragging, lengthMs > 0 else { return }
        let elapsed  = max(0, positionTimestamp.timeIntervalSince(prevTs)) * 1000
        let prevFrac = _isPlaying ? min(1, Double(prevMs + Int(elapsed)) / Double(lengthMs)) : Double(prevMs) / Double(max(1, lengthMs))
        let newFrac  = Double(positionMs) / Double(max(1, lengthMs))
        guard abs(newFrac - prevFrac) > 0.002 else { return }
        seekAnimFrom      = prevFrac
        seekAnimChangedAt = positionTimestamp
    }
    
    // MARK: Helpers
    
    private func formatMs(_ ms: Int) -> String {
        let s = ms / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
