//
//  PairingWindowController.swift
//  Soduto
//
//  Created by Sannidhya Roy on 22/02/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import Cocoa
import SwiftUI
import Combine
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
    private var stateCancellable: AnyCancellable?
    
    private static let touchBarCancelItemId = NSTouchBarItem.Identifier("com.soduto.soduto.pairing.touchbar.cancel")
    private static let touchBarAcceptItemId = NSTouchBarItem.Identifier("com.soduto.soduto.pairing.touchbar.accept")
    private static let touchBarDeclineItemId = NSTouchBarItem.Identifier("com.soduto.soduto.pairing.touchbar.decline")
    private static let touchBarDoneItemId = NSTouchBarItem.Identifier("com.soduto.soduto.pairing.touchbar.done")
    private static let touchBarCloseItemId = NSTouchBarItem.Identifier("com.soduto.soduto.pairing.touchbar.close")
    
    // MARK: - Initialization
    
    private init(device: Device, state: PairingState) {
        self.deviceId = device.id
        self.viewModel = PairingViewModel(device: device, state: state)
        let initialSize = Self.windowSize(for: state)

        // Create the window with alert-style appearance (no traffic buttons)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: initialSize.width, height: initialSize.height),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.title = ""
        window.isReleasedWhenClosed = false
        window.level = .floating // Always on top
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.collectionBehavior = [.moveToActiveSpace, .transient]
        window.isOpaque = false
        window.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92)

        // Prevent window from being resized
        window.minSize = initialSize
        window.maxSize = initialSize

        super.init(window: window)

        // Set up the SwiftUI view
        let hostingView = NSHostingView(rootView: PairingView(viewModel: viewModel))
        window.contentView = hostingView

        // Position window on screen before showing (avoids centering glitch)
        applyWindowSize(for: state)

        // Set up callbacks
        setupCallbacks(for: device)

        // Window delegate
        window.delegate = self
        
        // Bind Touch Bar to this controller and keep it in sync with state changes
        stateCancellable = viewModel.$state.removeDuplicates().sink { [weak self] newState in
            DispatchQueue.main.async {
                self?.applyWindowSize(for: newState)
                self?.refreshTouchBar()
            }
        }
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
    
    private static func windowSize(for state: PairingState) -> NSSize {
        switch state {
        case .outgoingRequest, .incomingRequest:
            // Wider for verification code display
            return NSSize(width: 340, height: 480)
        case .success, .failed, .timeout:
            // Smaller for result states
            return NSSize(width: 300, height: 380)
        }
    }

    private func applyWindowSize(for state: PairingState) {
        guard let window = window else { return }
        let targetSize = Self.windowSize(for: state)

        // Calculate new frame keeping window centered on screen
        if let screen = window.screen ?? NSScreen.main {
            let screenFrame = screen.visibleFrame
            let screenCenterX = screenFrame.midX
            let screenCenterY = screenFrame.midY

            let newFrame = NSRect(
                x: screenCenterX - (targetSize.width / 2),
                y: screenCenterY - (targetSize.height / 2),
                width: targetSize.width,
                height: targetSize.height
            )

            // Update min/max sizes
            window.minSize = targetSize
            window.maxSize = targetSize

            // Apply frame without animation
            window.setFrame(newFrame, display: true)
        }
    }
    
    private func setupCallbacks(for device: Device) {
        viewModel.onAccept = { [weak device] in
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
    
    private func refreshTouchBar() {
        guard window != nil else { return }
        // Force recreate touch bar by clearing it and triggering responder update
        if let currentTouchBar = touchBar {
            // Update the touch bar's identifiers for the new state
            currentTouchBar.defaultItemIdentifiers = touchBarItemIdentifiers
            currentTouchBar.principalItemIdentifier = touchBarPrincipalItemIdentifier
            // Force delegate to recreate items
            let delegate = currentTouchBar.delegate
            currentTouchBar.delegate = nil
            currentTouchBar.delegate = delegate
        }
        // If no touch bar exists, create one
        if touchBar == nil {
            touchBar = makeTouchBar()
        }
    }
    
    private var touchBarItemIdentifiers: [NSTouchBarItem.Identifier] {
        switch viewModel.state {
        case .outgoingRequest:
            return [.flexibleSpace, Self.touchBarCancelItemId, .flexibleSpace]
        case .incomingRequest:
            return [.flexibleSpace, Self.touchBarDeclineItemId, Self.touchBarAcceptItemId, .flexibleSpace]
        case .success:
            return [.flexibleSpace, Self.touchBarDoneItemId, .flexibleSpace]
        case .failed, .timeout:
            return [.flexibleSpace, Self.touchBarCloseItemId, .flexibleSpace]
        }
    }
    
    private var touchBarPrincipalItemIdentifier: NSTouchBarItem.Identifier? {
        switch viewModel.state {
        case .outgoingRequest:
            return Self.touchBarCancelItemId
        case .incomingRequest:
            return Self.touchBarAcceptItemId
        case .success:
            return Self.touchBarDoneItemId
        case .failed, .timeout:
            return Self.touchBarCloseItemId
        }
    }
    
    private enum TouchBarButtonStyle {
        case standard
        case primary
        case destructive
    }
    
    private func makeTouchBarButtonItem(
        identifier: NSTouchBarItem.Identifier,
        title: String,
        action: Selector,
        style: TouchBarButtonStyle = .standard,
        minWidth: CGFloat = 104
    ) -> NSCustomTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: identifier)
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: minWidth).isActive = true
        
        switch style {
        case .standard:
            break
        case .primary:
            button.bezelColor = .controlAccentColor
            button.contentTintColor = .white
        case .destructive:
            button.bezelColor = .systemRed
            button.contentTintColor = .white
        }
        
        item.view = button
        return item
    }
    
    // MARK: - NSWindowController Overrides
    
    override func close() {
        if let window = window {
            let touchBarBinding = NSBindingName(rawValue: #keyPath(touchBar))
            if window.infoForBinding(touchBarBinding) != nil {
                window.unbind(touchBarBinding)
            }
        }
        stateCancellable?.cancel()
        PairingWindowController.activeWindows.removeValue(forKey: deviceId)
        super.close()
    }
    
    override func makeTouchBar() -> NSTouchBar? {
        let touchBar = NSTouchBar()
        touchBar.delegate = self
        touchBar.defaultItemIdentifiers = touchBarItemIdentifiers
        touchBar.principalItemIdentifier = touchBarPrincipalItemIdentifier
        return touchBar
    }
    
    @objc private func touchBarCancelAction(_ sender: Any?) {
        viewModel.cancel()
    }
    
    @objc private func touchBarAcceptAction(_ sender: Any?) {
        viewModel.accept()
    }
    
    @objc private func touchBarDeclineAction(_ sender: Any?) {
        viewModel.decline()
    }
    
    @objc private func touchBarDoneAction(_ sender: Any?) {
        viewModel.dismiss()
    }
    
    @objc private func touchBarCloseAction(_ sender: Any?) {
        viewModel.dismiss()
    }
}

extension PairingWindowController: NSTouchBarDelegate {
    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        switch identifier {
        case Self.touchBarCancelItemId:
            return makeTouchBarButtonItem(
                identifier: identifier,
                title: "Cancel",
                action: #selector(touchBarCancelAction(_:)),
                style: .standard
            )
        case Self.touchBarAcceptItemId:
            return makeTouchBarButtonItem(
                identifier: identifier,
                title: "Accept",
                action: #selector(touchBarAcceptAction(_:)),
                style: .primary,
                minWidth: 112
            )
        case Self.touchBarDeclineItemId:
            return makeTouchBarButtonItem(
                identifier: identifier,
                title: "Decline",
                action: #selector(touchBarDeclineAction(_:)),
                style: .standard
            )
        case Self.touchBarDoneItemId:
            return makeTouchBarButtonItem(
                identifier: identifier,
                title: "Done",
                action: #selector(touchBarDoneAction(_:)),
                style: .primary,
                minWidth: 112
            )
        case Self.touchBarCloseItemId:
            return makeTouchBarButtonItem(
                identifier: identifier,
                title: "Close",
                action: #selector(touchBarCloseAction(_:)),
                style: .destructive,
                minWidth: 112
            )
        default:
            return nil
        }
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

    // Allow closing via keyboard shortcuts even without close button
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Always allow closing
        return true
    }
}
