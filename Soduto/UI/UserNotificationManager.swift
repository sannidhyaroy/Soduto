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
        // Positional action mappings - store the semantic action string from the remote device
        case action1 = "com.soduto.usernotificationmanager.action1"
        case action2 = "com.soduto.usernotificationmanager.action2"
        case action3 = "com.soduto.usernotificationmanager.action3"
    }
    
    /// Fixed positional action identifiers used across all notification categories
    public enum ActionIdentifier: String {
        case reply = "Reply"
        case action1 = "action_1"
        case action2 = "action_2"
        case action3 = "action_3"
        case dismiss = "Dismiss"
    }
    
    /// Shape-based category identifiers - finite and reusable
    /// Format: [Reply/NoReply]_[N]Actions where N is the number of custom actions (0-3)
    public enum CategoryIdentifier: String, CaseIterable {
        case noReply_0Actions = "NoReply_0Actions"
        case noReply_1Action = "NoReply_1Action"
        case noReply_2Actions = "NoReply_2Actions"
        case noReply_3Actions = "NoReply_3Actions"
        case reply_0Actions = "Reply_0Actions"
        case reply_1Action = "Reply_1Action"
        case reply_2Actions = "Reply_2Actions"
        case reply_3Actions = "Reply_3Actions"
        
        /// Get the appropriate category identifier based on notification shape
        public static func category(hasReply: Bool, actionCount: Int) -> CategoryIdentifier {
            let clampedCount = min(max(actionCount, 0), 3)
            switch (hasReply, clampedCount) {
            case (false, 0): return .noReply_0Actions
            case (false, 1): return .noReply_1Action
            case (false, 2): return .noReply_2Actions
            case (false, 3): return .noReply_3Actions
            case (true, 0): return .reply_0Actions
            case (true, 1): return .reply_1Action
            case (true, 2): return .reply_2Actions
            case (true, 3): return .reply_3Actions
            default: return hasReply ? .reply_0Actions : .noReply_0Actions
            }
        }
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
        
        // Register all shape-based notification categories once at startup
        registerNotificationCategories()
    }
    
    // MARK: Category Registration
    
    /// Registers all shape-based notification categories. Called once at app startup.
    /// Categories are based on "shape" (hasReply + actionCount), not semantic meaning.
    private func registerNotificationCategories() {
        var categories = Set<UNNotificationCategory>()
        
        // Add pairing category
        let pairAction = UNNotificationAction(identifier: "pair", title: "Pair")
        let declineAction = UNNotificationAction(identifier: "decline", title: "Decline")
        let pairingCategory = UNNotificationCategory(
            identifier: "PairDevice",
            actions: [pairAction, declineAction],
            intentIdentifiers: [],
            options: []
        )
        categories.insert(pairingCategory)
        
        // Add telephony categories
        let muteAction = UNNotificationAction(identifier: "mutecall", title: "Mute")
        let ringingCategory = UNNotificationCategory(
            identifier: "IncomingCall",
            actions: [muteAction],
            intentIdentifiers: [],
            options: []
        )
        categories.insert(ringingCategory)
        
        let smsReplyAction = UNTextInputNotificationAction(
            identifier: "reply",
            title: "Reply",
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Your message here..."
        )
        let smsCategory = UNNotificationCategory(
            identifier: "SMSReceived",
            actions: [smsReplyAction],
            intentIdentifiers: [],
            options: []
        )
        categories.insert(smsCategory)
        
        // Add share download category
        let openFileAction = UNNotificationAction(identifier: "openfile", title: "Open")
        let shareCategory = UNNotificationCategory(
            identifier: "DownloadFinished",
            actions: [openFileAction],
            intentIdentifiers: [],
            options: []
        )
        categories.insert(shareCategory)
        
        // Generate all shape-based categories for incoming notifications
        // These use positional action identifiers with generic titles
        // (titles don't matter for categories - they're overridden per notification isn't possible,
        // but the user sees them - so we use generic labels)
        
        let replyAction = UNTextInputNotificationAction(
            identifier: ActionIdentifier.reply.rawValue,
            title: "Reply",
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Your message here..."
        )
        let action1 = UNNotificationAction(identifier: ActionIdentifier.action1.rawValue, title: "Action 1")
        let action2 = UNNotificationAction(identifier: ActionIdentifier.action2.rawValue, title: "Action 2")
        let action3 = UNNotificationAction(identifier: ActionIdentifier.action3.rawValue, title: "Action 3")
        let dismissAction = UNNotificationAction(identifier: ActionIdentifier.dismiss.rawValue, title: "Dismiss")
        
        // NoReply categories
        categories.insert(UNNotificationCategory(
            identifier: CategoryIdentifier.noReply_0Actions.rawValue,
            actions: [dismissAction],
            intentIdentifiers: [],
            options: []
        ))
        categories.insert(UNNotificationCategory(
            identifier: CategoryIdentifier.noReply_1Action.rawValue,
            actions: [action1, dismissAction],
            intentIdentifiers: [],
            options: []
        ))
        categories.insert(UNNotificationCategory(
            identifier: CategoryIdentifier.noReply_2Actions.rawValue,
            actions: [action1, action2, dismissAction],
            intentIdentifiers: [],
            options: []
        ))
        categories.insert(UNNotificationCategory(
            identifier: CategoryIdentifier.noReply_3Actions.rawValue,
            actions: [action1, action2, action3, dismissAction],
            intentIdentifiers: [],
            options: []
        ))
        
        // Reply categories
        categories.insert(UNNotificationCategory(
            identifier: CategoryIdentifier.reply_0Actions.rawValue,
            actions: [replyAction, dismissAction],
            intentIdentifiers: [],
            options: []
        ))
        categories.insert(UNNotificationCategory(
            identifier: CategoryIdentifier.reply_1Action.rawValue,
            actions: [replyAction, action1, dismissAction],
            intentIdentifiers: [],
            options: []
        ))
        categories.insert(UNNotificationCategory(
            identifier: CategoryIdentifier.reply_2Actions.rawValue,
            actions: [replyAction, action1, action2, dismissAction],
            intentIdentifiers: [],
            options: []
        ))
        categories.insert(UNNotificationCategory(
            identifier: CategoryIdentifier.reply_3Actions.rawValue,
            actions: [replyAction, action1, action2, action3, dismissAction],
            intentIdentifiers: [],
            options: []
        ))
        
        UNUserNotificationCenter.current().setNotificationCategories(categories)
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
