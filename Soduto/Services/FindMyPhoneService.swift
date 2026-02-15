//
//  FindMyPhoneService.swift
//  Soduto
//
//  Created by Giedrius Stanevičius on 2016-11-20.
//  Copyright © 2016 Soduto. All rights reserved.
//

import Foundation
import AppKit

/// Find my phone service data packet utilities
fileprivate extension DataPacket {
    
    static let findMyPhoneRequestPacketType = "kdeconnect.findmyphone.request"
    
    static func findMyPhonePacket() -> DataPacket {
        return DataPacket(type: findMyPhoneRequestPacketType, body: Body())
    }
}

/// Ring a phone even if it is silenced
public class FindMyPhoneService: NSObject, Service {
    
    // MARK: Types
    
    enum ActionId: ServiceAction.Id {
        case findMyPhone
    }
    
    // MARK: Properties
    
    private var soundPlayer: NSSound? = nil
    private var deviceRinging: Bool = false
    private var findMyPhoneWindow: NSWindow? = nil
    private var windowController: NSWindowController? = nil
    private var hoverTrackingArea: NSTrackingArea? = nil // Store a reference to the tracking area
    private var hoverButton: NSButton? = nil // Reference to the button for hover effects
    private var visualEffectView: NSVisualEffectView? = nil
    private var iconView: NSImageView? = nil
    private var titleLabel: NSTextField? = nil
    private var subtitleLabel: NSTextField? = nil
    private var initiatorName: String = ""
    
    // MARK: Service properties
    
    public static let serviceId: Service.Id = "com.soduto.services.findmyphone"
    
    public let incomingCapabilities = Set<Service.Capability>([ DataPacket.findMyPhoneRequestPacketType ])
    public let outgoingCapabilities = Set<Service.Capability>([ DataPacket.findMyPhoneRequestPacketType ])
    
    
    // MARK: Service methods
    
    /// NIO-compatible packet handler.
    public func handleDataPacket(_ dataPacket: DataPacket, fromDevice device: Device, onAnyConnection connection: AnyBaseConnection) -> Bool {
        return handleDataPacketCore(dataPacket, fromDevice: device)
    }
    
    public func handleDataPacket(_ dataPacket: DataPacket, fromDevice device: Device, onConnection connection: Connection) -> Bool {
        return handleDataPacketCore(dataPacket, fromDevice: device)
    }
    
    private func handleDataPacketCore(_ dataPacket: DataPacket, fromDevice device: Device) -> Bool {
        guard dataPacket.type == DataPacket.findMyPhoneRequestPacketType else { return false }
        
        // Only process requests from paired devices
        guard device.pairingStatus == .Paired else { return false }
        
        // Start the alert if not already ringing
        if !deviceRinging {
            startRinging(initiator: device.name)
        }
        
        return true
    }
    
    public func setup(for device: Device) {}
    
    public func cleanup(for device: Device) {}
    
    public func actions(for device: Device) -> [ServiceAction] {
        guard device.incomingCapabilities.contains(DataPacket.findMyPhoneRequestPacketType) else { return [] }
        
        return [
            ServiceAction(id: ActionId.findMyPhone.rawValue, title: "Find My Device", description: "Ring the device so you can find it", service: self, device: device)
        ]
    }
    
    public func performAction(_ id: ServiceAction.Id, forDevice device: Device) {
        guard let actionId = ActionId(rawValue: id) else { return }
        
        switch actionId {
        case .findMyPhone:
            device.send(DataPacket.findMyPhonePacket())
            break
        }
    }
    
    // MARK: Private methods
    
    private func startRinging(initiator: String) {
        deviceRinging = true
        initiatorName = initiator
        
        // Create and start playing system sound in a loop
        if let soundURL = NSURL(fileURLWithPath: "/System/Library/Sounds/Ping.aiff") as URL? {
            // Use the Ping sound which is crisp and attention-grabbing
            soundPlayer = NSSound(contentsOf: soundURL, byReference: true)
            soundPlayer?.loops = true
            soundPlayer?.volume = 1.0  // Maximum volume
            soundPlayer?.play()
        } else {
            // Fallback to system alert sound if custom sound not available
            NSSound.beep()
            
            // Schedule repeating beeps since we don't have the custom sound
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
                if self?.deviceRinging == true {
                    NSSound.beep()
                } else {
                    timer.invalidate()
                }
            }
        }
        
        // Display a window to allow stopping the ringing
        showFindMyPhoneWindow(initiator: initiator)
    }
    
    private func stopRinging() {
        deviceRinging = false
        
        // Stop the sound
        soundPlayer?.stop()
        soundPlayer = nil
        
        // Clear window references safely
        if let window = findMyPhoneWindow {
            // First remove the delegate to prevent callbacks during closing
            window.delegate = nil
            findMyPhoneWindow = nil
        }
        
        // Close the window controller last
        if let controller = windowController {
            // Use performSelector to defer the close operation slightly
            // This avoids potential memory issues during the current call stack
            controller.perform(#selector(NSWindowController.close), with: nil, afterDelay: 0.1)
            windowController = nil
        }
    }
    
    private func showFindMyPhoneWindow(initiator: String) {
        // Create a stylish window with visual effect (blur)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 220),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        
        // Configure window appearance
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.level = .floating // Always on top
        window.hasShadow = true
        window.center()
        
        // Create main content view with visual effect (blur)
        let visualEffectView = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 400, height: 220))
        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 20
        self.visualEffectView = visualEffectView
        
        // Create a container for content with some padding
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 220))
        container.wantsLayer = true
        
        // Add device icon
        let iconWidth: CGFloat = 130
        let iconHeight: CGFloat = 70
        let iconView = NSImageView(frame: NSRect(x: (400 - iconWidth)/2, y: 135, width: iconWidth, height: iconHeight))
        self.iconView = iconView
        
        // Create a modern phone icon
        let icon = NSImage(size: NSSize(width: iconWidth, height: iconHeight))
        icon.lockFocus()
        
        NSColor.white.setFill()
        
        // Draw modern phone shape - no home button, full screen design
        let phoneWidth: CGFloat = 30
        let phoneHeight: CGFloat = 50
        let phoneX = (iconWidth - phoneWidth) / 2
        let phoneY = (iconHeight - phoneHeight) / 2
        
        // Draw phone body with more rounded corners for a modern look
        let cornerRadius: CGFloat = 8.0
        let phoneRect = NSRect(x: phoneX, y: phoneY, width: phoneWidth, height: phoneHeight)
        let roundedPath = NSBezierPath(roundedRect: phoneRect, xRadius: cornerRadius, yRadius: cornerRadius)
        roundedPath.fill()
        
        // Draw screen (edge to edge, no bezels)
        let screenInset: CGFloat = 1.0
        let screenRect = NSRect(
            x: phoneX + screenInset,
            y: phoneY + screenInset,
            width: phoneWidth - (screenInset * 2),
            height: phoneHeight - (screenInset * 2)
        )
        let screenPath = NSBezierPath(roundedRect: screenRect, xRadius: cornerRadius - screenInset, yRadius: cornerRadius - screenInset)
        NSColor.black.withAlphaComponent(0.3).setFill()
        screenPath.fill()
        
        // Draw signal waves outside the phone
        let phoneCenterX = phoneX + (phoneWidth / 2)
        let phoneCenterY = phoneY + (phoneHeight / 2)
        
        for i in 0..<3 {
            // Make waves larger and ensure they're outside the phone
            let waveSize: CGFloat = phoneWidth + 50.0 + CGFloat(i * 10)
            let wavePath = NSBezierPath()
            
            // Draw half-circle waves radiating from phone (right side)
            wavePath.appendArc(
                withCenter: NSPoint(x: phoneCenterX, y: phoneCenterY),
                radius: waveSize/2,
                startAngle: -30,  // Start from top-right
                endAngle: 30)     // End at bottom-right
            
            NSColor.white.withAlphaComponent(0.6 - CGFloat(i) * 0.15).setStroke()
            wavePath.lineWidth = 2.0
            wavePath.stroke()
        }
        
        icon.unlockFocus()
        
        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        
        // Create title label
        let titleLabel = NSTextField(frame: NSRect(x: 20, y: 110, width: 360, height: 24))
        titleLabel.stringValue = "Find My Device"
        titleLabel.alignment = .center
        titleLabel.font = NSFont.systemFont(ofSize: 18, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.isBezeled = false
        titleLabel.isEditable = false
        titleLabel.drawsBackground = false
        self.titleLabel = titleLabel
        
        // Create subtitle label
        let subtitleLabel = NSTextField(frame: NSRect(x: 20, y: 80, width: 360, height: 20))
        subtitleLabel.stringValue = "\(initiator) is looking for this device"
        subtitleLabel.alignment = .center
        subtitleLabel.font = NSFont.systemFont(ofSize: 14)
        subtitleLabel.textColor = .white
        subtitleLabel.isBezeled = false
        subtitleLabel.isEditable = false
        subtitleLabel.drawsBackground = false
        self.subtitleLabel = subtitleLabel
        
        // Create a properly styled button that looks good without hover effects
        let buttonWidth: CGFloat = 160
        let buttonHeight: CGFloat = 36
        
        // Use NSButton with some custom styling
        let button = NSButton(frame: NSRect(x: (400 - buttonWidth) / 2, y: 30, width: buttonWidth, height: buttonHeight))
        button.title = "Stop Ringing"
        button.alignment = .center
        button.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        button.bezelStyle = .regularSquare // Use regularSquare for a flat appearance
        button.isBordered = false // Remove default button border
        button.target = self
        button.action = #selector(stopRingingAction)
        
        // Set up a proper appearance for the button
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
        button.layer?.cornerRadius = buttonHeight / 2 // Fully rounded corners
        
        // Set text color
        button.contentTintColor = .white
        
        // Make the button more responsive to clicks
        if let cell = button.cell as? NSButtonCell {
            cell.setButtonType(.momentaryPushIn) // Simple press effect
        }
        
        // Store reference to the button for hover effects
        self.hoverButton = button
        
        // Create a tracking area for the button to handle hover effects
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInActiveApp]
        self.hoverTrackingArea = NSTrackingArea(rect: button.bounds,
                                                options: options,
                                                owner: self,
                                                userInfo: nil)
        button.addTrackingArea(self.hoverTrackingArea!)
        
        // Add all elements to container
        container.addSubview(iconView)
        container.addSubview(titleLabel)
        container.addSubview(subtitleLabel)
        container.addSubview(button)
        
        // Add container to visual effect view
        visualEffectView.addSubview(container)
        
        // Set as window content
        window.contentView = visualEffectView
        
        // Set window delegate to handle close
        window.delegate = self
        
        // Create a window controller to manage the window lifecycle
        windowController = NSWindowController(window: window)
        findMyPhoneWindow = window
        
        // Add observer for appearance changes using the effectiveAppearance property
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateUIForAppearanceChange(_:)),
            name: NSNotification.Name("AppleColorPreferencesChangedNotification"),
            object: nil)
        
        // Also set up a polling timer as a fallback
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            if self?.deviceRinging == false {
                timer.invalidate()
                return
            }
            self?.updateUIForCurrentAppearance()
        }
        
        // Show window
        windowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        // Update UI for current appearance
        updateUIForCurrentAppearance()
    }
    
    @objc private func stopRingingAction() {
        stopRinging()
    }
    
    private func updateUIForCurrentAppearance() {
        guard let visualEffectView = self.visualEffectView else { return }
        
        // Determine if we're in dark mode
        let isEffectivelyDarkMode = visualEffectView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        
        // Force layout update to ensure appearance changes are applied
        visualEffectView.needsLayout = true
        visualEffectView.needsDisplay = true
        
        // Update the phone icon
        if let iconView = self.iconView {
            updatePhoneIcon(iconView, width: iconView.frame.width, height: iconView.frame.height)
            iconView.needsDisplay = true
        }
        
        // Update text colors for labels - ensure they change with appearance
        if let titleLabel = self.titleLabel {
            titleLabel.textColor = isEffectivelyDarkMode ? NSColor.white : NSColor.black
            // Force refresh
            titleLabel.needsDisplay = true
        }
        
        if let subtitleLabel = self.subtitleLabel {
            subtitleLabel.textColor = isEffectivelyDarkMode ? NSColor.white : NSColor.darkGray
            // Force refresh the label
            subtitleLabel.stringValue = "\(initiatorName) is looking for this device"
            subtitleLabel.needsDisplay = true
        }
        
        // Update button appearance
        if let button = self.hoverButton {
            // Clear previous styling
            button.contentTintColor = nil
            
            // Apply new styling based on current appearance
            if isEffectivelyDarkMode {
                button.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
                button.contentTintColor = NSColor.white
            } else {
                button.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.1).cgColor
                button.contentTintColor = NSColor.black
            }
            
            // Force refresh the button
            button.needsDisplay = true
            
            // Update the hover tracking area with the new appearance info
            if let oldTrackingArea = self.hoverTrackingArea {
                button.removeTrackingArea(oldTrackingArea)
            }
            
            let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInActiveApp]
            self.hoverTrackingArea = NSTrackingArea(rect: button.bounds,
                                                    options: options,
                                                    owner: self,
                                                    userInfo: ["isDark": isEffectivelyDarkMode])
            button.addTrackingArea(self.hoverTrackingArea!)
        }
        
        // Force window to update
        if let window = findMyPhoneWindow {
            window.contentView?.needsDisplay = true
            window.display()
        }
    }
    
    private func updatePhoneIcon(_ iconView: NSImageView, width: CGFloat, height: CGFloat) {
        guard let visualEffectView = self.visualEffectView else { return }
        
        // Detect if we're in dark mode
        let isEffectivelyDarkMode = visualEffectView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        
        // Create a new icon image with the appropriate color for current appearance
        let icon = NSImage(size: NSSize(width: width, height: height))
        icon.lockFocus()
        
        // Use color based on current appearance
        let foregroundColor = isEffectivelyDarkMode ? NSColor.white : NSColor.black
        foregroundColor.setFill()
        
        // Draw modern phone shape
        let phoneWidth: CGFloat = 30
        let phoneHeight: CGFloat = 50
        let phoneX = (width - phoneWidth) / 2
        let phoneY = (height - phoneHeight) / 2
        
        // Draw phone body with more rounded corners
        let cornerRadius: CGFloat = 8.0
        let phoneRect = NSRect(x: phoneX, y: phoneY, width: phoneWidth, height: phoneHeight)
        let roundedPath = NSBezierPath(roundedRect: phoneRect, xRadius: cornerRadius, yRadius: cornerRadius)
        roundedPath.fill()
        
        // Draw screen
        let screenInset: CGFloat = 1.0
        let screenRect = NSRect(
            x: phoneX + screenInset,
            y: phoneY + screenInset,
            width: phoneWidth - (screenInset * 2),
            height: phoneHeight - (screenInset * 2)
        )
        let screenPath = NSBezierPath(roundedRect: screenRect, xRadius: cornerRadius - screenInset, yRadius: cornerRadius - screenInset)
        NSColor.lightGray.withAlphaComponent(0.3).setFill()
        screenPath.fill()
        
        // Draw signal waves
        let phoneCenterX = phoneX + (phoneWidth / 2)
        let phoneCenterY = phoneY + (phoneHeight / 2)
        
        for i in 0..<3 {
            let waveSize: CGFloat = phoneWidth + 50.0 + CGFloat(i * 10)
            let wavePath = NSBezierPath()
            
            wavePath.appendArc(
                withCenter: NSPoint(x: phoneCenterX, y: phoneCenterY),
                radius: waveSize/2,
                startAngle: -30,
                endAngle: 30)
            
            foregroundColor.withAlphaComponent(0.6 - CGFloat(i) * 0.15).setStroke()
            wavePath.lineWidth = 2.0
            wavePath.stroke()
        }
        
        icon.unlockFocus()
        
        // Update the image view with the new icon
        iconView.image = icon
    }
    
    deinit {
        // Clean up notification observers
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc private func updateUIForAppearanceChange(_ notification: Notification) {
        // Update UI for appearance changes
        updateUIForCurrentAppearance()
    }
}

// MARK: - NSWindowDelegate

extension FindMyPhoneService: NSWindowDelegate {
    public func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow == findMyPhoneWindow {
            stopRinging()
        }
    }
}

// MARK: - Mouse tracking methods

extension FindMyPhoneService {
    // Called when mouse enters the button area
    @objc public func mouseEntered(_ event: NSEvent) {
        if let button = self.hoverButton,
            let userInfo = event.trackingArea?.userInfo as? [String: Any],
           let isDark = userInfo["isDark"] as? Bool {
            
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                if isDark {
                    button.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.4).cgColor
                } else {
                    button.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.2).cgColor
                }
            })
        }
    }
    
    // Called when mouse exits the button area
    @objc public func mouseExited(_ event: NSEvent) {
        if let button = self.hoverButton,
           let userInfo = event.trackingArea?.userInfo as? [String: Any],
           let isDark = userInfo["isDark"] as? Bool {
            
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                if isDark {
                    button.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
                } else {
                    button.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.1).cgColor
                }
            })
        }
    }
}
