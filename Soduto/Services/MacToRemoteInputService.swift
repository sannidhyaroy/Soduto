//
//  MacToRemoteInputService.swift
//  Soduto
//
//  Created on 2025-04-27.
//  Copyright © 2025 Soduto. All rights reserved.
//

import Foundation
import Cocoa
import os

public class MacToRemoteInputService: Service {
    
    // MARK: - Service Properties
    
    public static let serviceId: Service.Id = "com.soduto.services.mactoremoteinput"
    
    // Define our own public constant to match the private one in RemoteKeyboardService
    public static let packetTypeMacToRemoteKeyboard = "kdeconnect.mousepad.request"
    
    public let incomingCapabilities = Set<Service.Capability>([])
    public let outgoingCapabilities = Set<Service.Capability>([
        MacToRemoteInputService.packetTypeMacToRemoteKeyboard
    ])
    
    // MARK: - Private Properties
    
    private var isCapturing = false
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    private var keyDownEventMonitor: Any?
    private var flagsChangedMonitor: Any?
    private var targetDevice: Device?
    private var hudWindow: NSWindow?
    private var lastMouseLocation: NSPoint?
    private var lastClickTime: TimeInterval = 0
    private var escapeComboMonitor: Any?
    private var escapeKeyPressed: Bool = false
    private var optionKeyPressed: Bool = false
    private var invisibleCursor: NSCursor?
    private var originalMouseLocation: NSPoint?
    private var eventTap: CFMachPort?
    private var eventRunLoopSource: CFRunLoopSource?
    private var capturedDisplay: CGDirectDisplayID?
    private var exitKeyTimer: Timer?
    private var exitKeyModifiers = 0
    private var lastOptionKeyTime: TimeInterval = 0
    
    // Constants for scaling mouse movement
    private let mouseMoveSensitivity: CGFloat = 1.0
    
    // Drag state tracking
    private var isDragging: Bool = false
    
    // MARK: - Service Methods
    
    public func handleDataPacket(_ dataPacket: DataPacket, fromDevice device: Device, onConnection connection: Connection) -> Bool {
        // This service doesn't handle incoming packets
        return false
    }
    
    public func setup(for device: Device) {}
    
    public func cleanup(for device: Device) {
        if targetDevice?.id == device.id {
            stopCapturing()
        }
    }
    
    // MARK: - Action IDs
    
    private enum ActionId: Int {
        case startInputCapturing = 1
        case stopInputCapturing = 2
    }
    
    public func actions(for device: Device) -> [ServiceAction] {
        if device.pairingStatus != .Paired || !device.isReachable {
            return []
        }
        
        if isCapturing && targetDevice?.id == device.id {
            return [
                ServiceAction(id: ActionId.stopInputCapturing.rawValue, title: "Stop Input Capture", description: "Stop sending input to this device", service: self, device: device)
            ]
        } else {
            return [
                ServiceAction(id: ActionId.startInputCapturing.rawValue, title: "Control Remote Device", description: "Send keyboard and mouse input to this device", service: self, device: device)
            ]
        }
    }
    
    public func performAction(_ id: ServiceAction.Id, forDevice device: Device) {
        switch id {
        case ActionId.startInputCapturing.rawValue:
            startCapturing(for: device)
        case ActionId.stopInputCapturing.rawValue:
            stopCapturing()
        default:
            Logger.services.notice("Unknown action id: \(id, privacy: .public)")
        }
    }
    
    // MARK: - Input Capturing
    
    private func startCapturing(for device: Device) {
        guard !isCapturing else { return }
        guard device.pairingStatus == .Paired else { return }
        
        Logger.services.info("Starting input capture for device: \(device.name, privacy: .public)")
        
        targetDevice = device
        isCapturing = true
        isDragging = false
        
        // Check accessibility permissions
        checkAndRequestAccessibilityPermissions { [weak self] granted in
            guard let self = self else { return }
            
            if !granted {
                DispatchQueue.main.async {
                    self.stopCapturing()
                }
                return
            }
            
            DispatchQueue.main.async {
                self.setupEventMonitors()
                self.showHUD()
                self.hideCursorAndRestrictToCenter()
            }
        }
    }
    
    private func stopCapturing() {
        // Ensure this runs on the main thread to avoid threading issues
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.stopCapturing()
            }
            return
        }
        
        // Check if we're already stopped to avoid double-cleanup
        guard isCapturing else { return }
        
        Logger.services.info("Stopping input capture")
        
        // Set isCapturing to false first to prevent any further events from being processed
        isCapturing = false
        
        // If we were in the middle of a drag operation when stopping, send a mouse up event
        if isDragging, let device = targetDevice {
            sendMouseUp(to: device)
            isDragging = false
        }
        
        // Clear the target device reference
        targetDevice = nil
        
        // Make sure we release resources in the correct order to avoid crashes
        // First remove the event tap
        removeEventTap()
        
        // Release all monitors
        releaseMonitors()
        
        // Reset tracking variables
        lastOptionKeyTime = 0
        lastMouseLocation = nil
        escapeKeyPressed = false
        optionKeyPressed = false
        
        // Show cursor and restore position
        showCursorAndRestorePosition()
        
        // Hide HUD last, after all other cleanup is done
        hideHUD()
        
        Logger.services.info("Input capture stopped successfully")
    }
    
    // MARK: - Cursor Management
    
    private func hideCursorAndRestrictToCenter() {
        // Save original mouse position to restore later
        originalMouseLocation = NSEvent.mouseLocation
        
        // Create an invisible cursor
        let blankImage = NSImage(size: NSSize(width: 1, height: 1))
        invisibleCursor = NSCursor(image: blankImage, hotSpot: NSPoint(x: 0, y: 0))
        NSCursor.hide()
        invisibleCursor?.push()
        
        // Center the cursor on screen to avoid edge triggering
        centerCursorOnScreen()
        
        // Set up an event tap to prevent the cursor from moving too far from center
        setupEventTap()
    }
    
    private func showCursorAndRestorePosition() {
        // Restore normal cursor
        if invisibleCursor != nil {
            invisibleCursor?.pop()
            invisibleCursor = nil
            NSCursor.unhide()
        }
        
        // Restore original mouse position
        if let originalPosition = originalMouseLocation {
            CGWarpMouseCursorPosition(CGPoint(x: originalPosition.x, y: originalPosition.y))
        }
        
        // Remove the event tap
        removeEventTap()
    }
    
    private func centerCursorOnScreen() {
        if let screen = NSScreen.main {
            let centerX = screen.frame.midX
            let centerY = screen.frame.midY
            CGWarpMouseCursorPosition(CGPoint(x: centerX, y: centerY))
        }
    }
    
    private func setupEventTap() {
        // Get the event tap mask to capture ALL event types including gestures
        let eventMask = createEventMask()
        
        guard let tap = createTap(withEventMask: eventMask) else {
            Logger.services.error("Failed to create event tap")
            return
        }
        
        eventTap = tap
        
        // Create a run loop source and add it to the current run loop
        eventRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource = eventRunLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        
        // Enable the tap
        CGEvent.tapEnable(tap: tap, enable: true)
    }
    
    private func removeEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            
            if let runLoopSource = eventRunLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
                eventRunLoopSource = nil
            }
            
            eventTap = nil
        }
    }
    
    private func createEventMask() -> CGEventMask {
        // Use kCGEventMaskForAllEvents to capture all possible input events
        // This ensures we don't miss any gestures or input types that our manual mask might miss
        return ~0
    }
    
    private func createTap(withEventMask eventMask: CGEventMask) -> CFMachPort? {
        // Create a high-priority event tap that intercepts all events
        return CGEvent.tapCreate(
            tap: .cgSessionEventTap,         // Capture at session level (current user session)
            place: .headInsertEventTap,      // Insert at the beginning of the event chain
            options: .defaultTap,            // Allow us to modify and block events
            eventsOfInterest: eventMask,     // Use kCGEventMaskForAllEvents from createEventMask()
            callback: eventTapCallback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )
    }
    
    private func handleEventTapEvent(_ type: CGEventType, _ event: CGEvent, for device: Device) -> Unmanaged<CGEvent>? {
        switch type {
        case .mouseMoved:
            handleMouseMovedEvent(event, for: device)
            
        case .leftMouseDown:
            if event.getIntegerValueField(.mouseEventClickState) == 2 {
                sendDoubleClick(to: device)
            } else {
                sendMouseDown(to: device)
            }
            // Swallow the event so it doesn't reach macOS
            return nil
            
        case .leftMouseUp:
            sendMouseUp(to: device)
            // Swallow the event so it doesn't reach macOS
            return nil
            
        case .rightMouseDown:
            sendRightClick(to: device)
            // Swallow the event so it doesn't reach macOS
            return nil
            
        case .otherMouseDown:
            sendMiddleClick(to: device)
            // Swallow the event so it doesn't reach macOS
            return nil
            
        case .scrollWheel:
            handleScrollEvent(event, for: device)
            // Swallow the event so it doesn't reach macOS
            return nil
            
        default:
            break
        }
        
        // For any event type we don't explicitly handle, stop it from reaching macOS
        return nil
    }
    
    private func handleMouseMovedEvent(_ event: CGEvent, for device: Device) {
        // Parse the delta and send to remote device
        let dx = event.getDoubleValueField(.mouseEventDeltaX)
        let dy = event.getDoubleValueField(.mouseEventDeltaY)
        
        if abs(dx) > 0.5 || abs(dy) > 0.5 {
            // If we're in drag mode, ensure the mouse button is held down
            if isDragging && event.type != .mouseMoved {
                // We're already in a drag operation, just send the movement
                sendMouseMove(dx: CGFloat(dx), dy: CGFloat(dy), to: device)
            } else {
                // Normal mouse movement
                sendMouseMove(dx: CGFloat(dx), dy: CGFloat(dy), to: device)
            }
        }
        
        // ALWAYS center the cursor to avoid reaching screen edges
        // This is critical for maintaining proper control during input capturing
        if let screen = NSScreen.main {
            let centerPoint = CGPoint(x: screen.frame.midX, y: screen.frame.midY)
            event.location = centerPoint
            
            // For maximum reliability, also directly warp the cursor position
            // This ensures the cursor stays centered even if event.location doesn't work
            CGWarpMouseCursorPosition(centerPoint)
        }
    }
    
    private func handleScrollEvent(_ event: CGEvent, for device: Device) {
        let dx = event.getDoubleValueField(.scrollWheelEventDeltaAxis2)
        let dy = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
        if abs(dx) > 0.1 || abs(dy) > 0.1 {
            sendScroll(dx: dx, dy: dy, to: device)
        }
    }
    
    private func checkAndRequestAccessibilityPermissions(completion: @escaping (Bool) -> Void) {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let accessEnabled = AXIsProcessTrustedWithOptions(options)
        
        if !accessEnabled {
            Logger.services.notice("Accessibility permissions not granted. Prompting user.")
            
            // Show an alert explaining why we need accessibility permissions
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Accessibility Permissions Required"
                alert.informativeText = "To send keyboard and mouse input to remote devices, Soduto needs accessibility permissions. Please grant access in System Settings > Privacy & Security > Accessibility."
                alert.addButton(withTitle: "Open System Settings")
                alert.addButton(withTitle: "Cancel")
                
                let response = alert.runModal()
                if response == .alertFirstButtonReturn {
                    if #available(macOS 13.0, *) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    } else {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/PreferencePanes/Security.prefPane"))
                    }
                }
                
                completion(false)
            }
        } else {
            Logger.services.info("Accessibility permissions already granted.")
            completion(true)
        }
    }
    
    private func setupEventMonitors() {
        // IMPORTANT: The order of event monitors registration is critical
        // NSEvent monitoring happens in reverse order of registration
        // We register from lowest to highest priority:
        
        // 1. First, set up the global mouse monitor (lowest priority)
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]) { [weak self] event in
            guard let self = self, self.isCapturing else { return }
            _ = self.handleMouseEvent(event)
        }
        
        // 2. Set up global key monitor as an additional safety net for Option+Escape detection
        // This monitor will help detect the key combination even if local monitors miss it
        keyDownEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self = self, self.isCapturing else { return }
            
            // Use our dedicated helper method to reliably detect Option+Escape
            if event.keyCode == 53 {
                // For Escape key events, check if Option is pressed or was recently pressed
                if event.type == .keyDown {
                    if event.modifierFlags.contains(.option) || self.optionKeyPressed {
                        Logger.services.debug("Global Option+Escape detected, stopping capture")
                        DispatchQueue.main.async {
                            self.stopCapturing()
                        }
                    }
                } else if event.type == .keyUp {
                    if event.modifierFlags.contains(.option) || self.optionKeyPressed {
                        Logger.services.debug("Global Option+Escape key-up detected")
                    }
                }
            }
            
            // Note: Global monitors can only observe events, not block them
            // Local monitors must handle the actual blocking of events
        }
        
        // 3. Set up flags changed global monitor for redundant Option key tracking
        // This is a safety net to catch Option key events that might bypass local monitors
        flagsChangedMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            guard let self = self, self.isCapturing else { return }
            
            // Track option key state redundantly at the global level
            let wasPreviouslyPressed = self.optionKeyPressed
            let isCurrentlyPressed = event.modifierFlags.contains(.option)
            
            if isCurrentlyPressed && !wasPreviouslyPressed {
                self.optionKeyPressed = true
                Logger.services.debug("Option key pressed (global monitor)")
                
                // Record the timestamp of the Option press for time-based detection
                self.lastOptionKeyTime = Date().timeIntervalSince1970
            }
            else if !isCurrentlyPressed && wasPreviouslyPressed {
                self.optionKeyPressed = false
                Logger.services.debug("Option key released (global monitor)")
            }
            
            // Note: Global monitors can't block events, they're observation only
            // The local monitors must handle the actual blocking
        }
        
        // 4. Dedicated high-priority monitor specifically for Option+Escape
        // This is our primary defense - it runs first and aggressively blocks the combination
        escapeComboMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self = self, self.isCapturing else { return event }
            
            // FIRST PRIORITY: Always aggressively catch and block Option+Escape
            
            // Special handling for flagsChanged - track the Option key state
            if event.type == .flagsChanged {
                // Update our option key tracking
                let wasOptionPressed = self.optionKeyPressed
                self.optionKeyPressed = event.modifierFlags.contains(.option)
                
                if self.optionKeyPressed && !wasOptionPressed {
                    // Option key was just pressed
                    Logger.services.debug("Option key pressed (high priority monitor)")
                } else if !self.optionKeyPressed && wasOptionPressed {
                    // Option key was just released
                    Logger.services.debug("Option key released (high priority monitor)")
                }
                
                // CRITICAL: Always block ALL flagsChanged during capture to prevent modifiers
                // from reaching applications - this is key to capturing Option+Escape
                return nil
            }
            
            // Detect and block Escape key with Option modifier
            if event.keyCode == 53 { // Escape key
                // Check for direct Option+Escape or Option followed by Escape
                if event.modifierFlags.contains(.option) || self.optionKeyPressed {
                    if event.type == .keyDown {
                        Logger.services.debug("Option+Escape detected by high priority monitor, stopping capture")
                        
                        // Schedule stop on main thread
                        DispatchQueue.main.async {
                            self.stopCapturing()
                        }
                    } else {
                        Logger.services.debug("Option+Escape key-up detected and blocked")
                    }
                    
                    // CRITICAL: Never allow Option+Escape to pass through
                    return nil
                }
            }
            
            // For all other events, let them through to be processed by other monitors
            return event
        }
        
        // 5. Finally set up the standard event monitor for all other input events
        // This is registered last, so it runs before the escape monitors above
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .keyDown, .keyUp, .flagsChanged,
                .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                .otherMouseDown, .otherMouseUp
        ]) { [weak self] event in
            guard let self = self, self.isCapturing else { return event }
            
            // LAST RESORT: Option+Escape interception
            // This is our final defense if the dedicated monitors somehow miss the combo
            
            // First check if this is an Option+Escape event using our dedicated helper
            if self.isOptionEscapeCombo(event) {
                Logger.services.debug("Option+Escape caught by fallback monitor - CRITICAL SAFETY NET")
                
                // Only trigger stop on key down
                if event.type == .keyDown {
                    DispatchQueue.main.async {
                        self.stopCapturing()
                    }
                }
                
                // ALWAYS block Option+Escape events completely
                return nil
            }
            
            // Special handling for modifier key events
            if event.type == .flagsChanged {
                // Track option key state as backup
                self.optionKeyPressed = event.modifierFlags.contains(.option)
                Logger.services.debug("Option key state: \(self.optionKeyPressed ? "pressed" : "released", privacy: .public) (fallback)")
                
                // Prevent ALL modifier key events from reaching applications during capture
                // This is critical to ensure modifiers don't affect background applications
                return nil
            }
            
            // Extra check specifically for Escape key
            if event.keyCode == 53 {
                // If we already know Option is pressed, this is definitely Option+Escape
                if self.optionKeyPressed {
                    Logger.services.debug("Option+Escape intercepted via separate key events (fallback)")
                    
                    if event.type == .keyDown {
                        DispatchQueue.main.async {
                            self.stopCapturing()
                        }
                    }
                    
                    // Block all Escape events when Option is being held
                    return nil
                }
            }
            
            // Process other events
            if self.handleKeyEvent(event) || self.handleMouseButtonEvent(event) {
                // Return nil to prevent the event from being passed to the application
                return nil
            }
            
            return event
        }
    }
    
    private func releaseMonitors() {
        if let globalEventMonitor = globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
        
        if let localEventMonitor = localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        
        if let keyDownEventMonitor = keyDownEventMonitor {
            NSEvent.removeMonitor(keyDownEventMonitor)
            self.keyDownEventMonitor = nil
        }
        
        if let escapeComboMonitor = escapeComboMonitor {
            NSEvent.removeMonitor(escapeComboMonitor)
            self.escapeComboMonitor = nil
        }
        
        if let flagsChangedMonitor = flagsChangedMonitor {
            NSEvent.removeMonitor(flagsChangedMonitor)
            self.flagsChangedMonitor = nil
        }
        
        // Cancel any pending timers
        exitKeyTimer?.invalidate()
        exitKeyTimer = nil
    }
    
    // MARK: - Event Handling
    
    private func handleMouseEvent(_ event: NSEvent) -> Bool {
        guard isCapturing, let device = targetDevice else { return false }
        
        switch event.type {
        case .mouseMoved:
            let currentLocation = NSEvent.mouseLocation
            
            if let lastMouseLocation = lastMouseLocation {
                let dx = (currentLocation.x - lastMouseLocation.x) * mouseMoveSensitivity
                let dy = (currentLocation.y - lastMouseLocation.y) * mouseMoveSensitivity
                
                // Only send if there's actual movement
                if abs(dx) > 0.5 || abs(dy) > 0.5 {
                    sendMouseMove(dx: dx, dy: -dy, to: device) // Invert y-axis
                }
            }
            
            lastMouseLocation = currentLocation
            return true
            
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let currentLocation = NSEvent.mouseLocation
            
            // For drag events, make sure mouse is held down
            if !isDragging && event.type == .leftMouseDragged {
                isDragging = true
                sendMouseDown(to: device)
                // Small delay to ensure press is registered before movement
                usleep(10000)
            }
            
            if let lastMouseLocation = lastMouseLocation {
                let dx = (currentLocation.x - lastMouseLocation.x) * mouseMoveSensitivity
                let dy = (currentLocation.y - lastMouseLocation.y) * mouseMoveSensitivity
                
                // Only send if there's actual movement
                if abs(dx) > 0.5 || abs(dy) > 0.5 {
                    sendMouseMove(dx: dx, dy: -dy, to: device) // Invert y-axis
                }
            }
            
            lastMouseLocation = currentLocation
            return true
            
        case .scrollWheel:
            let dx = Double(event.scrollingDeltaX)
            let dy = Double(event.scrollingDeltaY)
            
            // Only send if there's actual scrolling
            if abs(dx) > 0.1 || abs(dy) > 0.1 {
                sendScroll(dx: dx, dy: dy, to: device)
            }
            
            return true
            
        default:
            return false
        }
    }
    
    private func handleMouseButtonEvent(_ event: NSEvent) -> Bool {
        guard isCapturing, let device = targetDevice else { return false }
        
        switch event.type {
        case .leftMouseDown:
            if event.clickCount == 2 {
                sendDoubleClick(to: device)
            } else if event.clickCount == 1 {
                // Check if it might be part of a drag operation
                if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
                    // Let command-click and option-click pass through to local app
                    return false
                } else {
                    // Set drag state as active
                    isDragging = true
                    sendMouseDown(to: device)
                }
            }
            return true
            
        case .leftMouseUp:
            if event.clickCount == 1 && !event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.option) {
                // If this is a single click that's not a modifier-click
                let currentTime = Date().timeIntervalSince1970
                if currentTime - lastClickTime > 0.3 { // Not part of a double-click
                    // End any drag operation that might be in progress
                    isDragging = false
                    sendMouseUp(to: device)
                }
                lastClickTime = currentTime
            }
            return true
            
        case .rightMouseDown:
            sendRightClick(to: device)
            return true
            
        case .otherMouseDown:
            sendMiddleClick(to: device)
            return true
            
        default:
            return false
        }
    }
    
    private func isOptionEscapeCombo(_ event: NSEvent) -> Bool {
        // This helper function checks if an event is part of an Option+Escape combination
        // We use multiple detection strategies for maximum reliability
        
        // First, set up constants for time-based detection
        let optionEscapeTimeWindow: TimeInterval = 0.5 // Half a second window for Option+Escape sequence
        let currentTime = Date().timeIntervalSince1970
        
        // Strategy 1: Direct detection - Escape key with Option modifier flag
        if event.keyCode == 53 && event.modifierFlags.contains(.option) {
            Logger.services.debug("Option+Escape combo detected (direct modifier flags)")
            return true
        }
        
        // Strategy 2: State-based detection - Escape key press while Option is being tracked as pressed
        if event.keyCode == 53 && optionKeyPressed {
            Logger.services.debug("Option+Escape combo detected (tracked option state)")
            return true
        }
        
        // Strategy 3: Time-based detection - Escape pressed shortly after Option
        if event.keyCode == 53 && lastOptionKeyTime > 0 {
            let timeSinceOption = currentTime - lastOptionKeyTime
            if timeSinceOption < optionEscapeTimeWindow {
                Logger.services.debug("Option+Escape combo detected (time-based: \(timeSinceOption, privacy: .public)s)")
                return true
            }
        }
        
        // Strategy 4: For flagsChanged events, update our tracking state but don't
        // consider them Option+Escape combos by themselves
        if event.type == .flagsChanged {
            if event.modifierFlags.contains(.option) {
                lastOptionKeyTime = currentTime
                optionKeyPressed = true
            } else if optionKeyPressed {
                // Only reset optionKeyPressed if we think it was pressed before
                // This helps with tracking state properly
                optionKeyPressed = false
            }
        }
        
        return false
    }
    
    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard isCapturing, let device = targetDevice else { return false }
        
        let shift = event.modifierFlags.contains(.shift)
        let ctrl = event.modifierFlags.contains(.control)
        let alt = event.modifierFlags.contains(.option)
        
        // Always check for Option+Escape combination as highest priority
        // This is our final line of defense against the combo reaching apps
        if isOptionEscapeCombo(event) {
            Logger.services.debug("Option+Escape intercepted in handleKeyEvent, stopping capture")
            
            // We only want to trigger stopCapturing on keyDown events, not keyUp
            if event.type == .keyDown {
                DispatchQueue.main.async { [weak self] in
                    self?.stopCapturing()
                }
            }
            
            // Critical: Always return true for Option+Escape to ensure the monitor blocks it
            // This ensures the event is completely consumed and never passes to applications
            return true
        }
        
        // Process other events based on type
        switch event.type {
        case .keyDown:
            let key = event.characters ?? ""
            let keyCode = event.keyCode
            let specialKey = mapKeyCodeToSpecialKey(keyCode)
            
            // Process other keys normally
            if specialKey != nil {
                sendSpecialKey(specialKey!, shift: shift, ctrl: ctrl, alt: alt, to: device)
            } else if !key.isEmpty {
                sendKey(key, shift: shift, ctrl: ctrl, alt: alt, to: device)
            }
            return true
            
        case .flagsChanged:
            // Track option key state for potential escape combo detection
            // This state tracking is critical for detecting Option+Escape
            if event.modifierFlags.contains(.option) {
                // Record the time and state of the option key press
                lastOptionKeyTime = Date().timeIntervalSince1970
                optionKeyPressed = true
                Logger.services.debug("Option key detected (keyEvent handler)")
            } else if optionKeyPressed {
                // Option key was released
                lastOptionKeyTime = 0
                optionKeyPressed = false
                Logger.services.debug("Option key released (keyEvent handler)")
            }
            
            // Always consume flagsChanged events while capturing is active
            // This is critical to prevent modifiers from affecting other apps
            return true
            
        default:
            return false
        }
    }
    
    // MARK: - Packet Sending
    
    private func sendMouseMove(dx: CGFloat, dy: CGFloat, to device: Device) {
        let body: DataPacket.Body = [
            "dx": dx as NSNumber,
            "dy": dy as NSNumber
        ]
        
        let packet = DataPacket(type: MacToRemoteInputService.packetTypeMacToRemoteKeyboard, body: body)
        device.send(packet)
    }
    
    private func sendScroll(dx: Double, dy: Double, to device: Device) {
        let body: DataPacket.Body = [
            "scroll": true as NSNumber,
            "dx": dx as NSNumber,
            "dy": dy as NSNumber
        ]
        
        let packet = DataPacket(type: MacToRemoteInputService.packetTypeMacToRemoteKeyboard, body: body)
        device.send(packet)
    }
    
    private func sendMouseDown(to device: Device) {
        let body: DataPacket.Body = [
            "singlehold": true as NSNumber
        ]
        
        let packet = DataPacket(type: MacToRemoteInputService.packetTypeMacToRemoteKeyboard, body: body)
        device.send(packet)
    }
    
    private func sendMouseUp(to device: Device) {
        let body: DataPacket.Body = [
            "singlerelease": true as NSNumber
        ]
        
        let packet = DataPacket(type: MacToRemoteInputService.packetTypeMacToRemoteKeyboard, body: body)
        device.send(packet)
    }
    
    private func sendSingleClick(to device: Device) {
        let body: DataPacket.Body = [
            "singleclick": true as NSNumber
        ]
        
        let packet = DataPacket(type: MacToRemoteInputService.packetTypeMacToRemoteKeyboard, body: body)
        device.send(packet)
    }
    
    private func sendDoubleClick(to device: Device) {
        // Instead of sending a doubleclick packet directly, simulate with two quick clicks
        // This prevents triggering the overview on Android
        
        // First click
        sendMouseDown(to: device)
        
        // Small delay to make it register as separate clicks
        usleep(20000) // 20ms
        
        sendMouseUp(to: device)
        
        // Gap between clicks
        usleep(40000) // 40ms
        
        // Second click
        sendMouseDown(to: device)
        usleep(20000) // 20ms
        sendMouseUp(to: device)
    }
    
    private func sendRightClick(to device: Device) {
        let body: DataPacket.Body = [
            "rightclick": true as NSNumber
        ]
        
        let packet = DataPacket(type: MacToRemoteInputService.packetTypeMacToRemoteKeyboard, body: body)
        device.send(packet)
    }
    
    private func sendMiddleClick(to device: Device) {
        let body: DataPacket.Body = [
            "middleclick": true as NSNumber
        ]
        
        let packet = DataPacket(type: MacToRemoteInputService.packetTypeMacToRemoteKeyboard, body: body)
        device.send(packet)
    }
    
    private func sendKey(_ key: String, shift: Bool, ctrl: Bool, alt: Bool, to device: Device) {
        var body: DataPacket.Body = [
            "key": key as NSString,
            "sendAck": false as NSNumber
        ]
        
        if shift { body["shift"] = true as NSNumber }
        if ctrl { body["ctrl"] = true as NSNumber }
        if alt { body["alt"] = true as NSNumber }
        
        let packet = DataPacket(type: MacToRemoteInputService.packetTypeMacToRemoteKeyboard, body: body)
        device.send(packet)
    }
    
    private func sendSpecialKey(_ keyCode: Int, shift: Bool, ctrl: Bool, alt: Bool, to device: Device) {
        var body: DataPacket.Body = [
            "specialKey": keyCode as NSNumber,
            "sendAck": false as NSNumber
        ]
        
        if shift { body["shift"] = true as NSNumber }
        if ctrl { body["ctrl"] = true as NSNumber }
        if alt { body["alt"] = true as NSNumber }
        
        let packet = DataPacket(type: MacToRemoteInputService.packetTypeMacToRemoteKeyboard, body: body)
        device.send(packet)
    }
    
    // MARK: - Key Mapping
    
    private func mapKeyCodeToSpecialKey(_ keyCode: UInt16) -> Int? {
        switch keyCode {
        case 51: return 1  // Delete/Backspace
        case 48: return 2  // Tab
        case 36: return 3  // Return/Enter
        case 123: return 4 // Left Arrow
        case 126: return 5 // Up Arrow
        case 124: return 6 // Right Arrow
        case 125: return 7 // Down Arrow
        case 116: return 8 // Page Up
        case 121: return 9 // Page Down
        case 115: return 10 // Home
        case 119: return 11 // End
        case 117: return 13 // Forward Delete
        case 53: return 14  // Escape
        case 122: return 21 // F1
        case 120: return 22 // F2
        case 99: return 23  // F3
        case 118: return 24 // F4
        case 96: return 25  // F5
        case 97: return 26  // F6
        case 98: return 27  // F7
        case 100: return 28 // F8
        case 101: return 29 // F9
        case 109: return 30 // F10
        case 103: return 31 // F11
        case 111: return 32 // F12
        default: return nil
        }
    }
    
    // MARK: - HUD Window
    
    private func showHUD() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        
        window.level = .floating // Always on top
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.ignoresMouseEvents = true
        
        // Create visual effect view for the blur effect
        let visualEffectView = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 10
        visualEffectView.layer?.masksToBounds = true
        
        // Create container for content
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        container.translatesAutoresizingMaskIntoConstraints = false
        
        // Create title label
        let titleLabel = NSTextField(labelWithString: "Controlling Remote Device")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.boldSystemFont(ofSize: 16)
        titleLabel.textColor = .white
        titleLabel.alignment = .center
        container.addSubview(titleLabel)
        
        // Create device name label
        let deviceNameLabel = NSTextField(labelWithString: targetDevice?.name ?? "")
        deviceNameLabel.translatesAutoresizingMaskIntoConstraints = false
        deviceNameLabel.font = NSFont.systemFont(ofSize: 14)
        deviceNameLabel.textColor = .white
        deviceNameLabel.alignment = .center
        container.addSubview(deviceNameLabel)
        
        // Create instruction label
        let instructionLabel = NSTextField(labelWithString: "Press Option+Escape to stop")
        instructionLabel.translatesAutoresizingMaskIntoConstraints = false
        instructionLabel.font = NSFont.systemFont(ofSize: 12)
        instructionLabel.textColor = .white
        instructionLabel.alignment = .center
        container.addSubview(instructionLabel)
        
        // Set constraints
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 15),
            titleLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
            
            deviceNameLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            deviceNameLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            deviceNameLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 20),
            deviceNameLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
            
            instructionLabel.topAnchor.constraint(equalTo: deviceNameLabel.bottomAnchor, constant: 15),
            instructionLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            instructionLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 20),
            instructionLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
        ])
        
        // Add views to hierarchy
        visualEffectView.addSubview(container)
        window.contentView = visualEffectView
        
        // Set container constraints
        container.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
            container.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor)
        ])
        
        // Position window at the top of the screen
        if let screen = NSScreen.main {
            let screenRect = screen.frame
            let windowSize = window.frame.size
            let x = (screenRect.width - windowSize.width) / 2
            let y = screenRect.height - windowSize.height - 50 // 50px from top
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }
        
        self.hudWindow = window
        window.orderFrontRegardless()
        
        // Ensure window stays completely opaque
        window.alphaValue = 1.0
    }
    
    private func hideHUD() {
        // Never close the window directly as it may cause a crash
        // Instead, safely remove it from view and then clear our reference
        
        if let window = self.hudWindow {
            // Order it out first
            window.orderOut(nil)
            
            // Clear any content and release references that might be retained
            window.contentView = nil
            
            // Clear our reference - the window should be deallocated if no other references exist
            self.hudWindow = nil
            
            Logger.services.info("HUD window safely hidden and reference cleared")
        }
    }
    
    // MARK: - Event Tap Callback
    
    private let eventTapCallback: CGEventTapCallBack = { proxy, type, event, refcon in
        guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
        
        // Get reference to self from the user info
        let service = Unmanaged<MacToRemoteInputService>.fromOpaque(refcon).takeUnretainedValue()
        
        // Only process events if we're capturing input
        guard service.isCapturing, let device = service.targetDevice else {
            return Unmanaged.passUnretained(event)
        }
        
        // Make sure our event tap stays enabled
        if let tap = service.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        
        // Process the event
        let eventType = CGEventType(rawValue: type.rawValue) ?? .null
        
        switch eventType {
        case .mouseMoved:
            service.handleMouseMovedEvent(event, for: device)
            return nil
            
        case .leftMouseDown:
            if event.getIntegerValueField(.mouseEventClickState) == 2 {
                service.sendDoubleClick(to: device)
            } else {
                // Begin drag state
                service.isDragging = true
                service.sendMouseDown(to: device)
            }
            return nil
            
        case .leftMouseUp:
            // End drag state
            service.isDragging = false
            service.sendMouseUp(to: device)
            return nil
            
        case .leftMouseDragged:
            // Handle drag events (crucial for drag and drop)
            let dx = event.getDoubleValueField(.mouseEventDeltaX)
            let dy = event.getDoubleValueField(.mouseEventDeltaY)
            
            // Make sure the mouse is held down if we're detecting a drag
            if !service.isDragging {
                service.isDragging = true
                service.sendMouseDown(to: device)
                // Small delay to ensure press is registered before movement
                usleep(10000)
            }
            
            // Send the mouse movement while button is held down
            if abs(dx) > 0.5 || abs(dy) > 0.5 {
                service.sendMouseMove(dx: CGFloat(dx), dy: CGFloat(dy), to: device)
            }
            return nil
            
        case .rightMouseDown:
            service.sendRightClick(to: device)
            return nil
            
        case .rightMouseUp:
            // Consume right mouse up events to prevent them from reaching macOS
            return nil
            
        case .rightMouseDragged:
            // Handle right-drag events
            let dx = event.getDoubleValueField(.mouseEventDeltaX)
            let dy = event.getDoubleValueField(.mouseEventDeltaY)
            
            if abs(dx) > 0.5 || abs(dy) > 0.5 {
                service.sendMouseMove(dx: CGFloat(dx), dy: CGFloat(dy), to: device)
            }
            return nil
            
        case .otherMouseDown:
            service.sendMiddleClick(to: device)
            return nil
            
        case .otherMouseUp:
            // Consume middle mouse up events to prevent them from reaching macOS
            return nil
            
        case .otherMouseDragged:
            // Handle middle-button-drag events
            let dx = event.getDoubleValueField(.mouseEventDeltaX)
            let dy = event.getDoubleValueField(.mouseEventDeltaY)
            
            if abs(dx) > 0.5 || abs(dy) > 0.5 {
                service.sendMouseMove(dx: CGFloat(dx), dy: CGFloat(dy), to: device)
            }
            return nil
            
        case .scrollWheel:
            // Get the scroll deltas
            let dx = event.getDoubleValueField(.scrollWheelEventDeltaAxis2)
            let dy = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
            
            if abs(dx) > 0.1 || abs(dy) > 0.1 {
                service.sendScroll(dx: dx, dy: dy, to: device)
            }
            return nil
            
        case .tabletPointer, .tabletProximity:
            // Handle tablet/touchpad events
            // Block these tablet/touch events which could be gesture-related
            Logger.services.debug("Blocked tablet event: \(eventType.rawValue, privacy: .public)")
            return nil
            
        case .keyDown, .keyUp:
            // Special handling for Option+Escape in the low-level event tap
            // This is our deepest level of defense against the key combination
            
            // Check if this is Escape key (keycode 53)
            if event.getIntegerValueField(.keyboardEventKeycode) == 53 {
                // Get modifier flags
                let flags = event.flags
                let optionPressed = (flags.rawValue & CGEventFlags.maskAlternate.rawValue) != 0
                
                // If this is Escape with Option, or we know Option was already pressed
                if optionPressed || service.optionKeyPressed {
                    // If key down event, trigger stop capturing
                    if type == .keyDown {
                        Logger.services.debug("Option+Escape caught by event tap, stopping capture")
                        DispatchQueue.main.async {
                            service.stopCapturing()
                        }
                    }
                    
                    // Critical: Never let Option+Escape reach applications
                    return nil
                }
            }
            
            // For all other key events, block them while capturing
            return nil
            
        case .flagsChanged:
            // Track Option key state at a low level
            let flags = event.flags
            let optionPressed = (flags.rawValue & CGEventFlags.maskAlternate.rawValue) != 0
            service.optionKeyPressed = optionPressed
            
            // Block all modifier keys during capture
            return nil
            
        default:
            // Since we're using a mask that captures all event types, block anything else
            // This ensures we block all events we don't explicitly handle from reaching macOS
            Logger.services.debug("Blocked unhandled event type: \(eventType.rawValue, privacy: .public)")
            return nil
        }
    }
}
