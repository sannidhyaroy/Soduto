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

public class StatusBarMenuController: NSObject, NSWindowDelegate, NSMenuDelegate, NSDraggingDestination {
    
    @IBOutlet weak var statusBarMenu: NSMenu!
    @IBOutlet weak var availableDevicesItem: NSMenuItem!
    @IBOutlet weak var launchOnLoginItem: NSMenuItem!
    
    public var deviceDataSource: DeviceDataSource?
    public var serviceManager: ServiceManager?
    public var config: Configuration?
    
    let statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    
    lazy var preferencesWindowController: PreferencesWindowController? = {
        let controller = PreferencesWindowController.loadController()
        controller.deviceDataSource = self.deviceDataSource
        controller.config = self.config
        return controller
    }()
    
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
    }
    
    
    // MARK: Private methods
    
    private func refreshMenuDeviceList() {
        // remove old device items
        
        var item = self.statusBarMenu.item(withTag: InterfaceElementTags.availableDeviceMenuItem.rawValue)
        while item != nil {
            self.statusBarMenu.removeItem(item!)
            item = self.statusBarMenu.item(withTag: InterfaceElementTags.availableDeviceMenuItem.rawValue)
        }
        
        // add new device items
        
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
        }
    }
    
    private func statusImage(for device: Device) -> NSImage? {
        assert(self.serviceManager != nil, "serviceManager property is not setup correctly")
        guard let serviceManager = self.serviceManager else { return nil }
        
        var batteryStatus: BatteryService.BatteryStatus? = nil
        var connectivityStatus: ConnectivityReportService.ConnectivityStatus? = nil
        
        // Get battery status if available
        if let service = serviceManager.services.first(where: { $0 is BatteryService }) as? BatteryService {
            batteryStatus = service.statuses.first(where: { $0.key == device.id })?.value
        }
        
        // Get network status if available (uses first SIM until dual-SIM rendering is implemented)
        if let service = serviceManager.services.first(where: { $0 is ConnectivityReportService }) as? ConnectivityReportService {
            connectivityStatus = service.statuses.first(where: { $0.key == device.id })?.value.first
        }
        
        // If no status info available, return nil
        if batteryStatus == nil && connectivityStatus == nil {
            return nil
        }
        
        // Calculate image width based on what status info is available
        let batteryWidth: CGFloat = batteryStatus != nil ? 56 : 0
        let connectivityWidth: CGFloat = connectivityStatus != nil ? 30 : 0
        let totalWidth = batteryWidth + connectivityWidth
        
        // Create image with all status indicators
        let image = NSImage(size: CGSize(width: totalWidth, height: 13), flipped: false) { _ in
            var currentX: CGFloat = 0
            
            // Draw battery status if available
            if let batteryStatus = batteryStatus {
                // Map charge % to the nearest symbol tier (0, 10, 25, 50, 75, 100)
                // Breakpoints are at midpoints between adjacent tiers.
                let tier: Int
                switch batteryStatus.currentCharge {
                    case 0...5:   tier = 0
                    case 6...17:  tier = 10
                    case 18...37: tier = 25
                    case 38...62: tier = 50
                    case 63...87: tier = 75
                    default:      tier = 100
                }
                let config = NSImage.SymbolConfiguration.preferringMulticolor()
                let symbolName = batteryStatus.isCharging ? "battery.\(tier)percent.bolt" : "battery.\(tier)percent"
                if let symbol = NSImage(named: symbolName)?.withSymbolConfiguration(config) {
                    symbol.draw(in: NSRect(x: currentX, y: (13 - symbol.size.height) / 2, width: symbol.size.width, height: symbol.size.height))
                }
                
                let percentage = "\(batteryStatus.currentCharge)%" as NSString
                let attr: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 10),
                    .foregroundColor: NSColor.labelColor
                ]
                percentage.draw(in: NSRect(x: currentX + 26, y: 2, width: 28, height: 10), withAttributes: attr)
                
                currentX += batteryWidth
            }
            
            // Draw network status if available
            if let connectivityStatus = connectivityStatus {
                // Draw network type indicator
                let signalStrength = min(max(connectivityStatus.signalStrength, 0), 4)
                
                // Draw network type (3G/4G/5G)
                let networkType = connectivityStatus.networkType
                let networkLabel = (networkType == "LTE" ? "4G" :
                                        networkType == "5G" ? "5G" :
                                        (networkType == "UMTS" || networkType == "CDMA2000" || networkType == "HSPA") ? "3G" :
                                        (networkType == "GSM" || networkType == "CDMA" || networkType == "iDEN" || networkType == "EDGE") ? "2G" : "")
                
                if !networkLabel.isEmpty {
                    let netAttr = [NSAttributedString.Key.font: NSFont.systemFont(ofSize: 10),
                                   NSAttributedString.Key.foregroundColor: NSColor.labelColor,]
                    (networkLabel as NSString).draw(in: NSRect(x: currentX, y: 2, width: 15, height: 10), withAttributes: netAttr)
                }
                
                // Draw signal bars with larger size
                if signalStrength > 0 {
                    for i in 0..<signalStrength {
                        NSColor.labelColor.set()
                        let barHeight = CGFloat(i + 1) * 2.5 // Increased bar height
                        let barWidth: CGFloat = 2.0 // Increased bar width
                        NSRect(x: currentX + 16 + (CGFloat(i) * 3), y: 2, width: barWidth, height: barHeight).fill()
                    }
                } else {
                    // Draw X for no signal
                    let noSignalAttr = [NSAttributedString.Key.font: NSFont.systemFont(ofSize: 10),
                                        NSAttributedString.Key.foregroundColor: NSColor.labelColor,]
                    ("X" as NSString).draw(in: NSRect(x: currentX + 16, y: 2, width: 10, height: 10), withAttributes: noSignalAttr)
                }
            }
            
            return true
        }
        
        return image
    }
}
