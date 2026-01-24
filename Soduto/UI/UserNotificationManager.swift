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
    
    /// Cache for dynamically created categories, keyed by shape + action titles
    /// This allows reuse of categories when the same action pattern appears again
    /// Cache is empty on fresh app start (categories only persist for app lifetime)
    private var categoryCache: [String: String] = [:]  // cacheKey -> categoryIdentifier
    
    /// Set of all registered category identifiers (base + dynamic)
    private var registeredCategories = Set<UNNotificationCategory>()
    
    
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
    
    /// Registers base notification categories. Called once at app startup.
    /// Dynamic categories for incoming notifications are created on-demand and cached.
    private func registerNotificationCategories() {
        // Add pairing category
        let pairAction = UNNotificationAction(identifier: "pair", title: "Pair")
        let declineAction = UNNotificationAction(identifier: "decline", title: "Decline")
        let pairingCategory = UNNotificationCategory(
            identifier: "PairDevice",
            actions: [pairAction, declineAction],
            intentIdentifiers: [],
            options: []
        )
        registeredCategories.insert(pairingCategory)
        
        // Add telephony categories
        let muteAction = UNNotificationAction(identifier: "mutecall", title: "Mute")
        let ringingCategory = UNNotificationCategory(
            identifier: "IncomingCall",
            actions: [muteAction],
            intentIdentifiers: [],
            options: []
        )
        registeredCategories.insert(ringingCategory)
        
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
        registeredCategories.insert(smsCategory)
        
        // Add share download category
        let openFileAction = UNNotificationAction(identifier: "openfile", title: "Open")
        let shareCategory = UNNotificationCategory(
            identifier: "DownloadFinished",
            actions: [openFileAction],
            intentIdentifiers: [],
            options: []
        )
        registeredCategories.insert(shareCategory)
        
        UNUserNotificationCenter.current().setNotificationCategories(registeredCategories)
    }
    
    // MARK: Dynamic Category Management
    
    /// Gets or creates a notification category for the given shape and action titles.
    /// Categories are cached by their full signature (shape + titles) for reuse.
    /// - Parameters:
    ///   - hasReply: Whether the notification should have a reply action
    ///   - actionTitles: The titles of the custom action buttons (max 3)
    /// - Returns: The category identifier to use for the notification
    public func getOrCreateCategory(hasReply: Bool, actionTitles: [String]) -> String {
        let clampedActions = Array(actionTitles.prefix(3))
        
        // Build cache key from shape + titles
        let shape = CategoryIdentifier.category(hasReply: hasReply, actionCount: clampedActions.count).rawValue
        let titlesKey = clampedActions.joined(separator: "|")
        let cacheKey = "\(shape):\(titlesKey)"
        
        // Return cached category identifier if exists
        if let cachedCategoryId = categoryCache[cacheKey] {
            return cachedCategoryId
        }
        
        // Create a unique category identifier using hash for shorter ID
        let categoryId = "Dynamic.\(cacheKey.hashValue)"
        
        // Build actions array
        var actions: [UNNotificationAction] = []
        
        // Add reply action if needed
        if hasReply {
            let replyAction = UNTextInputNotificationAction(
                identifier: ActionIdentifier.reply.rawValue,
                title: "Reply",
                textInputButtonTitle: "Send",
                textInputPlaceholder: "Your message here..."
            )
            actions.append(replyAction)
        }
        
        // Add custom actions with actual titles from Android
        if clampedActions.count >= 1 {
            actions.append(UNNotificationAction(
                identifier: ActionIdentifier.action1.rawValue,
                title: clampedActions[0]
            ))
        }
        if clampedActions.count >= 2 {
            actions.append(UNNotificationAction(
                identifier: ActionIdentifier.action2.rawValue,
                title: clampedActions[1]
            ))
        }
        if clampedActions.count >= 3 {
            actions.append(UNNotificationAction(
                identifier: ActionIdentifier.action3.rawValue,
                title: clampedActions[2]
            ))
        }
        
        // Always add dismiss action
        actions.append(UNNotificationAction(
            identifier: ActionIdentifier.dismiss.rawValue,
            title: "Dismiss"
        ))
        
        // Create the category
        let category = UNNotificationCategory(
            identifier: categoryId,
            actions: actions,
            intentIdentifiers: [],
            options: []
        )
        
        // Cache the category identifier
        categoryCache[cacheKey] = categoryId
        
        // Add to registered categories and update the notification center
        registeredCategories.insert(category)
        UNUserNotificationCenter.current().setNotificationCategories(registeredCategories)
        
        return categoryId
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
