//
//  StatusBarImageProvider.swift
//  Soduto
//
//  Created by Sannidhya Roy on 07/03/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import AppKit

/// A service that contributes a status image fragment for a device's status bar menu item.
///
/// Services conforming to this protocol provide an `NSImage` representing their
/// current state for a given device (e.g., battery level, signal bars).
/// `StatusBarMenuController` composites these fragments left-to-right in
/// `statusBarImageSortOrder` order.
///
/// Conformance is opt-in: only services with visual status adopt this protocol.
public protocol StatusBarImageProvider: AnyObject {
    
    /// Sort order for horizontal compositing. Lower values appear further left.
    /// Connectivity = 0, Battery = 1 (matches phone UI convention).
    var statusBarImageSortOrder: Int { get }
    
    /// Returns a status image for the given device, or `nil` if no status data
    /// is available yet (e.g., no battery packet received).
    @MainActor
    func statusBarImage(for device: Device) -> NSImage?
}
