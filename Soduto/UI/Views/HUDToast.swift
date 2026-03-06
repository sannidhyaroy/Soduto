//
//  HUDToast.swift
//  Soduto
//
//  Created by Sannidhya Roy on 05/03/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import Cocoa

/// A translucent pill HUD that appears briefly at the bottom-center of the screen
/// to confirm a transient action (e.g. "OTP Copied").
///
/// Fully configurable via ``HUDToast.Style`` — colors, icon, timing, position.
/// Ships with semantic presets: `.success`, `.info`, `.warning`, `.error`.
///
/// Usage:
/// ```swift
/// // Quick — uses .success style
/// HUDToast.show("OTP Copied")
///
/// // Custom style
/// HUDToast.show("Device Paired", style: .info)
///
/// // Fully custom
/// let style = HUDToast.Style(
///     symbolName: "bolt.fill",
///     iconColor: .systemYellow,
///     backgroundColor: NSColor(white: 0.1, alpha: 0.85),
///     textColor: .white,
///     holdDuration: 2.5
/// )
/// HUDToast.show("Charging", style: style)
/// ```
final class HUDToast: NSPanel {
    
    // MARK: - Style Configuration
    
    /// All visual and timing properties for a HUD toast.
    struct Style {
        /// SF Symbol name for the leading icon.
        var symbolName: String
        /// Icon tint color.
        var iconColor: NSColor
        /// Pill background tint color — use alpha < 1.0 for translucency.
        var backgroundColor: NSColor
        /// Label text color.
        var textColor: NSColor
        /// How long the toast stays visible before fading out.
        var holdDuration: TimeInterval
        /// Fade-in animation duration.
        var fadeInDuration: TimeInterval
        /// Fade-out animation duration.
        var fadeOutDuration: TimeInterval
        /// Icon point size.
        var iconSize: CGFloat
        /// Label font size.
        var fontSize: CGFloat
        /// Distance from the bottom of the visible screen area.
        var bottomOffset: CGFloat
        /// Opacity of the frosted glass layer (0 = clear glass, 1 = heavy frost).
        var frostAlpha: CGFloat
        
        /// - Parameters:
        ///   - symbolName: SF Symbol name. Default: `"checkmark.circle.fill"`.
        ///   - iconColor: Icon tint. Default: system green.
        ///   - backgroundColor: Pill background tint. Default: dark translucent green.
        ///   - textColor: Label color. Default: white 95%.
        ///   - holdDuration: Visible duration in seconds. Default: 1.8s.
        ///   - fadeInDuration: Fade-in duration. Default: 0.25s.
        ///   - fadeOutDuration: Fade-out duration. Default: 0.5s.
        ///   - iconSize: SF Symbol point size. Default: 15.
        ///   - fontSize: Label font size. Default: 13.5.
        ///   - bottomOffset: Distance from bottom of screen. Default: 80pt.
        ///   - frostAlpha: Frosted glass intensity. 0 = clear glass, 1 = heavy frost. Default: 0.9.
        init(
            symbolName: String = "checkmark.circle.fill",
            iconColor: NSColor = NSColor(calibratedRed: 0.30, green: 0.85, blue: 0.47, alpha: 1.0),
            backgroundColor: NSColor = NSColor(calibratedRed: 0.06, green: 0.22, blue: 0.10, alpha: 0.45),
            textColor: NSColor = NSColor(white: 1.0, alpha: 0.95),
            holdDuration: TimeInterval = 1.8,
            fadeInDuration: TimeInterval = 0.25,
            fadeOutDuration: TimeInterval = 0.5,
            iconSize: CGFloat = 15,
            fontSize: CGFloat = 13.5,
            bottomOffset: CGFloat = 80,
            frostAlpha: CGFloat = 0.9
        ) {
            self.symbolName = symbolName
            self.iconColor = iconColor
            self.backgroundColor = backgroundColor
            self.textColor = textColor
            self.holdDuration = holdDuration
            self.fadeInDuration = fadeInDuration
            self.fadeOutDuration = fadeOutDuration
            self.iconSize = iconSize
            self.fontSize = fontSize
            self.bottomOffset = bottomOffset
            self.frostAlpha = frostAlpha
        }
        
        // MARK: Semantic Presets
        
        /// Green — for confirmations: "Copied", "Saved", "Paired".
        static let success = Style()
        
        /// Blue — for informational toasts: "Syncing", "Connected".
        static let info = Style(
            symbolName: "info.circle.fill",
            iconColor: NSColor(calibratedRed: 0.35, green: 0.65, blue: 1.0, alpha: 1.0),
            backgroundColor: NSColor(calibratedRed: 0.06, green: 0.12, blue: 0.28, alpha: 0.45)
        )
        
        /// Orange — for caution: "Battery Low", "Unstable Connection".
        static let warning = Style(
            symbolName: "exclamationmark.triangle.fill",
            iconColor: NSColor(calibratedRed: 1.0, green: 0.75, blue: 0.25, alpha: 1.0),
            backgroundColor: NSColor(calibratedRed: 0.28, green: 0.18, blue: 0.04, alpha: 0.45)
        )
        
        /// Red — for errors: "Failed", "Disconnected".
        static let error = Style(
            symbolName: "xmark.circle.fill",
            iconColor: NSColor(calibratedRed: 1.0, green: 0.35, blue: 0.37, alpha: 1.0),
            backgroundColor: NSColor(calibratedRed: 0.28, green: 0.06, blue: 0.08, alpha: 0.45)
        )
    }
    
    // MARK: - Internal state
    
    /// Horizontal padding inside the pill.
    private static let horizontalPadding: CGFloat = 18
    /// Vertical padding inside the pill.
    private static let verticalPadding: CGFloat = 10
    
    /// The style used for this toast instance.
    private let style: Style
    
    /// Tracks the currently visible toast so we can dismiss it if a new one arrives.
    @MainActor
    private static var currentToast: HUDToast?
    
    // MARK: - Public API
    
    /// Shows a HUD toast with the given message and style.
    ///
    /// - Parameters:
    ///   - message: Short text to display (e.g., "OTP Copied").
    ///   - style: Visual and timing configuration. Defaults to `.success`.
    @MainActor
    static func show(_ message: String, style: Style = .success) {
        // Dismiss any existing toast immediately
        currentToast?.dismissImmediately()
        
        let toast = HUDToast(message: message, style: style)
        currentToast = toast
        toast.present()
    }
    
    // MARK: - Initialization
    
    private init(message: String, style: Style) {
        self.style = style
        
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .transient]
        hidesOnDeactivate = false
        
        let content = makeContentView(message: message)
        self.contentView = content
        
        // Force layout so Auto Layout resolves a real size
        content.layoutSubtreeIfNeeded()
        let fitting = content.fittingSize
        let pillWidth = max(fitting.width, 140)
        let pillHeight = max(fitting.height, 38)
        setContentSize(NSSize(width: pillWidth, height: pillHeight))
    }
    
    // MARK: - View Construction
    
    private func makeContentView(message: String) -> NSView {
        let container = PillContainerView()
        container.translatesAutoresizingMaskIntoConstraints = false
        
        // Frosted glass layer — blurs the desktop behind the panel.
        // alphaValue controls frost intensity: 0 = clear glass, 1 = heavy frost.
        // At values < 1.0, the frost composites with the transparent window background,
        // mixing blurred and unblurred content for a subtler translucent look.
        let frost = NSVisualEffectView()
        frost.translatesAutoresizingMaskIntoConstraints = false
        frost.material = .popover
        frost.state = .active
        frost.blendingMode = .behindWindow
        frost.appearance = NSAppearance(named: .darkAqua)
        frost.alphaValue = style.frostAlpha
        container.addSubview(frost)
        
        // Optional color tint overlay — sits on top of the frost.
        let tint = NSView()
        tint.translatesAutoresizingMaskIntoConstraints = false
        tint.wantsLayer = true
        tint.layer?.backgroundColor = style.backgroundColor.cgColor
        container.addSubview(tint)
        
        // Icon
        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: style.symbolName, accessibilityDescription: nil)
        iconView.contentTintColor = style.iconColor
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: style.iconSize, weight: .semibold)
        
        // Label
        let label = NSTextField(labelWithString: message)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: style.fontSize, weight: .semibold)
        label.textColor = style.textColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        
        let stack = NSStackView(views: [iconView, label])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.spacing = 7
        stack.alignment = .centerY
        container.addSubview(stack)
        
        let hPad = Self.horizontalPadding
        let vPad = Self.verticalPadding
        
        NSLayoutConstraint.activate([
            // Frost fills container
            frost.topAnchor.constraint(equalTo: container.topAnchor),
            frost.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            frost.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            frost.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            
            // Tint overlay fills container
            tint.topAnchor.constraint(equalTo: container.topAnchor),
            tint.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            tint.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: vPad),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -vPad),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: hPad),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -hPad),
        ])
        
        return container
    }
    
    // MARK: - Presentation
    
    @MainActor
    private func present() {
        guard let screen = NSScreen.main else { return }
        
        // Position: bottom-center of visible screen area
        let visibleFrame = screen.visibleFrame
        let x = visibleFrame.midX - frame.width / 2
        let y = visibleFrame.minY + style.bottomOffset
        setFrameOrigin(NSPoint(x: x, y: y))
        
        // Start invisible + slightly scaled down for the spring entrance
        alphaValue = 0
        if let layer = contentView?.layer {
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.position = CGPoint(x: frame.width / 2, y: frame.height / 2)
            layer.setAffineTransform(CGAffineTransform(scaleX: 0.92, y: 0.92))
            
            // Core Animation spring for the scale — feels organic
            let spring = CASpringAnimation(keyPath: "transform.scale")
            spring.fromValue = 0.92
            spring.toValue = 1.0
            spring.damping = 14
            spring.stiffness = 300
            spring.mass = 0.8
            spring.duration = spring.settlingDuration
            spring.isRemovedOnCompletion = false
            spring.fillMode = .forwards
            layer.add(spring, forKey: "springScale")
            layer.setAffineTransform(.identity)
        }
        orderFrontRegardless()
        
        // Animate in: fade
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = style.fadeInDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1
        })
        
        // Hold, then fade out
        DispatchQueue.main.asyncAfter(deadline: .now() + style.holdDuration) { [weak self] in
            self?.fadeOutAndClose()
        }
    }
    
    @MainActor
    private func fadeOutAndClose() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = style.fadeOutDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.close()
                if Self.currentToast === self {
                    Self.currentToast = nil
                }
            }
        })
    }
    
    @MainActor
    private func dismissImmediately() {
        let ref = self
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            ref.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                ref.close()
            }
        })
        if Self.currentToast === self {
            Self.currentToast = nil
        }
    }
    
    // MARK: - Key handling (pass-through)
    
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}


// MARK: - Pill Container View

/// Clips contents to a pill shape with corner radius = height/2.
private final class PillContainerView: NSView {
    
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
    }
    
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    
    override var wantsUpdateLayer: Bool { true }
    
    override func updateLayer() {
        layer?.cornerRadius = bounds.height / 2
    }
}
