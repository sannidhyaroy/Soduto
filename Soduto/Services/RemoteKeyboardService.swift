//
//  RemoteKeyboardService.swift
//  Soduto
//
//  Created by Giedrius on 2017-05-21.
//  Copyright © 2017 Soduto. All rights reserved.
//

import Foundation
import Cocoa
import CleanroomLogger
import ApplicationServices

public class RemoteKeyboardService: Service {
    
    // MARK: Service
    
    public static let serviceId: Service.Id = "com.soduto.services.remotekeyboard"
    
    public let incomingCapabilities = Set<Service.Capability>([
        DataPacket.remoteKeyboardRequestPacketType,
        DataPacket.presenterPacketType
    ])
    public let outgoingCapabilities = Set<Service.Capability>([
        DataPacket.remoteKeyboardEchoPacketType
    ])
    
    private var hasCheckedAccessibility = false
    
    public func handleDataPacket(_ dataPacket: DataPacket, fromDevice device: Device, onConnection connection: Connection) -> Bool {
        guard dataPacket.isRemoteKeyboardRequestPacket || dataPacket.isPresenterPacket else { return false }
        
        // Check accessibility permissions before processing keyboard input
        if !hasCheckedAccessibility {
            checkAndRequestAccessibilityPermissions()
            hasCheckedAccessibility = true
        }

        do {
            if (dataPacket.isPresenterPacket) {
                // Process presenter input
                processPresenterInput(dataPacket)
            } else {
                // Process the actual keyboard input
                processKeyboardInput(dataPacket)
                
                // Process mouse input
                processMouseInput(dataPacket)

                guard try dataPacket.getSendAckFlag() else { return true }
                device.send(try DataPacket.remoteKeyboardEchoPacket(for: dataPacket))
            }
        }
        catch {
            Log.error?.message("Failed handling remote keyboard data packet: \(error).")
        }
        
        return true
    }
    
    public func setup(for device: Device) {}
    
    public func cleanup(for device: Device) {}
    
    public func actions(for device: Device) -> [ServiceAction] {
        // No supported actions
        return []
    }
    
    public func performAction(_ id: ServiceAction.Id, forDevice device: Device) {
        // No supported actions
    }
    
    // MARK: - Keyboard Input Processing
    
    private func processKeyboardInput(_ dataPacket: DataPacket) {
        // Get key (if available)
        var key: String? = nil
        if let extractedKey = try? dataPacket.getKey() {
            key = extractedKey
        }
        
        // Get special key (if available)
        var specialKey: Int? = nil
        if let extractedSpecialKey = try? dataPacket.getSpecialKey() {
            specialKey = extractedSpecialKey
        }
        
        var shift = false
        var ctrl = false
        var alt = false
        
        if let shiftFlag = try? dataPacket.getShiftFlag() {
            shift = shiftFlag ?? false
        }
        
        if let ctrlFlag = try? dataPacket.getCtrlFlag() {
            ctrl = ctrlFlag ?? false
        }
        
        if let altFlag = try? dataPacket.getAltFlag() {
            alt = altFlag ?? false
        }
        
        let modifiers = KeyModifiers(shift: shift, control: ctrl, option: alt)
        
        // Process input based on what's available
        if let specialKey = specialKey {
            // Handle special keys (arrow keys, function keys, etc.)
            simulateSpecialKey(specialKey, withModifiers: modifiers)
        } else if let key = key, !key.isEmpty {
            // Handle regular alphanumeric/character keys
            simulateKeyPress(key, withModifiers: modifiers)
        } else {
            Log.warning?.message("Received keyboard input packet with no valid key or special key")
        }
    }
    
    private struct KeyModifiers {
        let shift: Bool
        let control: Bool
        let option: Bool
        
        var flags: CGEventFlags {
            var flags = CGEventFlags()
            if shift { flags.insert(.maskShift) }
            if control { flags.insert(.maskControl) }
            if option { flags.insert(.maskAlternate) }
            return flags
        }
    }
    
    private func simulateKeyPress(_ key: String, withModifiers modifiers: KeyModifiers) {
        // Create a source for the CGEvent
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            Log.error?.message("Failed to create CGEventSource")
            return
        }
        
        // For emoji and complex Unicode characters, we need to handle them as a complete string
        // rather than individual Unicode scalars
        
        // Convert the string to UTF-16 representation which is what CGEvent expects
        let utf16Array = Array(key.utf16)
        
        // Create a key down event
        if let keyDownEvent = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
            keyDownEvent.flags = modifiers.flags
            
            // Set the entire string at once for proper emoji/complex character support
            keyDownEvent.keyboardSetUnicodeString(stringLength: utf16Array.count, unicodeString: utf16Array)
            keyDownEvent.post(tap: .cghidEventTap)
        }
        
        // Create a key up event
        if let keyUpEvent = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
            keyUpEvent.flags = modifiers.flags
            keyUpEvent.post(tap: .cghidEventTap)
        }
    }
    
    private func simulateSpecialKey(_ kdeKeyCode: Int, withModifiers modifiers: KeyModifiers) {
        let mappedKeyCode = mapSpecialKey(kdeKeyCode)
        
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            Log.error?.message("Failed to create CGEventSource")
            return
        }
        
        // Create a CGEvent for special key down
        if let keyDownEvent = CGEvent(keyboardEventSource: source, virtualKey: mappedKeyCode, keyDown: true) {
            keyDownEvent.flags = modifiers.flags
            keyDownEvent.post(tap: .cghidEventTap)
        }
        
        // Create a CGEvent for special key up
        if let keyUpEvent = CGEvent(keyboardEventSource: source, virtualKey: mappedKeyCode, keyDown: false) {
            keyUpEvent.flags = modifiers.flags
            keyUpEvent.post(tap: .cghidEventTap)
        }
    }
    
    private func mapSpecialKey(_ kdeKeyCode: Int) -> CGKeyCode {
        // Map KDE Connect special key codes to macOS CGKeyCode values
        switch kdeKeyCode {
        case 1: return 51  // BackSpace
        case 2: return 48  // Tab
        case 3: return 36  // Linefeed (Return on macOS)
        case 4: return 123 // Left Arrow
        case 5: return 126 // Up Arrow
        case 6: return 124 // Right Arrow
        case 7: return 125 // Down Arrow
        case 8: return 116 // Page_Up
        case 9: return 121 // Page_Down
        case 10: return 115 // Home
        case 11: return 119 // End
        case 12: return 36  // Return
        case 13: return 117 // Delete (Forward Delete on macOS)
        case 14: return 53  // Escape
        case 15: return 0   // Sys_Req (not commonly available on macOS)
        case 16: return 0   // Scroll_Lock (not commonly available on macOS)
        case 17: return 0   // Placeholder (not used in GSConnect)
        case 18: return 0   // Placeholder (not used in GSConnect)
        case 19: return 0   // Placeholder (not used in GSConnect)
        case 20: return 0   // Placeholder (not used in GSConnect)
        case 21: return 122 // F1
        case 22: return 120 // F2
        case 23: return 99  // F3
        case 24: return 118 // F4
        case 25: return 96  // F5
        case 26: return 97  // F6
        case 27: return 98  // F7
        case 28: return 100 // F8r
        case 29: return 101 // F9
        case 30: return 109 // F10
        case 31: return 103 // F11
        case 32: return 111 // F12
        // Default for unknown special keys
        default: return CGKeyCode(kdeKeyCode % 128) // Fallback with bounds protection
        }
    }
    
    // MARK: - Mouse Input Properties and Constants
    
    private struct MouseButtons {
        static let left = CGMouseButton.left
        static let right = CGMouseButton.right
        static let center = CGMouseButton.center
    }
    
    // MARK: Mouse Input Properties

    struct MouseInputProperty {
        public static let dx = "dx"
        public static let dy = "dy"
        public static let scroll = "scroll"
        public static let singleclick = "singleclick"
        public static let doubleclick = "doubleclick"
        public static let middleclick = "middleclick"
        public static let rightclick = "rightclick"
        public static let singlehold = "singlehold"
        public static let singlerelease = "singlerelease"
    }

    // Extract mouse movement values (dx, dy)
    func getMouseDx(from dataPacket: DataPacket) throws -> Double {
        try dataPacket.validateRemoteKeyboardRequestType()
        guard dataPacket.body.keys.contains(MouseInputProperty.dx) else { return 0 }
        guard let value = dataPacket.body[MouseInputProperty.dx] as? NSNumber else { 
            throw DataPacket.RemoteKeyboardError.invalidMouseInput
        }
        return value.doubleValue
    }

    func getMouseDy(from dataPacket: DataPacket) throws -> Double {
        try dataPacket.validateRemoteKeyboardRequestType()
        guard dataPacket.body.keys.contains(MouseInputProperty.dy) else { return 0 }
        guard let value = dataPacket.body[MouseInputProperty.dy] as? NSNumber else { 
            throw DataPacket.RemoteKeyboardError.invalidMouseInput
        }
        return value.doubleValue
    }

    // Extract scroll values
    func getScrollDx(from dataPacket: DataPacket) throws -> Double {
        try dataPacket.validateRemoteKeyboardRequestType()
        guard dataPacket.body.keys.contains(MouseInputProperty.scroll) && dataPacket.body.keys.contains(MouseInputProperty.dx) else { 
            return 0 
        }
        guard let value = dataPacket.body[MouseInputProperty.dx] as? NSNumber else { 
            throw DataPacket.RemoteKeyboardError.invalidMouseInput
        }
        return value.doubleValue
    }

    func getScrollDy(from dataPacket: DataPacket) throws -> Double {
        try dataPacket.validateRemoteKeyboardRequestType()
        guard dataPacket.body.keys.contains(MouseInputProperty.scroll) && dataPacket.body.keys.contains(MouseInputProperty.dy) else { 
            return 0 
        }
        guard let value = dataPacket.body[MouseInputProperty.dy] as? NSNumber else { 
            throw DataPacket.RemoteKeyboardError.invalidMouseInput
        }
        return value.doubleValue
    }

    func hasMouseSingleClick(in dataPacket: DataPacket) throws -> Bool {
        try dataPacket.validateRemoteKeyboardRequestType()
        return dataPacket.body.keys.contains(MouseInputProperty.singleclick)
    }

    func hasMouseDoubleClick(in dataPacket: DataPacket) throws -> Bool {
        try dataPacket.validateRemoteKeyboardRequestType()
        return dataPacket.body.keys.contains(MouseInputProperty.doubleclick)
    }

    func hasMouseMiddleClick(in dataPacket: DataPacket) throws -> Bool {
        try dataPacket.validateRemoteKeyboardRequestType()
        return dataPacket.body.keys.contains(MouseInputProperty.middleclick)
    }

    func hasMouseRightClick(in dataPacket: DataPacket) throws -> Bool {
        try dataPacket.validateRemoteKeyboardRequestType()
        return dataPacket.body.keys.contains(MouseInputProperty.rightclick)
    }

    func hasMouseSingleHold(in dataPacket: DataPacket) throws -> Bool {
        try dataPacket.validateRemoteKeyboardRequestType()
        return dataPacket.body.keys.contains(MouseInputProperty.singlehold)
    }

    func hasMouseSingleRelease(in dataPacket: DataPacket) throws -> Bool {
        try dataPacket.validateRemoteKeyboardRequestType()
        return dataPacket.body.keys.contains(MouseInputProperty.singlerelease)
    }

    // MARK: - Mouse Input Processing
    
    private func processMouseInput(_ dataPacket: DataPacket) {
        // First check for scroll events specifically - they also contain dx/dy but should be processed differently
        if dataPacket.body.keys.contains(MouseInputProperty.scroll) {
            if let dx = try? getScrollDx(from: dataPacket),
               let dy = try? getScrollDy(from: dataPacket) {
                scrollPointer(dx: dx, dy: dy)
                return
            }
        }
        
        // Then check for regular mouse movement (dx/dy)
        if !dataPacket.body.keys.contains(MouseInputProperty.scroll) && 
           dataPacket.body.keys.contains(MouseInputProperty.dx) && 
           dataPacket.body.keys.contains(MouseInputProperty.dy) {
            if let dx = try? getMouseDx(from: dataPacket), 
               let dy = try? getMouseDy(from: dataPacket) {
                movePointer(dx: dx, dy: dy)
                return
            }
        }
        
        if let singleClick = try? hasMouseSingleClick(in: dataPacket), singleClick {
            clickPointer(button: MouseButtons.left)
            return
        }
        
        if let doubleClick = try? hasMouseDoubleClick(in: dataPacket), doubleClick {
            doubleClickPointer()
            return
        }
        
        if let middleClick = try? hasMouseMiddleClick(in: dataPacket), middleClick {
            clickPointer(button: MouseButtons.center)
            return
        }
        
        if let rightClick = try? hasMouseRightClick(in: dataPacket), rightClick {
            clickPointer(button: MouseButtons.right)
            return
        }
        
        // Check for press and release (for drag operations)
        if let singleHold = try? hasMouseSingleHold(in: dataPacket), singleHold {
            pressPointer(button: MouseButtons.left)
            return
        }
        
        if let singleRelease = try? hasMouseSingleRelease(in: dataPacket), singleRelease {
            releasePointer(button: MouseButtons.left)
            return
        }
    }
    
    private func movePointer(dx: Double, dy: Double) {
        guard let currentPos = CGEvent(source: nil)?.location else {
            Log.error?.message("Failed to get current pointer position")
            return
        }
        
        let newX = currentPos.x + CGFloat(dx)
        let newY = currentPos.y + CGFloat(dy)
        
        // Create and post the mouse move event
        if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, 
                                 mouseCursorPosition: CGPoint(x: newX, y: newY), 
                                 mouseButton: .left) {
            moveEvent.post(tap: .cghidEventTap)
        } else {
            Log.error?.message("Failed to create mouse move event")
        }
    }
    
    private func scrollPointer(dx: Double, dy: Double) {
        // Create a CGEvent source
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            Log.error?.message("Failed to create CGEventSource")
            return
        }
        
        // Create a scroll wheel event (dy is vertical, dx is horizontal)
        if let scrollEvent = CGEvent(scrollWheelEvent2Source: source,
                                   units: .pixel,
                                   wheelCount: 2,
                                   wheel1: Int32(dy),
                                   wheel2: Int32(dx),
                                   wheel3: 0
        ) {
            scrollEvent.post(tap: .cghidEventTap)
        } else {
            Log.error?.message("Failed to create scroll event")
        }
    }
    
    private func clickPointer(button: CGMouseButton) {
        guard let currentPos = CGEvent(source: nil)?.location else {
            Log.error?.message("Failed to get current pointer position")
            return
        }
        
        // Create a mouse down event
        if let downEvent = CGEvent(mouseEventSource: nil, 
                                 mouseType: button == .left ? .leftMouseDown : 
                                           (button == .right ? .rightMouseDown : .otherMouseDown), 
                                 mouseCursorPosition: currentPos, 
                                 mouseButton: button) {
            if button == MouseButtons.center {
                downEvent.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button.rawValue))
            }
            downEvent.post(tap: .cghidEventTap)
        }
        
        // Small delay to make the click more natural
        usleep(10000) // 10ms
        
        // Create a mouse up event
        if let upEvent = CGEvent(mouseEventSource: nil, 
                               mouseType: button == .left ? .leftMouseUp : 
                                         (button == .right ? .rightMouseUp : .otherMouseUp), 
                               mouseCursorPosition: currentPos, 
                               mouseButton: button) {
            if button == MouseButtons.center {
                upEvent.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button.rawValue))
            }
            upEvent.post(tap: .cghidEventTap)
        }
    }
    
    private func doubleClickPointer() {
        // https://developer.apple.com/forums/thread/685901?answerId=752279022#752279022
        guard let currentPos = CGEvent(source: nil)?.location else {
            Log.error?.message("Failed to get current pointer position")
            return
        }
        
        // Create a source for the CGEvent
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            Log.error?.message("Failed to create CGEventSource")
            return
        }
        
        // Perform the double-click sequence twice since only that seems to work
        
        // First double-click sequence
        if let eventDown = CGEvent(mouseEventSource: source, 
                                 mouseType: .leftMouseDown, 
                                 mouseCursorPosition: currentPos, 
                                 mouseButton: .left) {
            eventDown.setIntegerValueField(.mouseEventClickState, value: 2)
            eventDown.post(tap: .cghidEventTap)
        }
        
        if let eventUp = CGEvent(mouseEventSource: source, 
                               mouseType: .leftMouseUp, 
                               mouseCursorPosition: currentPos, 
                               mouseButton: .left) {
            eventUp.setIntegerValueField(.mouseEventClickState, value: 2)
            eventUp.post(tap: .cghidEventTap)
        }
        
        // Small delay between sequences
        usleep(50000) // 50ms delay
        
        // Second double-click sequence
        if let eventDown2 = CGEvent(mouseEventSource: source, 
                                  mouseType: .leftMouseDown, 
                                  mouseCursorPosition: currentPos, 
                                  mouseButton: .left) {
            eventDown2.setIntegerValueField(.mouseEventClickState, value: 2)
            eventDown2.post(tap: .cghidEventTap)
        }
        
        if let eventUp2 = CGEvent(mouseEventSource: source, 
                                mouseType: .leftMouseUp, 
                                mouseCursorPosition: currentPos, 
                                mouseButton: .left) {
            eventUp2.setIntegerValueField(.mouseEventClickState, value: 2)
            eventUp2.post(tap: .cghidEventTap)
        }
    }
    
    private func pressPointer(button: CGMouseButton) {
        guard let currentPos = CGEvent(source: nil)?.location else {
            Log.error?.message("Failed to get current pointer position")
            return
        }
        
        // Create a mouse down event without an up event (for dragging)
        if let downEvent = CGEvent(mouseEventSource: nil, 
                                 mouseType: button == .left ? .leftMouseDown : 
                                           (button == .right ? .rightMouseDown : .otherMouseDown), 
                                 mouseCursorPosition: currentPos, 
                                 mouseButton: button) {
            downEvent.post(tap: .cghidEventTap)
        } else {
            Log.error?.message("Failed to create mouse press event")
        }
    }
    
    private func releasePointer(button: CGMouseButton) {
        guard let currentPos = CGEvent(source: nil)?.location else {
            Log.error?.message("Failed to get current pointer position")
            return
        }
        
        // Create a mouse up event
        if let upEvent = CGEvent(mouseEventSource: nil, 
                               mouseType: button == .left ? .leftMouseUp : 
                                         (button == .right ? .rightMouseUp : .otherMouseUp), 
                               mouseCursorPosition: currentPos, 
                               mouseButton: button) {
            upEvent.post(tap: .cghidEventTap)
        } else {
            Log.error?.message("Failed to create mouse release event")
        }
    }
    
    // MARK: - Accessibility Permissions

    private func checkAndRequestAccessibilityPermissions() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let accessEnabled = AXIsProcessTrustedWithOptions(options)
        
        if !accessEnabled {
            Log.warning?.message("Accessibility permissions not granted. Prompting user.")
            
            // Show an alert explaining why we need accessibility permissions
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Accessibility Permissions Required"
                alert.informativeText = "To enable remote keyboard and mouse functionality, Soduto needs accessibility permissions. Please grant access in System Settings > Privacy & Security > Accessibility."
                alert.addButton(withTitle: "Open System Settings")
                alert.addButton(withTitle: "Later")
                
                let response = alert.runModal()
                if response == .alertFirstButtonReturn {
                    // Open the accessibility preferences
                    let prefPanePath = "/System/Library/PreferencePanes/Security.prefPane"
                    
                    if #available(macOS 13.0, *) {
                        // For macOS Ventura and later
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    } else {
                        // For older macOS versions
                        NSWorkspace.shared.open(URL(fileURLWithPath: prefPanePath))
                    }
                }
            }
        } else {
            Log.info?.message("Accessibility permissions already granted.")
        }
    }
    
    // MARK: - Presenter Input Properties and Methods
    
    // Extract presenter movement values (dx, dy)
    func getPresenterDx(from dataPacket: DataPacket) -> Double {
        guard dataPacket.isPresenterPacket else { return 0 }
        guard dataPacket.body.keys.contains(MouseInputProperty.dx) else { return 0 }
        guard let value = dataPacket.body[MouseInputProperty.dx] as? NSNumber else { return 0 }
        return value.doubleValue
    }
    
    func getPresenterDy(from dataPacket: DataPacket) -> Double {
        guard dataPacket.isPresenterPacket else { return 0 }
        guard dataPacket.body.keys.contains(MouseInputProperty.dy) else { return 0 }
        guard let value = dataPacket.body[MouseInputProperty.dy] as? NSNumber else { return 0 }
        return value.doubleValue
    }
    
    // Process presenter input
    private func processPresenterInput(_ dataPacket: DataPacket) {
        // Get dx and dy values from the presenter packet
        let dx = getPresenterDx(from: dataPacket)
        let dy = getPresenterDy(from: dataPacket)
        
        // Use the same movePointer function as regular mouse movement
        // since presenter packets use the same format
        movePointer(dx: dx * 1000, dy: dy * 1000)
    }
}


// MARK: DataPacket (Remote keyboard)

/// Remote keyboard service data packet utilities
fileprivate extension DataPacket {
    
    // MARK: Types
    
    enum RemoteKeyboardError: Error {
        case wrongType
        case invalidSendAckFlag
        case invalidIsAckFlag
        case invalidKey
        case invalidSpecialKey
        case invalidShiftFlag
        case invalidCtrlFlag
        case invalidAltFlag
        case invalidMouseInput
    }
    
    struct RemoteKeyboardProperty {
        public static let sendAck = "sendAck"
        public static let isAck = "isAck"
        public static let key = "key"
        public static let specialKey = "specialKey"
        public static let shift = "shift"
        public static let ctrl = "ctrl"
        public static let alt = "alt"
    }
    
    
    // MARK: Properties
    
    static let remoteKeyboardRequestPacketType = "kdeconnect.mousepad.request"
    static let remoteKeyboardEchoPacketType = "kdeconnect.mousepad.echo"
    static let presenterPacketType = "kdeconnect.presenter"
    
    var isRemoteKeyboardRequestPacket: Bool { return self.type == DataPacket.remoteKeyboardRequestPacketType }
    var isRemoteKeyboardEchoPacket: Bool { return self.type == DataPacket.remoteKeyboardEchoPacketType }
    var isPresenterPacket: Bool { return self.type == DataPacket.presenterPacketType }
    
    
    // MARK: Public static methods
    
    static func remoteKeyboardEchoPacket(for dataPacket: DataPacket) throws -> DataPacket {
        assert(dataPacket.isRemoteKeyboardRequestPacket, "Expected packet type \(remoteKeyboardEchoPacketType), but got \(dataPacket.type)")
        var body: Body = [
            RemoteKeyboardProperty.isAck: true as AnyObject,
            RemoteKeyboardProperty.key: try dataPacket.getKey() as AnyObject
        ]
        
        // Handle optional values more safely
        if let specialKey = try dataPacket.getSpecialKey() {
            body[RemoteKeyboardProperty.specialKey] = specialKey as AnyObject
        }
        
        // Explicitly unwrap optional Bool values
        if let shiftOptional = try dataPacket.getShiftFlag(), shiftOptional {
            body[RemoteKeyboardProperty.shift] = shiftOptional as AnyObject
        }
        
        if let ctrlOptional = try dataPacket.getCtrlFlag(), ctrlOptional {
            body[RemoteKeyboardProperty.ctrl] = ctrlOptional as AnyObject
        }
        
        if let altOptional = try dataPacket.getAltFlag(), altOptional {
            body[RemoteKeyboardProperty.alt] = altOptional as AnyObject
        }
        
        return DataPacket(type: remoteKeyboardEchoPacketType, body: body)
    }
    
    
    // MARK: Public methods
    
    func getSendAckFlag() throws -> Bool {
        try self.validateRemoteKeyboardRequestType()
        guard body.keys.contains(RemoteKeyboardProperty.sendAck) else { return false }
        guard let value = body[RemoteKeyboardProperty.sendAck] as? NSNumber else { throw RemoteKeyboardError.invalidSendAckFlag }
        return value.boolValue
    }
    
    func getKey() throws -> String {
        try self.validateRemoteKeyboardType()
        guard body.keys.contains(RemoteKeyboardProperty.key) else { throw RemoteKeyboardError.invalidKey }
        guard let value = body[RemoteKeyboardProperty.key] as? String else { throw RemoteKeyboardError.invalidKey }
        return value
    }
    
    func getSpecialKey() throws -> Int? {
        try self.validateRemoteKeyboardType()
        guard body.keys.contains(RemoteKeyboardProperty.specialKey) else { return nil }
        guard let value = body[RemoteKeyboardProperty.specialKey] as? NSNumber else { throw RemoteKeyboardError.invalidSpecialKey }
        return value.intValue
    }
    
    func getShiftFlag() throws -> Bool? {
        try self.validateRemoteKeyboardType()
        guard body.keys.contains(RemoteKeyboardProperty.shift) else { return nil }
        guard let value = body[RemoteKeyboardProperty.shift] as? NSNumber else { throw RemoteKeyboardError.invalidShiftFlag }
        return value.boolValue
    }
    
    func getCtrlFlag() throws -> Bool? {
        try self.validateRemoteKeyboardType()
        guard body.keys.contains(RemoteKeyboardProperty.ctrl) else { return nil }
        guard let value = body[RemoteKeyboardProperty.ctrl] as? NSNumber else { throw RemoteKeyboardError.invalidCtrlFlag }
        return value.boolValue
    }
    
    func getAltFlag() throws -> Bool? {
        try self.validateRemoteKeyboardType()
        guard body.keys.contains(RemoteKeyboardProperty.alt) else { return nil }
        guard let value = body[RemoteKeyboardProperty.alt] as? NSNumber else { throw RemoteKeyboardError.invalidAltFlag }
        return value.boolValue
    }
    
    func validateRemoteKeyboardRequestType() throws {
        guard self.isRemoteKeyboardRequestPacket else { throw RemoteKeyboardError.wrongType }
    }
    
    func validateRemoteKeyboardEchoType() throws {
        guard self.isRemoteKeyboardEchoPacket else { throw RemoteKeyboardError.wrongType }
    }
    
    func validateRemoteKeyboardType() throws {
        guard self.isRemoteKeyboardRequestPacket || self.isRemoteKeyboardEchoPacket else { throw RemoteKeyboardError.wrongType }
    }
}
