//
//  ServiceActionMenuItem.swift
//  Soduto
//
//  Created by Giedrius Stanevičius on 2016-11-20.
//  Copyright © 2016 Soduto. All rights reserved.
//

import Foundation
import Cocoa

public class ServiceActionMenuItem: NSMenuItem {
    
    // MARK: Public properties
    
    public let serviceAction: ServiceAction
    
    
    // MARK: Init / Deinit
    
    public init(serviceAction: ServiceAction) {
        self.serviceAction = serviceAction
        
        if let children = serviceAction.children {
            let submenu = NSMenu(title: serviceAction.title)
            for child in children { submenu.addItem(ServiceActionMenuItem(serviceAction: child)) }
            super.init(title: serviceAction.title, action: nil, keyEquivalent: serviceAction.keyEquivalent)
            self.submenu = submenu
        } else {
            super.init(title: serviceAction.title, action: #selector(performServiceAction), keyEquivalent: serviceAction.keyEquivalent)
            self.target = self
        }
    }
    
    required public init(coder decoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    
    // MARK: Public methods
    
    @objc public func performServiceAction() {
        serviceAction.perform()
    }
}
