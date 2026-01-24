//
//  UserNotificationManager.swift
//  Soduto
//
//  Created by Giedrius Stanevičius on 2016-11-22.
//  Copyright © 2016 Soduto. All rights reserved.
//

import Foundation
import UserNotifications

public struct UserNotificationContext {
    
    public let config: Configuration
    public let serviceManager: ServiceManager
    public let deviceManager: DeviceManager
    
    public init(config: Configuration, serviceManager: ServiceManager, deviceManager: DeviceManager) {
        self.config = config
        self.serviceManager = serviceManager
        self.deviceManager = deviceManager
    }
}

public protocol UserNotificationActionHandler: AnyObject {
    
    static func handleAction(for notification: UNNotificationResponse, context: UserNotificationContext)
    
}

public class UserNotificationManager: NSObject {
    
    // MARK: Types
    
    public enum Property: String {
        case actionHandlerClass = "com.soduto.usernotificationmanager.actionhandlerclass"
        case dontPresent = "com.soduto.usernotificationmanager.dontPresent"
    }
    
    
    // MARK: Private properties
    
    private let context: UserNotificationContext
    
    
    // MARK: Init / Deinit
    
    public init(config: Configuration, serviceManager: ServiceManager, deviceManager: DeviceManager) {
        self.context = UserNotificationContext(config: config, serviceManager: serviceManager, deviceManager: deviceManager)
        
        super.init()
        
        // Request notification authorization
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { authorized, error in
            if authorized {
                print("Authorized to send notifications!")
            } else if !authorized {
                print("Not authorized to send notifications")
            } else if let error = error {
                print(error.localizedDescription)
            }
        }
    }
    
    // MARK: Action Handlers
    
    /// Dynamically dispatches the notification action to the appropriate handler class.
    /// The handler class name is stored in the notification's userInfo under the `actionHandlerClass` property.
    public func handleAction(for response: UNNotificationResponse) {
        let userInfo = response.notification.request.content.userInfo
        
        guard let handlerClassName = userInfo[Property.actionHandlerClass.rawValue] as? String else {
            print("No action handler class specified in notification userInfo")
            return
        }
        
        // Look up the handler class by name
        guard let handlerClass = NSClassFromString(handlerClassName) as? UserNotificationActionHandler.Type else {
            print("Could not find handler class: \(handlerClassName)")
            return
        }
        
        // Call the static handleAction method on the handler class
        handlerClass.handleAction(for: response, context: self.context)
        
        // Remove the notification after handling
        let id = response.notification.request.identifier
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
    }
}

// MARK: - UNUserNotificationCenter Utilities

extension UNUserNotificationCenter {
    
    typealias NotificationId = String
    
    func containsDeliveredNotification(withId id: NotificationId, completion: @escaping (Bool) -> Void) {
        getDeliveredNotifications { notifications in
            let exists = notifications.contains { $0.request.identifier == id }
            completion(exists)
        }
    }
    
    func removeNotification(withId id: NotificationId) {
        removePendingNotificationRequests(withIdentifiers: [id])
        removeDeliveredNotifications(withIdentifiers: [id])
    }
}
