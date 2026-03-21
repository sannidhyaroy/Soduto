//
//  StatusBarMenuController.swift
//  Soduto
//
//  Created by Giedrius Stanevicius on 2016-07-26.
//  Copyright © 2016 Soduto. All rights reserved.
//

import Foundation
import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import Combine

public class StatusBarMenuController: NSObject, NSWindowDelegate, NSMenuDelegate, NSDraggingDestination {
    
    @IBOutlet weak var statusBarMenu: NSMenu!
    @IBOutlet weak var availableDevicesItem: NSMenuItem!
    @IBOutlet weak var launchOnLoginItem: NSMenuItem!
    @IBOutlet weak var dashboardMenuItem: NSMenuItem!
    
    public var deviceDataSource: DeviceDataSource?
    public var serviceManager: ServiceManager?
    public var config: Configuration?
    
    let statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var cancellables: Set<AnyCancellable> = []
    /// Persistent references to device menu items keyed by device ID, for in-place image updates
    private var deviceMenuItems: [String: NSMenuItem] = [:]
    
    lazy var preferencesWindowController: PreferencesWindowController? = {
        let controller = PreferencesWindowController.loadController()
        controller.deviceDataSource = self.deviceDataSource
        controller.config = self.config
        return controller
    }()
    
    private var dashboardWindowController: DeviceDashboardWindowController?
    
    private var dragOperationPerformed: Bool = false
    
    override public func awakeFromNib() {
        let statusBarIcon = #imageLiteral(resourceName: "statusBarIcon")
        statusBarIcon.isTemplate = true
        
        if #available(macOS 10.14, *) {
            self.statusBarItem.button?.image = statusBarIcon
        } else {
            self.statusBarItem.image = statusBarIcon
        }
        self.statusBarItem.menu = self.statusBarMenu
        
        let dragTypes: [NSPasteboard.PasteboardType] = [
            NSPasteboard.PasteboardType(UTType.url.identifier),
            NSPasteboard.PasteboardType(UTType.text.identifier) ]
        self.statusBarItem.button?.window?.registerForDraggedTypes(dragTypes)
        self.statusBarItem.button?.window?.delegate = self
    }
    
    private func setupServiceObservers() {
        cancellables.removeAll()
        guard let serviceManager = self.serviceManager else { return }
        
        if let batteryService = serviceManager.service(ofType: BatteryService.self) {
            batteryService.$statuses
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in Task { @MainActor [weak self] in self?.updateDeviceImages() } }
                .store(in: &cancellables)
        }
        
        if let connectivityService = serviceManager.service(ofType: ConnectivityReportService.self) {
            connectivityService.$statuses
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in Task { @MainActor [weak self] in self?.updateDeviceImages() } }
                .store(in: &cancellables)
        }
    }
    
    
    // MARK: Actions
    
    @IBAction func quit(_ sender: Any?) {
        NSApp.terminate(sender)
    }
    
    @IBAction func toggleLaunchOnLogin(_ sender: Any?) {
        self.config?.launchOnLogin = !(self.config?.launchOnLogin ?? false)
    }
    
    @IBAction func refreshNotifications(_ sender: Any?) {
        AppDelegate.shared().serviceManager.service(ofType: NotificationsService.self)?.refreshNotifications()
        
    }
    
    @IBAction func openPreferences(_ sender: Any?) {
        self.preferencesWindowController?.showWindow(nil)
    }
    
    @IBAction func openDashboard(_ sender: Any?) {
        if dashboardWindowController == nil {
            guard let deviceDataSource = deviceDataSource,
                  let serviceManager = serviceManager else { return }
            let controller = DeviceDashboardWindowController(
                deviceDataSource: deviceDataSource,
                mediaPlayerService: serviceManager.service(ofType: MediaPlayerService.self),
                systemVolumeService: serviceManager.service(ofType: SystemVolumeService.self),
                batteryService: serviceManager.service(ofType: BatteryService.self),
                connectivityReportService: serviceManager.service(ofType: ConnectivityReportService.self)
            )
            controller.onClose = { [weak self] in self?.dashboardWindowController = nil }
            dashboardWindowController = controller
        }
        dashboardWindowController?.show()
    }
    
    @IBAction func showAboutWindow(_ sender: Any?) {
        AboutWindowController.showAboutWindow()
    }
    
    
    // MARK: Drag'n'Drop
    
    public dynamic func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragOperationPerformed = false
        for service in self.serviceManager?.services ?? [] {
            guard let destination = service as? NSDraggingDestination else { continue }
            guard let operation = destination.draggingEntered?(sender) else { continue }
            guard !operation.isEmpty else { continue }
            return operation
        }
        return []
    }
    
    public dynamic func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragOperationPerformed = false
        for service in self.serviceManager?.services ?? [] {
            guard let destination = service as? NSDraggingDestination else { continue }
            guard let operation = destination.draggingUpdated?(sender) else { continue }
            guard !operation.isEmpty else { continue }
            return operation
        }
        return []
    }
    
    public dynamic func draggingEnded(_ sender: NSDraggingInfo) {
        for service in self.serviceManager?.services ?? [] {
            guard let destination = service as? NSDraggingDestination else { continue }
            destination.draggingEnded?(sender)
        }
        
        // A workaround for items dragged from dock stack - in such case performDragOperation is not called
        if !dragOperationPerformed && self.statusBarItem.button?.frame.contains(sender.draggingLocation) == true {
            _ = performDragOperation(sender)
        }
    }
    
    public dynamic func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dragOperationPerformed = true
        for service in self.serviceManager?.services ?? [] {
            guard let destination = service as? NSDraggingDestination else { continue }
            guard destination.performDragOperation?(sender) == true else { continue }
            return true
        }
        return false
    }
    
    
    // MARK: NSMenuDelegate
    
    public func menuNeedsUpdate(_ menu: NSMenu) {
        // Removed automatic broadcast - not part of official KDE Connect protocol
        // Only broadcast on: app start, network change, manual Cmd+R
        
        if menu == self.statusBarMenu {
            self.dashboardMenuItem?.isEnabled = !(deviceDataSource?.pairedDevices.isEmpty ?? true) || !(deviceDataSource?.unavailableDevices.isEmpty ?? true)
            self.refreshMenuDeviceList()
            if #available(macOS 13.0, *) {
                let loginItem = SMAppService.mainApp
                switch (loginItem.status.rawValue) {
                case 0:
                    self.launchOnLoginItem.state = NSControl.StateValue.off
                    break
                case 1:
                    self.launchOnLoginItem.state = NSControl.StateValue.on
                    break
                default:
                    self.launchOnLoginItem.state = NSControl.StateValue.mixed
                    break
                }
            } else {
                self.launchOnLoginItem.state = (self.config?.launchOnLogin ?? false) ? NSControl.StateValue.on : NSControl.StateValue.off
            }
        }
    }
    
    
    // MARK: Public methods
    
    func refreshDeviceLists() {
        self.preferencesWindowController?.refreshDeviceLists()
        self.dashboardWindowController?.refreshDeviceList()
        self.dashboardMenuItem?.isEnabled = !(deviceDataSource?.pairedDevices.isEmpty ?? true) || !(deviceDataSource?.unavailableDevices.isEmpty ?? true)
    }
    
    /// Call this once from AppDelegate after all services have been registered.
    func startServiceObservers() {
        setupServiceObservers()
    }
    
    
    // MARK: Private methods
    
    @MainActor
    private func refreshMenuDeviceList() {
        // Remove all existing device items and clear stored references
        deviceMenuItems.removeAll()
        var item = self.statusBarMenu.item(withTag: InterfaceElementTags.availableDeviceMenuItem.rawValue)
        while item != nil {
            self.statusBarMenu.removeItem(item!)
            item = self.statusBarMenu.item(withTag: InterfaceElementTags.availableDeviceMenuItem.rawValue)
        }
        
        // Re-add device items, storing references for live image updates
        let devices = self.deviceDataSource?.pairedDevices ?? []
        guard devices.count > 0 else { return }
        
        var index = self.statusBarMenu.index(of: self.availableDevicesItem)
        assert(index != -1, "availableDevicesItem expected to be item of statusBarMenu")
        for device in devices {
            let item = NSMenuItem(title: device.name, action: nil, keyEquivalent: "")
            item.tag = InterfaceElementTags.availableDeviceMenuItem.rawValue
            item.submenu = DeviceMenu(device: device)
            item.image = statusImage(for: device)
            index += 1
            self.statusBarMenu.insertItem(item, at: index)
            deviceMenuItems[device.id] = item
        }
    }
    
    /// Updates only the status images on existing device menu items without rebuilding the menu.
    /// Called by service observers for real-time battery/connectivity changes.
    /// Also restores the title defensively as AppKit can drop the title text when the image
    /// is updated while the menu is mid-render (transient layout glitch).
    @MainActor
    private func updateDeviceImages() {
        guard let devices = self.deviceDataSource?.pairedDevices else { return }
        for device in devices {
            guard let item = deviceMenuItems[device.id] else { continue }
            if item.title != device.name { item.title = device.name }
            item.image = statusImage(for: device)
        }
    }
    
    @MainActor
    private func statusImage(for device: Device) -> NSImage? {
        guard let serviceManager = self.serviceManager else { return nil }
        
        // Collect image fragments from all services that provide status bar images
        let fragments: [(order: Int, image: NSImage)] = serviceManager.services
            .compactMap { $0 as? StatusBarImageProvider }
            .compactMap { provider in
                guard let image = provider.statusBarImage(for: device) else { return nil }
                return (provider.statusBarImageSortOrder, image)
            }
            .sorted { $0.order < $1.order }
        
        guard !fragments.isEmpty else { return nil }
        
        // Composite all fragments horizontally with spacing between them
        let interSpacing: CGFloat = 2
        let imageHeight: CGFloat = 13
        let totalWidth = fragments.map(\.image.size.width).reduce(0, +) + interSpacing * CGFloat(max(fragments.count - 1, 0))
        
        let image = NSImage(size: CGSize(width: totalWidth, height: imageHeight), flipped: false) { _ in
            var x: CGFloat = 0
            for (index, fragment) in fragments.enumerated() {
                fragment.image.draw(in: NSRect(
                    x: x,
                    y: (imageHeight - fragment.image.size.height) / 2,
                    width: fragment.image.size.width,
                    height: fragment.image.size.height
                ))
                x += fragment.image.size.width + (index < fragments.count - 1 ? interSpacing : 0)
            }
            return true
        }
        
        return image
    }
}
