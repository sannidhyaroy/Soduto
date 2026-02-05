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

// MARK: - Public Privacy Shorthand

/// Convenience extensions for `OSLogInterpolation` to reduce verbosity when logging
/// non-sensitive values that should not be redacted in release builds.
///
/// By default, os.Logger redacts interpolated values in release builds for privacy.
/// Use `pub:` label for values that are safe to log publicly.
///
/// ## Usage
/// ```swift
/// // Instead of:
/// Logger.device.debug("Device \(device.name, privacy: .public) on port \(port, privacy: .public)")
///
/// // Write:
/// Logger.device.debug("Device \(pub: device.name) on port \(pub: port)")
/// ```
///
/// ## When to use `pub:` vs default (redacted)
/// - **Use `pub:`**: Device names, packet types, connection states, ports, file names
/// - **Keep redacted**: Certificates, tokens, passwords, personal data
extension OSLogInterpolation {
    
    // MARK: Optimized paths for common conforming types
    
    /// Interpolate a CustomStringConvertible value as public (not redacted).
    mutating func appendInterpolation<T: CustomStringConvertible>(pub value: T) {
        appendInterpolation(value, privacy: .public)
    }
    
    /// Interpolate an optional CustomStringConvertible value as public.
    mutating func appendInterpolation<T: CustomStringConvertible>(pub value: T?) {
        if let value = value {
            appendInterpolation(value, privacy: .public)
        } else {
            appendInterpolation("nil", privacy: .public)
        }
    }
    
    /// Interpolate an Int as public.
    mutating func appendInterpolation(pub value: Int) {
        appendInterpolation(value, privacy: .public)
    }
    
    /// Interpolate a UInt as public.
    mutating func appendInterpolation(pub value: UInt) {
        appendInterpolation(value, privacy: .public)
    }
    
    /// Interpolate a UInt16 as public (commonly used for ports).
    mutating func appendInterpolation(pub value: UInt16) {
        appendInterpolation(value, privacy: .public)
    }
    
    /// Interpolate a Double as public.
    mutating func appendInterpolation(pub value: Double) {
        appendInterpolation(value, privacy: .public)
    }
    
    /// Interpolate a Bool as public.
    mutating func appendInterpolation(pub value: Bool) {
        appendInterpolation(value, privacy: .public)
    }
    
    // MARK: Fallback for non-conforming types
    
    /// Interpolate an Error as public.
    mutating func appendInterpolation(pub value: Error) {
        appendInterpolation(String(describing: value), privacy: .public)
    }
    
    /// Interpolate any non-CustomStringConvertible value as public.
    /// Falls back to String(describing:) for types without native os.Logger support.
    mutating func appendInterpolation<T>(pub value: T) {
        appendInterpolation(String(describing: value), privacy: .public)
    }
    
    /// Interpolate any optional non-CustomStringConvertible value as public.
    mutating func appendInterpolation<T>(pub value: T?) {
        if let value = value {
            appendInterpolation(String(describing: value), privacy: .public)
        } else {
            appendInterpolation("nil", privacy: .public)
        }
    }
}
