//
//  SharedUserDefaults.swift
//  Soduto
//
//  Created by Sannidhya Roy on 04/12/22.
//  Copyright © 2022 Soduto. All rights reserved.
//

import Foundation

enum AppDefaultsStore {
    // MARK: - Bundle Identity
    
    // Extension bundle identifiers must use the main app's bundle identifier as a prefix
    // (e.g. "com.example.App.Share"). The last dot-component is stripped when running inside
    // an extension (.appex) to recover the host app's identifier.
    static let mainBundleId: String = {
        var id = Bundle.main.bundleIdentifier!
        if Bundle.main.bundleURL.pathExtension == "appex" {
            id = id.components(separatedBy: ".").dropLast().joined(separator: ".")
        }
        return id
    }()
    
    // Reverse-DNS domain prefix (everything before the final app-name component).
    // e.g. "com.example.App" → "com.example". Used as the root namespace for all stored keys
    // so that forks with different bundle IDs get their own isolated key space automatically.
    fileprivate static let base: String = mainBundleId.components(separatedBy: ".").dropLast().joined(separator: ".")
    
    // MARK: - Suite Instances
    
    static let appGroupDefaults: UserDefaults? = {
        guard let teamId = Bundle.main.object(forInfoDictionaryKey: "TeamIdentifierPrefix") as? String else {
            return nil
        }
        return UserDefaults(suiteName: teamId + mainBundleId)
    }()
    
    // MARK: - Darwin Notification Names (cross-process: main app ↔ Share Extension)
    
    enum DarwinNotifications {
        static let shareHandoff = mainBundleId + ".share.handoff"
        static let shareStatus  = mainBundleId + ".share.status"
    }
    
    // MARK: - Share Extension Communication
    
    enum ShareExtension {
        fileprivate static let base = "\(AppDefaultsStore.base).share"
        
        /// Timestamp (timeIntervalSince1970) of the last heartbeat from the main app
        /// Written periodically by the main app; read by the extension to detect crashes
        static var appLastHeartbeat: TimeInterval {
            get { appGroupDefaults?.double(forKey: "\(base).appLastHeartbeat") ?? 0 }
            set { appGroupDefaults?.set(newValue, forKey: "\(base).appLastHeartbeat") }
        }
        
        static var reachableDevices: [[String: String]] {
            get { appGroupDefaults?.object(forKey: "\(base).reachableDevices") as? [[String: String]] ?? [] }
            set { appGroupDefaults?.set(newValue, forKey: "\(base).reachableDevices") }
        }
        
        static var selectedDevice: String? {
            get { appGroupDefaults?.string(forKey: "\(base).selectedDevice") }
            set { appGroupDefaults?.set(newValue, forKey: "\(base).selectedDevice") }
        }
        
        static var fileBookmarkData: [Data]? {
            get { appGroupDefaults?.array(forKey: "\(base).fileBookmarkData") as? [Data] }
            set { appGroupDefaults?.set(newValue, forKey: "\(base).fileBookmarkData") }
        }
        
        static var sharedTexts: [String]? {
            get { appGroupDefaults?.stringArray(forKey: "\(base).sharedTexts") }
            set { appGroupDefaults?.set(newValue, forKey: "\(base).sharedTexts") }
        }
        
        /// Transfer status per device for the current share session
        /// Maps device ID -> status: "success", "failed". Written by main app, read by extension
        static var transferStatuses: [String: String]? {
            get { appGroupDefaults?.dictionary(forKey: "\(base).transferStatuses") as? [String: String] }
            set { appGroupDefaults?.set(newValue, forKey: "\(base).transferStatuses") }
        }
    }
    
    
    // MARK: - User Preferences
    
    enum Preferences {
        fileprivate static let base = "\(AppDefaultsStore.base).preferences"
        
        static var disableSharePopUp: Bool {
            get { UserDefaults.standard.bool(forKey: "\(base).disablesharepopup") }
            set { UserDefaults.standard.set(newValue, forKey: "\(base).disablesharepopup") }
        }
        
        static var deviceType: Int {
            get { UserDefaults.standard.integer(forKey: "\(base).devicetype") }
            set { UserDefaults.standard.set(newValue, forKey: "\(base).devicetype") }
        }
        
        // MARK: Service Enable/Disable
        
        enum Services {
            fileprivate static let base = "\(Preferences.base).services"
            
            enum Battery: ServiceToggle {
                static let base = "\(Services.base).battery"
            }
            
            enum Clipboard: ServiceToggle {
                static let base = "\(Services.base).clipboard"
            }
            
            enum Contacts: ServiceIncomingToggle {
                static let base = "\(Services.base).contacts"
            }
            
            enum Digitizer: ServiceIncomingToggle {
                static let base = "\(Services.base).digitizer"
            }
            
            enum FindMy: ServiceToggle {
                static let base = "\(Services.base).findmy"
            }
            
            enum Lock: ServiceToggle {
                static let base = "\(Services.base).lock"
            }
            
            enum MousePad: ServiceIncomingToggle {
                static let base = "\(Services.base).mousepad"
            }
            
            enum Presenter: ServiceIncomingToggle {
                static let base = "\(Services.base).presenter"
            }
            
            enum RemoteControl: ServiceOutgoingToggle {
                static let base = "\(Services.base).remotecontrol"
            }
            
            enum RunCommand: ServiceToggle {
                static let base = "\(Services.base).runcommand"
                static let commandsKey = "\(base).commands"
            }
            
            enum SMS: ServiceIncomingToggle {
                static let base = "\(Services.base).sms"
            }
            
            enum SystemVolume: ServiceToggle {
                static let base = "\(Services.base).systemvolume"
            }
            
            enum Webcam: ServiceIncomingToggle {
                static let base = "\(Services.base).webcam"
                static let fpsKey = "\(base).fps"
                static let bitrateKey = "\(base).bitrateBps"
            }
        }
    }
}


// MARK: - Service Preference Helpers

/// A service that can receive data from a remote device (incoming direction)
protocol ServiceIncomingToggle {
    /// Namespace prefix for this service, e.g. "com.soduto.preferences.services.clipboard"
    static var base: String { get }
}
extension ServiceIncomingToggle {
    static var incomingKey: String { "\(base).incoming" }
    static var incomingEnabled: Bool {
        get { UserDefaults.standard.serviceBool(incomingKey) }
        set { UserDefaults.standard.set(newValue, forKey: incomingKey) }
    }
}

/// A service that can send data to a remote device (outgoing direction)
protocol ServiceOutgoingToggle {
    /// Namespace prefix for this service, e.g. "com.soduto.preferences.services.clipboard"
    static var base: String { get }
}
extension ServiceOutgoingToggle {
    static var outgoingKey: String { "\(base).outgoing" }
    static var outgoingEnabled: Bool {
        get { UserDefaults.standard.serviceBool(outgoingKey) }
        set { UserDefaults.standard.set(newValue, forKey: outgoingKey) }
    }
}

/// Convenience alias for services with both directions
typealias ServiceToggle = ServiceIncomingToggle & ServiceOutgoingToggle

extension UserDefaults {
    /// Reads a Bool preference that defaults to `true` when not yet set
    func serviceBool(_ key: String) -> Bool { object(forKey: key) as? Bool ?? true }
}
