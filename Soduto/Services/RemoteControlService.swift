//
//  RemoteControlService.swift
//  Soduto
//
//  Created by Swapnil Devesh on 2025-04-27.
//  Copyright © 2025 Soduto. All rights reserved.
//

import Foundation
import Cocoa
import os

/// Service for sending keyboard and mouse input from this Mac to a remote device.
///
/// Implements the outgoing side of the `kdeconnect.mousepad` protocol. When capturing is
/// active, all Mac keyboard and mouse events are intercepted via a CGEvent tap and forwarded
/// as `kdeconnect.mousepad.request` packets to the paired target device. The Mac cursor is
/// hidden and locked to the screen center so the physical pointer stays out of the way.
///
/// Press **Option+Escape** to toggle capture mode.
///
/// Requires Accessibility permissions (System Settings › Privacy & Security › Accessibility).
public class RemoteControlService: OutgoingService, ObservableObject {
    
    // MARK: ServiceBase
    
    public var userDefaults: UserDefaults = .standard
    public let outgoingPreferenceKey = AppDefaultsStore.Preferences.Services.RemoteControl.outgoingKey
    
    // MARK: Properties
    
    public static let serviceId: Service.Id = "com.soduto.services.remotecontrol"
    
    public let incomingCapabilities = Set<Service.Capability>([
        DataPacket.mousePadKeyboardStatePacketType
    ])
    public var outgoingCapabilities: Set<Service.Capability> {
        outgoingEnabled ? [DataPacket.mousePadRequestPacketType] : []
    }
    
    @Published public private(set) var isCapturing = false
    @Published public private(set) var remoteKeyboardEnabled = false
    /// Briefly set when any nav action fires (from button, shortcut, or gesture) so the UI can flash the right button.
    @Published public private(set) var navHighlight: RemoteControlNavHighlight? = nil
    
    // Set by whoever owns RemoteControlWindowController (e.g. AppDelegate)
    var openPanel: ((Device) -> Void)?
    
    private var targetDevice: Device?
    private var eventTap: CFMachPort?
    private var eventRunLoopSource: CFRunLoopSource?
    private var optionKeyPressed = false
    private var isDragging = false
    private var originalMouseLocation: NSPoint?
    private var invisibleCursor: NSCursor?
    private var escapeMonitor: Any?
    
    /// Exposes the connected device type to the CGEvent tap callback (which has no `self`).
    var targetDeviceType: DeviceType? { targetDevice?.type }
    
    // Scroll/swipe accumulation for lock mode — mirrors TrackpadNSView's logic
    private var lockScrollAccumDx: Double = 0
    private var lockScrollAccumDy: Double = 0
    private var lockScrollStart: Date?
    
    
    // MARK: Service
    
    public func handleDataPacket(_ dataPacket: DataPacket, fromDevice device: Device, onConnection connection: Connection) -> Bool {
        guard dataPacket.isMousePadKeyboardStatePacket else { return false }
        if let state = dataPacket.body["state"] as? NSNumber {
            DispatchQueue.main.async { self.remoteKeyboardEnabled = state.boolValue }
        }
        return true
    }
    
    public func setup(for device: Device) {
        // Reset remoteKeyboardEnabled to trigger view re-evaluation after identity extension fields are refreshed.
        DispatchQueue.main.async { self.remoteKeyboardEnabled = false }
    }
    
    public func cleanup(for device: Device) {
        if targetDevice?.id == device.id {
            stopCapturing()
        }
    }
    
    
    // MARK: Actions
    
    private enum ActionId: Int {
        case startInputCapturing = 1
        case stopInputCapturing = 2
    }
    
    public func actions(for device: Device) -> [ServiceAction] {
        guard outgoingEnabled, device.pairingStatus == .Paired, device.isReachable else { return [] }
        if isCapturing && targetDevice?.id == device.id {
            return [ServiceAction(id: ActionId.stopInputCapturing.rawValue,
                                  title: "Unlock Capture",
                                  description: "Release mouse and keyboard lock",
                                  service: self, device: device)]
        }
        return [ServiceAction(id: ActionId.startInputCapturing.rawValue,
                              title: "Control Device",
                              description: "Open remote control panel",
                              service: self, device: device)]
    }
    
    public func performAction(_ id: ServiceAction.Id, forDevice device: Device, userInfo: [String: Any]?) {
        switch id {
        case ActionId.startInputCapturing.rawValue:
            if let panel = openPanel {
                panel(device)
            } else {
                Logger.services.error("RemoteControlService: openPanel not set — window controller not wired up")
            }
        case ActionId.stopInputCapturing.rawValue:
            stopCapturing()
        default:
            Logger.services.notice("Unknown action id: \(id, privacy: .public)")
        }
    }
    
    
    // MARK: Capturing
    
    /// Shows an accessibility permission alert if not yet granted. System notification alone is too subtle.
    func checkAccessibilityForLock() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        guard !AXIsProcessTrustedWithOptions(options) else { return }
        
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Accessibility Permissions Required"
            alert.informativeText = "Lock Input captures all keyboard and mouse events to control the remote device. Soduto needs Accessibility permissions to do this.\n\nGrant access in System Settings › Privacy & Security › Accessibility, then press ⌥+⎋ to activate Lock Input."
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                if #available(macOS 13.0, *) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                } else {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/PreferencePanes/Security.prefPane"))
                }
            }
        }
    }
    
    func startCapturing(for device: Device) {
        guard !isCapturing, device.pairingStatus == .Paired else { return }
        
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        guard AXIsProcessTrustedWithOptions(options) else {
            Logger.services.notice("Accessibility permissions not granted for remote control; prompting user...")
            checkAccessibilityForLock()  // reuse the same visible alert
            return
        }
        
        Logger.services.info("Starting input capture for device: \(device.name, privacy: .public)")
        targetDevice = device
        isCapturing = true
        isDragging = false
        
        setupEscapeMonitor()
        setupEventTap()
        hideCursorAndCenterOnScreen()
    }
    
    func stopCapturing() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.stopCapturing() }
            return
        }
        guard isCapturing else { return }
        
        Logger.services.info("Stopping input capture")
        isCapturing = false
        
        if isDragging, let device = targetDevice {
            sendMouseUp(to: device)
            isDragging = false
        }
        targetDevice = nil
        
        removeEventTap()
        removeEscapeMonitor()
        showCursorAndRestorePosition()
        
        Logger.services.info("Input capture stopped")
    }
    
    
    // MARK: Cursor management
    
    private func hideCursorAndCenterOnScreen() {
        originalMouseLocation = NSEvent.mouseLocation
        
        let blankImage = NSImage(size: NSSize(width: 1, height: 1))
        invisibleCursor = NSCursor(image: blankImage, hotSpot: .zero)
        NSCursor.hide()
        invisibleCursor?.push()
        
        if let screen = NSScreen.main {
            CGWarpMouseCursorPosition(CGPoint(x: screen.frame.midX, y: screen.frame.midY))
        }
    }
    
    private func showCursorAndRestorePosition() {
        if invisibleCursor != nil {
            invisibleCursor?.pop()
            invisibleCursor = nil
            NSCursor.unhide()
        }
        if let pos = originalMouseLocation {
            CGWarpMouseCursorPosition(CGPoint(x: pos.x, y: pos.y))
            originalMouseLocation = nil
        }
    }
    
    
    // MARK: Event tap
    
    private func setupEventTap() {
        let eventMask: CGEventMask = [
            CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
            .scrollWheel, .keyDown, .keyUp, .flagsChanged
        ].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            Logger.services.error("Failed to create CGEvent tap for remote control")
            return
        }
        
        eventTap = tap
        eventRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = eventRunLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }
    
    private func removeEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = eventRunLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
                eventRunLoopSource = nil
            }
            eventTap = nil
        }
    }
    
    
    // MARK: Escape monitor
    
    // Backup local monitor: catches Option+Escape if CGEvent tap is auto-disabled by macOS (slow callbacks),
    // and blocks modifiers from leaking to foreground apps while capturing.
    private func setupEscapeMonitor() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.isCapturing else { return event }
            if event.type == .flagsChanged {
                self.optionKeyPressed = event.modifierFlags.contains(.option)
                return nil
            }
            if event.keyCode == 53 && (event.modifierFlags.contains(.option) || self.optionKeyPressed) {
                DispatchQueue.main.async { self.stopCapturing() }
                return nil
            }
            return nil
        }
    }
    
    private func removeEscapeMonitor() {
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
    }
    
    
    // MARK: Packet sending
    
    func sendMouseMove(dx: CGFloat, dy: CGFloat, to device: Device) {
        device.send(DataPacket(type: DataPacket.mousePadRequestPacketType, body: [
            "dx": dx as NSNumber,
            "dy": dy as NSNumber
        ]))
    }
    
    func sendScroll(dx: Double, dy: Double, to device: Device) {
        // Scale raw macOS pixel/line deltas down to values Android expects (~1–5 per event)
        let scale = 0.2
        device.send(DataPacket(type: DataPacket.mousePadRequestPacketType, body: [
            "scroll": true as NSNumber,
            "dx": dx * scale as NSNumber,
            "dy": dy * scale as NSNumber
        ]))
    }
    
    func sendSingleClick(to device: Device) {
        device.send(DataPacket(type: DataPacket.mousePadRequestPacketType, body: ["singleclick": true as NSNumber]))
    }
    
    func sendMouseDown(to device: Device) {
        device.send(DataPacket(type: DataPacket.mousePadRequestPacketType, body: ["singlehold": true as NSNumber]))
    }
    
    func sendMouseUp(to device: Device) {
        device.send(DataPacket(type: DataPacket.mousePadRequestPacketType, body: ["singlerelease": true as NSNumber]))
    }
    
    func sendDoubleClick(to device: Device) {
        device.send(DataPacket(type: DataPacket.mousePadRequestPacketType, body: ["doubleclick": true as NSNumber]))
    }
    
    func sendRightClick(to device: Device) {
        device.send(DataPacket(type: DataPacket.mousePadRequestPacketType, body: ["rightclick": true as NSNumber]))
    }
    
    func sendMiddleClick(to device: Device) {
        device.send(DataPacket(type: DataPacket.mousePadRequestPacketType, body: ["middleclick": true as NSNumber]))
    }
    
    func sendKey(_ key: String, shift: Bool, ctrl: Bool, alt: Bool, command: Bool = false, to device: Device) {
        var body: DataPacket.Body = ["key": key as NSString, "sendAck": false as NSNumber]
        if shift   { body["shift"] = true as NSNumber }
        if ctrl    { body["ctrl"]  = true as NSNumber }
        if alt     { body["alt"]   = true as NSNumber }
        if command { body["super"] = true as NSNumber }
        device.send(DataPacket(type: DataPacket.mousePadRequestPacketType, body: body))
    }
    
    func sendSpecialKey(_ keyCode: Int, shift: Bool, ctrl: Bool, alt: Bool, command: Bool = false, to device: Device) {
        var body: DataPacket.Body = ["specialKey": keyCode as NSNumber, "sendAck": false as NSNumber]
        if shift   { body["shift"] = true as NSNumber }
        if ctrl    { body["ctrl"]  = true as NSNumber }
        if alt     { body["alt"]   = true as NSNumber }
        if command { body["super"] = true as NSNumber }
        device.send(DataPacket(type: DataPacket.mousePadRequestPacketType, body: body))
    }
    
    // Android navigation: click mappings are standard across KDE Connect Android clients, similar to a physical keyboard.
    // rightclick → Back, middleclick → Home, doubleclick → Recents.
    func sendBack(to device: Device)    { sendRightClick(to: device);  flash(.back) }
    func sendHome(to device: Device)    { sendMiddleClick(to: device); flash(.home) }
    func sendRecents(to device: Device) { sendDoubleClick(to: device); flash(.recents) }
    
    // Discrete long press (longclick field): opens Android contextual menu. Soduto exclusive implementation, so other clients ignore it.
    func sendLongTap(to device: Device) {
        device.send(DataPacket(type: DataPacket.mousePadRequestPacketType, body: [
            "longclick": true as NSNumber
        ]))
    }
    
    // Extended navigation: action field (power, volume) handled by Soduto (Android) only.
    func sendPower(to device: Device) {
        device.send(DataPacket(type: DataPacket.mousePadRequestPacketType, body: ["action": "power" as NSString]))
        flash(.power)
    }
    
    func sendVolumeUp(to device: Device) {
        device.send(DataPacket(type: DataPacket.mousePadRequestPacketType, body: ["action": "volume_up" as NSString]))
        flash(.volumeUp)
    }
    
    func sendVolumeDown(to device: Device) {
        device.send(DataPacket(type: DataPacket.mousePadRequestPacketType, body: ["action": "volume_down" as NSString]))
        flash(.volumeDown)
    }
    
    private func flash(_ h: RemoteControlNavHighlight) {
        DispatchQueue.main.async { [weak self] in
            self?.navHighlight = h
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                if self?.navHighlight == h { self?.navHighlight = nil }
            }
        }
    }
    
    var isAndroidCompanion: Bool { targetDevice?.isAndroidCompanion ?? false }
    
    /// True when the peer is standard Android KDE Connect (not Soduto Android).
    /// Used in the CGEvent tap to decide between spoon-feeding vs raw passthrough.
    var isVanillaAndroid: Bool {
        let isMobile = targetDevice?.type == .Phone || targetDevice?.type == .Tablet
        return isMobile && !isAndroidCompanion
    }
    
    // Touch drag swipe: press → move → release, then restore pointer to avoid drift.
    func sendSwipe(dx: Double, dy: Double, to device: Device) {
        sendMouseDown(to: device)
        sendMouseMove(dx: CGFloat(dx), dy: CGFloat(dy), to: device)
        sendMouseUp(to: device)
        sendMouseMove(dx: -CGFloat(dx), dy: -CGFloat(dy), to: device)
    }
    
    
    // MARK: Event tap callback
    
    private let eventTapCallback: CGEventTapCallBack = { proxy, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let service = Unmanaged<RemoteControlService>.fromOpaque(refcon).takeUnretainedValue()
        guard service.isCapturing, let device = service.targetDevice else {
            return Unmanaged.passUnretained(event)
        }
        
        // Re-enable tap if macOS auto-disabled it (slow callbacks).
        if let tap = service.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        
        let eventType = CGEventType(rawValue: type.rawValue) ?? .null
        
        switch eventType {
            
        // MARK: Mouse movement
        case .mouseMoved:
            let dx = event.getDoubleValueField(.mouseEventDeltaX)
            let dy = event.getDoubleValueField(.mouseEventDeltaY)
            if abs(dx) > 0.5 || abs(dy) > 0.5 {
                service.sendMouseMove(dx: CGFloat(dx), dy: CGFloat(dy), to: device)
            }
            if let screen = NSScreen.main {
                CGWarpMouseCursorPosition(CGPoint(x: screen.frame.midX, y: screen.frame.midY))
            }
            return nil
            
        // MARK: Left mouse
        case .leftMouseDown:
            if event.getIntegerValueField(.mouseEventClickState) == 2 {
                service.sendDoubleClick(to: device)
            } else {
                service.isDragging = true
                service.sendMouseDown(to: device)
            }
            return nil
            
        case .leftMouseUp:
            // Release only if drag/press is in progress. isDragging is false after doubleclick,
            // so the trailing mouseUp is swallowed (no spurious singlerelease).
            if service.isDragging {
                service.isDragging = false
                service.sendMouseUp(to: device)
            }
            return nil
            
        case .leftMouseDragged:
            let dx = event.getDoubleValueField(.mouseEventDeltaX)
            let dy = event.getDoubleValueField(.mouseEventDeltaY)
            if !service.isDragging {
                service.isDragging = true
                service.sendMouseDown(to: device)
            }
            if abs(dx) > 0.5 || abs(dy) > 0.5 {
                service.sendMouseMove(dx: CGFloat(dx), dy: CGFloat(dy), to: device)
            }
            return nil
            
        // MARK: Right mouse
        case .rightMouseDown:
            service.sendRightClick(to: device)
            return nil
            
        case .rightMouseUp:
            return nil
            
        case .rightMouseDragged:
            let dx = event.getDoubleValueField(.mouseEventDeltaX)
            let dy = event.getDoubleValueField(.mouseEventDeltaY)
            if abs(dx) > 0.5 || abs(dy) > 0.5 {
                service.sendMouseMove(dx: CGFloat(dx), dy: CGFloat(dy), to: device)
            }
            return nil
            
        // MARK: Middle mouse
        case .otherMouseDown:
            service.sendMiddleClick(to: device)
            return nil
            
        case .otherMouseUp:
            return nil
            
        case .otherMouseDragged:
            let dx = event.getDoubleValueField(.mouseEventDeltaX)
            let dy = event.getDoubleValueField(.mouseEventDeltaY)
            if abs(dx) > 0.5 || abs(dy) > 0.5 {
                service.sendMouseMove(dx: CGFloat(dx), dy: CGFloat(dy), to: device)
            }
            return nil
            
        // MARK: Scroll / swipe (lock mode)
        case .scrollWheel:
            // Use NSEvent's scrollingDeltaX/Y (pixel values) — same source as windowed mode.
            // CGEvent's scrollWheelEventDeltaAxis fields return integer line counts which are
            // often 0 on modern trackpads that use precise pixel scrolling.
            guard let nsEvent = NSEvent(cgEvent: event) else { return nil }
            let dx = Double(nsEvent.scrollingDeltaX)
            let dy = Double(nsEvent.scrollingDeltaY)
            
            // Always send scroll in real-time
            if abs(dx) > 0.01 || abs(dy) > 0.01 {
                service.sendScroll(dx: dx, dy: dy, to: device)
            }
            
            // Swipe detection using the same phase + threshold logic as TrackpadNSView
            switch nsEvent.phase {
            case .began:
                service.lockScrollAccumDx = dx
                service.lockScrollAccumDy = dy
                service.lockScrollStart = Date()
            case .changed:
                service.lockScrollAccumDx += dx
                service.lockScrollAccumDy += dy
            case .ended:
                if let start = service.lockScrollStart {
                    let elapsed = Date().timeIntervalSince(start)
                    let magnitude = hypot(service.lockScrollAccumDx, service.lockScrollAccumDy)
                    if elapsed < 0.35 && magnitude > 30 {
                        service.sendSwipe(dx: service.lockScrollAccumDx, dy: service.lockScrollAccumDy, to: device)
                    }
                }
                service.lockScrollAccumDx = 0; service.lockScrollAccumDy = 0; service.lockScrollStart = nil
            default: break
            }
            return nil
            
        // MARK: Keyboard
        case .keyDown:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags
            let optionDown = flags.contains(.maskAlternate) || service.optionKeyPressed
            
            // Option+Escape is ALWAYS handled here — never forwarded to the device.
            if keyCode == 53 && optionDown {
                DispatchQueue.main.async { service.stopCapturing() }
                return nil
            }
            
            let isMobile = service.targetDeviceType == .Phone || service.targetDeviceType == .Tablet
            if isMobile {
                let cmd   = flags.contains(.maskCommand)
                let shift = flags.contains(.maskShift)
                let ctrl  = flags.contains(.maskControl)
                let noAlt = !flags.contains(.maskAlternate)
                
                // Android shortcuts: intercepted in the tap so they work even in lock mode.
                // Consume them so they don't also appear as forwarded key packets.
                if cmd && noAlt && !ctrl, let device = service.targetDevice {
                    switch (keyCode, shift) {
                    case (33, false): DispatchQueue.main.async { service.sendBack(to: device) };       return nil  // Cmd+[       → Back
                    case ( 4,  true): DispatchQueue.main.async { service.sendHome(to: device) };       return nil  // Cmd+Shift+H → Home
                    case (15,  true): DispatchQueue.main.async { service.sendRecents(to: device) };    return nil  // Cmd+Shift+R → Recents
                    case (126, true): DispatchQueue.main.async { service.sendVolumeUp(to: device) };   return nil  // Cmd+Shift+↑ → Vol+
                    case (125, true): DispatchQueue.main.async { service.sendVolumeDown(to: device) }; return nil  // Cmd+Shift+↓ → Vol−
                    case (37,  true): DispatchQueue.main.async { service.sendPower(to: device) };      return nil  // Cmd+Shift+L → Power
                    default: break
                    }
                }
                
                // Mac window shortcuts: pass through so panel responds even while locked.
                // Desktop lock mode: these fall through to key-send (forwarded to device).
                if cmd && noAlt {
                    if keyCode == 13 && !ctrl  { return Unmanaged.passUnretained(event) }  // Cmd+W → close
                    if keyCode == 3  &&  ctrl  { return Unmanaged.passUnretained(event) }  // Cmd+Ctrl+F → fullscreen
                }
            }
            
            let shift   = flags.contains(.maskShift)
            let ctrl    = flags.contains(.maskControl)
            let alt     = flags.contains(.maskAlternate)
            let command = flags.contains(.maskCommand)
            
            if let specialKey = kdeSpecialKey(for: keyCode) {
                service.sendSpecialKey(specialKey, shift: shift, ctrl: ctrl, alt: alt, command: command, to: device)
            } else {
                // Vanilla Android: spoon-feed event.characters. Other targets: base glyph + modifiers.
                let key: String
                if service.isVanillaAndroid {
                    if let nsEvent = NSEvent(cgEvent: event) {
                        key = nsEvent.characters ?? ""
                    } else { key = "" }
                } else {
                    key = rawBaseCharacter(for: keyCode) ?? ""
                }
                if !key.isEmpty {
                    service.sendKey(key, shift: shift, ctrl: ctrl, alt: alt, command: command, to: device)
                }
            }
            return nil
            
        case .keyUp:
            return nil
            
        case .flagsChanged:
            service.optionKeyPressed = event.flags.contains(.maskAlternate)
            // Must pass through: consuming flagsChanged causes modifier state to get stuck in the OS.
            return Unmanaged.passUnretained(event)
            
        default:
            return nil
        }
    }
}

// MARK: Nav highlight type

public enum RemoteControlNavHighlight: Equatable {
    case back, home, recents, volumeUp, volumeDown, power
}


// MARK: DataPacket (MousePad)

fileprivate extension DataPacket {
    static let mousePadRequestPacketType = "kdeconnect.mousepad.request"
    static let mousePadKeyboardStatePacketType = "kdeconnect.mousepad.keyboardstate"
    
    var isMousePadKeyboardStatePacket: Bool { type == DataPacket.mousePadKeyboardStatePacketType }
}
