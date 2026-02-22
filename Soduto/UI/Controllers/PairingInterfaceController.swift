//
//  PairingInterfaceController.swift
//  Soduto
//
//  Created by Giedrius Stanevičius on 2016-11-23.
//  Copyright © 2016 Soduto. All rights reserved.
//

import Foundation
import UserNotifications

/// Handles the pairing notification UI and user responses.
public class PairingInterfaceController: UserNotificationActionHandler {
    
    private static let deviceIdProperty = "com.soduto.pairinginterfacecontroller.deviceId"
    
    /// Handles user responses to pairing notifications.
    ///
    /// Supports the following actions:
    /// - **pair**: Accepts the pairing request from the device
    /// - **decline**: Declines the pairing request from the device
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
    
    /// Shows the pairing window for an incoming pairing request.
    /// - Parameter device: The device requesting to be paired.
    public static func showPairingNotification(for device: Device) {
        DispatchQueue.main.async {
            PairingWindowController.showIncomingRequest(for: device)
        }
    }
    
    /// Updates the pairing window state for a device.
    /// Call this when pairing succeeds or fails.
    public static func updatePairingUI(for deviceId: Device.Id, success: Bool) {
        DispatchQueue.main.async {
            if success {
                PairingWindowController.updateState(for: deviceId, state: .success)
            } else {
                // Close immediately on failure - the device will handle status reset
                PairingWindowController.close(for: deviceId)
            }
        }
    }
    
}
