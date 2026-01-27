//
//  UNMutableNotificationContent+Urgency.swift
//  Soduto
//
//  Created by Sannidhya Roy on 27/01/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import UserNotifications

// MARK: - UNMutableNotificationContent Utilities

extension UNMutableNotificationContent {
    
    /// Notification urgency levels, mapped to `UNNotificationInterruptionLevel` on macOS 12.0+.
    /// On macOS 11.0, these have no effect since `interruptionLevel` is not available.
    public enum NotificationUrgency {
        /// Silent delivery - no sound, no screen wake. Use for background updates.
        case passive
        /// Normal notification behavior. Default level.
        case active
        /// May break through Focus modes. Use for calls, urgent messages.
        case timeSensitive
    }
    
    /// Sets the interruption level for the notification.
    /// On macOS 12.0+, this maps to `UNNotificationInterruptionLevel`.
    /// On earlier versions, this is a no-op.
    /// - Parameter urgency: The urgency level for the notification.
    public func setUrgency(_ urgency: NotificationUrgency) {
        if #available(macOS 12.0, *) {
            switch urgency {
            case .passive:
                self.interruptionLevel = .passive
            case .active:
                self.interruptionLevel = .active
            case .timeSensitive:
                self.interruptionLevel = .timeSensitive
            }
        }
        // On macOS 11.0, interruptionLevel is not available - no-op
    }
}
