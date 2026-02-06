//
//  Logger+Categories.swift
//  Soduto Share
//
//  Created by Sannidhya Roy on 07/02/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import os

/// Logger categories for Soduto Share extension.
///
/// Organized by functional areas to enable filtering in Console.app.
///
/// ## Categories
///
/// - `general`: Extension lifecycle, initialization, app communication
/// - `sharing`: Share operations (loading items, bookmarks, transfers)
/// - `ui`: UI controllers, views, TouchBar
extension Logger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.soduto.Soduto.Soduto-Share"

    static let general = Logger(subsystem: subsystem, category: "general")
    static let sharing = Logger(subsystem: subsystem, category: "sharing")
    static let ui = Logger(subsystem: subsystem, category: "ui")
}
