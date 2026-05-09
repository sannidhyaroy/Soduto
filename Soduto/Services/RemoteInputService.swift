//
//  RemoteInputService.swift
//  Soduto
//
//  Created by Giedrius on 2017-05-21.
//  Copyright © 2017 Soduto. All rights reserved.
//

import Foundation
import Cocoa
import os
import ApplicationServices

/// Service for receiving keyboard and mouse input from a remote device.
///
/// Implements the `kdeconnect.mousepad` protocol. Handles one incoming packet type:
///
/// `kdeconnect.mousepad.request` — carries either keyboard or mouse input:
///   - **Keyboard**: `key` (String) for text characters, and/or `specialKey` (Int, 1–32 KDE
///     keycode) for special keys such as arrows, Enter, Backspace, and function keys.
///     Optional modifiers: `shift`, `ctrl`, `alt`, `super` (Bool).
///     If `sendAck` is `true`, a `kdeconnect.mousepad.echo` reply is sent back.
///   - **Mouse**: `dx`/`dy` (Double) for relative movement; `scroll` (Bool) + `dx`/`dy`
///     for scroll wheel; `singleclick`, `doubleclick`, `middleclick`, `rightclick`,
///     `singlehold`, `singlerelease` (Bool) for click and drag operations.
///
/// On device connection, sends `kdeconnect.mousepad.keyboardstate` with `state: true`
/// to inform the peer that keyboard input is accepted.
///
/// Requires Accessibility permissions (System Settings › Privacy & Security › Accessibility)
/// to synthesise CGEvents.
public class RemoteInputService: IncomingService {
    
    // MARK: ServiceBase
    
    public var userDefaults: UserDefaults = .standard
    public let incomingPreferenceKey = AppDefaultsStore.Preferences.Services.MousePad.incomingKey
    
    // MARK: Properties
    
    private var hasCheckedAccessibility = false
    
    // MARK: Service
    
    public static let serviceId: Service.Id = "com.soduto.services.remoteinput"
    
    public var incomingCapabilities: Set<Service.Capability> {
        incomingEnabled ? [DataPacket.mousePadRequestPacketType] : []
    }
    public let outgoingCapabilities = Set<Service.Capability>([
        DataPacket.mousePadEchoPacketType,
        DataPacket.mousePadKeyboardStatePacketType
    ])
    
    public func handleDataPacket(_ dataPacket: DataPacket, fromDevice device: Device, onConnection connection: Connection) -> Bool {
        guard dataPacket.isMousePadRequestPacket else { return false }
        guard incomingEnabled else { return true }
        
        if !hasCheckedAccessibility {
            checkAndRequestAccessibilityPermissions()
            hasCheckedAccessibility = true
        }
        
        do {
            if dataPacket.hasKeyboardInput {
                processKeyboardInput(dataPacket)
            } else {
                processMouseInput(dataPacket)
            }
            
            if try dataPacket.getSendAckFlag() {
                device.send(DataPacket.mousePadEchoPacket(for: dataPacket))
            }
        } catch {
            Logger.services.error("Failed handling mousepad packet: \(error, privacy: .public)")
        }
        
        return true
    }
    
    public func setup(for device: Device) {
        device.send(DataPacket.mousePadKeyboardStatePacket(state: true))
    }
    
    public func cleanup(for device: Device) {}
    
    public func actions(for device: Device) -> [ServiceAction] {
        // No supported actions
        return []
    }
    
    public func performAction(_ id: ServiceAction.Id, forDevice device: Device, userInfo: [String: Any]?) {
        // No supported actions
    }
    
    
    // MARK: Private types
    
    private struct KeyModifiers {
        let shift: Bool
        let control: Bool
        let option: Bool
        let command: Bool
        
        var flags: CGEventFlags {
            var flags = CGEventFlags()
            if shift   { flags.insert(.maskShift) }
            if control { flags.insert(.maskControl) }
            if option  { flags.insert(.maskAlternate) }
            if command { flags.insert(.maskCommand) }
            return flags
        }
    }
    
    
    // MARK: Keyboard input
    
    private func processKeyboardInput(_ dataPacket: DataPacket) {
        let modifiers = KeyModifiers(
            shift:   (try? dataPacket.getShiftFlag()) ?? false,
            control: (try? dataPacket.getCtrlFlag())  ?? false,
            option:  (try? dataPacket.getAltFlag())   ?? false,
            command: (try? dataPacket.getSuperFlag()) ?? false
        )
        
        if let specialKey = try? dataPacket.getSpecialKey() {
            simulateSpecialKey(specialKey, withModifiers: modifiers)
        } else if let key = try? dataPacket.getKey(), !key.isEmpty {
            simulateKeyPress(key, withModifiers: modifiers)
        }
    }
    
    private func simulateKeyPress(_ key: String, withModifiers modifiers: KeyModifiers) {
        // Some Android IMEs (e.g. those using InputConnection.commitText rather than
        // sendKeyEvent) deliver control characters as plain text instead of specialKey codes.
        // Map them to their physical special-key equivalents for broad app compatibility.
        switch key {
        case "\n", "\r", "\r\n":
            simulateSpecialKey(12, withModifiers: modifiers)  // KDE code 12 = Return
            return
        case "\t":
            simulateSpecialKey(2, withModifiers: modifiers)   // KDE code 2 = Tab
            return
        default:
            break
        }
        
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            Logger.services.error("Failed to create CGEventSource for key press")
            return
        }
        
        let utf16 = Array(key.utf16)
        if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
            down.flags = modifiers.flags
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
            up.flags = modifiers.flags
            up.post(tap: .cghidEventTap)
        }
    }
    
    private func simulateSpecialKey(_ kdeKeyCode: Int, withModifiers modifiers: KeyModifiers) {
        let keyCode = mapSpecialKey(kdeKeyCode)
        
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            Logger.services.error("Failed to create CGEventSource for special key")
            return
        }
        
        if let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) {
            down.flags = modifiers.flags
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) {
            up.flags = modifiers.flags
            up.post(tap: .cghidEventTap)
        }
    }
    
    private func mapSpecialKey(_ kdeKeyCode: Int) -> CGKeyCode {
        // Maps KDE Connect special key codes (1–32) to macOS virtual key codes.
        switch kdeKeyCode {
        case 1:  return 51   // Backspace
        case 2:  return 48   // Tab
        case 3:  return 36   // Linefeed — treated same as Return on macOS
        case 4:  return 123  // Left arrow
        case 5:  return 126  // Up arrow
        case 6:  return 124  // Right arrow
        case 7:  return 125  // Down arrow
        case 8:  return 116  // Page Up
        case 9:  return 121  // Page Down
        case 10: return 115  // Home
        case 11: return 119  // End
        case 12: return 36   // Return
        case 13: return 117  // Forward Delete
        case 14: return 53   // Escape
        case 15: return 0    // Sys Req (no direct macOS equivalent)
        case 16: return 0    // Scroll Lock (no direct macOS equivalent)
            // 17–20 are unassigned in the KDE Connect protocol
        case 21: return 122  // F1
        case 22: return 120  // F2
        case 23: return 99   // F3
        case 24: return 118  // F4
        case 25: return 96   // F5
        case 26: return 97   // F6
        case 27: return 98   // F7
        case 28: return 100  // F8
        case 29: return 101  // F9
        case 30: return 109  // F10
        case 31: return 103  // F11
        case 32: return 111  // F12
        default: return CGKeyCode(kdeKeyCode % 128)
        }
    }
    
    
    // MARK: Mouse input
    
    private func processMouseInput(_ dataPacket: DataPacket) {
        if dataPacket.isScrollPacket {
            scrollPointer(dx: dataPacket.scrollDx, dy: dataPacket.scrollDy)
        } else if dataPacket.isMovementPacket {
            movePointer(dx: dataPacket.moveDx, dy: dataPacket.moveDy)
        } else if dataPacket.isSingleClickPacket {
            clickPointer(button: .left)
        } else if dataPacket.isDoubleClickPacket {
            doubleClickPointer()
        } else if dataPacket.isMiddleClickPacket {
            clickPointer(button: .center)
        } else if dataPacket.isRightClickPacket {
            clickPointer(button: .right)
        } else if dataPacket.isSingleHoldPacket {
            pressPointer(button: .left)
        } else if dataPacket.isSingleReleasePacket {
            releasePointer(button: .left)
        }
    }
    
    private func movePointer(dx: Double, dy: Double) {
        guard let pos = CGEvent(source: nil)?.location else {
            Logger.services.error("Failed to get pointer position for move")
            return
        }
        let newPos = CGPoint(x: pos.x + CGFloat(dx), y: pos.y + CGFloat(dy))
        if let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                               mouseCursorPosition: newPos, mouseButton: .left) {
            event.post(tap: .cghidEventTap)
        }
    }
    
    private func scrollPointer(dx: Double, dy: Double) {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            Logger.services.error("Failed to create CGEventSource for scroll")
            return
        }
        if let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                               wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) {
            event.post(tap: .cghidEventTap)
        }
    }
    
    private func clickPointer(button: CGMouseButton) {
        guard let pos = CGEvent(source: nil)?.location else {
            Logger.services.error("Failed to get pointer position for click")
            return
        }
        let downType: CGEventType = button == .left ? .leftMouseDown : (button == .right ? .rightMouseDown : .otherMouseDown)
        let upType: CGEventType = button == .left ? .leftMouseUp : (button == .right ? .rightMouseUp : .otherMouseUp)
        
        if let down = CGEvent(mouseEventSource: nil, mouseType: downType,
                              mouseCursorPosition: pos, mouseButton: button) {
            if button == .center { down.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button.rawValue)) }
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(mouseEventSource: nil, mouseType: upType,
                            mouseCursorPosition: pos, mouseButton: button) {
            if button == .center { up.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button.rawValue)) }
            up.post(tap: .cghidEventTap)
        }
    }
    
    private func doubleClickPointer() {
        // Two full clickState=2 sequences are needed for a reliable double-click.
        // https://developer.apple.com/forums/thread/685901?answerId=752279022#752279022
        guard let pos = CGEvent(source: nil)?.location else {
            Logger.services.error("Failed to get pointer position for double-click")
            return
        }
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            Logger.services.error("Failed to create CGEventSource for double-click")
            return
        }
        
        func sequence() {
            if let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                                  mouseCursorPosition: pos, mouseButton: .left) {
                down.setIntegerValueField(.mouseEventClickState, value: 2)
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                                mouseCursorPosition: pos, mouseButton: .left) {
                up.setIntegerValueField(.mouseEventClickState, value: 2)
                up.post(tap: .cghidEventTap)
            }
        }
        
        sequence()
        usleep(50_000) // 50 ms inter-click gap
        sequence()
    }
    
    private func pressPointer(button: CGMouseButton) {
        guard let pos = CGEvent(source: nil)?.location else {
            Logger.services.error("Failed to get pointer position for press")
            return
        }
        let type: CGEventType = button == .left ? .leftMouseDown : (button == .right ? .rightMouseDown : .otherMouseDown)
        if let event = CGEvent(mouseEventSource: nil, mouseType: type,
                               mouseCursorPosition: pos, mouseButton: button) {
            event.post(tap: .cghidEventTap)
        }
    }
    
    private func releasePointer(button: CGMouseButton) {
        guard let pos = CGEvent(source: nil)?.location else {
            Logger.services.error("Failed to get pointer position for release")
            return
        }
        let type: CGEventType = button == .left ? .leftMouseUp : (button == .right ? .rightMouseUp : .otherMouseUp)
        if let event = CGEvent(mouseEventSource: nil, mouseType: type,
                               mouseCursorPosition: pos, mouseButton: button) {
            event.post(tap: .cghidEventTap)
        }
    }
    
    
    // MARK: Accessibility permissions
    
    private func checkAndRequestAccessibilityPermissions() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        guard !AXIsProcessTrustedWithOptions(options) else {
            Logger.services.info("Accessibility permissions already granted for remote input")
            return
        }
        
        Logger.services.notice("Accessibility permissions not granted for remote input — prompting user")
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Accessibility Permissions Required"
            alert.informativeText = "To enable remote keyboard and mouse control, Soduto needs Accessibility permissions. Please grant access in System Settings › Privacy & Security › Accessibility."
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
}


// MARK: DataPacket (MousePad)

/// Mouse and keyboard input data packet utilities for the `kdeconnect.mousepad` protocol.
fileprivate extension DataPacket {
    
    // MARK: Types
    
    enum MousePadError: Error {
        case wrongType
        case invalidKey
        case invalidSpecialKey
        case invalidSendAckFlag
        case invalidShiftFlag
        case invalidCtrlFlag
        case invalidAltFlag
        case invalidSuperFlag
    }
    
    struct MousePadProperty {
        // Keyboard input
        static let key = "key"
        static let specialKey = "specialKey"
        static let shift = "shift"
        static let ctrl = "ctrl"
        static let alt = "alt"
        static let superKey = "super"
        static let sendAck = "sendAck"
        static let isAck = "isAck"
        // Mouse input
        static let dx = "dx"
        static let dy = "dy"
        static let scroll = "scroll"
        static let singleclick = "singleclick"
        static let doubleclick = "doubleclick"
        static let middleclick = "middleclick"
        static let rightclick = "rightclick"
        static let singlehold = "singlehold"
        static let singlerelease = "singlerelease"
        // Keyboard state
        static let state = "state"
    }
    
    
    // MARK: Properties
    
    static let mousePadRequestPacketType = "kdeconnect.mousepad.request"
    static let mousePadEchoPacketType = "kdeconnect.mousepad.echo"
    static let mousePadKeyboardStatePacketType = "kdeconnect.mousepad.keyboardstate"
    
    var isMousePadRequestPacket: Bool { return self.type == DataPacket.mousePadRequestPacketType }
    var isMousePadEchoPacket: Bool { return self.type == DataPacket.mousePadEchoPacketType }
    var isMousePadKeyboardStatePacket: Bool { return self.type == DataPacket.mousePadKeyboardStatePacketType }
    
    /// `true` when the packet carries keyboard input (`key` or `specialKey` is present).
    /// Per the KDE Connect protocol, a single packet is either keyboard or mouse — not both.
    var hasKeyboardInput: Bool {
        return body[MousePadProperty.key] != nil || body[MousePadProperty.specialKey] != nil
    }
    
    // Mouse packet classifiers — check the actual boolean value, not just key presence.
    var isScrollPacket: Bool { return (body[MousePadProperty.scroll] as? NSNumber)?.boolValue == true }
    var isSingleClickPacket: Bool { return (body[MousePadProperty.singleclick] as? NSNumber)?.boolValue == true }
    var isDoubleClickPacket: Bool { return (body[MousePadProperty.doubleclick] as? NSNumber)?.boolValue == true }
    var isMiddleClickPacket: Bool { return (body[MousePadProperty.middleclick] as? NSNumber)?.boolValue == true }
    var isRightClickPacket: Bool { return (body[MousePadProperty.rightclick] as? NSNumber)?.boolValue == true }
    var isSingleHoldPacket: Bool { return (body[MousePadProperty.singlehold] as? NSNumber)?.boolValue == true }
    var isSingleReleasePacket: Bool { return (body[MousePadProperty.singlerelease] as? NSNumber)?.boolValue == true }
    
    /// `true` for relative-movement packets (`dx`/`dy` present, `scroll` absent).
    var isMovementPacket: Bool {
        return !isScrollPacket && body[MousePadProperty.dx] != nil && body[MousePadProperty.dy] != nil
    }
    
    var moveDx: Double { return (body[MousePadProperty.dx] as? NSNumber)?.doubleValue ?? 0 }
    var moveDy: Double { return (body[MousePadProperty.dy] as? NSNumber)?.doubleValue ?? 0 }
    var scrollDx: Double { return isScrollPacket ? moveDx : 0 }
    var scrollDy: Double { return isScrollPacket ? moveDy : 0 }
    
    
    // MARK: Public static methods
    
    /// Builds an echo reply for a request packet that had `sendAck: true`.
    static func mousePadEchoPacket(for request: DataPacket) -> DataPacket {
        var body: Body = [MousePadProperty.isAck: true as AnyObject]
        if let key = try? request.getKey() {
            body[MousePadProperty.key] = key as AnyObject
        }
        if let specialKey = try? request.getSpecialKey() {
            body[MousePadProperty.specialKey] = specialKey as AnyObject
        }
        if (try? request.getShiftFlag()) == true { body[MousePadProperty.shift] = true as AnyObject }
        if (try? request.getCtrlFlag()) == true { body[MousePadProperty.ctrl] = true as AnyObject }
        if (try? request.getAltFlag()) == true { body[MousePadProperty.alt] = true as AnyObject }
        if (try? request.getSuperFlag()) == true { body[MousePadProperty.superKey] = true as AnyObject }
        return DataPacket(type: mousePadEchoPacketType, body: body)
    }
    
    /// Builds a keyboard-state announcement packet.
    static func mousePadKeyboardStatePacket(state: Bool) -> DataPacket {
        return DataPacket(type: mousePadKeyboardStatePacketType, body: [
            MousePadProperty.state: state as AnyObject
        ])
    }
    
    
    // MARK: Public methods
    
    func getSendAckFlag() throws -> Bool {
        try self.validateMousePadRequestType()
        guard body.keys.contains(MousePadProperty.sendAck) else { return false }
        guard let value = body[MousePadProperty.sendAck] as? NSNumber else { throw MousePadError.invalidSendAckFlag }
        return value.boolValue
    }
    
    func getKey() throws -> String? {
        try self.validateMousePadType()
        guard body.keys.contains(MousePadProperty.key) else { return nil }
        guard let value = body[MousePadProperty.key] as? String else { throw MousePadError.invalidKey }
        return value
    }
    
    func getSpecialKey() throws -> Int? {
        try self.validateMousePadType()
        guard body.keys.contains(MousePadProperty.specialKey) else { return nil }
        guard let value = body[MousePadProperty.specialKey] as? NSNumber else { throw MousePadError.invalidSpecialKey }
        return value.intValue
    }
    
    func getShiftFlag() throws -> Bool {
        try self.validateMousePadType()
        guard body.keys.contains(MousePadProperty.shift) else { return false }
        guard let value = body[MousePadProperty.shift] as? NSNumber else { throw MousePadError.invalidShiftFlag }
        return value.boolValue
    }
    
    func getCtrlFlag() throws -> Bool {
        try self.validateMousePadType()
        guard body.keys.contains(MousePadProperty.ctrl) else { return false }
        guard let value = body[MousePadProperty.ctrl] as? NSNumber else { throw MousePadError.invalidCtrlFlag }
        return value.boolValue
    }
    
    func getAltFlag() throws -> Bool {
        try self.validateMousePadType()
        guard body.keys.contains(MousePadProperty.alt) else { return false }
        guard let value = body[MousePadProperty.alt] as? NSNumber else { throw MousePadError.invalidAltFlag }
        return value.boolValue
    }
    
    func getSuperFlag() throws -> Bool {
        try self.validateMousePadType()
        guard body.keys.contains(MousePadProperty.superKey) else { return false }
        guard let value = body[MousePadProperty.superKey] as? NSNumber else { throw MousePadError.invalidSuperFlag }
        return value.boolValue
    }
    
    func validateMousePadRequestType() throws {
        guard self.isMousePadRequestPacket else { throw MousePadError.wrongType }
    }
    
    func validateMousePadType() throws {
        guard self.isMousePadRequestPacket || self.isMousePadEchoPacket else { throw MousePadError.wrongType }
    }
}
