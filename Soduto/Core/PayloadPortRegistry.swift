//
//  PayloadPortRegistry.swift
//  Soduto
//
//  Created by Sannidhya Roy on 17/02/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import Foundation

/// Centralized registry for managing payload transfer ports.
///
/// This class tracks which ports in the payload port range (1739-1764) are currently
/// in use by upload tasks. It provides thread-safe access to port state and posts
/// notifications when ports become available.
public final class PayloadPortRegistry {
    
    // MARK: - Notification
    
    /// Posted when a port is released and becomes available for use.
    /// The notification object is the port number as `AnyObject`.
    public static let portReleaseNotification = Notification.Name(rawValue: "com.soduto.uploadTask.portReleasedNotification")
    
    // MARK: - Private State
    
    private static var usedPorts: [UInt16] = []
    private static let lock = NSLock()
    
    // MARK: - Public API
    
    /// Returns `true` if any ports are currently in use.
    public static func hasUsedPorts() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !usedPorts.isEmpty
    }
    
    /// Returns `true` if the specified port is currently in use.
    public static func isPortUsed(_ port: UInt16) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return usedPorts.contains(port)
    }
    
    /// Marks a port as in use.
    ///
    /// - Precondition: The port must not already be in use.
    public static func usePort(_ port: UInt16) {
        lock.lock()
        defer { lock.unlock() }
        assert(!usedPorts.contains(port), "Port \(port) is already in use")
        usedPorts.append(port)
    }
    
    /// Releases a port, making it available for future use.
    ///
    /// Posts `portReleaseNotification` on the main queue after releasing.
    ///
    /// - Precondition: The port must currently be in use.
    public static func releasePort(_ port: UInt16) {
        lock.lock()
        let removed: Bool
        if let index = usedPorts.firstIndex(of: port) {
            usedPorts.remove(at: index)
            removed = true
        } else {
            removed = false
        }
        lock.unlock()
        
        if removed {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: portReleaseNotification, object: port as AnyObject)
            }
        } else {
            assertionFailure("Could not release port (\(port)) which was not being used.")
        }
    }
}
