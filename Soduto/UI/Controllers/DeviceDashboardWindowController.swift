//
//  DeviceDashboardWindowController.swift
//  Soduto
//
//  Created by Sannidhya Roy on 20/03/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import Cocoa
import SwiftUI
import Combine

final class DeviceDashboardWindowController: NSWindowController, NSWindowDelegate {
    
    private(set) var model: DeviceDashboardModel
    private var titleCancellable: AnyCancellable?
    private var localKeyMonitor: Any?
    
    init(deviceDataSource: DeviceDataSource,
         mediaPlayerService: MediaPlayerService?,
         systemVolumeService: SystemVolumeService?,
         batteryService: BatteryService?,
         connectivityReportService: ConnectivityReportService?) {
        let model = DeviceDashboardModel(
            deviceDataSource: deviceDataSource,
            mediaPlayerService: mediaPlayerService,
            systemVolumeService: systemVolumeService,
            batteryService: batteryService,
            connectivityReportService: connectivityReportService
        )
        self.model = model
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "No Devices"
        window.minSize = NSSize(width: 560, height: 360)
        window.setFrameAutosaveName("DeviceDashboard")
        window.center()
        
        super.init(window: window)
        window.delegate = self
        
        let rootView = DeviceDashboardView(model: model)
        window.contentViewController = NSHostingController(rootView: rootView)
        
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window,
                  event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers == "w" else { return event }
            self.window?.performClose(nil)
            return nil
        }
        
        titleCancellable = model.$selectedDeviceId
            .combineLatest(model.$devices)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (selectedId, devices) in
                if let id = selectedId, let device = devices.first(where: { $0.id == id }) {
                    self?.window?.title = device.device.name
                } else {
                    self?.window?.title = "No Devices"
                }
            }
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

    /// Called when the window closes. StatusBarMenuController sets this to nil out
    /// its strong reference, fully releasing the model and all Combine subscriptions.
    var onClose: (() -> Void)?

    func show() {
        if window?.isVisible == false {
            // Restore saved frame or fall back to center
            if window?.setFrameUsingName("DeviceDashboard") == false {
                window?.center()
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
    
    func refreshDeviceList() {
        model.refreshDeviceList()
    }
}
