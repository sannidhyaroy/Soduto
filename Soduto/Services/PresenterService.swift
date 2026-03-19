//
//  PresenterService.swift
//  Soduto
//
//  Created by Sannidhya Roy on 19/03/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import Cocoa
import os

/// Service providing presenter/laser-pointer functionality, receiving pointer movement
/// packets from a remote device and displaying a red dot overlay on the Mac screen
///
/// The remote device sends `kdeconnect.presenter` packets with relative `dx`/`dy`
/// deltas derived from the phone's gyroscope (fractional values where 1.0 = full
/// screen width/height) while the user holds the presenter button and physically
/// tilts the phone. A `stop: true` field signals the end of a gesture (button released)
///
/// A floating red dot overlay (inspired by KDE Desktop's `PresenterRedDot.qml`)
/// is shown without moving the actual mouse pointer. The dot appears when the first
/// movement packet arrives, tracks the gyroscope-derived position, and disappears on
/// `stop: true` or after a 500 ms inactivity timeout (matching KDE's auto-hide timer).
/// The system cursor is hidden for the duration of the gesture.
///
/// Smoothing pipeline: dead-zone filter → EMA on deltas → velocity scaling → accumulate.
/// Only one device may own the pointer at a time; packets from other devices are ignored
/// until the active gesture ends. Momentary finger-lifts (less than 5s) resume from the last
/// position rather than snapping back to center.
public class PresenterService: IncomingService {
    
    // MARK: Service
    
    public static let serviceId: Service.Id = "com.soduto.services.presenter"
    
    public let incomingCapabilities = Set<Service.Capability>([
        DataPacket.presenterPacketType
    ])
    public let outgoingCapabilities = Set<Service.Capability>([])
    
    // MARK: IncomingService
    
    var userDefaults: UserDefaults = .standard
    let incomingPreferenceKey = AppDefaultsStore.Preferences.Services.Presenter.incomingKey
    
    // MARK: Presenter State
    
    /// Normalized position in [0, 1] ((0.5, 0.5) is screen center)
    /// xPos: 0 = left edge, 1 = right edge
    /// yPos: 0 = top edge, 1 = bottom edge (matches Quartz/KDE convention)
    private var xPos: Double = 0.5
    private var yPos: Double = 0.5
    
    /// EMA state: previous smoothed deltas for exponential moving average
    private var prevSmoothedDx: Double = 0
    private var prevSmoothedDy: Double = 0
    
    /// The full-screen overlay panel showing the red dot
    private var overlayPanel: PresenterOverlayPanel?
    
    /// Auto-hide timer (if no packet arrives within this interval, the dot disappears)
    private var hideTimer: Timer?
    private static let hideTimeout: TimeInterval = 0.5
    
    /// Timestamp of the last gesture stop
    /// Used to decide whether to reset position to center (long idle) or resume (momentary finger-lift)
    private var lastStopTime: Date?
    
    /// How long the pointer must be idle before a new gesture resets to center
    /// Finger-lifts shorter than this resume from the previous position
    private static let centerResetTimeout: TimeInterval = 5.0
    
    /// The device currently owning the pointer gesture
    private weak var activeDevice: Device?
    
    private var isCursorHidden = false
    
    // MARK: Tuning Constants
    
    /// Dead-zone threshold: deltas whose combined magnitude falls below this value
    /// are ignored, filtering out idle hand tremor from gyroscope noise
    private static let deadZone: Double = 0.003
    
    /// EMA smoothing factor (0–1):  Higher = more responsive, lower = smoother
    /// 0.45 balances jitter reduction with tracking responsiveness
    private static let emaAlpha: Double = 0.45
    
    /// Velocity scaling boost factor: Multiplied by delta magnitude and added to 1.0,
    /// so small movements stay near 1× while large sweeps get amplified
    private static let velocityBoostFactor: Double = 8.0
    
    // MARK: Service Protocol
    
    public func handleDataPacket(_ dataPacket: DataPacket, fromDevice device: Device, onConnection connection: Connection) -> Bool {
        guard dataPacket.isPresenterPacket else { return false }
        guard incomingEnabled else { return true }
        
        do {
            switch dataPacket.type {
            case DataPacket.presenterPacketType:
                if try dataPacket.isStopPresenter() {
                    // Only the active device (or if none is active) can trigger stop
                    guard activeDevice == nil || activeDevice === device else { return true }
                    stopGesture()
                    return true
                }
                
                // Multi-device gate: if another device owns the gesture, ignore
                if let active = activeDevice, active !== device { return true }
                
                var dx = try dataPacket.getPresenterDx()
                var dy = try dataPacket.getPresenterDy()
                
                // Dead-zone filter: skip micro-movements from idle hand tremor
                guard abs(dx) + abs(dy) >= Self.deadZone else {
                    resetHideTimer()
                    return true
                }
                
                // First movement after a stop (or cold start)
                if overlayPanel == nil { startGesture(for: device) }
                
                applySmoothing(dx: &dx, dy: &dy)
                
                // Accumulate deltas with aspect ratio correction (matching KDE: dy *= screenW/screenH)
                // Use the panel's actual screen (not NSScreen.main) to support external displays
                guard let screen = overlayPanel?.screen ?? NSScreen.main else { return true }
                let ratio = Double(screen.frame.width) / Double(screen.frame.height)
                xPos += dx
                yPos += dy * ratio
                xPos = xPos.clamped(to: 0...1)
                yPos = yPos.clamped(to: 0...1)
                
                updateOverlay()
                resetHideTimer()
                return true
            default:
                return false
            }
        } catch {
            Logger.services.error("Error handling presenter packet: \(error, privacy: .public)")
        }
        return true
    }
    
    public func setup(for device: Device) {}
    
    public func cleanup(for device: Device) {
        if activeDevice === device {
            stopGesture()
        }
    }
    
    public func actions(for device: Device) -> [ServiceAction] { return [] }
    public func performAction(_ id: ServiceAction.Id, forDevice device: Device) {}
    
    // MARK: Gesture Lifecycle
    
    /// Begins a new gesture for the given device: locks device ownership, resets position
    /// if the idle gap was long enough to warrant centering, clears EMA state, and shows the overlay
    private func startGesture(for device: Device) {
        activeDevice = device
        
        // Reset to center only after a long idle; short finger-lifts resume from last position
        let shouldReset: Bool
        if let stopTime = lastStopTime {
            shouldReset = Date().timeIntervalSince(stopTime) >= Self.centerResetTimeout
        } else {
            shouldReset = true // Cold start (no previous position)
        }
        if shouldReset {
            xPos = 0.5
            yPos = 0.5
        }
        
        // Clear EMA state so the first real movement isn't blended with stale data
        prevSmoothedDx = 0
        prevSmoothedDy = 0
        
        showOverlay()
    }
    
    /// Ends the current gesture: hides the dot, records the stop time, and releases
    /// the active device lock so another device can take over
    private func stopGesture() {
        hideTimer?.invalidate()
        hideTimer = nil
        lastStopTime = Date()
        
        if let panel = overlayPanel {
            panel.fadeOutAndClose()
            overlayPanel = nil
        }
        showCursor()
        activeDevice = nil
    }
    
    // MARK: Overlay Management
    
    private func showOverlay() {
        guard overlayPanel == nil, let screen = screenForPresentation() else { return }
        let panel = PresenterOverlayPanel(screen: screen)
        panel.orderFrontRegardless()
        overlayPanel = panel
        hideCursor()
        updateOverlay()
    }
    
    private func updateOverlay() {
        guard let panel = overlayPanel else { return }
        panel.dotView.setDotPosition(x: xPos, y: yPos)
    }
    
    private func resetHideTimer() {
        hideTimer?.invalidate()
        hideTimer = Timer.compatScheduledTimer(withTimeInterval: Self.hideTimeout, repeats: false) { [weak self] _ in
            self?.stopGesture()
        }
    }
    
    // MARK: Smoothing Pipeline
    
    /// Applies EMA smoothing followed by velocity scaling to the raw deltas (in-place).
    /// EMA reduces jitter; velocity scaling boosts larger sweeps for faster traversal.
    private func applySmoothing(dx: inout Double, dy: inout Double) {
        // EMA smoothing: blend current delta with previous smoothed delta
        dx = Self.emaAlpha * dx + (1.0 - Self.emaAlpha) * prevSmoothedDx
        dy = Self.emaAlpha * dy + (1.0 - Self.emaAlpha) * prevSmoothedDy
        prevSmoothedDx = dx
        prevSmoothedDy = dy
        
        // Velocity scaling: large sweeps are boosted for faster screen traversal
        let magnitude = hypot(dx, dy)
        let boost = 1.0 + Self.velocityBoostFactor * magnitude
        dx *= boost
        dy *= boost
    }
    
    // MARK: Screen Selection
    
    /// Returns the screen where the presentation is most likely happening:
    /// the screen currently containing the mouse cursor, falling back to the main screen.
    /// This is more correct than `NSScreen.main` in multi-monitor setups where the
    /// presentation is running on an external display.
    private func screenForPresentation() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main
    }
    
    // MARK: Cursor Visibility
    // NOTE: This is a best-effort attempt, as it might not work when other apps are in focus
    
    /// Hides the system cursor globally using Core Graphics
    private func hideCursor() {
        guard !isCursorHidden else { return }
        CGDisplayHideCursor(CGMainDisplayID())
        isCursorHidden = true
    }
    
    private func showCursor() {
        guard isCursorHidden else { return }
        CGDisplayShowCursor(CGMainDisplayID())
        isCursorHidden = false
    }
}


// MARK: Presenter Overlay Panel

/// A full-screen, transparent, click-through panel that hosts the presenter dot
/// Covers the main screen at `.screenSaver` level so it floats above everything,
/// including fullscreen presentations
final class PresenterOverlayPanel: NSPanel {
    
    let dotView: PresenterDotView
    
    init(screen: NSScreen) {
        dotView = PresenterDotView(frame: NSRect(origin: .zero, size: screen.frame.size))
        
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .transient]
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        
        contentView = dotView
    }
    
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    
    /// Fades out the panel over 200 ms, then closes it
    func fadeOutAndClose() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                self.close()
            }
        })
    }
}


// MARK: Presenter Dot View

/// Draws the presenter dot as a radial gradient (hot orange-red core fading to a soft glow)
/// with `.plusLighter` blend mode for an emissive laser-pointer look, plus a wider bloom
/// halo for visibility on dark backgrounds (compensates for Stevens' power law: perceived
/// brightness scales sublinearly with luminance, so faint red on dark needs more area)
final class PresenterDotView: NSView {
    
    /// Current dot position in normalized coordinates
    private var dotX: Double = 0.5
    private var dotY: Double = 0.5
    
    /// Center of the last drawn dot in view coordinates, used to compute the dirty rect
    private var lastDrawnCenter: CGPoint?
    
    /// Outer radius of the main dot gradient in points
    private static let dotRadius: CGFloat = 11
    
    /// Bloom extends this factor beyond the dot radius for dark-background visibility
    private static let bloomRadiusFactor: CGFloat = 1.6
    
    /// Maximum radius of any drawing (bloom edge), used to bound the dirty rect
    private static var maxDrawRadius: CGFloat { dotRadius * bloomRadiusFactor }
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    
    /// Updates the dot position and invalidates only the affected region of the view
    /// (union of old and new dot bounding boxes) rather than the full screen-sized view.
    func setDotPosition(x: Double, y: Double) {
        dotX = x
        dotY = y
        
        let r = Self.maxDrawRadius
        let newCenter = CGPoint(x: x * bounds.width, y: (1.0 - y) * bounds.height)
        var dirtyRect = NSRect(x: newCenter.x - r, y: newCenter.y - r, width: r * 2, height: r * 2)
        
        if let last = lastDrawnCenter {
            let oldRect = NSRect(x: last.x - r, y: last.y - r, width: r * 2, height: r * 2)
            dirtyRect = dirtyRect.union(oldRect)
        }
        
        lastDrawnCenter = newCenter
        setNeedsDisplay(dirtyRect)
    }
    
    // MARK: Gradient Cache
    
    // Gradients are immutable and their inputs are compile-time constants, so we create
    // them once at first draw and reuse them every subsequent frame.
    
    private lazy var dotGradient: CGGradient = {
        let cs = CGColorSpaceCreateDeviceRGB()
        let colors = [
            CGColor(srgbRed: 1.0, green: 0.18, blue: 0.05, alpha: 1.0),
            CGColor(srgbRed: 1.0, green: 0.12, blue: 0.05, alpha: 1.0),
            CGColor(srgbRed: 1.0, green: 0.05, blue: 0.02, alpha: 0.55),
            CGColor(srgbRed: 1.0, green: 0.0,  blue: 0.0,  alpha: 0.28),
            CGColor(srgbRed: 1.0, green: 0.0,  blue: 0.0,  alpha: 0.0)
        ] as CFArray
        let locations: [CGFloat] = [0.0, 0.12, 0.28, 0.68, 1.0]
        return CGGradient(colorsSpace: cs, colors: colors, locations: locations)!
    }()
    
    private lazy var bloomGradient: CGGradient = {
        let cs = CGColorSpaceCreateDeviceRGB()
        let colors = [
            CGColor(srgbRed: 1.0, green: 0.1, blue: 0.05, alpha: 0.12),
            CGColor(srgbRed: 1.0, green: 0.0, blue: 0.0,  alpha: 0.05),
            CGColor(srgbRed: 1.0, green: 0.0, blue: 0.0,  alpha: 0.0)
        ] as CFArray
        let locations: [CGFloat] = [0.0, 0.5, 1.0]
        return CGGradient(colorsSpace: cs, colors: colors, locations: locations)!
    }()
    
    // MARK: Drawing
    
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        
        // Convert normalized (top-left origin) to view coordinates (bottom-left origin)
        let center = CGPoint(x: dotX * bounds.width, y: (1.0 - dotY) * bounds.height)
        
        ctx.setBlendMode(.plusLighter)
        
        // Main gradient: hot orange-red core → tight glow → transparent
        ctx.drawRadialGradient(dotGradient,
                               startCenter: center, startRadius: 0,
                               endCenter: center, endRadius: Self.dotRadius,
                               options: [])
        
        // Bloom halo: wider, very faint, improves visibility on dark backgrounds
        ctx.drawRadialGradient(bloomGradient,
                               startCenter: center, startRadius: 0,
                               endCenter: center, endRadius: Self.dotRadius * Self.bloomRadiusFactor,
                               options: [])
    }
}


// MARK: DataPacket (Presenter)

/// Presenter service data packet utilities (kdeconnect.presenter)
fileprivate extension DataPacket {
    
    // MARK: Types
    
    enum PresenterError: Error {
        case wrongType
        case invalidDx
        case invalidDy
        case invalidStopFlag
    }
    
    struct PresenterProperty {
        static let dx   = "dx"
        static let dy   = "dy"
        static let stop = "stop"
    }
    
    // MARK: Properties
    
    static let presenterPacketType = "kdeconnect.presenter"
    
    var isPresenterPacket: Bool { return self.type == DataPacket.presenterPacketType }
    
    // MARK: Public methods
    
    /// Relative horizontal delta (fraction of screen width; positive = right)
    func getPresenterDx() throws -> Double {
        try self.validatePresenterPacketType()
        guard body.keys.contains(PresenterProperty.dx) else { return 0.0 }
        guard let value = body[PresenterProperty.dx] as? NSNumber else { throw PresenterError.invalidDx }
        return value.doubleValue
    }
    
    /// Relative vertical delta (fraction of screen height; positive = downward)
    func getPresenterDy() throws -> Double {
        try self.validatePresenterPacketType()
        guard body.keys.contains(PresenterProperty.dy) else { return 0.0 }
        guard let value = body[PresenterProperty.dy] as? NSNumber else { throw PresenterError.invalidDy }
        return value.doubleValue
    }
    
    /// `true` when the remote signals the end of a presenter gesture
    func isStopPresenter() throws -> Bool {
        try self.validatePresenterPacketType()
        guard body.keys.contains(PresenterProperty.stop) else { return false }
        guard let value = body[PresenterProperty.stop] as? NSNumber else { throw PresenterError.invalidStopFlag }
        return value.boolValue
    }
    
    func validatePresenterPacketType() throws {
        guard self.isPresenterPacket else { throw PresenterError.wrongType }
    }
}

// MARK: Clamping Helper

fileprivate extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        return Swift.max(range.lowerBound, Swift.min(range.upperBound, self))
    }
}
