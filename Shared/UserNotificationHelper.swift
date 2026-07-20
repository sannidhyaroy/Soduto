//
//  UserNotificationHelper.swift
//  Soduto
//
//  Created by Sannidhya Roy on 27/01/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import UserNotifications

public enum UserNotificationHelper {
    public static func show(title: String, subtitle: String? = nil, body: String, sound: Bool, id: String, urgency: UNMutableNotificationContent.NotificationUrgency = .active, threadIdentifier: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle {
            content.subtitle = subtitle
        }
        content.body = body
        content.sound = sound ? .default : nil
        content.setUrgency(urgency)
        if let threadIdentifier {
            content.threadIdentifier = threadIdentifier
        }
        
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        
        UNUserNotificationCenter.current().add(request)
    }
}
