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
    
    public static func handleAction(for response: UNNotificationResponse, context: UserNotificationContext) {
        
        guard let deviceId = response.notification.request.content.userInfo[deviceIdProperty] as? Device.Id else {
            fatalError("User info with device id property expected to be provided for pairing notification")
        }
        
        switch response.actionIdentifier {
        case "pair":
            context.deviceManager.device(withId: deviceId)?.acceptPairing()
        case "decline", UNNotificationDismissActionIdentifier:
            context.deviceManager.device(withId: deviceId)?.declinePairing()
        default:
            break
        }
    }
    
    public static func showPairingNotification(for device: Device) {
        let un = UNUserNotificationCenter.current()
        let notificationId = "com.soduto.pairinginterfacecontroller.device.\(device.id)"
        
        let notification = UNMutableNotificationContent()
        notification.userInfo = [
            deviceIdProperty: device.id,
            UserNotificationManager.Property.actionHandlerClass.rawValue: NSStringFromClass(PairingInterfaceController.self)
        ]
        notification.title = device.name
        notification.body = "Do you want to pair this device?"
        notification.sound = UNNotificationSound.default
        notification.categoryIdentifier = "PairDevice"
        
        let request = UNNotificationRequest(identifier: notificationId, content: notification, trigger: nil)
        un.add(request) { error in
            if let error = error {
                print(error.localizedDescription)
            }
        }
        
        _ = Timer.compatScheduledTimer(withTimeInterval: DefaultPairingHandler.pairingTimoutInterval, repeats: false) { _ in
            un.removeNotification(withId: notificationId)
        }
    }
    
}
