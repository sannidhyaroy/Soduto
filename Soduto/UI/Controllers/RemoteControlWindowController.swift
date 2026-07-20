//
//  RemoteControlWindowController.swift
//  Soduto
//
//  Created by Sannidhya Roy on 07/05/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import Cocoa
import SwiftUI
import os

class RemoteControlWindowController: NSWindowController, NSWindowDelegate {
    
    private let service: RemoteControlService
    private var currentDevice: Device?
    private var hostingController: NSHostingController<RemoteControlView>?
    
    // NSEvent local monitor — handles window shortcuts (Cmd+W, Cmd+Ctrl+F, nav shortcuts)
    private var localMonitor: Any?
    // CGEvent tap — intercepts Option+Escape at kernel level for lock, same as the
    // service's own tap handles it for unlock. NSEvent monitors are too late for this combo.
    private var lockTap: CFMachPort?
    private var lockTapSource: CFRunLoopSource?
    
    
    init(service: RemoteControlService) {
        self.service = service
        
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 580),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.title = "Remote Control"
        panel.minSize = NSSize(width: 360, height: 440)
        panel.isMovableByWindowBackground = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenPrimary]
        panel.hidesOnDeactivate = false
        
        super.init(window: panel)
        panel.delegate = self
    }
    
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    
    
    // MARK: Public interface
    
    func show(for device: Device) {
        currentDevice = device
        
        let view = RemoteControlView(service: service, device: device)
        if let hc = hostingController {
            hc.rootView = view
        } else {
            let hc = NSHostingController(rootView: view)
            hostingController = hc
            window?.contentView = hc.view
        }
        
        if window?.isVisible == false {
            window?.center()
        }
        window?.makeKeyAndOrderFront(nil)
        setupMonitors()
    }
    
    
    // MARK: NSWindowDelegate
    
    func windowWillClose(_ notification: Notification) {
        if service.isCapturing { service.stopCapturing() }
        removeMonitors()
        NotificationCenter.default.removeObserver(self, name: NSApplication.didBecomeActiveNotification, object: nil)
    }
    
    func windowDidEnterFullScreen(_ notification: Notification) {
        hostingController?.view.needsLayout = true
    }
    
    
    // MARK: Monitor setup / teardown
    
    private func setupMonitors() {
        setupLockTap()
        setupLocalMonitor()
        // Retry CGEvent tap when app becomes active (in case permissions were granted in Settings).
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.setupLockTap()
            }
    }
    
    private func removeMonitors() {
        removeLockTap()
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
    }
    
    
    // MARK: CGEvent tap (Option+Escape lock)
    
    private func setupLockTap() {
        guard lockTap == nil else { return }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        lockTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, refcon in
                guard let refcon, type == .keyDown else { return Unmanaged.passUnretained(event) }
                let wc = Unmanaged<RemoteControlWindowController>.fromOpaque(refcon).takeUnretainedValue()
                guard wc.window?.isVisible == true, !wc.service.isCapturing else {
                    return Unmanaged.passUnretained(event)
                }
                let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
                let flags = event.flags
                // Only pure Option+Escape (no ⌘ or ⌃) to avoid false matches
                let isOptionOnly = flags.contains(.maskAlternate) && !flags.contains(.maskCommand) && !flags.contains(.maskControl)
                if keyCode == 53, isOptionOnly {
                    Logger.ui.debug("RemoteControlWindowController: CGEvent tap Option+Escape → lock")
                    DispatchQueue.main.async { wc.lock() }
                    return nil  // consume — prevents any app from seeing the event
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )
        if let tap = lockTap {
            lockTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            if let source = lockTapSource {
                CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
            CGEvent.tapEnable(tap: tap, enable: true)
        } else {
            Logger.ui.error("RemoteControlWindowController: failed to create lock CGEvent tap; check Accessibility permission")
        }
    }
    
    private func removeLockTap() {
        if let tap = lockTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = lockTapSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
                lockTapSource = nil
            }
            lockTap = nil
        }
    }
    
    
    // MARK: NSEvent local monitor (Cmd+W, fullscreen, nav shortcuts)
    
    private func setupLocalMonitor() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let flags = event.modifierFlags
            
            // Nav + media shortcuts for mobile (non-lock mode only)
            if !self.service.isCapturing, let device = self.currentDevice {
                let isMobile = device.type == .Phone || device.type == .Tablet
                if isMobile {
                    let cmd   = flags.contains(.command)
                    let shift = flags.contains(.shift)
                    switch (event.keyCode, cmd, shift) {
                    case (33, true, false): self.service.sendBack(to: device);        return nil  // Cmd+[
                    case ( 4, true,  true): self.service.sendHome(to: device);        return nil  // Cmd+Shift+H
                    case (15, true,  true): self.service.sendRecents(to: device);     return nil  // Cmd+Shift+R
                    case (126, true,  true): self.service.sendVolumeUp(to: device);   return nil  // Cmd+Shift+↑
                    case (125, true,  true): self.service.sendVolumeDown(to: device); return nil  // Cmd+Shift+↓
                    case (37,  true,  true): self.service.sendPower(to: device);      return nil  // Cmd+Shift+L
                    default: break
                    }
                }
            }
            
            // Cmd+W → close window
            if event.keyCode == 13, flags.contains(.command), !flags.contains(.control), !flags.contains(.option) {
                DispatchQueue.main.async { self.window?.performClose(nil) }
                return nil
            }
            
            // Cmd+Ctrl+F → toggle fullscreen
            if event.keyCode == 3, flags.contains(.command), flags.contains(.control) {
                DispatchQueue.main.async { self.window?.toggleFullScreen(nil) }
                return nil
            }
            
            return event
        }
    }
    
    
    // MARK: Lock / unlock
    
    private func lock() {
        guard let device = currentDevice else {
            Logger.ui.error("RemoteControlWindowController.lock; no currentDevice, ignoring")
            return
        }
        // Retry CGEvent tap in case permissions were granted after panel opened.
        setupLockTap()
        service.startCapturing(for: device)
    }
}
