//
//  PairingWindowController.swift
//  Soduto
//
//  Created by Sannidhya Roy on 22/02/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import Cocoa
import SwiftUI
import os

/// Manages the standalone pairing window for a device.
/// Shows verification code and handles accept/decline actions.
@MainActor
class PairingWindowController: NSWindowController {
    
    // MARK: - Static Properties
    
    /// Track active pairing windows by device ID
    private static var activeWindows: [Device.Id: PairingWindowController] = [:]
    
    // MARK: - Properties
    
    private let viewModel: PairingViewModel
    private let deviceId: Device.Id
    
    // MARK: - Initialization
    
    private init(device: Device, state: PairingState) {
        self.deviceId = device.id
        self.viewModel = PairingViewModel(device: device, state: state)
        
        // Create the window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        
        window.title = "Pairing"
        window.isReleasedWhenClosed = false
        window.center()
        window.level = .floating // Always on top
        
        super.init(window: window)
        
        // Set up the SwiftUI view
        let hostingView = NSHostingView(rootView: PairingView(viewModel: viewModel))
        window.contentView = hostingView
        
        // Set up callbacks
        setupCallbacks(for: device)
        
        // Window delegate
        window.delegate = self
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Public Static Methods
    
    /// Show pairing window for outgoing request (we initiated pairing)
    static func showOutgoingRequest(for device: Device) {
        show(for: device, state: .outgoingRequest)
    }
    
    /// Show pairing window for incoming request (remote device initiated pairing)
    static func showIncomingRequest(for device: Device) {
        show(for: device, state: .incomingRequest)
    }
    
    /// Update the pairing window state for a device
    static func updateState(for deviceId: Device.Id, state: PairingState) {
        guard let controller = activeWindows[deviceId] else { return }
        controller.viewModel.state = state
    }
    
    /// Update the verification code for a device's pairing window
    static func updateVerificationCode(for deviceId: Device.Id, code: String?) {
        guard let controller = activeWindows[deviceId] else { return }
        controller.viewModel.verificationCode = code
    }
    
    /// Close the pairing window for a device
    static func close(for deviceId: Device.Id) {
        guard let controller = activeWindows[deviceId] else { return }
        controller.close()
    }
    
    /// Check if a pairing window is active for a device
    static func isActive(for deviceId: Device.Id) -> Bool {
        return activeWindows[deviceId] != nil
    }
    
    // MARK: - Private Methods
    
    private static func show(for device: Device, state: PairingState) {
        // Close existing window for this device if any
        activeWindows[device.id]?.close()
        
        // Create and show new window
        let controller = PairingWindowController(device: device, state: state)
        activeWindows[device.id] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    private func setupCallbacks(for device: Device) {
        viewModel.onAccept = { [weak self, weak device] in
            guard let device = device else { return }
            Logger.ui.debug("Pairing window: user accepted pairing for \(device.name, privacy: .public)")
            device.acceptPairing()
        }
        
        viewModel.onDecline = { [weak self, weak device] in
            guard let self = self, let device = device else { return }
            Logger.ui.debug("Pairing window: user declined pairing for \(device.name, privacy: .public)")
            device.declinePairing()
            self.close()
        }
        
        viewModel.onCancel = { [weak self, weak device] in
            guard let self = self, let device = device else { return }
            Logger.ui.debug("Pairing window: user cancelled pairing for \(device.name, privacy: .public)")
            device.declinePairing()
            self.close()
        }
        
        viewModel.onDismiss = { [weak self] in
            self?.close()
        }
    }
    
    // MARK: - NSWindowController Overrides
    
    override func close() {
        PairingWindowController.activeWindows.removeValue(forKey: deviceId)
        super.close()
    }
}

// MARK: - NSWindowDelegate

extension PairingWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // If pairing is still in progress when window closes, cancel it
        let state = viewModel.state
        if state == .outgoingRequest || state == .incomingRequest {
            Logger.ui.debug("Pairing window closed while pairing in progress - cancelling")
            viewModel.device?.declinePairing()
        }
        
        PairingWindowController.activeWindows.removeValue(forKey: deviceId)
    }
}
