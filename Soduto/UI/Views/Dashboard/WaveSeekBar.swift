//
//  WaveSeekBar.swift
//  Soduto
//
//  Created by Sannidhya Roy on 22/03/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import SwiftUI
import AppKit
import Combine

// MARK: - WaveSeekBar

/// NSViewRepresentable wrapper for WaveBarNSView
///
/// All rendering (wave bar, time labels, digit-flip animations) live in the NSView layer.
/// Position updates flow directly from `PlayerRemote.positionSubject` → NSView via Combine.
/// During normal playback, zero SwiftUI body re-evaluations occur from this component.
struct WaveSeekBar: NSViewRepresentable {
    let player: PlayerRemote
    let lengthMs: Int
    let pendingSeekMs: Int?
    let isPlaying: Bool
    let canSeek: Bool
    let onSeekCommitted: (_ positionMs: Int) -> Void
    let onPositionReceived: (_ positionMs: Int) -> Void
    
    func makeNSView(context: Context) -> WaveBarNSView {
        let view = WaveBarNSView()
        view.subscribeToPlayer(player)
        return view
    }
    
    func updateNSView(_ view: WaveBarNSView, context: Context) {
        view.onSeekCommitted = onSeekCommitted
        view.onPositionReceived = onPositionReceived
        view.updateState(lengthMs: lengthMs, pendingSeekMs: pendingSeekMs, isPlaying: isPlaying, canSeek: canSeek)
    }
}

// MARK: - WaveBarNSView

/// Core Graphics wave seek bar with integrated time labels, driven by a 30 fps Timer.
///
/// Time labels use a per-character "digit flip" animation (vertical slide + fade)
/// implemented entirely in Core Graphics.
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
    
    private let labelWidth: CGFloat         = 36
    private let labelSpacing: CGFloat       = 8
    private let labelAnimDuration: Double   = 0.4
    private let labelSlideDistance: CGFloat  = 5
    
    // MARK: Cached colors + font
    
    private var cachedAccentColor: CGColor    = NSColor.controlAccentColor.cgColor
    private var cachedSecondaryColor: CGColor = NSColor.secondaryLabelColor.cgColor
    private var cachedTertiaryColor: NSColor  = .tertiaryLabelColor
    private let labelFont: NSFont = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    private lazy var labelAttributes: [NSAttributedString.Key: Any] = [
        .font: labelFont,
        .foregroundColor: cachedTertiaryColor
    ]
    private var charSizeCache: [Character: CGSize] = [:]
    
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
    
    // MARK: Digit flip state
    
    private struct CharFlip {
        var current: Character
        var previous: Character
        var changedAt: Date
        var slidesUp: Bool  // true = old slides up / new enters from below; false = reverse
    }
    private var positionFlips: [CharFlip] = []
    private var currentPositionLabel: String = ""
    private var lengthFlips: [CharFlip] = []
    private var currentLengthLabel: String = ""
    private var lastLabelFlipTime: Date = .distantPast
    
    // MARK: Interaction state
    
    private var isHovering: Bool     = false
    private var isDragging: Bool     = false
    private var dragFraction: Double = 0
    private var mouseDownX: CGFloat  = 0
    
    // MARK: Combine + callbacks
    
    private var positionCancellable: AnyCancellable?
    private var animationTimer: Timer?
    private var initialized = false
    var onSeekCommitted: ((_ positionMs: Int) -> Void)?
    var onPositionReceived: ((_ positionMs: Int) -> Void)?
    
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
        positionCancellable?.cancel()
        positionCancellable = nil
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
        cachedTertiaryColor = .tertiaryLabelColor
        labelAttributes[.foregroundColor] = cachedTertiaryColor
        charSizeCache.removeAll()
        needsDisplay = true
    }
    
    // MARK: Player subscription
    
    /// Subscribe to position updates directly from the player's Combine subject.
    /// Position flows through Combine → NSView, never touching SwiftUI's observation.
    func subscribeToPlayer(_ player: PlayerRemote) {
        positionMs        = player.position
        positionTimestamp = player.timestamp
        knownPositionMs   = player.position
        knownTimestamp    = player.timestamp
        
        // Initialize position label without animation
        let label = formatMs(player.position)
        currentPositionLabel = label
        positionFlips = Array(label).map {
            CharFlip(current: $0, previous: $0, changedAt: .distantPast, slidesUp: true)
        }
        
        positionCancellable = player.positionSubject
            .sink { [weak self] position, timestamp in
                self?.handlePositionUpdate(positionMs: position, timestamp: timestamp)
            }
    }
    
    private func handlePositionUpdate(positionMs: Int, timestamp: Date) {
        let oldTimestamp    = self.positionTimestamp
        self.positionMs    = positionMs
        self.positionTimestamp = timestamp
        
        if timestamp != oldTimestamp {
            handleTimestampChange()
        }
        
        refreshAnimation()
        onPositionReceived?(positionMs)
    }
    
    // MARK: State update (from SwiftUI / non-position properties only)
    
    func updateState(lengthMs: Int, pendingSeekMs: Int?, isPlaying: Bool, canSeek: Bool) {
        let isFirst    = !initialized
        initialized    = true
        let oldPending = self.pendingSeekMs
        let oldCanSeek = self.canSeek
        
        self.lengthMs = lengthMs
        self.canSeek  = canSeek
        let newLengthLabel = formatMs(lengthMs)
        if newLengthLabel != currentLengthLabel {
            if isFirst {
                // Initialize without animation
                currentLengthLabel = newLengthLabel
                lengthFlips = Array(newLengthLabel).map {
                    CharFlip(current: $0, previous: $0, changedAt: .distantPast, slidesUp: true)
                }
            } else {
                updateLengthFlips(to: newLengthLabel, at: Date())
            }
        }
        
        if isPlaying != _isPlaying {
            _isPlaying = isPlaying
            setPlaying(isPlaying, animated: !isFirst)
        }
        if !canSeek && oldCanSeek { setInteraction(false) }
        
        if pendingSeekMs != oldPending {
            handlePendingSeekChange(old: oldPending, new: pendingSeekMs)
        }
        self.pendingSeekMs = pendingSeekMs
        
        refreshAnimation()
    }
    
    // MARK: Drawing
    
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let w = bounds.width, h = bounds.height
        guard w > 0, h > 0 else { return }
        let now = Date()
        
        // Layout: [positionLabel 36] [8] [--- wave bar ---] [8] [lengthLabel 36]
        let barLeft  = labelWidth + labelSpacing
        let barRight = w - labelWidth - labelSpacing
        let barWidth = max(1, barRight - barLeft)
        
        let interactiveProg = eased(from: interactiveFrom, target: interactiveTarget ? 1 : 0, changedAt: interactiveChangedAt, now: now)
        let playingProg = eased(from: playingFrom, target: playingTarget ? 1 : 0, changedAt: playingChangedAt, now: now)
        let fraction     = displayFraction(at: now)
        let combinedProg = max(playingProg, interactiveProg)
        let barH = restHeight + (playingHeight - restHeight) * playingProg * (1 - interactiveProg) + (hoverHeight - restHeight) * interactiveProg
        let waveAmp = maxAmplitude * playingProg * (1 - interactiveProg)
        let fillX   = max(barLeft, min(barRight, barLeft + barWidth * fraction))
        let flatH   = barH * 0.8
        let midY    = h / 2
        let phase   = Float(fmod(now.timeIntervalSinceReferenceDate * waveSpeed, 2 * .pi))
        
        ctx.clear(bounds)
        
        // Update position label (detect changes for digit flip)
        let currentMs = Int(fraction * Double(max(1, lengthMs)))
        let newLabel = formatMs(currentMs)
        if newLabel != currentPositionLabel {
            updatePositionFlips(to: newLabel, at: now)
        }
        
        // Position label (left, with digit flip animation)
        drawPositionLabel(ctx, midY: midY, now: now)
        
        // Length label (right, with digit flip animation)
        drawLengthLabel(ctx, barRight: barRight, midY: midY, now: now)
        
        // Unfilled track
        if barRight - fillX > 0.5 {
            let r = flatH / 2
            ctx.saveGState()
            ctx.setAlpha(0.22)
            ctx.setFillColor(cachedSecondaryColor)
            ctx.addPath(CGPath(roundedRect: CGRect(x: fillX, y: midY - r, width: barRight - fillX, height: flatH), cornerWidth: r, cornerHeight: r, transform: nil))
            ctx.fillPath()
            ctx.restoreGState()
        }
        
        // Filled wave bar
        if fillX - barLeft > 0.5 {
            let halfH  = barH / 2
            let startX = barLeft + halfH
            let endX   = max(startX, fillX - halfH)
            
            ctx.setStrokeColor(cachedAccentColor)
            ctx.setLineWidth(barH)
            ctx.setLineCap(.round)
            ctx.beginPath()
            
            let step: CGFloat = 2
            var x = startX
            var first = true
            while x <= endX {
                let localX = x - barLeft
                let tp = min(1, localX / max(taperWidth, 0.001)) * min(1, (fillX - x) / max(taperWidth, 0.001))
                let y  = midY + CGFloat(sinf(Float(localX) * waveFreq + phase)) * waveAmp * tp
                if first { ctx.move(to: CGPoint(x: x, y: y)); first = false }
                else     { ctx.addLine(to: CGPoint(x: x, y: y)) }
                x += step
            }
            if !first {
                let localX = endX - barLeft
                let tp = min(1, localX / max(taperWidth, 0.001)) * min(1, (fillX - endX) / max(taperWidth, 0.001))
                let y  = midY + CGFloat(sinf(Float(localX) * waveFreq + phase)) * waveAmp * tp
                ctx.addLine(to: CGPoint(x: endX, y: y))
            } else {
                let midBar = (barLeft + fillX) / 2
                ctx.move(to: CGPoint(x: midBar, y: midY))
                ctx.addLine(to: CGPoint(x: midBar, y: midY))
            }
            ctx.strokePath()
        }
        
        // Thumb
        if combinedProg > 0.01 {
            let tr  = thumbRadius * combinedProg
            let tcx = max(barLeft + tr, min(barRight - tr, fillX))
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.12 * combinedProg))
            ctx.fillEllipse(in: CGRect(x: tcx - (tr + 1.2), y: midY - (tr + 0.4), width: (tr + 1.2) * 2, height: (tr + 0.4) * 2))
            ctx.setFillColor(CGColor(gray: 1, alpha: combinedProg))
            ctx.fillEllipse(in: CGRect(x: tcx - tr, y: midY - tr, width: tr * 2, height: tr * 2))
        }
    }
    
    // MARK: Label drawing
    
    /// Draw position label with digit flip animation (left-aligned).
    private func drawPositionLabel(_ ctx: CGContext, midY: CGFloat, now: Date) {
        drawFlippingLabel(ctx, flips: positionFlips, originX: 0, midY: midY, now: now, rightAlign: false)
    }
    
    /// Draw length label with digit flip animation (right-aligned).
    private func drawLengthLabel(_ ctx: CGContext, barRight: CGFloat, midY: CGFloat, now: Date) {
        let originX = barRight + labelSpacing
        drawFlippingLabel(ctx, flips: lengthFlips, originX: originX, midY: midY, now: now, rightAlign: true)
    }
    
    /// Shared digit flip drawing for both labels.
    private func drawFlippingLabel(_ ctx: CGContext, flips: [CharFlip], originX: CGFloat,
                                   midY: CGFloat, now: Date, rightAlign: Bool) {
        guard !flips.isEmpty else { return }
        let textHeight = labelFont.ascender - labelFont.descender
        let baseY = midY - textHeight / 2
        
        // Compute total width for right-alignment
        var startX = originX
        if rightAlign {
            var total: CGFloat = 0
            for flip in flips { total += cachedCharSize(flip.current).width }
            startX = originX + labelWidth - total
        }
        
        var x = startX
        for flip in flips {
            let size = cachedCharSize(flip.current)
            let elapsed = now.timeIntervalSince(flip.changedAt)
            
            if elapsed < labelAnimDuration && flip.previous != flip.current {
                let t = min(1, elapsed / labelAnimDuration)
                // Ease-in-out cubic: smooth acceleration and deceleration
                let progress = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
                
                // Slide direction: up for increasing digits, down for decreasing
                let dir: CGFloat = flip.slidesUp ? 1 : -1
                
                // Clip to character cell
                ctx.saveGState()
                ctx.clip(to: CGRect(x: x - 0.5, y: baseY - 0.5, width: size.width + 1, height: textHeight + 1))
                
                // Old character sliding out + fading
                let oldY = baseY - dir * labelSlideDistance * progress
                ctx.saveGState()
                ctx.setAlpha(CGFloat(1 - progress))
                (String(flip.previous) as NSString).draw(at: NSPoint(x: x, y: oldY), withAttributes: labelAttributes)
                ctx.restoreGState()
                
                // New character sliding in + fading
                let newY = baseY + dir * labelSlideDistance * (1 - progress)
                ctx.saveGState()
                ctx.setAlpha(CGFloat(progress))
                (String(flip.current) as NSString).draw(at: NSPoint(x: x, y: newY), withAttributes: labelAttributes)
                ctx.restoreGState()
                
                ctx.restoreGState()
            } else {
                (String(flip.current) as NSString).draw(at: NSPoint(x: x, y: baseY), withAttributes: labelAttributes)
            }
            
            x += size.width
        }
    }
    
    // MARK: Flip state management
    
    private func updatePositionFlips(to newLabel: String, at now: Date) {
        updateFlips(&positionFlips, to: newLabel, at: now)
        currentPositionLabel = newLabel
        lastLabelFlipTime = now
    }
    
    private func updateLengthFlips(to newLabel: String, at now: Date) {
        updateFlips(&lengthFlips, to: newLabel, at: now)
        currentLengthLabel = newLabel
        lastLabelFlipTime = now
    }
    
    private func updateFlips(_ flips: inout [CharFlip], to newLabel: String, at now: Date) {
        let newChars = Array(newLabel)
        
        if flips.count != newChars.count {
            // Character count changed (e.g. "9:59" → "10:00"), flip all
            let grows = newChars.count > flips.count
            flips = newChars.map {
                CharFlip(current: $0, previous: " ", changedAt: now, slidesUp: grows)
            }
        } else {
            for i in 0..<newChars.count {
                if newChars[i] != flips[i].current {
                    flips[i].previous = flips[i].current
                    flips[i].slidesUp = newChars[i] > flips[i].current
                    flips[i].current = newChars[i]
                    flips[i].changedAt = now
                }
            }
        }
    }
    
    private func cachedCharSize(_ char: Character) -> CGSize {
        if let cached = charSizeCache[char] { return cached }
        let size = (String(char) as NSString).size(withAttributes: labelAttributes)
        charSizeCache[char] = size
        return size
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
        dragFraction = barFraction(forX: x)
        refreshAnimation()
    }
    
    override func mouseUp(with event: NSEvent) {
        guard canSeek else { return }
        let x = convert(event.locationInWindow, from: nil).x
        let f = barFraction(forX: x)
        
        if isDragging {
            dragFraction = f
            localPendingFraction = f
            isDragging = false
            setInteraction(isHovering)
            onSeekCommitted?(Int(f * Double(max(1, lengthMs))))
        } else {
            // Tap: animate from current visual position to tap target
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
    
    private func barFraction(forX x: CGFloat) -> Double {
        let barLeft  = labelWidth + labelSpacing
        let barWidth = bounds.width - 2 * (labelWidth + labelSpacing)
        return max(0, min(1, (x - barLeft) / max(1, barWidth)))
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
        if now.timeIntervalSince(lastLabelFlipTime) < labelAnimDuration { return true }
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
