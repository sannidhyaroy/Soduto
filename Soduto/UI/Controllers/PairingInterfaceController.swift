//
//  PairingInterfaceController.swift
//  Soduto
//
//  Created by Giedrius Stanevičius on 2016-11-23.
//  Copyright © 2016 Soduto. All rights reserved.
//

import Foundation

/// Handles the pairing window UI entry points and updates.
public class PairingInterfaceController {
    
    /// Shows the pairing window for an incoming pairing request.
    /// - Parameter device: The device requesting to be paired.
    public static func showPairingWindow(for device: Device) {
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
