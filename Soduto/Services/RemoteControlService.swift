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
/// Press **Option+Escape** to exit capture mode.
///
/// Requires Accessibility permissions (System Settings › Privacy & Security › Accessibility).
public class RemoteControlService: Service {

    // MARK: Properties

    public static let serviceId: Service.Id = "com.soduto.services.remotecontrol"

    public let incomingCapabilities = Set<Service.Capability>([])
    public let outgoingCapabilities = Set<Service.Capability>([
        DataPacket.mousePadRequestPacketType
    ])

    private var isCapturing = false
    private var targetDevice: Device?
    private var eventTap: CFMachPort?
    private var eventRunLoopSource: CFRunLoopSource?
    private var optionKeyPressed = false
    private var isDragging = false
    private var originalMouseLocation: NSPoint?
    private var invisibleCursor: NSCursor?
    private var hudPanel: NSPanel?
    private var escapeMonitor: Any?


    // MARK: Service

    public func handleDataPacket(_ dataPacket: DataPacket, fromDevice device: Device, onConnection connection: Connection) -> Bool {
        return false
    }

    public func setup(for device: Device) {}

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
        guard device.pairingStatus == .Paired, device.isReachable else { return [] }
        if isCapturing && targetDevice?.id == device.id {
            return [ServiceAction(id: ActionId.stopInputCapturing.rawValue, title: "Stop Input Capture", description: "Stop sending input to this device", service: self, device: device)]
        }
        return [ServiceAction(id: ActionId.startInputCapturing.rawValue, title: "Control Remote Device", description: "Send keyboard and mouse input to this device", service: self, device: device)]
    }

    public func performAction(_ id: ServiceAction.Id, forDevice device: Device) {
        switch id {
        case ActionId.startInputCapturing.rawValue: startCapturing(for: device)
        case ActionId.stopInputCapturing.rawValue:  stopCapturing()
        default: Logger.services.notice("Unknown action id: \(id, privacy: .public)")
        }
    }


    // MARK: Capturing

    private func startCapturing(for device: Device) {
        guard !isCapturing, device.pairingStatus == .Paired else { return }

        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        guard AXIsProcessTrustedWithOptions(options) else {
            Logger.services.notice("Accessibility permissions not granted for remote control; prompting user...")
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Accessibility Permissions Required"
                alert.informativeText = "To send keyboard and mouse input to remote devices, Soduto needs Accessibility permissions. Please grant access in System Settings › Privacy & Security › Accessibility."
                alert.addButton(withTitle: "Open System Settings")
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            }
            return
        }

        Logger.services.info("Starting input capture for device: \(device.name, privacy: .public)")
        targetDevice = device
        isCapturing = true
        isDragging = false

        setupEscapeMonitor()
        setupEventTap()
        showHUD()
        hideCursorAndCenterOnScreen()
    }

    private func stopCapturing() {
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
        hideHUD()

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

    // Backup local monitor that catches Option+Escape if the CGEvent tap is ever auto-disabled
    // by macOS (the OS kills taps whose callbacks take too long). Also blocks modifier events
    // from leaking to foreground apps while capture is active.
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

    private func sendMouseMove(dx: CGFloat, dy: CGFloat, to device: Device) {
        device.send(DataPacket(type: DataPacket.mousePadRequestPacketType, body: [
            "dx": dx as NSNumber,
            "dy": dy as NSNumber
        ]))
    }

    private func sendScroll(dx: Double, dy: Double, to device: Device) {
        device.send(DataPacket(type: DataPacket.mousePadRequestPacketType, body: [
            "scroll": true as NSNumber,
            "dx": dx as NSNumber,
            "dy": dy as NSNumber
        ]))
    }

    private func sendMouseDown(to device: Device) {
        device.send(DataPacket(type: DataPacket.mousePadRequestPacketType, body: ["singlehold": true as NSNumber]))
    }

    private func sendMouseUp(to device: Device) {
        device.send(DataPacket(type: DataPacket.mousePadRequestPacketType, body: ["singlerelease": true as NSNumber]))
    }

    private func sendDoubleClick(to device: Device) {
        device.send(DataPacket(type: DataPacket.mousePadRequestPacketType, body: ["doubleclick": true as NSNumber]))
    }

    private func sendRightClick(to device: Device) {
        device.send(DataPacket(type: DataPacket.mousePadRequestPacketType, body: ["rightclick": true as NSNumber]))
    }

    private func sendMiddleClick(to device: Device) {
        device.send(DataPacket(type: DataPacket.mousePadRequestPacketType, body: ["middleclick": true as NSNumber]))
    }

    private func sendKey(_ key: String, shift: Bool, ctrl: Bool, alt: Bool, to device: Device) {
        var body: DataPacket.Body = ["key": key as NSString, "sendAck": false as NSNumber]
        if shift { body["shift"] = true as NSNumber }
        if ctrl  { body["ctrl"]  = true as NSNumber }
        if alt   { body["alt"]   = true as NSNumber }
        device.send(DataPacket(type: DataPacket.mousePadRequestPacketType, body: body))
    }

    private func sendSpecialKey(_ keyCode: Int, shift: Bool, ctrl: Bool, alt: Bool, to device: Device) {
        var body: DataPacket.Body = ["specialKey": keyCode as NSNumber, "sendAck": false as NSNumber]
        if shift { body["shift"] = true as NSNumber }
        if ctrl  { body["ctrl"]  = true as NSNumber }
        if alt   { body["alt"]   = true as NSNumber }
        device.send(DataPacket(type: DataPacket.mousePadRequestPacketType, body: body))
    }


    // MARK: Key mapping

    private func mapKeyCodeToSpecialKey(_ keyCode: UInt16) -> Int? {
        switch keyCode {
        case 51:  return 1   // Backspace
        case 48:  return 2   // Tab
        case 36:  return 3   // Return
        case 123: return 4   // Left Arrow
        case 126: return 5   // Up Arrow
        case 124: return 6   // Right Arrow
        case 125: return 7   // Down Arrow
        case 116: return 8   // Page Up
        case 121: return 9   // Page Down
        case 115: return 10  // Home
        case 119: return 11  // End
        case 117: return 13  // Forward Delete
        case 53:  return 14  // Escape
        case 122: return 21  // F1
        case 120: return 22  // F2
        case 99:  return 23  // F3
        case 118: return 24  // F4
        case 96:  return 25  // F5
        case 97:  return 26  // F6
        case 98:  return 27  // F7
        case 100: return 28  // F8
        case 101: return 29  // F9
        case 109: return 30  // F10
        case 103: return 31  // F11
        case 111: return 32  // F12
        default:  return nil
        }
    }


    // MARK: HUD

    private func showHUD() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isFloatingPanel = true

        let blur = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 360, height: 80))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 10
        blur.layer?.masksToBounds = true

        let titleLabel = NSTextField(labelWithString: "Controlling \(targetDevice?.name ?? "Remote Device")")
        titleLabel.font = .boldSystemFont(ofSize: 15)
        titleLabel.textColor = .white
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let hintLabel = NSTextField(labelWithString: "Press Option+Escape to stop")
        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = NSColor.white.withAlphaComponent(0.75)
        hintLabel.alignment = .center
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        blur.addSubview(titleLabel)
        blur.addSubview(hintLabel)
        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: blur.centerXAnchor),
            titleLabel.topAnchor.constraint(equalTo: blur.topAnchor, constant: 16),
            hintLabel.centerXAnchor.constraint(equalTo: blur.centerXAnchor),
            hintLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8)
        ])
        panel.contentView = blur

        if let screen = NSScreen.main {
            let x = (screen.frame.width - 360) / 2
            let y = screen.frame.height - 80 - 50
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        hudPanel = panel
        panel.orderFrontRegardless()
    }

    private func hideHUD() {
        hudPanel?.orderOut(nil)
        hudPanel?.contentView = nil
        hudPanel = nil
    }


    // MARK: Event tap callback

    private let eventTapCallback: CGEventTapCallBack = { proxy, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let service = Unmanaged<RemoteControlService>.fromOpaque(refcon).takeUnretainedValue()
        guard service.isCapturing, let device = service.targetDevice else {
            return Unmanaged.passUnretained(event)
        }

        // Re-enable the tap if macOS auto-disabled it (the OS kills taps whose callbacks are too slow).
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
            service.isDragging = false
            service.sendMouseUp(to: device)
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

        // MARK: Scroll
        case .scrollWheel:
            let dx = event.getDoubleValueField(.scrollWheelEventDeltaAxis2)
            let dy = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
            if abs(dx) > 0.1 || abs(dy) > 0.1 {
                service.sendScroll(dx: dx, dy: dy, to: device)
            }
            return nil

        // MARK: Keyboard
        case .keyDown:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags
            let optionDown = flags.contains(.maskAlternate) || service.optionKeyPressed

            if keyCode == 53 && optionDown {
                DispatchQueue.main.async { service.stopCapturing() }
                return nil
            }

            let shift = flags.contains(.maskShift)
            let ctrl  = flags.contains(.maskControl)
            let alt   = flags.contains(.maskAlternate)

            if let specialKey = service.mapKeyCodeToSpecialKey(keyCode) {
                service.sendSpecialKey(specialKey, shift: shift, ctrl: ctrl, alt: alt, to: device)
            } else {
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)
                if length > 0 {
                    let key = String(utf16CodeUnits: Array(chars.prefix(length)), count: length)
                    if !key.isEmpty {
                        service.sendKey(key, shift: shift, ctrl: ctrl, alt: alt, to: device)
                    }
                }
            }
            return nil

        case .keyUp:
            return nil

        case .flagsChanged:
            service.optionKeyPressed = event.flags.contains(.maskAlternate)
            return nil

        default:
            return nil
        }
    }
}


// MARK: DataPacket (MousePad)

fileprivate extension DataPacket {
    static let mousePadRequestPacketType = "kdeconnect.mousepad.request"
}
