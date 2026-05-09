//
//  ServiceAction.swift
//  Soduto
//
//  Created by Giedrius Stanevičius on 2016-11-19.
//  Copyright © 2016 Soduto. All rights reserved.
//

import Foundation

/// `ServiceAction` abstracts server supported actions in a manner suitable for different uses,
/// be it a GUI, command line or some other use. For example GUI does not need to know
/// particular methods supported by various servers - it can ask the Core to provide actions
/// for particular device and create a menu item for each of the actions returned.
/// `ServiceAction` encapsulates all the information needed to perform an action, so no
/// additional parameters needed to be supplied
public struct ServiceAction {
    
    // MARK: Types
    
    public typealias Id = Int
    public typealias Group = String
    
    
    // MARK: Public properties
    
    public static let defaultGroup: Group = "default"
    
    /// Action id uniquely defining concrete action to be performed on particular service.
    /// Same ids on different services may mean different actions, so only a pair of
    /// id and service uniquely define an action
    public let id: Id
    
    /// Action group identifier. It may be used to group or sort actions.
    public let group: Group
    
    /// Short action title suitable to display in UI
    public let title: String
    
    /// Possibly slightly longer than title action description suitable to display in UI
    public let decription: String
    
    public let service: Service
    public let device: Device
    
    /// Child actions for submenu support. When non-nil, this action renders as a
    /// submenu folder instead of a clickable item
    public let children: [ServiceAction]?
    
    /// Keyboard equivalent (e.g. "r", "n", space)
    public let keyEquivalent: String
    
    /// Opaque payload carried with the action. Passed back to the service via
    /// `performAction(_:forDevice:userInfo:)` so the action is self-contained
    public let userInfo: [String: Any]?
    
    
    // MARK: Init / Deinit
    
    init(id: Id, group: Group = defaultGroup, title: String, description: String, service: Service, device: Device, children: [ServiceAction]? = nil, keyEquivalent: String = "", userInfo: [String: Any]? = nil) {
        self.id = id
        self.group = group
        self.title = title
        self.decription = description
        self.service = service
        self.device = device
        self.children = children
        self.keyEquivalent = keyEquivalent
        self.userInfo = userInfo
    }
    
    
    // MARK: Public methods
    
    public func perform() {
        guard self.device.pairingStatus == .Paired else { return }
        service.performAction(self.id, forDevice: self.device, userInfo: self.userInfo)
    }
}
