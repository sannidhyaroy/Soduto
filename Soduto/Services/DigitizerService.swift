//
//  DigitizerService.swift
//  Soduto
//
//  Created by Sannidhya Roy on 27/03/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import Cocoa
import os
import ApplicationServices

/// Service for receiving drawing tablet (digitizer) input from a remote device.
///
/// Implements the `kdeconnect.digitizer` protocol. Handles two incoming packet types:
///
/// `kdeconnect.digitizer.session` starts or ends a drawing tablet session:
///   - Start: `action: "start"` with `width`, `height` (tablet surface dimensions)
///     and `resolutionX`, `resolutionY` (pixels/mm). Creates the virtual tablet context.
///   - End: `action: "end"`. Tears down the session. Also ends implicitly on disconnect.
///   - Starting a new session while one is active ends the old session first.
///
/// `kdeconnect.digitizer`: stylus or finger event (must not arrive before a session starts):
///   - `active` (Bool): tool is in proximity; `false` when the tool exits hover range.
///   - `touching` (Bool): tool is touching the surface (pen down / pen up).
///   - `tool` (String): `"Pen"` or `"Rubber"` (eraser).
///   - `x`, `y` (Int): absolute position on the tablet surface.
///   - `pressure` (Double, 0–1): pen pressure.
///
/// The service maps absolute tablet coordinates to the Mac screen proportionally and
/// synthesises `CGEvent` mouse events with tablet-point subtype fields (pressure, device ID)
/// so that apps reading CGEvent tablet fields (Markup, Preview, Pixelmator Pro) recognise the
/// input as tablet input. Apps requiring a registered HID device (Apple Notes, Krita, Photoshop)
/// will not see pressure, their approach requires private entitlements from Apple.
/// Proximity events are emitted on tool enter/exit and tool-type changes (pen ↔ eraser).
///
/// Requires Accessibility permissions (System Settings › Privacy & Security › Accessibility)
/// to synthesise CGEvents.
public class DigitizerService: IncomingService {
    
    // MARK: Types
    
    private struct Session {
        let width: Int
        let height: Int
        let resolutionX: Int
        let resolutionY: Int
    }
    
    private enum Tool: String {
        case pen = "Pen"
        case rubber = "Rubber"
    }
    
    
    // MARK: Properties
    
    var userDefaults: UserDefaults = .standard
    let incomingPreferenceKey = AppDefaultsStore.Preferences.Services.Digitizer.incomingKey
    
    private var hasCheckedAccessibility = false
    
    private var session: Session?
    private var currentTool: Tool?
    private var isTouching = false
    /// Last position warped to via CGWarpMouseCursorPosition, used as fallback when
    /// a packet arrives without coordinates (e.g. finger-lift ACTION_UP sends active=false
    /// with no x/y).
    private var lastWarpedPosition: CGPoint?
    
    /// Serial queue for CGEvent posting (same pattern as RemoteInputService).
    /// `CGEvent.post()` can block when the window server is locked by a modal tracking
    /// loop, so posting off-main keeps packet processing responsive.
    private let eventPostQueue = DispatchQueue(label: "com.soduto.services.digitizer.events", qos: .userInteractive)
    
    // Virtual tablet device identifiers stamped on proximity events so the system
    // treats all events as coming from one coherent tablet device.
    private let virtualVendorID: Int64 = 0x0E8F   // arbitrary, distinct from real vendors
    private let virtualTabletID: Int64 = 1
    private let virtualDeviceID: Int64 = 1
    private let virtualPointerID: Int64 = 1
    
    
    // MARK: Service
    
    public static let serviceId: Service.Id = "com.soduto.services.digitizer"
    
    public let incomingCapabilities = Set<Service.Capability>([
        DataPacket.digitizerSessionPacketType,
        DataPacket.digitizerPacketType
    ])
    public let outgoingCapabilities = Set<Service.Capability>([])
    
    public func handleDataPacket(_ dataPacket: DataPacket, fromDevice device: Device, onConnection connection: Connection) -> Bool {
        guard incomingEnabled else { return true }
        
        if !hasCheckedAccessibility {
            checkAndRequestAccessibilityPermissions()
            hasCheckedAccessibility = true
        }
        
        switch dataPacket.type {
        case DataPacket.digitizerSessionPacketType:
            handleSessionPacket(dataPacket)
        case DataPacket.digitizerPacketType:
            handleToolEvent(dataPacket)
        default:
            return false
        }
        
        return true
    }
    
    public func setup(for device: Device) {}
    
    public func cleanup(for device: Device) {
        // Per protocol: session ends on disconnect
        endSession()
    }
    
    public func actions(for device: Device) -> [ServiceAction] { return [] }
    public func performAction(_ id: ServiceAction.Id, forDevice device: Device, userInfo: [String: Any]?) {}
    
    
    // MARK: Session Management
    
    private func handleSessionPacket(_ packet: DataPacket) {
        do {
            let action = try packet.getDigitizerAction()
            
            switch action {
            case "start":
                let width = try packet.getDigitizerWidth()
                let height = try packet.getDigitizerHeight()
                let resX = try packet.getDigitizerResolutionX()
                let resY = try packet.getDigitizerResolutionY()
                startSession(width: width, height: height, resolutionX: resX, resolutionY: resY)
                
            case "end":
                endSession()
                
            default:
                Logger.services.warning("Digitizer: unknown session action '\(action, privacy: .public)'. Ignoring...")
            }
        } catch {
            Logger.services.error("Error handling digitizer session packet: \(error, privacy: .public)")
        }
    }
    
    private func startSession(width: Int, height: Int, resolutionX: Int, resolutionY: Int) {
        // If a session already exists, end it first (per protocol)
        if session != nil { endSession() }
        session = Session(width: width, height: height, resolutionX: resolutionX, resolutionY: resolutionY)
        Logger.services.info("Digitizer session started: \(width)×\(height), resolution \(resolutionX)×\(resolutionY) px/mm")
    }
    
    private func endSession() {
        guard session != nil else { return }
        
        // Clean up in-flight state: release touch, exit proximity
        if isTouching {
            let pos = CGEvent(source: nil)?.location ?? .zero
            postMouseEvent(.leftMouseUp, at: pos, pressure: 0, asDrag: false)
            isTouching = false
        }
        if currentTool != nil {
            postProximityEvent(entering: false)
            currentTool = nil
        }
        
        session = nil
        lastWarpedPosition = nil
        Logger.services.info("Digitizer session ended")
    }
    
    
    // MARK: Tool Event Handling
    
    private func handleToolEvent(_ packet: DataPacket) {
        guard let session = session else {
            Logger.services.debug("Digitizer: received tool event without active session. Ignoring...")
            return
        }
        
        let active = packet.digitizerActive
        let touching = packet.digitizerTouching
        let toolStr = packet.digitizerTool
        let x = packet.digitizerX
        let y = packet.digitizerY
        let pressure = packet.digitizerPressure
        
        // active=false: tool exited proximity
        if active == false {
            let pos = mapToScreen(x: x, y: y, session: session) ?? lastWarpedPosition ?? CGEvent(source: nil)?.location ?? .zero
            if isTouching {
                postMouseEvent(.leftMouseUp, at: pos, pressure: 0, asDrag: false)
                isTouching = false
            }
            if currentTool != nil {
                postProximityEvent(entering: false, at: pos)
                currentTool = nil
            }
            return
        }
        
        // Tool type management (proximity enter/exit on change)
        let resolvedTool: Tool
        if let str = toolStr, let parsed = Tool(rawValue: str) {
            resolvedTool = parsed
        } else {
            resolvedTool = currentTool ?? .pen
        }
        
        if currentTool != resolvedTool {
            // Tool changed (or first event): exit old tool, enter new tool
            if currentTool != nil {
                postProximityEvent(entering: false)
            }
            currentTool = resolvedTool
            postProximityEvent(entering: true)
        }
        
        // Coordinate mapping
        let screenPos = mapToScreen(x: x, y: y, session: session)
        
        // Resolve effective touch state
        // The `touching` field is the primary indicator (stylus sends touching=true on
        // ACTION_DOWN). However, Android never sends touching=true for finger input,
        // even when the "Draw" button is held, it sends touching=false with pressure=1.0.
        // We infer touch from pressure > 0 to support finger drawing.
        let effectiveTouching: Bool?
        if let t = touching {
            if !t && !isTouching, let p = pressure, p > 0 {
                // touching=false but pressure>0: finger+draw-button case → infer touch
                effectiveTouching = true
            } else {
                effectiveTouching = t
            }
        } else if !isTouching, let p = pressure, p > 0 {
            // touching absent but pressure>0 on first move after finger ACTION_DOWN
            effectiveTouching = true
        } else {
            effectiveTouching = nil
        }
        
        // Touch state transitions
        if let nowTouching = effectiveTouching {
            if nowTouching && !isTouching {
                // Pen down
                if let pos = screenPos {
                    CGWarpMouseCursorPosition(pos)
                    CGAssociateMouseAndMouseCursorPosition(1)
                    lastWarpedPosition = pos
                    let p = pressure ?? 1.0
                    postMouseEvent(.leftMouseDown, at: pos, pressure: p, asDrag: false)
                }
                isTouching = true
            } else if !nowTouching && isTouching {
                // Pen up: report pressure 0 per Linux impl (BTN_TOUCH 0 → ABS_PRESSURE 0)
                let pos = screenPos ?? lastWarpedPosition ?? CGEvent(source: nil)?.location ?? .zero
                postMouseEvent(.leftMouseUp, at: pos, pressure: 0, asDrag: false)
                isTouching = false
            }
        }
        
        // Movement / hover
        if let pos = screenPos {
            CGWarpMouseCursorPosition(pos)
            CGAssociateMouseAndMouseCursorPosition(1)
            lastWarpedPosition = pos
            
            let p = pressure ?? (isTouching ? 1.0 : 0.0)
            if isTouching {
                postMouseEvent(.leftMouseDragged, at: pos, pressure: p, asDrag: true)
            } else {
                postMouseEvent(.mouseMoved, at: pos, pressure: p, asDrag: false)
            }
        }
    }
    
    
    // MARK: Coordinate Mapping
    
    /// Maps absolute tablet coordinates to macOS screen coordinates proportionally.
    /// Returns `nil` if either coordinate is absent or the session dimensions are invalid.
    private func mapToScreen(x: Int?, y: Int?, session: Session) -> CGPoint? {
        guard let x = x, let y = y else { return nil }
        guard session.width > 0, session.height > 0 else { return nil }
        
        // Use the screen containing the mouse cursor (supports multi-monitor)
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main
        guard let frame = screen?.frame else { return nil }
        
        // Proportional mapping: tablet (0,0)→screen top-left, tablet (w,h)→screen bottom-right
        // NSScreen uses bottom-left origin; CGEvent/Quartz uses top-left origin.
        // CGWarpMouseCursorPosition uses the Quartz (global display) coordinate space.
        let screenX = (Double(x) / Double(session.width)) * frame.width + frame.origin.x
        // For Quartz Y: 0 = top of the main display. Convert from NS (bottom-left) to CG (top-left).
        let mainHeight = NSScreen.screens.first?.frame.height ?? frame.height
        let nsY = (Double(y) / Double(session.height)) * frame.height
        let screenY = (mainHeight - frame.origin.y - frame.height) + nsY
        
        return CGPoint(x: screenX, y: screenY)
    }
    
    
    // MARK: CGEvent Posting
    
    /// Posts a mouse event with tablet-point subtype fields (pressure, device ID).
    private func postMouseEvent(_ type: CGEventType, at position: CGPoint, pressure: Double, asDrag: Bool) {
        let devID = virtualDeviceID
        eventPostQueue.async {
            guard let source = CGEventSource(stateID: .hidSystemState) else { return }
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: position, mouseButton: .left) else { return }
            // Mark as tablet-point event so drawing apps pick up pressure
            event.setIntegerValueField(.mouseEventSubtype, value: 1)  // NX_SUBTYPE_TABLET_POINT
            event.setDoubleValueField(.tabletEventPointPressure, value: pressure)
            event.setIntegerValueField(.tabletEventDeviceID, value: devID)
            event.post(tap: .cghidEventTap)
        }
    }
    
    /// Posts a tablet proximity event (tool enter/exit) so drawing apps recognise tool type.
    /// The position is used as the `mouseCursorPosition` on the underlying `.mouseMoved`
    /// event. Passing `.zero` would warp the cursor to the top-left corner.
    private func postProximityEvent(entering: Bool, at position: CGPoint? = nil) {
        let pos = position ?? lastWarpedPosition ?? CGEvent(source: nil)?.location ?? .zero
        let pointerType: Int64 = (currentTool == .rubber) ? 3 : 1   // 1 = pen, 3 = eraser
        let vendorID = virtualVendorID
        let tabletID = virtualTabletID
        let deviceID = virtualDeviceID
        let pointerID = virtualPointerID
        // Capability mask: pen tip (bit 0) + eraser (bit 1)
        let capabilityMask: Int64 = 0x0003
        eventPostQueue.async {
            guard let source = CGEventSource(stateID: .hidSystemState) else { return }
            // Proximity events are delivered as mouse-moved with the proximity subtype
            guard let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: pos, mouseButton: .left) else { return }
            event.setIntegerValueField(.mouseEventSubtype, value: 2)  // NX_SUBTYPE_TABLET_PROXIMITY
            event.setIntegerValueField(.tabletProximityEventEnterProximity, value: entering ? 1 : 0)
            event.setIntegerValueField(.tabletProximityEventPointerType, value: pointerType)
            event.setIntegerValueField(.tabletProximityEventVendorID, value: vendorID)
            event.setIntegerValueField(.tabletProximityEventTabletID, value: tabletID)
            event.setIntegerValueField(.tabletProximityEventDeviceID, value: deviceID)
            event.setIntegerValueField(.tabletProximityEventPointerID, value: pointerID)
            event.setIntegerValueField(.tabletProximityEventCapabilityMask, value: capabilityMask)
            event.post(tap: .cghidEventTap)
        }
    }
    
    
    // MARK: Accessibility Permissions
    
    private func checkAndRequestAccessibilityPermissions() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        guard !AXIsProcessTrustedWithOptions(options) else {
            Logger.services.info("Accessibility permissions already granted for digitizer input")
            return
        }
        
        Logger.services.notice("Accessibility permissions not granted for digitizer input. Prompting user...")
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Accessibility Permissions Required"
            alert.informativeText = "To enable remote drawing tablet input, Soduto needs Accessibility permissions. Please grant access in System Settings › Privacy & Security › Accessibility."
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
        }
    }
}


// MARK: - DataPacket (Digitizer)

/// Digitizer data packet utilities for the `kdeconnect.digitizer` protocol.
fileprivate extension DataPacket {
    
    // MARK: Types
    
    enum DigitizerError: Error {
        case wrongType
        case missingAction
        case invalidAction
        case missingWidth
        case invalidWidth
        case missingHeight
        case invalidHeight
        case missingResolutionX
        case invalidResolutionX
        case missingResolutionY
        case invalidResolutionY
    }
    
    struct DigitizerProperty {
        // Session fields
        static let action      = "action"
        static let width       = "width"
        static let height      = "height"
        static let resolutionX = "resolutionX"
        static let resolutionY = "resolutionY"
        // Event fields
        static let active      = "active"
        static let touching    = "touching"
        static let tool        = "tool"
        static let x           = "x"
        static let y           = "y"
        static let pressure    = "pressure"
    }
    
    
    // MARK: Properties
    
    static let digitizerSessionPacketType = "kdeconnect.digitizer.session"
    static let digitizerPacketType        = "kdeconnect.digitizer"
    
    var isDigitizerSessionPacket: Bool { self.type == DataPacket.digitizerSessionPacketType }
    var isDigitizerPacket: Bool { self.type == DataPacket.digitizerPacketType }
    
    
    // MARK: Session Accessors
    
    func getDigitizerAction() throws -> String {
        try validateDigitizerSessionType()
        guard body.keys.contains(DigitizerProperty.action) else { throw DigitizerError.missingAction }
        guard let value = body[DigitizerProperty.action] as? String else { throw DigitizerError.invalidAction }
        return value
    }
    
    func getDigitizerWidth() throws -> Int {
        try validateDigitizerSessionType()
        guard body.keys.contains(DigitizerProperty.width) else { throw DigitizerError.missingWidth }
        guard let value = body[DigitizerProperty.width] as? NSNumber else { throw DigitizerError.invalidWidth }
        return value.intValue
    }
    
    func getDigitizerHeight() throws -> Int {
        try validateDigitizerSessionType()
        guard body.keys.contains(DigitizerProperty.height) else { throw DigitizerError.missingHeight }
        guard let value = body[DigitizerProperty.height] as? NSNumber else { throw DigitizerError.invalidHeight }
        return value.intValue
    }
    
    func getDigitizerResolutionX() throws -> Int {
        try validateDigitizerSessionType()
        guard body.keys.contains(DigitizerProperty.resolutionX) else { throw DigitizerError.missingResolutionX }
        guard let value = body[DigitizerProperty.resolutionX] as? NSNumber else { throw DigitizerError.invalidResolutionX }
        return value.intValue
    }
    
    func getDigitizerResolutionY() throws -> Int {
        try validateDigitizerSessionType()
        guard body.keys.contains(DigitizerProperty.resolutionY) else { throw DigitizerError.missingResolutionY }
        guard let value = body[DigitizerProperty.resolutionY] as? NSNumber else { throw DigitizerError.invalidResolutionY }
        return value.intValue
    }
    
    func validateDigitizerSessionType() throws {
        guard self.isDigitizerSessionPacket else { throw DigitizerError.wrongType }
    }
    
    
    // MARK: Event Accessors (computed properties, all fields are optional per protocol)
    
    var digitizerActive: Bool? { (body[DigitizerProperty.active] as? NSNumber)?.boolValue }
    var digitizerTouching: Bool? { (body[DigitizerProperty.touching] as? NSNumber)?.boolValue }
    var digitizerTool: String? { body[DigitizerProperty.tool] as? String }
    var digitizerX: Int? { (body[DigitizerProperty.x] as? NSNumber)?.intValue }
    var digitizerY: Int? { (body[DigitizerProperty.y] as? NSNumber)?.intValue }
    var digitizerPressure: Double? { (body[DigitizerProperty.pressure] as? NSNumber)?.doubleValue }
}
