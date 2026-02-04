//
//  Log.swift
//  Soduto Files
//
//  Created by Sannidhya Roy on 04/02/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import os

/// Logger categories for Soduto Files (SFTP browser) application.
///
/// Organized by architectural layers to enable filtering in Console.app.
///
/// ## Migration from CleanroomLogger to os.Logger
///
/// Log level mapping:
/// - `Log.verbose?.message(...)` → `Logger.xxx.debug(...)`
/// - `Log.debug?.message(...)` → `Logger.xxx.debug(...)`
/// - `Log.info?.message(...)` → `Logger.xxx.info(...)`
/// - `Log.warning?.message(...)` → `Logger.xxx.notice(...)`
/// - `Log.error?.message(...)` → `Logger.xxx.error(...)`
///
/// ## Categories
///
/// - `general`: App lifecycle (`AppDelegate.swift`)
/// - `filesystem`: SFTP operations, file handling
/// - `ui`: Browser UI, image loading
extension Logger {
    private static var subsystem = Bundle.main.bundleIdentifier!
    
    static let general = Logger(subsystem: subsystem, category: "general")
    static let filesystem = Logger(subsystem: subsystem, category: "filesystem")
    static let ui = Logger(subsystem: subsystem, category: "ui")
}
