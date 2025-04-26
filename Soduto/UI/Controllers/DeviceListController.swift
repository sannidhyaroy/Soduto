//
//  DeviceListController.swift
//  Soduto
//
//  Created by Giedrius on 2017-05-23.
//  Copyright © 2017 Soduto. All rights reserved.
//

import Foundation
import Cocoa

class DeviceListController: NSViewController {
 
    var deviceDataSource: DeviceDataSource?
    @IBOutlet weak var deviceList: NSTableView!
    
    
    func refreshDeviceList() {
        self.deviceList.reloadData()
    }
    
    override func viewDidLoad() {
        refreshDeviceList()
        ModernUIStyleKit.applyModernStyleToTableView(to: deviceList)
    }
    
    override func viewWillAppear() {
        // Resize first column to full table width
        self.deviceList.tableColumns.first?.width = self.deviceList.frame.width - self.deviceList.intercellSpacing.width - 8
        
        NotificationCenter.default.post(name: ConnectionProvider.broadcastAnnouncementNotification, object: nil)
    }
    
    override public func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers?.lowercased() == "r" && event.modifierFlags.contains(.command) {
            NotificationCenter.default.post(name: ConnectionProvider.broadcastAnnouncementNotification, object: nil)
        }
    }
    
    @IBAction func showDeviceInfo(_ sender: Any?) {
        guard self.deviceList.clickedRow >= 0 else { return }
        guard let rowView = self.deviceList.rowView(atRow: self.deviceList.clickedRow, makeIfNecessary: false) else { return }
        guard let cellView = rowView.view(atColumn: 0) as? DeviceListItemView else { return }
        guard let device = cellView.device else { return }
        
        let controller = DeviceInfoWindowController.loadController()
        controller.device = device
        
        guard let window = controller.window else { return }
        self.view.window?.beginSheet(window) { _ in
            controller.window = nil // just to keep controller until sheet ends
        }
    }
    
}

// MARK: - DeviceListController DataSource

extension DeviceListController : NSTableViewDataSource {
    
    public func numberOfRows(in tableView: NSTableView) -> Int {
        guard let deviceDataSource = self.deviceDataSource else { return 0 }
        return deviceDataSource.pairedDevices.count + deviceDataSource.unpairedDevices.count + deviceDataSource.unavailableDevices.count
    }
    
}


// MARK: - DeviceListController Delegate

extension DeviceListController: NSTableViewDelegate {
    
    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        
        guard let deviceDataSource = self.deviceDataSource else { return nil }
        
        let device: Device
        var i = row
        if i < deviceDataSource.pairedDevices.count {
            device = deviceDataSource.pairedDevices[i]
        }
        else {
            i = i - deviceDataSource.pairedDevices.count
            if i < deviceDataSource.unpairedDevices.count {
                device = deviceDataSource.unpairedDevices[i]
            }
            else {
                i = i - deviceDataSource.unpairedDevices.count
                if i < deviceDataSource.unavailableDevices.count {
                    device = deviceDataSource.unavailableDevices[i]
                }
                else {
                    return nil
                }
            }
        }
        
        if let view = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier(rawValue: "DeviceItemID"), owner: nil) as? DeviceListItemView {
            view.device = device
            return view
        }
        
        return nil
    }
    
    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = ModernTableRowView()
        return rowView
    }
}
