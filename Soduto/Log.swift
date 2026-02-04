//
//  Log.swift
//  Soduto
//
//  Created by Sannidhya Roy on 04/02/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import os

/// Logger categories for Soduto main application.
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
/// - `general`: App lifecycle, initialization (`AppDelegate.swift`)
/// - `network`: TCP/UDP sockets, transfers, network utilities
/// - `device`: Device lifecycle, pairing, reachability
/// - `config`: Settings, certificates, keychain operations
/// - `services`: Service-specific packet handling (all 13 services)
/// - `ui`: UI controllers and views
extension Logger {
    private static var subsystem = Bundle.main.bundleIdentifier!
    
    static let general = Logger(subsystem: subsystem, category: "general")
    static let network = Logger(subsystem: subsystem, category: "network")
    static let device = Logger(subsystem: subsystem, category: "device")
    static let config = Logger(subsystem: subsystem, category: "config")
    static let services = Logger(subsystem: subsystem, category: "services")
    static let ui = Logger(subsystem: subsystem, category: "ui")
}
