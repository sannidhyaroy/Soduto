//
//  DeviceMenu.swift
//  Soduto
//
//  Created by Giedrius Stanevičius on 2016-11-20.
//  Copyright © 2016 Soduto. All rights reserved.
//

import Foundation
import Cocoa

public class DeviceMenu: NSMenu {
    
    // MARK: Public properties
    
    public let device: Device
    
    
    // MARK: Init / Deinit
    
    public init(device: Device) {
        self.device = device
        
        super.init(title: device.name)
        
        self.autoenablesItems = false
        
        let actions = device.serviceActions()
        
        var actionsByGroup: [ServiceAction.Group:[ServiceAction]] = [:]
        for action in actions {
            if actionsByGroup[action.group] != nil {
                actionsByGroup[action.group]?.append(action)
            }
            else {
                actionsByGroup[action.group] = [action]
            }
        }
        
        for groupActions in actionsByGroup {
            for action in groupActions.value {
                // Special handling for Run Command action - replace with submenu
                if let runCommandService = action.service as? RunCommandService,
                   runCommandService.actions(for: device).contains(where: { $0.id == RunCommandService.ActionId.runCommand.rawValue }) {
                    // Create menu item with submenu
                    let item = NSMenuItem(title: action.title, action: nil, keyEquivalent: "")
                    item.submenu = runCommandService.createRunCommandMenu(for: device)
                    self.addItem(item)
                } else {
                    // Normal handling for other actions
                    let item = ServiceActionMenuItem(serviceAction: action)
                    self.addItem(item)
                }
            }
            self.addItem(NSMenuItem.separator())
        }
    }
    
    required public init(coder decoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
