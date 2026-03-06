//
//  UserNotificationManager.swift
//  Soduto
//
//  Created by Giedrius Stanevičius on 2016-11-22.
//  Copyright © 2016 Soduto. All rights reserved.
//

import Foundation
import UserNotifications

/// Context object passed to notification action handlers, providing access to app services.
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

/// Protocol for services that handle user notification actions.
/// Conforming types must implement a static method that handles the action response.
public protocol UserNotificationActionHandler: AnyObject {
    
    /// Handles the user's response to a notification action.
    /// - Parameters:
    ///   - notification: The notification response from the user.
    ///   - context: The notification context providing access to app services.
    static func handleAction(for notification: UNNotificationResponse, context: UserNotificationContext)
    
}

/// Manages user notifications for Soduto, including authorization, category registration, and action dispatch.
///
/// This class handles:
/// - Acting as the UNUserNotificationCenterDelegate for the app
/// - Requesting notification authorization at app startup
/// - Registering base notification categories (telephony, share)
/// - Creating and caching dynamic notification categories for Android notifications
/// - Dispatching notification actions to the appropriate handler classes
/// - Determining how notifications are presented in the foreground
@MainActor
public class UserNotificationManager: NSObject, UNUserNotificationCenterDelegate {
    
    // MARK: Types
    
    /// Keys for storing notification-related data in userInfo dictionaries.
    public enum Property: String {
        case actionHandlerClass = "com.soduto.usernotificationmanager.actionhandlerclass"
        case dontPresent = "com.soduto.usernotificationmanager.dontPresent"
        case shouldMute = "com.soduto.usernotificationmanager.shouldMute"
        // Positional action mappings - store the semantic action string from the remote device
        case action1 = "com.soduto.usernotificationmanager.action1"
        case action2 = "com.soduto.usernotificationmanager.action2"
        case action3 = "com.soduto.usernotificationmanager.action3"
        // OTP code to copy when the user taps the "Copy OTP" action button
        case otpCode = "com.soduto.usernotificationmanager.otpCode"
    }
    
    /// Fixed positional action identifiers used across all notification categories
    public enum ActionIdentifier: String {
        case reply = "Reply"
        case action1 = "action_1"
        case action2 = "action_2"
        case action3 = "action_3"
        case copyOtp = "copy_otp"
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
    
    private let un = UNUserNotificationCenter.current()
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
        
        // Set ourselves as the notification center delegate
        un.delegate = self
        
        Task {
            // Request notification authorization
            do {
                let authorized = try await un.requestAuthorization(options: [.alert, .sound, .badge])
                if authorized {
                    print("Authorized to send notifications!")
                } else {
                    print("Not authorized to send notifications")
                }
            } catch {
                print("Notification authorization error: \(error.localizedDescription)")
            }
            
            // Register all shape-based notification categories once at startup
            registerNotificationCategories()
        }
    }
    
    // MARK: UNUserNotificationCenterDelegate
    
    /// Handles user actions on notifications by dispatching to the appropriate handler class.
    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            handleAction(for: response)
        }
        completionHandler()
    }
    
    /// Determines how to present notifications when the app is in the foreground.
    /// - `dontPresent`: Notification not presented at all (e.g., answer packets)
    /// - `shouldMute`: Notification shows banner but without sound (silent notifications from Android)
    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let userInfo = notification.request.content.userInfo
        
        // Check if the notification should not be presented
        if let dontPresent = userInfo[Property.dontPresent.rawValue] as? NSNumber, dontPresent.boolValue {
            return completionHandler([])
        }
        
        // Check if the notification should be shown without sound (silent notifications from Android)
        if let shouldMute = userInfo[Property.shouldMute.rawValue] as? NSNumber, shouldMute.boolValue {
            return completionHandler([.list, .banner])
        }
        
        // Default: show notification as banner with sound
        return completionHandler([.list, .banner, .sound])
    }
    
    // MARK: Category Registration
    
    /// Registers base notification categories. Called once at app startup.
    /// Dynamic categories for incoming notifications are created on-demand and cached.
    private func registerNotificationCategories() {
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
        
        un.setNotificationCategories(registeredCategories)
    }
    
    // MARK: Dynamic Category Management
    
    /// Gets or creates a notification category for the given shape and action titles.
    /// Categories are cached by their full signature (shape + titles + OTP code) for reuse.
    /// - Parameters:
    ///   - hasReply: Whether the notification should have a reply action
    ///   - actionTitles: The titles of the custom action buttons (max 3)
    ///   - otpCode: The detected OTP code to show in the button title (e.g. `Copy "XYZABC"`), or nil for no OTP button
    /// - Returns: The category identifier to use for the notification
    public func getOrCreateCategory(hasReply: Bool, actionTitles: [String], otpCode: String? = nil) -> String {
        let clampedActions = Array(actionTitles.prefix(3))
        
        // Build cache key from shape + titles + OTP code (unique per code so each shows its own value)
        let shape = CategoryIdentifier.category(hasReply: hasReply, actionCount: clampedActions.count).rawValue
        let titlesKey = clampedActions.joined(separator: "|")
        let cacheKey = "\(shape):\(titlesKey):\(otpCode.map { "otp_\($0)" } ?? "")"
        
        // Return cached category identifier if exists
        if let cachedCategoryId = categoryCache[cacheKey] {
            return cachedCategoryId
        }
        
        // Create a unique category identifier using hash for shorter ID
        let categoryId = "Dynamic.\(StableHashing.shortSha256(cacheKey))"
        
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
        
        // Add "Copy <code>" action if an OTP was detected in the notification body
        if let otp = otpCode {
            actions.append(UNNotificationAction(
                identifier: ActionIdentifier.copyOtp.rawValue,
                title: "Copy \"\(otp)\""
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
        un.setNotificationCategories(registeredCategories)
        
        return categoryId
    }
    
    // MARK: Action Handlers
    
    /// Dynamically dispatches the notification action to the appropriate handler class.
    ///
    /// The handler class name is stored in the notification's userInfo under the `actionHandlerClass` property.
    ///
    /// ## Default Action Handling
    ///
    /// When the user clicks on the notification body (triggering `UNNotificationDefaultActionIdentifier`),
    /// we intentionally do **not** remove the notification from the Notification Center. This allows
    /// each handler to decide whether clicking the body should have any effect.
    ///
    /// For `NotificationsService`, clicking the body does nothing - the notification stays visible.
    /// For `ShareService`, clicking the body opens the downloaded file.
    ///
    /// This design gives users explicit control: they must use action buttons to interact with
    /// notifications, rather than accidentally dismissing them by clicking.
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
        
        // Don't remove the notification if the user just clicked the body.
        // Each handler decides what to do for the default action.
        // For most handlers (NotificationsService), clicking does nothing and the notification stays.
        // For ShareService, clicking opens the file but we still don't auto-remove here -
        // the notification gets replaced by the system when clicked.
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            return
        }
        
        // Remove the notification after handling an explicit action (button press)
        let id = response.notification.request.identifier
        un.removeDeliveredNotifications(withIdentifiers: [id])
    }
}

// MARK: - UNUserNotificationCenter Utilities

extension UNUserNotificationCenter {
    
    typealias NotificationId = String
    
    /// Checks if a notification with the given identifier has been delivered.
    /// - Parameters:
    ///   - id: The notification identifier to check.
    ///   - completion: Completion handler called with `true` if the notification exists.
    func containsDeliveredNotification(withId id: NotificationId, completion: @escaping (Bool) -> Void) {
        getDeliveredNotifications { notifications in
            let exists = notifications.contains { $0.request.identifier == id }
            completion(exists)
        }
    }
    
    /// Removes a notification (both pending and delivered) with the given identifier.
    /// - Parameter id: The notification identifier to remove.
    func removeNotification(withId id: NotificationId) {
        removePendingNotificationRequests(withIdentifiers: [id])
        removeDeliveredNotifications(withIdentifiers: [id])
    }
}
