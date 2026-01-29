//
//  SharedUserDefaults.swift
//  Soduto
//
//  Created by Sannidhya Roy on 04/12/22.
//  Copyright © 2022 Soduto. All rights reserved.
//

import Foundation

enum AppDefaultsStore {
    
    // MARK: - Suite Instances
    
    static let appGroupDefaults: UserDefaults? = {
        let teamId = Bundle.main.object(forInfoDictionaryKey: "TeamIdentifierPrefix") as? String ?? ""
        return UserDefaults(suiteName: teamId + "com.soduto.Soduto")
    }()
    
    // MARK: - Share Extension Communication
    
    enum ShareExtension {
        static var reachableDevices: [[String: String]] {
            get { appGroupDefaults?.object(forKey: "com.soduto.share.reachableDevices") as? [[String: String]] ?? [] }
            set { appGroupDefaults?.set(newValue, forKey: "com.soduto.share.reachableDevices") }
        }
        
        static var selectedDevice: String? {
            get { appGroupDefaults?.string(forKey: "com.soduto.share.selectedDevice") }
            set { appGroupDefaults?.set(newValue, forKey: "com.soduto.share.selectedDevice") }
        }
        
        static var fileBookmarkData: Data? {
            get { appGroupDefaults?.data(forKey: "com.soduto.share.fileBookmarkData") }
            set { appGroupDefaults?.set(newValue, forKey: "com.soduto.share.fileBookmarkData") }
        }
    }
    
    
    // MARK: - User Preferences
    
    enum Preferences {
        static var disableSharePopUp: Bool {
            get { UserDefaults.standard.bool(forKey: "com.soduto.preferences.disablesharepopup") }
            set { UserDefaults.standard.set(newValue, forKey: "com.soduto.preferences.disablesharepopup") }
        }
        
        static var deviceType: Int {
            get { UserDefaults.standard.integer(forKey: "com.soduto.preferences.devicetype") }
            set { UserDefaults.standard.set(newValue, forKey: "com.soduto.preferences.devicetype") }
        }
    }
}
