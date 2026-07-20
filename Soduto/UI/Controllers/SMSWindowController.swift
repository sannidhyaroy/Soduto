//
//  SMSWindowController.swift
//  Soduto
//
//  Created by Sannidhya Roy on 17/05/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import Cocoa
import SwiftUI
import Combine

/// Per-device SMS window. One controller instance per `Device`; `SMSService` keeps a
/// `[Device.Id: SMSWindowController]` dict so reopening a device's Messages window shows
/// the existing instance rather than spawning a duplicate.
///
/// Bootstrap of the conversation list is **deferred** to the window's first appearance, so
/// it doesn't happen on app launch or device connect.
///
/// **Toolbar note:** an empty `NSToolbar` is attached purely so `NSWindow.subtitle`
/// (driven by SwiftUI's `.navigationSubtitle` modifier in `SMSView`) has somewhere to
/// render. The compose ("New Message") button lives in SwiftUI's `.toolbar` modifier on
/// `ConversationListView` instead, it lands in the sidebar's portion of the toolbar
/// area, matching Apple Messages' compose-icon placement.
final class SMSWindowController: NSWindowController, NSWindowDelegate {
    
    let device: Device
    private(set) var model: SMSDataModel
    private var localKeyMonitor: Any?
    private var hasAppearedOnce = false
    
    init(device: Device, smsService: SMSService, contactsService: ContactsService) {
        self.device = device
        let model = SMSDataModel(device: device, smsService: smsService, contactsService: contactsService)
        self.model = model
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Messages"  // overridden by SMSView's .navigationTitle once it mounts
        window.minSize = NSSize(width: 600, height: 400)
        
        // Empty `NSToolbar` attached purely so `NSWindow.subtitle` (written via SwiftUI's `.navigationSubtitle` on `SMSView`) has a slot to render
        // The compose button is injected from the SwiftUI side via `.toolbar` on `ConversationListView` so it sits in the sidebar's portion of the toolbar (Apple Messages style).
        let toolbar = NSToolbar(identifier: NSToolbar.Identifier("SMSWindowToolbar"))
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        // Per-device autosave name so each phone's window remembers its own frame
        window.setFrameAutosaveName("SMSWindow-\(device.id)")
        // Soduto is `LSUIElement` so AppKit doesn't auto-enable fullscreen on our windows
        // Insert `.fullScreenPrimary` to make the green traffic light show the fullscreen arrows and route the system Ctrl+Cmd+F shortcut
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.center()
        
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: SMSView(model: model))
        
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let chars = event.charactersIgnoringModifiers
            if event.modifierFlags.contains([.control, .command]), chars == "f" {
                self.window?.toggleFullScreen(nil)
                return nil
            }
            if event.modifierFlags.contains(.command), chars == "w" {
                self.window?.performClose(nil)
                return nil
            }
            return event
        }
        
        // No manual title binding
        // SMSView's `.navigationTitle` / `.navigationSubtitle` modifiers own the window's title and subtitle, driven by the model
        // Setting `window.title` here fights SwiftUI and loses (subtitle disappears, Dock tooltip shows the wrong text)
    }
    
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    
    deinit {
        if let monitor = localKeyMonitor { NSEvent.removeMonitor(monitor) }
    }
    
    // MARK: NSWindowDelegate
    
    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
    
    // MARK: Public
    
    /// Called when the window closes.
    /// `SMSService` sets this to drop its entry from the per-device controller dict, releasing the model and subscriptions.
    var onClose: (() -> Void)?
    
    func show() {
        if window?.isVisible == false {
            if window?.setFrameUsingName("SMSWindow-\(device.id)") == false {
                window?.center()
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        
        // Lazy bootstrap on first appearance only
        if !hasAppearedOnce {
            hasAppearedOnce = true
            model.windowDidAppear()
        }
    }
}
