//
//  SharedUserDefaults.swift
//  Soduto
//
//  Created by Sannidhya Roy on 04/12/22.
//  Copyright © 2022 Soduto. All rights reserved.
//

import Foundation

enum AppDefaultsStore {
    fileprivate static let base = "com.soduto"
    
    // MARK: - Suite Instances
    
    static let appGroupDefaults: UserDefaults? = {
        let teamId = Bundle.main.object(forInfoDictionaryKey: "TeamIdentifierPrefix") as? String ?? ""
        return UserDefaults(suiteName: teamId + "com.soduto.Soduto")
    }()
    
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
            
            enum Clipboard: ServiceToggle {
                static let base = "\(Services.base).clipboard"
            }
            
            enum Battery: ServiceToggle {
                static let base = "\(Services.base).battery"
            }
            
            enum SystemVolume: ServiceToggle {
                static let base = "\(Services.base).systemvolume"
            }
            
            enum Lock: ServiceToggle {
                static let base = "\(Services.base).lock"
            }
            
            enum Presenter: ServiceIncomingToggle {
                static let base = "\(Services.base).presenter"
            }
            
            enum Digitizer: ServiceIncomingToggle {
                static let base = "\(Services.base).digitizer"
            }
            
            enum Webcam: ServiceIncomingToggle {
                static let base = "\(Services.base).webcam"
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
