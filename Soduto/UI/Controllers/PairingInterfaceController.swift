//
//  PairingInterfaceController.swift
//  Soduto
//
//  Created by Giedrius Stanevičius on 2016-11-23.
//  Copyright © 2016 Soduto. All rights reserved.
//

import Foundation
import UserNotifications

public class PairingInterfaceController: UserNotificationActionHandler {
    
    private static let deviceIdProperty = "com.soduto.pairinginterfacecontroller.deviceId"
    
    public static func handleAction(for notification: NSUserNotification, context: UserNotificationContext) {
        
        guard let deviceId = notification.userInfo?[deviceIdProperty] as? Device.Id else {
            fatalError("User info with device id property expected to be provided for pairing notification")
        }
        
        switch notification.activationType {
        case .actionButtonClicked:
            context.deviceManager.device(withId: deviceId)?.acceptPairing()
            break
        default:
            context.deviceManager.device(withId: deviceId)?.declinePairing()
            break
        }
    }
    
    public static func showPairingNotification(for device: Device) {
        if #available(macOS 11.0, *) {
            let un = UNUserNotificationCenter.current()
            un.getNotificationSettings { (settings) in
                if settings.authorizationStatus == .authorized {
                    let notification = UNMutableNotificationContent()
                    let notificationId = "com.soduto.pairinginterfacecontroller.device.\(device.id)"
                    var userInfo = notification.userInfo
                    userInfo[deviceIdProperty] = device.id
                    notification.userInfo = userInfo
                    notification.title = device.name
                    notification.body = "Do you want to pair this device?"
                    notification.sound = UNNotificationSound.default()
                    notification.categoryIdentifier = "PairDevice"
                    let pair = UNNotificationAction(identifier: "pair", title: "Pair")
                    let decline = UNNotificationAction(identifier: "decline", title: "Decline")
                    let category = UNNotificationCategory(identifier: "PairDevice", actions: [pair, decline], intentIdentifiers: [], options: [])
                    let request = UNNotificationRequest(identifier: notificationId, content: notification, trigger: nil)
                    un.setNotificationCategories([category])
                    un.add(request){ (error) in
                        if error != nil {print(error?.localizedDescription as Any)}
                    }
                    _ = Timer.compatScheduledTimer(withTimeInterval: DefaultPairingHandler.pairingTimoutInterval, repeats: false) { _ in
                        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notificationId])
                    }
                }
            }
        } else {
            let notification = NSUserNotification(actionHandlerClass: PairingInterfaceController.self)
            var userInfo = notification.userInfo
            userInfo?[deviceIdProperty] = device.id
            notification.userInfo = userInfo
            notification.title = device.name
            notification.informativeText = "Do you want to pair this device?"
            notification.soundName = NSUserNotificationDefaultSoundName
            notification.hasActionButton = true
            notification.actionButtonTitle = "Pair"
            notification.otherButtonTitle = "Decline"
            notification.identifier = "com.soduto.pairinginterfacecontroller.device.\(device.id)"
            NSUserNotificationCenter.default.scheduleNotification(notification)
            
            _ = Timer.compatScheduledTimer(withTimeInterval: DefaultPairingHandler.pairingTimoutInterval, repeats: false) { _ in
                NSUserNotificationCenter.default.removeDeliveredNotification(notification)
            }
        }
    }
    
}
